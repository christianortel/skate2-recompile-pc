#pragma once

// In-game Skate 2 settings panel.
//
// A short list of the PC settings players change most (frame rate, rendering,
// display, driver and world detail), with presets based on the supplied
// launcher profiles. It opens with a keyboard shortcut (F1 by default, the
// bind_skate2_settings setting) or by holding Back + Start on a controller for
// about a second, and is navigated with the mouse, the keyboard or the
// controller.
//
// Every value is read and written through the runtime settings registry by
// name, so settings this build does not register are left out of the panel.
// Settings that apply immediately change while the game runs; the others are
// marked as needing a restart. "Save" writes the same configuration file as
// the runtime settings overlay (F4).
//
// While the panel is open, game input is withheld.

#include <filesystem>
#include <memory>

struct ImFontAtlas;

namespace rex::ui {
class ImGuiDrawer;
class WindowedAppContext;
}  // namespace rex::ui

class Skate2SettingsPanelState;

class Skate2SettingsPanel {
 public:
  Skate2SettingsPanel(rex::ui::WindowedAppContext& app_context, rex::ui::ImGuiDrawer* drawer,
                      std::filesystem::path config_path);
  ~Skate2SettingsPanel();
  Skate2SettingsPanel(const Skate2SettingsPanel&) = delete;
  Skate2SettingsPanel& operator=(const Skate2SettingsPanel&) = delete;

  // Adds the panel's font to the ImGui atlas. Call from
  // ReXApp::OnConfigureFonts; without it the panel scales the default font.
  static void ConfigureFonts(ImFontAtlas* atlas);

  // Whether game input should be withheld: the panel is open, its controller
  // shortcut is being held, or a key or button used to close it has not been
  // released yet. Safe to call from any thread, at any time.
  static bool BlocksGameInput();

  // Records the values this run started with, for the restart notices, and
  // starts watching for the controller shortcut. Call once on the UI thread
  // after the runtime is set up.
  void Start();

  // Opens or closes the panel. UI thread only.
  void Toggle();

 private:
  std::shared_ptr<Skate2SettingsPanelState> state_;
};
