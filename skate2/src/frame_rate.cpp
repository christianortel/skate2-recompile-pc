#include "frame_rate.h"

#include <rex/cvar.h>
#include <rex/cvar_validation.h>
#include <rex/logging.h>
#include <rex/system.h>

#include <charconv>
#include <mutex>
#include <string>

REXCVAR_DEFINE_STRING(skate2_frame_rate, "original", "Skate 2",
    "Frame-rate mode: original, 60, 120, 144, 165, 200, 240, or unlimited. "
    "Higher rates and unlimited are experimental; actual FPS depends on the scene and hardware. "
    "Optional modes require guest VSync; conflicting live changes are rejected. "
    "Restart required. Original resets saved guest refresh to 60 Hz; an explicit command-line "
    "or environment video_mode_refresh_rate override is preserved. Unlimited uses 60 Hz guest refresh.")
    .allowed({"original", "60", "120", "144", "165", "200", "240", "unlimited"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace {

struct FrameRateSettings {
  // Zero means leave the original loaded register untouched. The game's
  // immediate-present selector is 0x80000000, not zero (zero maps to interval 1).
  uint64_t interval_override = 0;
  std::string mode;
  std::string error;
};

// Published once on the startup thread before guest/GPU threads are created.
// The pointed-to settings never change; the hook has no locks or registry work.
const FrameRateSettings* configured_settings = nullptr;

bool RequireGuestVsync(std::string_view value) {
  if (rex::string::from_string<bool>(value, false)) return true;
  // This runs under the registry lock, before publishing the attempted value.
  // Log the reason without opening a modal dialog or changing another flag.
  REXLOG_WARN("VSync change rejected: the active Skate 2 frame-rate mode requires vsync=true. "
              "Select original mode, save, and restart before disabling guest VSync.");
  return false;
}

FrameRateSettings MakeSettings() {
  FrameRateSettings settings;
  settings.mode = rex::cvar::GetFlagByName("skate2_frame_rate");
  const bool original = settings.mode == "original";
  const bool unlimited = settings.mode == "unlimited";
  int refresh = 60;
  if (!original && !unlimited) {
    const auto [end, error] = std::from_chars(
        settings.mode.data(), settings.mode.data() + settings.mode.size(), refresh);
    if (error != std::errc{} || end != settings.mode.data() + settings.mode.size() ||
        (refresh != 60 && refresh != 120 && refresh != 144 && refresh != 165 &&
         refresh != 200 && refresh != 240)) {
      settings.error = "Unknown Skate 2 frame-rate mode. Choose original, 60, 120, 144, 165, 200, 240, or unlimited.";
      return settings;
    }
  }

  if (!rex::cvar::GetFlagInfo("video_mode_refresh_rate")) {
    settings.error = "The runtime did not register video_mode_refresh_rate; frame-rate setup cannot continue.";
    return settings;
  }

  const auto refresh_source = rex::cvar::GetFlagSource("video_mode_refresh_rate");
  const bool independent_refresh = refresh_source == rex::cvar::Source::kCommandLine ||
      refresh_source == rex::cvar::Source::kEnvironment ||
      refresh_source == rex::cvar::Source::kRuntime;
  const double previous_refresh = rex::cvar::Query<double>("video_mode_refresh_rate");

  // SaveConfig serializes the effective refresh alongside the selected mode.
  // A later switch back to original must not inherit a previous mode's 120+ Hz.
  // A config-file value has no provenance to distinguish it from that stale
  // value, so independent original-mode overrides must be explicit at startup.
  if (!(original && independent_refresh)) {
    if (previous_refresh != refresh) {
      if (!rex::cvar::SetFlagByName("video_mode_refresh_rate", std::to_string(refresh))) {
        settings.error = "The runtime rejected the guest refresh rate for the selected Skate 2 mode.";
        return settings;
      }
      REXLOG_INFO("Skate 2 frame-rate mode {}: guest refresh {} -> {} Hz", settings.mode,
                  previous_refresh, refresh);
    }
  } else if (previous_refresh != 60.0) {
    REXLOG_WARN("Skate 2 original mode preserves explicit guest refresh {} Hz; this differs from the original 60 Hz display mode.",
                previous_refresh);
  }

  if (unlimited) {
    settings.interval_override = UINT64_C(0x80000000);
  } else if (!original) {
    settings.interval_override = 1;
  }
  REXLOG_INFO("Skate 2 frame-rate mode: {} (guest refresh {} Hz; clocks unchanged)",
              settings.mode, rex::cvar::GetFlagByName("video_mode_refresh_rate"));
  if (!original) {
    REXLOG_WARN("Skate 2 mode {} is experimental: higher-rate simulation, replay, animation and audio timing remain under validation.",
                settings.mode);
  }
  return settings;
}

}  // namespace

void ConfigureSkate2FrameRate() {
  static std::once_flag configured;
  std::call_once(configured, [] {
    static const FrameRateSettings settings = MakeSettings();
    configured_settings = &settings;
    // This is initial setup, before the first presentation/runtime creation.
    // All current settings take effect now; a programmatic refresh adjustment
    // must not leave a misleading "restart required" notice on this fresh run.
    rex::cvar::ClearPendingRestartFlags();
  });
}

bool ValidateSkate2FrameRate() {
  std::string error;
  if (!configured_settings) {
    error = "Skate 2 frame-rate settings were not initialized.";
  } else {
    error = configured_settings->error;
    if (error.empty() && configured_settings->interval_override != 0) {
      if (!rex::cvar::GetFlagInfo("vsync") || !rex::cvar::Query<bool>("vsync")) {
        error = "The selected Skate 2 frame-rate mode requires vsync=true. "
                "This runtime setting controls guest vblank timing, not just monitor presentation. "
                "Enable it and restart, or select original mode.";
      } else {
        // Install once while startup still owns settings. The decision uses the
        // immutable active mode, not a new selection awaiting its next restart.
        static const bool guarded = rex::cvar::SetFlagValidator("vsync", RequireGuestVsync);
        if (!guarded) {
          error = "The runtime could not protect guest VSync for the selected Skate 2 frame-rate mode.";
        } else if (rex::cvar::Query<bool>("clock_no_scaling") ||
                   rex::cvar::Query<bool>("clock_source_raw")) {
          REXLOG_WARN("Experimental Skate 2 frame-rate mode is combined with nondefault clock options. "
                      "Clock options are unchanged; this combination has not been validated.");
        }
      }
    }
  }
  if (error.empty()) return true;
  REXLOG_ERROR("{}", error);
  rex::ShowSimpleMessageBox(rex::SimpleMessageBoxType::Error, error);
  return false;
}

void Skate2PresentationInterval(PPCRegister& r11) {
  if (configured_settings && configured_settings->interval_override != 0) {
    r11.u64 = configured_settings->interval_override;
  }
}
