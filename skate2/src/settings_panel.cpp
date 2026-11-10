#include "settings_panel.h"

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/imgui_dialog.h>
#include <rex/ui/imgui_drawer.h>
#include <rex/ui/windowed_app_context.h>

#include <imgui.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cfloat>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <xinput.h>
#endif

// Named rather than anonymous: Skate2SettingsPanelState, declared in the
// header, holds several of these types.
namespace skate2_panel {

using Clock = std::chrono::steady_clock;

// XInput button bits. The values are fixed by the XInput API.
constexpr uint16_t kPadDpadUp = 0x0001;
constexpr uint16_t kPadDpadDown = 0x0002;
constexpr uint16_t kPadDpadLeft = 0x0004;
constexpr uint16_t kPadDpadRight = 0x0008;
constexpr uint16_t kPadStart = 0x0010;
constexpr uint16_t kPadBack = 0x0020;
constexpr uint16_t kPadLeftThumb = 0x0040;
constexpr uint16_t kPadRightThumb = 0x0080;
constexpr uint16_t kPadLeftShoulder = 0x0100;
constexpr uint16_t kPadRightShoulder = 0x0200;
constexpr uint16_t kPadA = 0x1000;
constexpr uint16_t kPadB = 0x2000;
constexpr uint16_t kPadX = 0x4000;
constexpr uint16_t kPadY = 0x8000;

// Back + Start held together: menu buttons that are not pressed together
// during play. Held for kShortcutHold before the panel toggles.
constexpr uint16_t kShortcutButtons = kPadBack | kPadStart;
constexpr auto kShortcutHold = std::chrono::milliseconds(1000);
constexpr auto kPollInterval = std::chrono::milliseconds(25);
constexpr auto kEmptySlotProbeInterval = std::chrono::seconds(2);
// After closing, game input stays withheld until the closing key or button is
// released, so that press does not reach the game; never longer than this.
constexpr int64_t kReleaseTimeoutMs = 1500;
constexpr uint8_t kTriggerThreshold = 30;
constexpr int kLeftStickDeadZone = 7849;   // XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE
constexpr int kRightStickDeadZone = 8689;  // XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE
constexpr int kMaxXInputUsers = 4;

// Read by the game's input gate on guest threads. Process lifetime, so the
// gate stays valid even after the panel object is gone.
std::atomic<bool> g_panel_open{false};
std::atomic<bool> g_shortcut_held{false};
std::atomic<bool> g_release_pending{false};
std::atomic<int64_t> g_release_deadline_ms{0};

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch())
      .count();
}

void ArmReleaseGuard() {
  g_release_deadline_ms.store(NowMs() + kReleaseTimeoutMs, std::memory_order_relaxed);
  g_release_pending.store(true, std::memory_order_release);
}

// ---- Font -----------------------------------------------------------------

// The runtime's default font is a 10 px bitmap-style face, too small for a
// panel used from the couch or on a handheld. A system UI font is baked at a
// few sizes; the atlas cannot grow at run time (the runtime uploads it once),
// so ImGui scales the nearest baked size to the size the panel asks for.
struct PanelFont {
  ImFont* font = nullptr;
  float baked_size = 0.0f;
};
constexpr std::array<float, 3> kFontBakeSizes{18.0f, 26.0f, 36.0f};
std::array<PanelFont, 3> g_fonts{};

ImFont* ChooseFont(float size) {
  for (const auto& entry : g_fonts) {
    if (entry.font && entry.baked_size >= size) return entry.font;
  }
  for (auto it = g_fonts.rbegin(); it != g_fonts.rend(); ++it) {
    if (it->font) return it->font;
  }
  return nullptr;  // Keep the current (default) font, scaled.
}

// ---- Controller -------------------------------------------------------------

struct PadState {
  bool connected = false;
  uint16_t buttons = 0;
  uint8_t left_trigger = 0;
  uint8_t right_trigger = 0;
  int16_t lx = 0;
  int16_t ly = 0;
  int16_t rx = 0;
  int16_t ry = 0;
};

#if defined(_WIN32)
using XInputGetStateFn = DWORD(WINAPI*)(DWORD, XINPUT_STATE*);

// XInput is read directly rather than through the runtime's input system:
// that path is gated (it reports an idle pad while the panel is open) and
// reading it would also consume state the game polls for, such as packet
// numbers and mouse deltas. XInput reads have no side effects.
XInputGetStateFn LoadXInputGetState() {
  static const XInputGetStateFn function = []() -> XInputGetStateFn {
    for (const wchar_t* name : {L"xinput1_4.dll", L"xinput1_3.dll", L"xinput9_1_0.dll"}) {
      if (HMODULE module = LoadLibraryW(name)) {
        if (auto proc = reinterpret_cast<XInputGetStateFn>(GetProcAddress(module, "XInputGetState"))) {
          return proc;
        }
        FreeLibrary(module);
      }
    }
    REXLOG_WARN("Skate 2 settings panel: XInput is unavailable; the controller shortcut is disabled.");
    return nullptr;
  }();
  return function;
}
#endif

int16_t LargerMagnitude(int16_t a, int16_t b) {
  return std::abs(int(b)) > std::abs(int(a)) ? b : a;
}

// Merges every connected controller, so any pad can open and use the panel.
// Empty slots are probed only every couple of seconds, because querying an
// empty XInput slot is slow.
class PadReader {
 public:
  PadState Read() {
    PadState merged;
#if defined(_WIN32)
    const XInputGetStateFn get_state = LoadXInputGetState();
    if (!get_state) return merged;
    const auto now = Clock::now();
    for (int slot = 0; slot < kMaxXInputUsers; ++slot) {
      if (!connected_[slot] && now < next_probe_[slot]) continue;
      XINPUT_STATE state{};
      if (get_state(DWORD(slot), &state) != ERROR_SUCCESS) {
        connected_[slot] = false;
        next_probe_[slot] = now + kEmptySlotProbeInterval;
        continue;
      }
      connected_[slot] = true;
      const XINPUT_GAMEPAD& pad = state.Gamepad;
      merged.connected = true;
      merged.buttons = uint16_t(merged.buttons | pad.wButtons);
      merged.left_trigger = std::max(merged.left_trigger, pad.bLeftTrigger);
      merged.right_trigger = std::max(merged.right_trigger, pad.bRightTrigger);
      merged.lx = LargerMagnitude(merged.lx, pad.sThumbLX);
      merged.ly = LargerMagnitude(merged.ly, pad.sThumbLY);
      merged.rx = LargerMagnitude(merged.rx, pad.sThumbRX);
      merged.ry = LargerMagnitude(merged.ry, pad.sThumbRY);
    }
#endif
    return merged;
  }

 private:
  std::array<bool, kMaxXInputUsers> connected_{};
  std::array<Clock::time_point, kMaxXInputUsers> next_probe_{};
};

// Keys the runtime's keyboard-as-controller mode maps to game buttons by
// default (Return = Start, Space = A, Backspace = B, Tab = Back), plus Escape.
bool AnyMenuKeyDown() {
#if defined(_WIN32)
  for (int key : {VK_RETURN, VK_SPACE, VK_BACK, VK_TAB, VK_ESCAPE}) {
    if (GetAsyncKeyState(key) & 0x8000) return true;
  }
#endif
  return false;
}

