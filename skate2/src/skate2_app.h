// Skate 2 development application. Runtime and gameplay remain under validation.

#pragma once

#include "crash_diagnostics.h"
#include "automatic_gpu_selection.h"
#include "frame_pacing.h"
#include "frame_rate.h"
#include "nvidia_profile.h"
#include "settings_panel.h"

#include <rex/rex_app.h>
#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/input/input_system.h>
#include <rex/logging.h>
#include <rex/perf/counter.h>
#include <rex/system.h>
#include <rex/ui/keybinds.h>

#include <memory>
#include <string>
#include <string_view>
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
                            "skate2_frame_limit", "skate2_nvidia_max_performance",
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
    // Values in effect for this run are final now; the panel compares against
    // them for its restart notices.
    if (settings_panel_) settings_panel_->Start();
  }

  void OnConfigureFonts(ImFontAtlas* atlas) override {
    Skate2SettingsPanel::ConfigureFonts(atlas);
  }

  void OnCreateDialogs(rex::ui::ImGuiDrawer* drawer) override {
    settings_panel_ =
        std::make_unique<Skate2SettingsPanel>(app_context(), drawer, skate2_config_path_);
    // F1 is free: the SDK overlays use F3, F4, F7 and Backtick.
    rex::ui::RegisterBind("bind_skate2_settings", "F1", "Toggle Skate 2 settings panel", [this] {
      if (settings_panel_) settings_panel_->Toggle();
    });
  }

  void OnPostSetup() override {
    // ConstructRuntime has just installed the SDK's input gate, which only
    // knows the SDK overlays. Replace it with the same rule plus the Skate 2
    // panel: while any overlay is drawn, game input pauses whenever ImGui
    // wants the mouse; while the panel is open (or its controller shortcut is
    // held), game input pauses entirely.
    auto* input = runtime() ? static_cast<rex::input::InputSystem*>(runtime()->input_system())
                            : nullptr;
    if (!input || !imgui_drawer()) return;
    input->SetActiveCallback([this]() {
      if (Skate2SettingsPanel::BlocksGameInput()) return false;
      auto* drawer = imgui_drawer();
      if (!drawer || !drawer->HasDialogs()) return true;
      return !drawer->GetIO().WantCaptureMouse;
    });
  }

  void OnShutdown() override {
    rex::ui::UnregisterBind("bind_skate2_settings");
    settings_panel_.reset();
  }

  bool SetupPresentation() override {
    // Before the adapter probe below loads the display driver, so the driver
    // reads an updated application profile in this run.
    ApplySkate2NvidiaProfile();
    AutomaticGpuSelection automatic_gpu;
    if (!rex::ReXApp::SetupPresentation()) return false;
    // The GPU plugin has now registered its flags, but guest GPU setup has not
    // run yet, so these defaults still take effect in this run.
    ApplyProfileDefaults();
    if (!ValidateSkate2FrameRate()) return false;
    if (!ConfigureSkate2FrameLimit(window() ? window()->GetNativeWindowHandle() : nullptr)) {
      return false;
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
    skate2_config_path_ = paths.config_path;
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
  // The default launch profile: 2x rendering on the ROV path with the graphics
  // synchronization settings (the unlimited frame-rate mode is the registered
  // default of skate2_frame_rate). The launchers pass none of these unless a
  // profile or option asks for another value, so a value saved in skate2.toml
  // applies; these apply when nothing is saved, also for a direct skate2.exe
  // launch.
  //
  // They become the registered defaults rather than values set at startup:
  // Save to config (F4 and the F1 panel) writes only settings that differ from
  // the registered default. Otherwise a saved 1x would be left out of the file
  // as the runtime's default, and 2x would apply again at the next start; and
  // an unchanged profile value would be written and then pinned.
  static void ApplyProfileDefaults() {
    struct ProfileDefault {
      std::string_view name;
      std::string_view value;  // As the setting's getter formats it.
    };
    static constexpr ProfileDefault kDefaults[] = {
        {"draw_resolution_scale_x", "2"},
        {"draw_resolution_scale_y", "2"},
        {"render_target_path_d3d12", "rov"},
        {"async_shader_compilation", "false"},
        {"d3d12_present_idleclean_sync", "true"},
    };
    // The registry has no call to change a default, so its entries are
    // updated directly, as the runtime's settings overlay also reads them.
    // This runs on the UI thread before the runtime and its threads exist.
    for (auto& entry : rex::cvar::GetRegistry()) {
      for (const auto& profile : kDefaults) {
        if (entry.name != profile.name) continue;
        entry.default_value = std::string(profile.value);
        // Config, environment and command-line values keep precedence.
        const bool use_default = entry.source == rex::cvar::Source::kDefault;
        if (!use_default) {
          REXLOG_INFO("Skate 2 profile default {}={}: saved or launch value {} applies",
                      profile.name, profile.value, entry.getter());
        } else if (entry.setter(profile.value)) {
          REXLOG_INFO("Skate 2 profile default {}={}: applied", profile.name, profile.value);
        } else {
          REXLOG_WARN("Skate 2 profile default {}={} was rejected", profile.name, profile.value);
        }
      }
    }
  }

  bool performance_capture_started_ = false;
  std::filesystem::path skate2_config_path_;
  std::unique_ptr<Skate2SettingsPanel> settings_panel_;
};
