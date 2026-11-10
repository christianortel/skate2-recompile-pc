#include "frame_pacing.h"

#include <rex/cvar.h>
#include <rex/cvar_validation.h>
#include <rex/logging.h>
#include <rex/system.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <timeapi.h>
#endif

REXCVAR_DEFINE_STRING(skate2_frame_limit, "off", "Skate 2",
    "Frame limiter: off, auto, or a frame rate from 20 to 1000. Paces each game frame on an "
    "absolute schedule so frames arrive evenly. auto targets slightly below the refresh rate of "
    "the monitor showing the game, for G-Sync/FreeSync displays. Most useful with "
    "skate2_frame_rate=unlimited. Applies immediately.")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace {

constexpr double kAuto = -1.0;
constexpr double kMinLimit = 20.0;
constexpr double kMaxLimit = 1000.0;

// Configured limit: 0 = off, kAuto, or frames per second. Written by the
// startup thread and the settings change callback; read once per guest frame.
std::atomic<double> g_limit{0.0};
std::atomic<void*> g_window{nullptr};

std::optional<double> ParseLimit(std::string_view text) {
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) {
    text.remove_prefix(1);
  }
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) {
    text.remove_suffix(1);
  }
  std::string lower(text);
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (lower == "off" || lower == "0") return 0.0;
  if (lower == "auto") return kAuto;
  double value = 0.0;
  const auto [end, error] = std::from_chars(lower.data(), lower.data() + lower.size(), value);
  if (error != std::errc{} || end != lower.data() + lower.size() || value < kMinLimit ||
      value > kMaxLimit) {
    return std::nullopt;
  }
  return value;
}

std::string DescribeLimit(double limit) {
  if (limit == 0.0) return "off";
  if (limit < 0.0) return "auto";
  return std::to_string(limit);
}

// Target for "auto": a few frames below the display refresh so presents stay
// inside a variable-refresh window instead of colliding with the refresh
// boundary. Zero when the refresh rate is unknown.
double AutoTargetHz(double refresh_hz) {
  if (refresh_hz < kMinLimit) return 0.0;
  return refresh_hz - std::max(3.0, refresh_hz * 0.03);
}

#if defined(_WIN32)

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

int64_t Now() {
  LARGE_INTEGER value;
  QueryPerformanceCounter(&value);
  return value.QuadPart;
}

double QueryRefreshHz(HWND window) {
  HMONITOR monitor = window ? MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)
                            : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0.0;
  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  if (!EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode)) return 0.0;
  // 0 and 1 mean "hardware default" rather than a rate.
  return mode.dmDisplayFrequency > 1 ? double(mode.dmDisplayFrequency) : 0.0;
}

struct Pacer {
  std::mutex mutex;
  int64_t frequency = 0;
  HANDLE timer = nullptr;
  bool high_resolution = false;
  bool initialized = false;

  double active_hz = 0.0;  // Rate the current schedule was built for.
  int64_t next = 0;        // Deadline of the next frame, in counter ticks.

  double refresh_hz = 0.0;
  int64_t refresh_checked = 0;
  bool reported_unknown_refresh = false;

  // Rolling statistics, logged about once a minute while limiting.
  int64_t stats_start = 0;
  uint64_t frames = 0;
  uint64_t waited_frames = 0;
  uint64_t late_frames = 0;
  int64_t waited_ticks = 0;
};

Pacer g_pacer;

void Initialize(Pacer& p) {
  LARGE_INTEGER frequency;
  QueryPerformanceFrequency(&frequency);
  p.frequency = frequency.QuadPart;
  p.timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                   TIMER_ALL_ACCESS);
  p.high_resolution = p.timer != nullptr;
  if (!p.timer) {
    // Older Windows and some compatibility layers lack the high-resolution
    // timer. Raise the system timer resolution so the standard timer wakes
    // within about a millisecond; the spin below covers the remainder.
    timeBeginPeriod(1);
    p.timer = CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);
  }
  REXLOG_INFO("Skate 2 frame limiter timer: {}",
              p.high_resolution ? "high resolution"
                                : (p.timer ? "standard (1 ms system timer)" : "spin only"));
  p.initialized = true;
}

void WaitUntil(Pacer& p, int64_t target) {
  // Sleep through most of the interval, then spin the final stretch: timer
  // wake-ups are early or late by a fraction of a millisecond.
  const int64_t spin_ticks = p.frequency * (p.high_resolution ? 1 : 2) / 1000;
  const int64_t remaining = target - Now();
  if (p.timer && remaining > spin_ticks) {
    LARGE_INTEGER due;
    // Negative = relative, in 100 ns units.
    due.QuadPart = -((remaining - spin_ticks) * 10000000 / p.frequency);
    if (due.QuadPart < 0 && SetWaitableTimer(p.timer, &due, 0, nullptr, nullptr, FALSE)) {
      WaitForSingleObject(p.timer, INFINITE);
    }
  }
  while (Now() < target) {
    YieldProcessor();
  }
}