struct PadKey {
  ImGuiKey key;
  uint16_t bit;
};
constexpr PadKey kPadKeys[] = {
    {ImGuiKey_GamepadStart, kPadStart},
    {ImGuiKey_GamepadBack, kPadBack},
    {ImGuiKey_GamepadFaceDown, kPadA},
    {ImGuiKey_GamepadFaceRight, kPadB},
    {ImGuiKey_GamepadFaceLeft, kPadX},
    {ImGuiKey_GamepadFaceUp, kPadY},
    {ImGuiKey_GamepadDpadLeft, kPadDpadLeft},
    {ImGuiKey_GamepadDpadRight, kPadDpadRight},
    {ImGuiKey_GamepadDpadUp, kPadDpadUp},
    {ImGuiKey_GamepadDpadDown, kPadDpadDown},
    {ImGuiKey_GamepadL1, kPadLeftShoulder},
    {ImGuiKey_GamepadR1, kPadRightShoulder},
    {ImGuiKey_GamepadL3, kPadLeftThumb},
    {ImGuiKey_GamepadR3, kPadRightThumb},
};
constexpr ImGuiKey kPadAnalogKeys[] = {
    ImGuiKey_GamepadL2,          ImGuiKey_GamepadR2,          ImGuiKey_GamepadLStickLeft,
    ImGuiKey_GamepadLStickRight, ImGuiKey_GamepadLStickUp,    ImGuiKey_GamepadLStickDown,
    ImGuiKey_GamepadRStickLeft,  ImGuiKey_GamepadRStickRight, ImGuiKey_GamepadRStickUp,
    ImGuiKey_GamepadRStickDown,
};

float StickAxis(int value, int dead_zone) {
  const int magnitude = std::abs(value);
  if (magnitude <= dead_zone) return 0.0f;
  const float scaled = std::min(1.0f, float(magnitude - dead_zone) / float(32767 - dead_zone));
  return value < 0 ? -scaled : scaled;
}

void FeedStick(ImGuiIO& io, ImGuiKey negative, ImGuiKey positive, float value) {
  io.AddKeyAnalogEvent(negative, value < -0.1f, value < 0.0f ? -value : 0.0f);
  io.AddKeyAnalogEvent(positive, value > 0.1f, value > 0.0f ? value : 0.0f);
}

void ReleasePadKeys(ImGuiIO& io) {
  for (const PadKey& entry : kPadKeys) io.AddKeyEvent(entry.key, false);
  for (ImGuiKey key : kPadAnalogKeys) io.AddKeyAnalogEvent(key, false, 0.0f);
}

void FeedPad(ImGuiIO& io, const PadState& pad) {
  for (const PadKey& entry : kPadKeys) io.AddKeyEvent(entry.key, (pad.buttons & entry.bit) != 0);
  io.AddKeyAnalogEvent(ImGuiKey_GamepadL2, pad.left_trigger > kTriggerThreshold,
                       float(pad.left_trigger) / 255.0f);
  io.AddKeyAnalogEvent(ImGuiKey_GamepadR2, pad.right_trigger > kTriggerThreshold,
                       float(pad.right_trigger) / 255.0f);
  FeedStick(io, ImGuiKey_GamepadLStickLeft, ImGuiKey_GamepadLStickRight,
            StickAxis(pad.lx, kLeftStickDeadZone));
  FeedStick(io, ImGuiKey_GamepadLStickDown, ImGuiKey_GamepadLStickUp,
            StickAxis(pad.ly, kLeftStickDeadZone));
  FeedStick(io, ImGuiKey_GamepadRStickLeft, ImGuiKey_GamepadRStickRight,
            StickAxis(pad.rx, kRightStickDeadZone));
  FeedStick(io, ImGuiKey_GamepadRStickDown, ImGuiKey_GamepadRStickUp,
            StickAxis(pad.ry, kRightStickDeadZone));
}

// ---- Settings registry helpers ----------------------------------------------

// Copy of the registry metadata the panel needs. GetFlagInfo's pointer is
// invalidated by later registry calls, so nothing keeps it.
struct FlagMeta {
  rex::cvar::Lifecycle lifecycle = rex::cvar::Lifecycle::kHotReload;
  std::vector<std::string> allowed;
  std::optional<double> min;
  std::optional<double> max;
  std::string default_value;
};

std::optional<FlagMeta> GetMeta(std::string_view name) {
  const auto* info = rex::cvar::GetFlagInfo(name);
  if (!info) return std::nullopt;
  FlagMeta meta;
  meta.lifecycle = info->lifecycle;
  meta.allowed = info->constraints.allowed_values;
  meta.min = info->constraints.min;
  meta.max = info->constraints.max;
  meta.default_value = info->default_value;
  return meta;
}

bool FlagExists(std::string_view name) {
  return rex::cvar::GetFlagInfo(name) != nullptr;
}

std::string Trimmed(std::string_view text) {
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.front()))) {
    text.remove_prefix(1);
  }
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back()))) {
    text.remove_suffix(1);
  }
  std::string result(text);
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return result;
}

std::optional<int> ParseInt(std::string_view text) {
  int value = 0;
  const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
  if (error != std::errc{} || end != text.data() + text.size()) return std::nullopt;
  return value;
}

std::optional<double> ParseDouble(std::string_view text) {
  double value = 0.0;
  if (!rex::cvar::ParseDouble(text, value)) return std::nullopt;
  return value;
}

int ReadInt(std::string_view name, int fallback) {
  return ParseInt(Trimmed(rex::cvar::GetFlagByName(name))).value_or(fallback);
}

bool ReadBool(std::string_view name) {
  const std::string value = Trimmed(rex::cvar::GetFlagByName(name));
  return value == "true" || value == "1";
}

bool ApplyFlag(std::string_view name, std::string_view value) {
  // SetFlagByName runs the setting's validators and change callbacks, so
  // live settings take effect exactly as when changed from F4.
  if (rex::cvar::SetFlagByName(name, value)) {
    REXLOG_INFO("Skate 2 settings panel: {} = {}", name, value);
    return true;
  }
  REXLOG_WARN("Skate 2 settings panel: {} rejected '{}'", name, value);
  return false;
}

struct RenderScale {
  int x = 1;
  int y = 1;
  bool operator==(const RenderScale&) const = default;
};

// Mirrors how the GPU texture cache resolves its scale at startup: a
// non-default resolution_scale applies to each axis that has no explicit
// draw_resolution_scale_x/_y of its own.
std::optional<RenderScale> CurrentRenderScale() {
  if (!FlagExists("draw_resolution_scale_x") || !FlagExists("draw_resolution_scale_y")) {
    return std::nullopt;
  }
  const bool use_shared =
      FlagExists("resolution_scale") && rex::cvar::HasNonDefaultValue("resolution_scale");
  const int shared = std::max(1, ReadInt("resolution_scale", 1));
  auto axis = [&](const char* name) {
    if (use_shared && !rex::cvar::HasNonDefaultValue(name)) return shared;
    return std::max(1, ReadInt(name, 1));
  };
  return RenderScale{axis("draw_resolution_scale_x"), axis("draw_resolution_scale_y")};
}

