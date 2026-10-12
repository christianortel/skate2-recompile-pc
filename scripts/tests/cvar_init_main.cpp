#include <rex/cvar.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

// This app-owned flag is registered before Init, as in the real executable.
// Runtime and late GPU flags below come from the actual installed DLLs.
REXCVAR_DEFINE_STRING(skate2_frame_rate, "original", "Fixture", "startup mode");

static int checks = 0;
static int failures = 0;
static void Check(bool pass, const char* label) {
  ++checks;
  if (!pass) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", label);
  }
}

static std::filesystem::path ModulePath(HMODULE module) {
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(module, path.data(), DWORD(path.size()));
  if (!length || length >= path.size()) return {};
  path.resize(length);
  return path;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 4) return 2;
  const std::wstring case_arg = argv[1];
  const std::string test_case(case_arg.begin(), case_arg.end());
  const std::filesystem::path sdk_bin = argv[2];
  const std::filesystem::path report = argv[3];
  const bool capture = test_case == "explicit-capture";
  const bool omitted = test_case == "omitted-capture-saved-config";
  const bool broken = test_case == "trailing-empty-control";
  if (!capture && !omitted && !broken) return 2;

  Check(std::filesystem::equivalent(ModulePath(GetModuleHandleW(L"rexruntime.dll")),
                                    sdk_bin / "rexruntime.dll"),
        "using the installed actual runtime DLL");
  Check(rex::cvar::GetFlagInfo("perf_log_csv") != nullptr,
        "capture flag supplied by runtime before Init");
  Check(rex::cvar::GetFlagInfo("async_shader_compilation") == nullptr &&
            rex::cvar::GetFlagInfo("d3d12_present_idleclean_sync") == nullptr &&
            rex::cvar::GetFlagInfo("draw_resolution_scale_x") == nullptr,
        "GPU flags are genuinely unregistered before Init");

  std::vector<std::string> arguments = {
      "cvar-init", "--skate2_frame_rate=unlimited", "--async_shader_compilation=false",
      "--d3d12_present_idleclean_sync=true", "--resolution_scale=1",
      "--draw_resolution_scale_x=2", "--draw_resolution_scale_y=2"};
  if (capture) arguments.emplace_back("--perf_log_csv=explicit-capture.csv");
  if (broken) arguments.emplace_back("--perf_log_csv=");
  std::vector<char*> pointers;
  for (auto& argument : arguments) pointers.push_back(argument.data());
  rex::cvar::Init(static_cast<int>(pointers.size()), pointers.data());

  if (!broken) {
    const auto config = report / "saved-settings.toml";
    std::ofstream(config) << "perf_log_csv = \"saved-capture.csv\"\n"
                            "skate2_frame_rate = \"60\"\n";
    rex::cvar::LoadConfig(config);
  }

  const auto frame_source = rex::cvar::GetFlagSource("skate2_frame_rate");
  const auto capture_source = rex::cvar::GetFlagSource("perf_log_csv");
  Check(rex::cvar::GetFlagByName("skate2_frame_rate") == (broken ? "original" : "unlimited"),
        "known frame callback applied only for valid CLI");
  Check(frame_source == (broken ? rex::cvar::Source::kDefault : rex::cvar::Source::kCommandLine),
        "known frame source records the actual callback outcome");
  const std::string expected_capture = capture ? "explicit-capture.csv"
      : omitted ? "saved-capture.csv" : "";
  Check(rex::cvar::GetFlagByName("perf_log_csv") == expected_capture,
        "capture path follows valid CLI or saved configuration");
  Check(capture_source == (capture ? rex::cvar::Source::kCommandLine
      : omitted ? rex::cvar::Source::kConfig : rex::cvar::Source::kDefault),
        "saved capture remains config-source so the app guard ignores it");

  // Load registrations only. Never call the plugin factory or initialize GPU,
  // audio, guest memory, game files, or a window.
  const HMODULE gpu = LoadLibraryW((sdk_bin / "rexgpu-xenos.dll").c_str());
  Check(gpu != nullptr, "actual installed GPU plugin loaded for late registrations");
  if (gpu) {
    Check(std::filesystem::equivalent(ModulePath(gpu), sdk_bin / "rexgpu-xenos.dll"),
          "using the installed actual GPU plugin DLL");
    for (const auto* name : {"async_shader_compilation", "d3d12_present_idleclean_sync",
                             "resolution_scale", "draw_resolution_scale_x", "draw_resolution_scale_y"}) {
      Check(rex::cvar::GetFlagInfo(name) != nullptr, "real late GPU flag registered");
      Check(rex::cvar::GetFlagSource(name) == rex::cvar::Source::kCommandLine,
            "real late GPU flag consumed pending command-line source");
    }
    Check(rex::cvar::GetFlagByName("async_shader_compilation") == "false",
          "late synchronous-shader choice applied even in broken control");
    Check(rex::cvar::GetFlagByName("d3d12_present_idleclean_sync") == "true",
          "late idle-clean choice applied even in broken control");
    Check(rex::cvar::GetFlagByName("resolution_scale") == "1" &&
              rex::cvar::GetFlagByName("draw_resolution_scale_x") == "2" &&
              rex::cvar::GetFlagByName("draw_resolution_scale_y") == "2",
          "late render-scale values applied even in broken control");
  }
  std::printf("{\"case\":\"%s\",\"checks\":%d,\"failures\":%d,\"pass\":%s,"
              "\"frameMode\":\"%s\",\"frameSource\":%d,\"captureSource\":%d}\n",
              test_case.c_str(), checks, failures, failures ? "false" : "true",
              rex::cvar::GetFlagByName("skate2_frame_rate").c_str(),
              int(frame_source), int(capture_source));
  std::fflush(stdout);
  return failures ? 1 : 0;
}