void LogStatistics(Pacer& p, int64_t now) {
  if (p.stats_start == 0) {
    p.stats_start = now;
    return;
  }
  if (now - p.stats_start < p.frequency * 60) return;
  const double seconds = double(now - p.stats_start) / double(p.frequency);
  REXLOG_INFO(
      "Skate 2 frame limiter: target {:.1f} FPS, actual {:.1f} FPS, waited on {:.0f}% of frames "
      "(average {:.2f} ms), {} late frames resynchronized",
      p.active_hz, double(p.frames) / seconds,
      p.frames ? 100.0 * double(p.waited_frames) / double(p.frames) : 0.0,
      p.waited_frames ? 1000.0 * double(p.waited_ticks) / double(p.frequency) /
                            double(p.waited_frames)
                      : 0.0,
      p.late_frames);
  p.stats_start = now;
  p.frames = p.waited_frames = p.late_frames = 0;
  p.waited_ticks = 0;
}

#endif  // _WIN32

void PublishLimit(double limit) {
  const double previous = g_limit.exchange(limit, std::memory_order_relaxed);
  if (previous != limit) {
    REXLOG_INFO("Skate 2 frame limit: {}", DescribeLimit(limit));
  }
}

}  // namespace

bool ConfigureSkate2FrameLimit(void* native_window) {
  g_window.store(native_window, std::memory_order_relaxed);
  const std::string value = rex::cvar::GetFlagByName("skate2_frame_limit");
  const auto parsed = ParseLimit(value);
  if (!parsed) {
    const std::string error = "Invalid skate2_frame_limit '" + value +
                              "'. Use off, auto, or a frame rate from 20 to 1000.";
    REXLOG_ERROR("{}", error);
    rex::ShowSimpleMessageBox(rex::SimpleMessageBoxType::Error, error);
    return false;
  }
  PublishLimit(*parsed);

  static std::once_flag hooks_installed;
  std::call_once(hooks_installed, [] {
    rex::cvar::SetFlagValidator("skate2_frame_limit", [](std::string_view text) {
      if (ParseLimit(text)) return true;
      REXLOG_WARN("skate2_frame_limit '{}' rejected: use off, auto, or 20 to 1000.", text);
      return false;
    });
    rex::cvar::RegisterChangeCallback(
        "skate2_frame_limit", [](std::string_view, std::string_view text) {
          if (const auto limit = ParseLimit(text)) PublishLimit(*limit);
        });
  });
  return true;
}

void PaceSkate2Frame() {
  const double limit = g_limit.load(std::memory_order_relaxed);
  if (limit == 0.0) return;

#if defined(_WIN32)
  Pacer& p = g_pacer;
  std::lock_guard<std::mutex> lock(p.mutex);
  if (!p.initialized) Initialize(p);
  const int64_t now = Now();

  double hz = limit;
  if (limit < 0.0) {
    // Re-read the monitor rate every few seconds so moving the window to
    // another display or changing its mode is picked up.
    if (p.refresh_checked == 0 || now - p.refresh_checked > p.frequency * 5) {
      p.refresh_hz = QueryRefreshHz(static_cast<HWND>(g_window.load(std::memory_order_relaxed)));
      p.refresh_checked = now;
    }
    hz = AutoTargetHz(p.refresh_hz);
    if (hz <= 0.0) {
      if (!p.reported_unknown_refresh) {
        REXLOG_WARN("Skate 2 frame limit auto: display refresh rate unknown; not limiting.");
        p.reported_unknown_refresh = true;
      }
      return;
    }
  }

  if (hz != p.active_hz) {
    if (limit < 0.0) {
      REXLOG_INFO("Skate 2 frame limit auto: {:.1f} FPS for a {:.0f} Hz display", hz,
                  p.refresh_hz);
    }
    p.active_hz = hz;
    p.next = 0;
    p.stats_start = 0;
    p.frames = p.waited_frames = p.late_frames = 0;
    p.waited_ticks = 0;
  }

  const int64_t interval = int64_t(double(p.frequency) / hz + 0.5);
  ++p.frames;
  if (p.next == 0 || now - p.next > interval) {
    // First frame, or more than a whole interval behind (loading, a hitch):
    // restart the schedule instead of rushing to catch up.
    if (p.next != 0) ++p.late_frames;
    p.next = now + interval;
    LogStatistics(p, now);
    return;
  }
  if (now < p.next) {
    WaitUntil(p, p.next);
    ++p.waited_frames;
    p.waited_ticks += Now() - now;
  }
  // Absolute schedule: deadlines advance by exactly one interval, so wake-up
  // jitter never accumulates into drift.
  p.next += interval;
  LogStatistics(p, now);
#else
  using Clock = std::chrono::steady_clock;
  static std::mutex mutex;
  static Clock::time_point next{};
  static double active_hz = 0.0;
  std::lock_guard<std::mutex> lock(mutex);
  if (limit < 0.0) return;  // Display refresh queries are Windows-only.
  if (limit != active_hz) {
    active_hz = limit;
    next = {};
  }
  const auto interval = std::chrono::duration_cast<Clock::duration>(
      std::chrono::duration<double>(1.0 / limit));
  const auto now = Clock::now();
  if (next == Clock::time_point{} || now - next > interval) {
    next = now + interval;
    return;
  }
  if (now < next) std::this_thread::sleep_until(next);
  next += interval;
#endif
}