bool ApplyRenderScale(int scale) {
  // Same three values the launcher passes for -RenderScale.
  const std::string value = std::to_string(scale);
  bool ok = true;
  if (FlagExists("resolution_scale")) ok = ApplyFlag("resolution_scale", "1") && ok;
  ok = ApplyFlag("draw_resolution_scale_x", value) && ok;
  ok = ApplyFlag("draw_resolution_scale_y", value) && ok;
  return ok;
}

// ---- Panel contents ---------------------------------------------------------

struct Option {
  const char* value;
  const char* label;
};
struct IntOption {
  int value;
  const char* label;
};

constexpr Option kFrameRateOptions[] = {
    {"original", "Original"}, {"60", "60 FPS"},   {"120", "120 FPS"}, {"144", "144 FPS"},
    {"165", "165 FPS"},       {"200", "200 FPS"}, {"240", "240 FPS"}, {"unlimited", "Unlimited"},
};
constexpr Option kFrameLimitOptions[] = {
    {"off", "Off"},         {"auto", "Auto"},       {"30", "30 FPS"},   {"60", "60 FPS"},
    {"72", "72 FPS"},       {"90", "90 FPS"},       {"120", "120 FPS"}, {"144", "144 FPS"},
    {"165", "165 FPS"},     {"240", "240 FPS"},
};
constexpr Option kRenderPathOptions[] = {
    {"rov", "ROV (default)"},
    {"rtv", "RTV (faster)"},
};
constexpr Option kNvidiaOptions[] = {
    {"off", "Off"},
    {"on", "On"},
    {"restore", "Restore"},
};
constexpr IntOption kRenderScaleOptions[] = {
    {1, "1x"},
    {2, "2x"},
    {3, "3x (experimental)"},
    {4, "4x (experimental)"},
};
constexpr IntOption kSubmitIntervalOptions[] = {
    {0, "0 (end of frame)"}, {256, "256"},   {512, "512"},
    {1024, "1024"},          {2048, "2048"}, {4096, "4096"},
};

enum class Kind { kChoice, kFrameLimit, kRenderScale, kIntChoice, kToggle, kDistance };

struct Entry {
  const char* section;
  const char* name;  // Registry name; the X axis for the render scale.
  const char* label;
  const char* help;
  Kind kind;
  std::span<const Option> options = {};
  std::span<const IntOption> int_options = {};
};

const Entry kEntries[] = {
    {"Frame rate", "skate2_frame_rate", "Frame-rate mode",
     "Original is the console timing. 60 to 240 and Unlimited are experimental and need VSync "
     "on; Unlimited is the default. Applies after a restart.",
     Kind::kChoice, kFrameRateOptions},
    {"Frame rate", "skate2_frame_limit", "Frame limiter",
     "Holds frames to an even pace. Auto targets just below the display refresh rate, for "
     "G-Sync and FreeSync. Most useful with Unlimited. Applies immediately.",
     Kind::kFrameLimit, kFrameLimitOptions},
    {"Rendering", "draw_resolution_scale_x", "Render scale",
     "Internal rendering resolution. 2x is the default; 3x and 4x are experimental and much "
     "heavier on the GPU. Applies after a restart.",
     Kind::kRenderScale, {}, kRenderScaleOptions},
    {"Rendering", "render_target_path_d3d12", "Render path",
     "ROV is the default and the most tested. RTV is faster, especially on NVIDIA GPUs. Applies "
     "after a restart.",
     Kind::kChoice, kRenderPathOptions},
    {"Rendering", "d3d12_submit_draw_interval", "GPU submit interval",
     "Sends recorded GPU work every N draws so the GPU starts earlier in the frame. 0 waits for "
     "the end of the frame; 1024 measured fastest. Applies immediately.",
     Kind::kIntChoice, {}, kSubmitIntervalOptions},
    {"Rendering", "d3d12_async_submission", "Submission thread",
     "Hands recorded GPU work to the driver on a separate thread. Part of the RTV performance "
     "profile. Applies after a restart.",
     Kind::kToggle},
    {"Display", "vsync", "VSync",
     "Keep on: it also controls the game's timing, and the higher frame-rate modes require it. "
     "Applies immediately.",
     Kind::kToggle},
    {"Display", "fullscreen", "Fullscreen",
     "Borderless fullscreen on the current display, or a window. Applies immediately.",
     Kind::kToggle},
    {"Driver", "skate2_nvidia_max_performance", "NVIDIA max performance",
     "NVIDIA GPUs only. On sets Prefer maximum performance in the driver profile for skate2.exe; "
     "Restore removes it. The driver keeps the change. Applies at the next start.",
     Kind::kChoice, kNvidiaOptions},
    {"World detail", "skate2_draw_distance_scale", "Draw distance",
     "How far away small world objects such as street furniture and building detail are drawn. "
     "Only geometry the game has already loaded can appear. 1.00x is the original; higher "
     "values cost performance.",
     Kind::kDistance},
    {"World detail", "skate2_lod_distance_scale", "LOD distance",
     "How far character and vehicle models keep full detail before switching to lower-detail "
     "versions. Does not change where pedestrians and props appear (the game spawns those "
     "separately).",
     Kind::kDistance},
};

// Values recorded at startup, for restart notices.
constexpr const char* kTrackedFlags[] = {
    "skate2_frame_rate",          "skate2_frame_limit",
    "resolution_scale",           "draw_resolution_scale_x",
    "draw_resolution_scale_y",    "render_target_path_d3d12",
    "d3d12_submit_draw_interval", "d3d12_async_submission",
    "vsync",                      "fullscreen",
    "skate2_nvidia_max_performance", "skate2_draw_distance_scale",
    "skate2_lod_distance_scale",
};

// Presets cover the frame-rate mode and rendering settings of the supplied
// launch profiles. They leave the frame limiter, display, driver and world
// detail settings as they are.
struct Preset {
  const char* label;
  const char* summary;
  const char* frame_rate;
  int render_scale;
  const char* render_path;
  int submit_interval;
  bool async_submission;
};

constexpr Preset kPresets[] = {
    {"Quality",
     "Default profile: ROV render path, 2x scale, unlimited frame rate, standard GPU "
     "submission.",
     "unlimited", 2, "rov", 0, false},
    {"Balanced",
     "RTV Performance launcher profile: RTV render path, 2x scale, unlimited frame rate, GPU "
     "submit interval 1024 and the submission thread.",
     "unlimited", 2, "rtv", 1024, true},
    {"Performance",
     "Lower GPU load: RTV render path, 1x scale, unlimited frame rate, GPU submit interval 1024 "
     "and the submission thread.",
     "unlimited", 1, "rtv", 1024, true},
    {"Steam Deck",
     "Steam Deck profile: RTV render path, 1x scale, 60 FPS mode, GPU submit interval 1024 and "
     "the submission thread.",
     "60", 1, "rtv", 1024, true},
};

const char* LabelFor(std::span<const Option> options, std::string_view value) {
  for (const Option& option : options) {
    if (value == option.value) return option.label;
  }
  return nullptr;
}

const char* LabelFor(std::span<const IntOption> options, int value) {
  for (const IntOption& option : options) {
    if (value == option.value) return option.label;
  }
  return nullptr;
}

