// Skate 2 development application. Runtime and gameplay remain under validation.

#pragma once

#include "crash_diagnostics.h"
#include "automatic_gpu_selection.h"
#include "frame_rate.h"

#include <rex/rex_app.h>
#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/perf/counter.h>
#include <rex/system.h>

#include <system_error>

class Skate2App : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    InstallCrashDiagnostics();
    return std::unique_ptr<Skate2App>(new Skate2App(ctx, "skate2",
        PPCImageConfig));
  }

 protected:
  void OnPreLaunchModule() override {
    // Record effective values after GPU-plugin registration for reproducible
    // graphics comparisons. This reads settings once, outside the frame loop.
    for (const auto* flag : {"async_shader_compilation", "readback_resolve",
                            "readback_memexport", "readback_memexport_fast",
                            "clear_memory_page_state", "render_target_path_d3d12",
                            "vsync", "video_mode_refresh_rate",
                            "d3d12_present_idleclean_sync", "skate2_frame_rate",
                            "resolution_scale", "draw_resolution_scale_x",
                            "draw_resolution_scale_y"}) {
      REXLOG_INFO("Graphics setting {}={}", flag, rex::cvar::GetFlagByName(flag));
    }
    // The SDK exposes per-frame CSV counters but does not open the configured
    // output itself. Set it once before guest rendering begins. The writer
    // flushes every 60 rows; the SDK's hard-exit path may drop the final tail.
    const auto performance_path = rex::cvar::GetFlagByName("perf_log_csv");
    // A path saved by F4 must never cause an old capture to be overwritten on
    // the next ordinary launch. Capture is an explicit command-line action.
    if (!performance_capture_started_ && !performance_path.empty() &&
        rex::cvar::GetFlagSource("perf_log_csv") == rex::cvar::Source::kCommandLine) {
#ifdef REXGLUE_ENABLE_PERF_COUNTERS
      rex::perf::SetCsvLogPath(performance_path);
#else
      REXLOG_WARN("Frame capture requested, but this SDK was built without Release performance counters.");
#endif
      performance_capture_started_ = true;
    }
  }

  bool SetupPresentation() override {
    AutomaticGpuSelection automatic_gpu;
    if (!rex::ReXApp::SetupPresentation()) return false;
    if (!ValidateSkate2FrameRate()) return false;
    // The GPU plugin has now registered its flags, but guest GPU setup has not
    // run yet. Give direct EXE launches the same rendering path as the launcher.
    if (rex::cvar::GetFlagInfo("render_target_path_d3d12") &&
        rex::cvar::GetFlagSource("render_target_path_d3d12") == rex::cvar::Source::kDefault) {
      rex::cvar::SetFlagByName("render_target_path_d3d12", "rov");
    }
    return true;
  }

  void OnPreSetup(rex::RuntimeConfig& config) override {
    ConfigureSkate2FrameRate();
    if (config.gpu_plugin.empty()) config.gpu_plugin = "xenos";
    // Retain the SDK's default SDL input factory for gamepad support.
  }

  void OnConfigurePaths(rex::PathConfig& paths) override {
    namespace fs = std::filesystem;
    const auto exe_dir = rex::filesystem::GetExecutableFolder();
    auto app_root = exe_dir;
    // Support a developer build below skate2/out/build and a portable game/.
    for (auto candidate = exe_dir; !candidate.empty();) {
      std::error_code error;
      if (fs::is_regular_file(candidate / "skate2_manifest.toml", error) ||
          fs::is_regular_file(candidate / "game" / "default.xex", error)) {
        app_root = candidate;
        break;
      }
      if (candidate == candidate.root_path()) break;
      candidate = candidate.parent_path();
    }
    if (paths.game_data_root.empty()) {
      std::error_code error;
      const auto packaged_game = app_root / "game";
      if (fs::is_directory(packaged_game, error)) {
        paths.game_data_root = packaged_game;
      } else {
        paths.game_data_root = app_root.parent_path() / "game";
      }
    }
    if (REXCVAR_GET(user_data_root).empty()) paths.user_data_root = app_root / "userdata";
    if (REXCVAR_GET(cache_root).empty()) paths.cache_root = app_root / "cache";
    paths.config_path = app_root / "skate2.toml";
  }

  bool SetupEnvironment() override {
    if (!rex::ReXApp::SetupEnvironment()) return false;
    std::error_code error;
    if (!std::filesystem::is_regular_file(game_data_root() / "default.xex", error) ||
        !std::filesystem::is_directory(game_data_root() / "data", error)) {
      rex::ShowSimpleMessageBox(rex::SimpleMessageBoxType::Error,
          "Skate 2 game files are missing. Expected default.xex and the data folder in:\n" +
          game_data_root().string() +
          "\n\nUse Launch Skate 2.cmd or place your extracted game in the game folder.");
      return false;
    }
    return true;
  }
 private:
  bool performance_capture_started_ = false;
};