// Frame-limit values compare by meaning: "0" is off, "60" equals "60.0".
bool SameFrameLimit(std::string_view a, std::string_view b) {
  const std::string left = Trimmed(a);
  const std::string right = Trimmed(b);
  auto canonical = [](const std::string& text) { return text == "0" ? std::string("off") : text; };
  if (canonical(left) == canonical(right)) return true;
  const auto x = ParseDouble(left);
  const auto y = ParseDouble(right);
  return x && y && *x == *y;
}

std::string FormatScale(double value) {
  char text[32];
  std::snprintf(text, sizeof(text), "%.2f", value);
  return text;
}

class PanelDialog;

}  // namespace skate2_panel

using namespace skate2_panel;

// ---- Panel state --------------------------------------------------------------

class Skate2SettingsPanelState : public std::enable_shared_from_this<Skate2SettingsPanelState> {
 public:
  Skate2SettingsPanelState(rex::ui::WindowedAppContext& app_context, rex::ui::ImGuiDrawer* drawer,
                           std::filesystem::path config_path);
  ~Skate2SettingsPanelState();

  void Start();
  void Shutdown();
  void Toggle();
  void Open();
  void Close();
  // From inside the dialog's draw: the dialog cannot be destroyed there, so
  // input is released now and the dialog is destroyed right after the frame.
  void RequestCloseFromDraw();

  PadState LatestPad() {
    std::lock_guard lock(pad_mutex_);
    return latest_pad_;
  }
  const std::string* StartupValue(std::string_view name) const {
    const auto it = startup_values_.find(std::string(name));
    return it == startup_values_.end() ? nullptr : &it->second;
  }
  bool SetAtLaunch(std::string_view name) const {
    return set_at_launch_.count(std::string(name)) != 0;
  }
  const std::optional<RenderScale>& startup_scale() const { return startup_scale_; }
  const std::filesystem::path& config_path() const { return config_path_; }

 private:
  void PollLoop();
  void PostToggle();

  rex::ui::WindowedAppContext& app_context_;
  rex::ui::ImGuiDrawer* drawer_;
  std::filesystem::path config_path_;
  std::unique_ptr<PanelDialog> dialog_;
  bool started_ = false;

  std::map<std::string, std::string> startup_values_;
  std::set<std::string> set_at_launch_;
  std::optional<RenderScale> startup_scale_;

  std::thread poll_thread_;
  std::mutex poll_mutex_;
  std::condition_variable poll_wake_;
  bool stop_polling_ = false;

  std::mutex pad_mutex_;
  PadState latest_pad_;
};

// ---- Dialog -----------------------------------------------------------------

namespace skate2_panel {

class PanelDialog final : public rex::ui::ImGuiDialog {
 public:
  PanelDialog(rex::ui::ImGuiDrawer* drawer, Skate2SettingsPanelState& state)
      : rex::ui::ImGuiDialog(drawer), state_(state) {}
  ~PanelDialog() override;

 protected:
  void OnDraw(ImGuiIO& io) override;

 private:
  void UpdateInput(ImGuiIO& io);
  void DrawContents(float font_size);
  void DrawPresets();
  void DrawEntries(float label_width, float value_width);
  void DrawEntry(const Entry& entry, const FlagMeta& meta);
  void DrawChoice(const Entry& entry, bool live, const FlagMeta& meta, const std::string& help);
  void DrawFrameLimit(const Entry& entry, bool live, const std::string& help);
  void DrawRenderScale(const Entry& entry, bool live, const std::string& help);
  void DrawIntChoice(const Entry& entry, bool live, const std::string& help);
  void DrawToggle(const Entry& entry, bool live, const std::string& help);
  void DrawDistance(const Entry& entry, bool live, const FlagMeta& meta, const std::string& help);
  void DrawApplies(bool live, bool pending, bool set_at_launch);
  void DrawFooter();
  void HandleBack();

  bool IsPending(const Entry& entry) const;
  bool IsSetAtLaunch(const Entry& entry) const;
  bool PresetMatches(const Preset& preset) const;
  void ApplyPreset(const Preset& preset);
  void Change(const Entry& entry, bool live, const std::string& value);
  void ReportResult(const Entry& entry, bool live, bool ok);
  void Save();
  void NoteHelp(const std::string& help);
  void SetStatus(std::string text, const ImVec4& color);

  Skate2SettingsPanelState& state_;
  bool first_frame_ = true;
  bool busy_last_frame_ = false;
  float footer_height_ = 0.0f;
  int added_config_flags_ = 0;
  int added_backend_flags_ = 0;

  std::string help_;
  std::string previous_help_;
  std::string status_;
  ImVec4 status_color_{1.0f, 1.0f, 1.0f, 1.0f};
  std::vector<std::string> pending_labels_;
  bool any_set_at_launch_ = false;

  // Slider value while it is being dragged; applied on release.
  std::string editing_name_;
  float editing_value_ = 1.0f;
};

PanelDialog::~PanelDialog() {
  ImGuiIO& io = GetIO();
  ReleasePadKeys(io);
  io.ConfigFlags &= ~added_config_flags_;
  io.BackendFlags &= ~added_backend_flags_;
}

void PanelDialog::UpdateInput(ImGuiIO& io) {
  // The runtime does not enable ImGui navigation; enable it while the panel
  // is open and restore the previous flags when it closes.
  constexpr int kNavigation = ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
  added_config_flags_ |= kNavigation & ~io.ConfigFlags;
  io.ConfigFlags |= kNavigation;

  const PadState pad = state_.LatestPad();
  if (pad.connected) {
    added_backend_flags_ |= ImGuiBackendFlags_HasGamepad & ~io.BackendFlags;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    FeedPad(io, pad);
  } else if (added_backend_flags_ & ImGuiBackendFlags_HasGamepad) {
    ReleasePadKeys(io);
    io.BackendFlags &= ~ImGuiBackendFlags_HasGamepad;
    added_backend_flags_ &= ~ImGuiBackendFlags_HasGamepad;
  }
}

void PanelDialog::OnDraw(ImGuiIO& io) {
  // Closed from inside a previous frame; destroyed once that frame is done.
  if (!g_panel_open.load(std::memory_order_acquire)) return;
  UpdateInput(io);

  // Size everything from the display height so the panel is readable on a
  // TV or handheld as well as a desktop monitor.
  const float font_size = std::clamp(io.DisplaySize.y / 48.0f, 16.0f, 40.0f);
  ImGui::PushFont(ChooseFont(font_size), font_size);
  const ImGuiStyle& style = ImGui::GetStyle();
  const float scale = font_size / 13.0f;
  const ImVec2 window_padding(style.WindowPadding.x * scale, style.WindowPadding.y * scale);
  const ImVec2 frame_padding(style.FramePadding.x * scale, style.FramePadding.y * scale);
  const ImVec2 item_spacing(style.ItemSpacing.x * scale, style.ItemSpacing.y * scale);
  const ImVec2 inner_spacing(style.ItemInnerSpacing.x * scale, style.ItemInnerSpacing.y * scale);
  const ImVec2 cell_padding(style.CellPadding.x * scale, style.CellPadding.y * scale);
  const float scrollbar_size = style.ScrollbarSize * scale;
  const float grab_size = style.GrabMinSize * scale;
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, window_padding);
  ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, frame_padding);
  ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, item_spacing);
  ImGui::PushStyleVar(ImGuiStyleVar_ItemInnerSpacing, inner_spacing);
  ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, cell_padding);
  ImGui::PushStyleVar(ImGuiStyleVar_ScrollbarSize, scrollbar_size);
  ImGui::PushStyleVar(ImGuiStyleVar_GrabMinSize, grab_size);
  constexpr int kStyleVarCount = 7;

  if (first_frame_) {
    const ImGuiViewport* viewport = ImGui::GetMainViewport();
    const float width = std::min(viewport->Size.x * 0.95f, font_size * 38.0f);
    const float height = std::min(viewport->Size.y * 0.92f, font_size * 42.0f);
    ImGui::SetNextWindowPos(viewport->GetCenter(), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(width, height), ImGuiCond_Always);
  }
  // Take focus when opening, and back whenever no overlay has it (a click on
  // the game image clears ImGui focus), so keyboard and controller navigation
  // keep working. Another overlay that has focus keeps it.
  if (first_frame_ || !ImGui::IsWindowFocused(ImGuiFocusedFlags_AnyWindow)) {
    ImGui::SetNextWindowFocus();
  }
  ImGui::SetNextWindowBgAlpha(0.95f);
  bool open = true;
  if (ImGui::Begin("Skate 2 Settings###skate2_settings_panel", &open,
                   ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings)) {
    DrawContents(font_size);
    HandleBack();
  }
  ImGui::End();

  ImGui::PopStyleVar(kStyleVarCount);
  ImGui::PopFont();
  first_frame_ = false;
  if (!open) state_.RequestCloseFromDraw();
}

void PanelDialog::DrawContents(float font_size) {
  // The footer buttons come after the help area, so their help is shown from
  // the previous frame.
  previous_help_ = std::move(help_);
  help_.clear();
  pending_labels_.clear();
  any_set_at_launch_ = false;

  const std::string key = rex::cvar::GetFlagByName("bind_skate2_settings");
  ImGui::TextDisabled("%s or hold Back + Start: close     B or Esc: back",
                      key.empty() ? "F1" : key.c_str());

  ImGui::SeparatorText("Presets");
  DrawPresets();

  float label_width = 0.0f;
  for (const Entry& entry : kEntries) {
    label_width = std::max(label_width, ImGui::CalcTextSize(entry.label).x);
  }
  const float value_width = font_size * 12.0f;

  // The settings list scrolls; the footer below it stays in place. Its height
  // is measured each frame and used for the next one, with an estimate
  // (help, status, notices and buttons) for the first.
  const ImGuiStyle& style = ImGui::GetStyle();
  if (footer_height_ <= 0.0f) {
    footer_height_ = ImGui::GetTextLineHeightWithSpacing() * 6.0f +
                     ImGui::GetFrameHeightWithSpacing() + style.ItemSpacing.y * 2.0f;
  }
  if (ImGui::BeginChild("##settings", ImVec2(0.0f, -footer_height_),
                        ImGuiChildFlags_NavFlattened)) {
    DrawEntries(label_width, value_width);
  }
  ImGui::EndChild();
  const float footer_top = ImGui::GetCursorPosY();
  DrawFooter();
  // Includes the spacing after the buttons, which the child's own trailing
  // spacing makes up for; one extra pixel absorbs rounding.
  footer_height_ = ImGui::GetCursorPosY() - footer_top + 1.0f;
}

void PanelDialog::DrawPresets() {
  const float spacing = ImGui::GetStyle().ItemSpacing.x;
  const size_t count = std::size(kPresets);
  const float width =
      (ImGui::GetContentRegionAvail().x - spacing * float(count - 1)) / float(count);
  for (size_t i = 0; i < count; ++i) {
    const Preset& preset = kPresets[i];
    if (i != 0) ImGui::SameLine();
    const bool current = PresetMatches(preset);
    const std::string label =
        std::string(preset.label) + (current ? " *" : "") + "###preset" + std::to_string(i);
    if (current) ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
    if (ImGui::Button(label.c_str(), ImVec2(width, 0.0f))) ApplyPreset(preset);
    if (current) ImGui::PopStyleColor();
    if (i == 0 && first_frame_) ImGui::SetItemDefaultFocus();
    NoteHelp(std::string(preset.summary) +
             (current ? " (* = matches the current settings.)"
                      : " Frame limiter, display, driver and world detail stay unchanged."));
  }
}

void PanelDialog::DrawEntries(float label_width, float value_width) {
  size_t index = 0;
  const size_t count = std::size(kEntries);
  while (index < count) {
    const char* section = kEntries[index].section;
    size_t end = index;
    while (end < count && std::string_view(kEntries[end].section) == section) ++end;

    // Look every setting up each frame: one that this build does not
    // register (or that is registered later) is simply not shown.
    std::vector<std::pair<const Entry*, FlagMeta>> visible;
    for (size_t i = index; i < end; ++i) {
      const Entry& entry = kEntries[i];
      if (entry.kind == Kind::kRenderScale && !CurrentRenderScale()) continue;
      if (auto meta = GetMeta(entry.name)) visible.emplace_back(&entry, std::move(*meta));
    }
    if (!visible.empty()) {
      ImGui::SeparatorText(section);
      const std::string table_id = std::string("##") + section;
      if (ImGui::BeginTable(table_id.c_str(), 3,
                            ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_NoSavedSettings)) {
        ImGui::TableSetupColumn("##label", ImGuiTableColumnFlags_WidthFixed, label_width);
        ImGui::TableSetupColumn("##value", ImGuiTableColumnFlags_WidthFixed, value_width);
        ImGui::TableSetupColumn("##applies", ImGuiTableColumnFlags_WidthStretch);
        for (const auto& [entry, meta] : visible) DrawEntry(*entry, meta);
        ImGui::EndTable();
      }
    }
    index = end;
  }
}

void PanelDialog::DrawEntry(const Entry& entry, const FlagMeta& meta) {
  const bool live = meta.lifecycle == rex::cvar::Lifecycle::kHotReload;
  const std::string help = entry.help;
  ImGui::PushID(entry.name);
  ImGui::TableNextRow();
  ImGui::TableSetColumnIndex(0);
  ImGui::AlignTextToFramePadding();
  ImGui::TextUnformatted(entry.label);
  ImGui::TableSetColumnIndex(1);
  ImGui::SetNextItemWidth(-FLT_MIN);
  switch (entry.kind) {
    case Kind::kChoice:
      DrawChoice(entry, live, meta, help);
      break;
    case Kind::kFrameLimit:
      DrawFrameLimit(entry, live, help);
      break;
    case Kind::kRenderScale:
      DrawRenderScale(entry, live, help);
      break;
    case Kind::kIntChoice:
      DrawIntChoice(entry, live, help);
      break;
    case Kind::kToggle:
      DrawToggle(entry, live, help);
      break;
    case Kind::kDistance:
      DrawDistance(entry, live, meta, help);
      break;
  }
  const bool pending = !live && IsPending(entry);
  const bool set_at_launch = IsSetAtLaunch(entry);
  if (pending) pending_labels_.emplace_back(entry.label);
  any_set_at_launch_ = any_set_at_launch_ || set_at_launch;
  ImGui::TableSetColumnIndex(2);
  ImGui::AlignTextToFramePadding();
  DrawApplies(live, pending, set_at_launch);

  if (entry.kind == Kind::kFrameLimit) {
    // Any other limit, adjusted with - and + or typed and confirmed with Enter.
    ImGui::TableNextRow();
    ImGui::TableSetColumnIndex(0);
    ImGui::AlignTextToFramePadding();
    ImGui::TextDisabled("  Custom limit");
    ImGui::TableSetColumnIndex(1);
    const std::string current = Trimmed(rex::cvar::GetFlagByName(entry.name));
    const auto numeric = ParseDouble(current);
    int custom = numeric && *numeric >= 20.0 ? int(*numeric + 0.5) : 60;
    ImGui::SetNextItemWidth(-FLT_MIN);
    if (ImGui::InputInt("##custom", &custom, 1, 10, ImGuiInputTextFlags_EnterReturnsTrue)) {
      Change(entry, live, std::to_string(std::clamp(custom, 20, 1000)));
    }
    NoteHelp("Any limit from 20 to 1000 FPS: use - and +, or type a value and press Enter. "
             "Applies immediately.");
    ImGui::TableSetColumnIndex(2);
    ImGui::AlignTextToFramePadding();
    DrawApplies(live, false, false);
  }
  ImGui::PopID();
}

void PanelDialog::DrawChoice(const Entry& entry, bool live, const FlagMeta& meta,
                             const std::string& help) {
  // The registry's allowed values decide what is offered when it has them.
  std::vector<std::pair<std::string, std::string>> options;
  if (!meta.allowed.empty()) {
    for (const std::string& value : meta.allowed) {
      const char* label = LabelFor(entry.options, value);
      options.emplace_back(value, label ? label : value);
    }
  } else {
    for (const Option& option : entry.options) options.emplace_back(option.value, option.label);
  }
  const std::string current = rex::cvar::GetFlagByName(entry.name);
  const char* label = LabelFor(entry.options, current);
  const std::string preview = current.empty() ? std::string("Automatic") : (label ? label : current);
  const bool open = ImGui::BeginCombo("##value", preview.c_str());
  NoteHelp(help);
  if (!open) return;
  for (const auto& [value, text] : options) {
    const bool selected = value == current;
    if (ImGui::Selectable(text.c_str(), selected) && !selected) Change(entry, live, value);
    if (selected) ImGui::SetItemDefaultFocus();
  }
  ImGui::EndCombo();
}

void PanelDialog::DrawFrameLimit(const Entry& entry, bool live, const std::string& help) {
  const std::string current = Trimmed(rex::cvar::GetFlagByName(entry.name));
  std::string preview;
  if (current == "off" || current == "0" || current.empty()) {
    preview = "Off";
  } else if (current == "auto") {
    preview = "Auto";
  } else {
    preview = current + " FPS";
  }
  const bool open = ImGui::BeginCombo("##value", preview.c_str());
  NoteHelp(help);
  if (!open) return;
  for (const Option& option : entry.options) {
    const bool selected = SameFrameLimit(current, option.value);
    if (ImGui::Selectable(option.label, selected) && !selected) Change(entry, live, option.value);
    if (selected) ImGui::SetItemDefaultFocus();
  }
  ImGui::EndCombo();
}

void PanelDialog::DrawRenderScale(const Entry& entry, bool live, const std::string& help) {
  const RenderScale current = CurrentRenderScale().value_or(RenderScale{});
  std::string preview;
  if (current.x == current.y) {
    const char* label = LabelFor(entry.int_options, current.x);
    preview = label ? label : std::to_string(current.x) + "x";
  } else {
    preview = std::to_string(current.x) + "x by " + std::to_string(current.y) + "x (custom)";
  }
  const bool open = ImGui::BeginCombo("##value", preview.c_str());
  NoteHelp(help);
  if (!open) return;
  for (const IntOption& option : entry.int_options) {
    const bool selected = current.x == option.value && current.y == option.value;
    if (ImGui::Selectable(option.label, selected) && !selected) {
      ReportResult(entry, live, ApplyRenderScale(option.value));
    }
    if (selected) ImGui::SetItemDefaultFocus();
  }
  ImGui::EndCombo();
}

void PanelDialog::DrawIntChoice(const Entry& entry, bool live, const std::string& help) {
  const int current = ReadInt(entry.name, 0);
  const char* label = LabelFor(entry.int_options, current);
  const std::string preview = label ? label : std::to_string(current) + " (custom)";
  const bool open = ImGui::BeginCombo("##value", preview.c_str());
  NoteHelp(help);
  if (!open) return;
  for (const IntOption& option : entry.int_options) {
    const bool selected = current == option.value;
    if (ImGui::Selectable(option.label, selected) && !selected) {
      Change(entry, live, std::to_string(option.value));
    }
    if (selected) ImGui::SetItemDefaultFocus();
  }
  ImGui::EndCombo();
}

void PanelDialog::DrawToggle(const Entry& entry, bool live, const std::string& help) {
  bool value = ReadBool(entry.name);
  if (ImGui::Checkbox(value ? "On##value" : "Off##value", &value)) {
    Change(entry, live, value ? "true" : "false");
  }
  NoteHelp(help);
}

void PanelDialog::DrawDistance(const Entry& entry, bool live, const FlagMeta& meta,
                               const std::string& help) {
  float min = meta.min ? float(*meta.min) : 0.5f;
  float max = meta.max ? float(*meta.max) : 3.0f;
  if (!(max > min)) {
    min = 0.5f;
    max = 3.0f;
  }
  const double current = ParseDouble(Trimmed(rex::cvar::GetFlagByName(entry.name))).value_or(1.0);
  float value = editing_name_ == entry.name ? editing_value_ : float(current);

  const ImGuiStyle& style = ImGui::GetStyle();
  const float reset_width = ImGui::CalcTextSize("Reset").x + style.FramePadding.x * 2.0f;
  ImGui::SetNextItemWidth(std::max(1.0f, ImGui::GetContentRegionAvail().x - reset_width -
                                             style.ItemSpacing.x));
  if (ImGui::SliderFloat("##value", &value, min, max, "%.2fx", ImGuiSliderFlags_AlwaysClamp)) {
    editing_name_ = entry.name;
    editing_value_ = value;
  }
  NoteHelp(help);
  // Applied once the slider is released rather than on every step.
  if (ImGui::IsItemDeactivatedAfterEdit()) Change(entry, live, FormatScale(value));
  if (!ImGui::IsItemActive() && editing_name_ == entry.name) editing_name_.clear();
  ImGui::SameLine();
  if (ImGui::Button("Reset")) Change(entry, live, meta.default_value);
  const auto original = ParseDouble(meta.default_value);
  NoteHelp("Back to the original distance (" +
           (original ? FormatScale(*original) + "x" : meta.default_value) + ").");
}

void PanelDialog::DrawApplies(bool live, bool pending, bool set_at_launch) {
  const auto& colors = imgui_drawer()->style().settings;
  if (live) {
    ImGui::TextColored(colors.lifecycle_live, "Live");
  } else if (pending) {
    ImGui::TextColored(colors.warning, "Restart needed");
  } else {
    ImGui::TextDisabled("After restart");
  }
  if (set_at_launch) {
    ImGui::SameLine();
    ImGui::TextDisabled("(L)");
  }
}

void PanelDialog::DrawFooter() {
  const auto& colors = imgui_drawer()->style().settings;
  ImGui::Separator();

  // Help for the focused or hovered setting, in a fixed three-line area.
  const float help_height = ImGui::GetTextLineHeightWithSpacing() * 3.0f;
  const float help_top = ImGui::GetCursorPosY();
  const std::string& help = help_.empty() ? previous_help_ : help_;
  if (!help.empty()) ImGui::TextWrapped("%s", help.c_str());
  const float used = ImGui::GetCursorPosY() - help_top;
  if (used < help_height) ImGui::Dummy(ImVec2(0.0f, help_height - used));

  if (!status_.empty()) {
    ImGui::PushStyleColor(ImGuiCol_Text, status_color_);
    ImGui::TextWrapped("%s", status_.c_str());
    ImGui::PopStyleColor();
  } else {
    ImGui::NewLine();
  }
  if (!pending_labels_.empty()) {
    std::string text = "Restart the game to apply: ";
    for (size_t i = 0; i < pending_labels_.size(); ++i) {
      if (i != 0) text += ", ";
      text += pending_labels_[i];
    }
    text += ".";
    ImGui::PushStyleColor(ImGuiCol_Text, colors.warning);
    ImGui::TextWrapped("%s", text.c_str());
    ImGui::PopStyleColor();
  }
  if (any_set_at_launch_) {
    // Only values passed on the command line: the default launchers pass none
    // of these settings, so their saved values apply.
    ImGui::TextDisabled("(L) Set by a launch option, which sets it again at the next start.");
  }

  ImGui::Separator();
  const std::string save_label = "Save to " + state_.config_path().filename().string();
  if (ImGui::Button(save_label.c_str())) Save();
  NoteHelp("Writes the settings in effect to " + state_.config_path().filename().string() +
           ", like Save to config in F4, including values marked (L). The default launchers "
           "then start with them.");
  ImGui::SameLine();
  if (ImGui::Button("Close")) state_.RequestCloseFromDraw();
  NoteHelp("Close the panel. Unsaved changes stay in effect until the game closes.");
}

void PanelDialog::HandleBack() {
  // B or Escape closes the panel, unless that press closes a list or ends an
  // edit, this frame or the previous one (ImGui handles those first).
  const bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId | ImGuiPopupFlags_AnyPopupLevel);
  const bool active = ImGui::IsAnyItemActive();
  const bool busy = popup || active || busy_last_frame_;
  busy_last_frame_ = popup || active;
  if (busy || !ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows)) return;
  if (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
      ImGui::IsKeyPressed(ImGuiKey_Escape, false)) {
    state_.RequestCloseFromDraw();
  }
}

bool PanelDialog::IsPending(const Entry& entry) const {
  if (entry.kind == Kind::kRenderScale) {
    const auto& startup = state_.startup_scale();
    const auto current = CurrentRenderScale();
    return startup && current && !(*startup == *current);
  }
  const std::string* startup = state_.StartupValue(entry.name);
  return startup && *startup != rex::cvar::GetFlagByName(entry.name);
}

bool PanelDialog::IsSetAtLaunch(const Entry& entry) const {
  if (entry.kind == Kind::kRenderScale) {
    return state_.SetAtLaunch("draw_resolution_scale_x") ||
           state_.SetAtLaunch("draw_resolution_scale_y") || state_.SetAtLaunch("resolution_scale");
  }
  return state_.SetAtLaunch(entry.name);
}

bool PanelDialog::PresetMatches(const Preset& preset) const {
  if (FlagExists("skate2_frame_rate") &&
      rex::cvar::GetFlagByName("skate2_frame_rate") != preset.frame_rate) {
    return false;
  }
  if (const auto scale = CurrentRenderScale()) {
    if (scale->x != preset.render_scale || scale->y != preset.render_scale) return false;
  }
  if (FlagExists("render_target_path_d3d12") &&
      rex::cvar::GetFlagByName("render_target_path_d3d12") != preset.render_path) {
    return false;
  }
  if (FlagExists("d3d12_submit_draw_interval") &&
      ReadInt("d3d12_submit_draw_interval", 0) != preset.submit_interval) {
    return false;
  }
  if (FlagExists("d3d12_async_submission") &&
      ReadBool("d3d12_async_submission") != preset.async_submission) {
    return false;
  }
  return true;
}

void PanelDialog::ApplyPreset(const Preset& preset) {
  bool ok = true;
  auto set = [&ok](const char* name, const std::string& value) {
    if (FlagExists(name)) ok = ApplyFlag(name, value) && ok;
  };
  set("skate2_frame_rate", preset.frame_rate);
  if (CurrentRenderScale()) ok = ApplyRenderScale(preset.render_scale) && ok;
  set("render_target_path_d3d12", preset.render_path);
  set("d3d12_submit_draw_interval", std::to_string(preset.submit_interval));
  set("d3d12_async_submission", preset.async_submission ? "true" : "false");
  REXLOG_INFO("Skate 2 settings panel: applied preset {}", preset.label);
  const auto& colors = imgui_drawer()->style().settings;
  if (!ok) {
    SetStatus(std::string(preset.label) + ": some values were rejected; see the log.", colors.warning);
  } else {
    SetStatus(std::string(preset.label) +
                  " selected. Save to keep it; settings marked Restart needed apply at the next "
                  "start.",
              colors.lifecycle_live);
  }
}

void PanelDialog::Change(const Entry& entry, bool live, const std::string& value) {
  ReportResult(entry, live, ApplyFlag(entry.name, value));
}

void PanelDialog::ReportResult(const Entry& entry, bool live, bool ok) {
  const auto& colors = imgui_drawer()->style().settings;
  if (!ok) {
    std::string text = std::string(entry.label) + " was not changed: the value was rejected.";
    if (std::string_view(entry.name) == "vsync") {
      text += " VSync must stay on while a frame-rate mode other than Original is active.";
    } else {
      text += " See the log for details.";
    }
    SetStatus(std::move(text), colors.warning);
    return;
  }
  SetStatus(std::string(entry.label) +
                (live ? " changed." : " changed; it applies after a restart. Save to keep it."),
            colors.lifecycle_live);
}

void PanelDialog::Save() {
  // The same call and file as Save to config in the runtime settings overlay.
  rex::cvar::SaveConfig(state_.config_path());
  REXLOG_INFO("Skate 2 settings panel: saved settings to {}", state_.config_path().string());
  std::string text = "Saved to " + state_.config_path().filename().string() + ".";
  if (!pending_labels_.empty()) text += " Restart the game to apply the remaining changes.";
  SetStatus(std::move(text), imgui_drawer()->style().settings.lifecycle_live);
}

void PanelDialog::NoteHelp(const std::string& help) {
  if (ImGui::IsItemFocused() || ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) {
    help_ = help;
  }
}

void PanelDialog::SetStatus(std::string text, const ImVec4& color) {
  status_ = std::move(text);
  status_color_ = color;
}

}  // namespace skate2_panel

// ---- Panel state implementation ----------------------------------------------

Skate2SettingsPanelState::Skate2SettingsPanelState(rex::ui::WindowedAppContext& app_context,
                                                   rex::ui::ImGuiDrawer* drawer,
                                                   std::filesystem::path config_path)
    : app_context_(app_context), drawer_(drawer), config_path_(std::move(config_path)) {}

Skate2SettingsPanelState::~Skate2SettingsPanelState() {
  Shutdown();
}

void Skate2SettingsPanelState::Start() {
  if (started_) return;
  started_ = true;
  for (const char* name : kTrackedFlags) {
    if (!FlagExists(name)) continue;
    startup_values_[name] = rex::cvar::GetFlagByName(name);
    if (rex::cvar::GetFlagSource(name) == rex::cvar::Source::kCommandLine) {
      set_at_launch_.insert(name);
    }
  }
  startup_scale_ = CurrentRenderScale();
#if defined(_WIN32)
  poll_thread_ = std::thread([this] { PollLoop(); });
#endif
  const std::string key = rex::cvar::GetFlagByName("bind_skate2_settings");
  REXLOG_INFO("Skate 2 settings panel ready: press {} or hold Back + Start on a controller",
              key.empty() ? std::string("F1") : key);
}

void Skate2SettingsPanelState::Shutdown() {
  {
    std::lock_guard lock(poll_mutex_);
    stop_polling_ = true;
  }
  poll_wake_.notify_all();
  if (poll_thread_.joinable()) poll_thread_.join();
  g_panel_open.store(false, std::memory_order_release);
  dialog_.reset();
}

void Skate2SettingsPanelState::Toggle() {
  if (g_panel_open.load(std::memory_order_acquire)) {
    Close();
  } else {
    Open();
  }
}

void Skate2SettingsPanelState::Open() {
  if (!drawer_) return;
  if (!dialog_) dialog_ = std::make_unique<PanelDialog>(drawer_, *this);
  g_release_pending.store(false, std::memory_order_relaxed);
  g_panel_open.store(true, std::memory_order_release);
  REXLOG_INFO("Skate 2 settings panel opened");
}

void Skate2SettingsPanelState::Close() {
  if (g_panel_open.exchange(false, std::memory_order_acq_rel)) {
    ArmReleaseGuard();
    REXLOG_INFO("Skate 2 settings panel closed");
  }
  dialog_.reset();
}

void Skate2SettingsPanelState::RequestCloseFromDraw() {
  if (!g_panel_open.exchange(false, std::memory_order_acq_rel)) return;
  ArmReleaseGuard();
  REXLOG_INFO("Skate 2 settings panel closed");
  app_context_.CallInUIThreadDeferred([weak = weak_from_this()] {
    const auto self = weak.lock();
    // Reopened before this ran: keep the dialog.
    if (self && !g_panel_open.load(std::memory_order_acquire)) self->dialog_.reset();
  });
}

void Skate2SettingsPanelState::PostToggle() {
  app_context_.CallInUIThread([weak = weak_from_this()] {
    if (const auto self = weak.lock()) self->Toggle();
  });
}

void Skate2SettingsPanelState::PollLoop() {
  PadReader reader;
  bool combo_down = false;
  bool combo_fired = false;
  Clock::time_point combo_since{};
  std::unique_lock lock(poll_mutex_);
  while (!stop_polling_) {
    lock.unlock();
    const PadState pad = reader.Read();
    {
      std::lock_guard pad_lock(pad_mutex_);
      latest_pad_ = pad;
    }
    const auto now = Clock::now();
    const bool combo = pad.connected && (pad.buttons & kShortcutButtons) == kShortcutButtons;
    if (combo) {
      if (!combo_down) {
        combo_down = true;
        combo_fired = false;
        combo_since = now;
      }
      // Withhold game input while the shortcut is held, so holding Start
      // does not leave the game paused behind the panel.
      g_shortcut_held.store(true, std::memory_order_release);
      if (!combo_fired && now - combo_since >= kShortcutHold) {
        combo_fired = true;
        PostToggle();
      }
    } else {
      combo_down = false;
      g_shortcut_held.store(false, std::memory_order_release);
    }
    if (g_release_pending.load(std::memory_order_acquire)) {
      const bool pad_idle = pad.buttons == 0 && pad.left_trigger <= kTriggerThreshold &&
                            pad.right_trigger <= kTriggerThreshold;
      if ((pad_idle && !AnyMenuKeyDown()) ||
          NowMs() >= g_release_deadline_ms.load(std::memory_order_relaxed)) {
        g_release_pending.store(false, std::memory_order_release);
      }
    }
    lock.lock();
    poll_wake_.wait_for(lock, kPollInterval, [this] { return stop_polling_; });
  }
}

// ---- Public interface -------------------------------------------------------------

Skate2SettingsPanel::Skate2SettingsPanel(rex::ui::WindowedAppContext& app_context,
                                         rex::ui::ImGuiDrawer* drawer,
                                         std::filesystem::path config_path)
    : state_(std::make_shared<Skate2SettingsPanelState>(app_context, drawer,
                                                        std::move(config_path))) {}

Skate2SettingsPanel::~Skate2SettingsPanel() {
  if (state_) state_->Shutdown();
}

void Skate2SettingsPanel::ConfigureFonts(ImFontAtlas* atlas) {
#if defined(_WIN32)
  if (!atlas) return;
  wchar_t windows_directory[MAX_PATH] = {};
  const UINT length = GetWindowsDirectoryW(windows_directory, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return;
  const std::filesystem::path fonts = std::filesystem::path(windows_directory) / L"Fonts";
  // Segoe UI on Windows; Tahoma and Arial are also provided by Wine/Proton.
  for (const wchar_t* name : {L"segoeui.ttf", L"tahoma.ttf", L"arial.ttf"}) {
    const std::filesystem::path path = fonts / name;
    std::error_code error;
    if (!std::filesystem::is_regular_file(path, error)) continue;
    const std::string file = path.string();
    static const ImWchar kLatin1[] = {0x0020, 0x00FF, 0};
    for (size_t i = 0; i < kFontBakeSizes.size(); ++i) {
      ImFontConfig config;
      config.PixelSnapH = true;
      g_fonts[i].font = atlas->AddFontFromFileTTF(file.c_str(), kFontBakeSizes[i], &config, kLatin1);
      g_fonts[i].baked_size = kFontBakeSizes[i];
    }
    return;
  }
  REXLOG_WARN("Skate 2 settings panel: no system UI font found; using the default font.");
#else
  (void)atlas;
#endif
}

bool Skate2SettingsPanel::BlocksGameInput() {
  if (g_panel_open.load(std::memory_order_acquire)) return true;
  if (g_shortcut_held.load(std::memory_order_acquire)) return true;
  return g_release_pending.load(std::memory_order_acquire) &&
         NowMs() < g_release_deadline_ms.load(std::memory_order_relaxed);
}

void Skate2SettingsPanel::Start() {
  state_->Start();
}

void Skate2SettingsPanel::Toggle() {
  state_->Toggle();
}
