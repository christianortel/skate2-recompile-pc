# Display and quality options

The normal launcher uses 2x quality with unlimited presentation and the tested GPU synchronization fix. It keeps the game's current camera/aspect. A short 2x gameplay test on the development PC was reported sharper, smooth, and visually clean; other hardware and longer sessions remain unverified. Use **Launch Skate 2 - 1x Performance.cmd** for the original render scale with the same timing fix.

## Higher-resolution displays

**Launch Skate 2 - 2x Quality.cmd** and **Launch Skate 2 - 4x Quality.cmd** preserve the tested synchronization profile and increase both rendering axes equally. The 2x option passed the user's short visual/gameplay check; 4x is still experimental and untested. You can also use:

```powershell
.\scripts\Launch-Skate2.ps1 -FrameRate unlimited -RenderScale 2
```

Supported launcher scales are 1, 2, 3, and 4. Restart to change them. These are internal render scales, not output-resolution guarantees. Inspected world targets are 1152x640: 3x would be 3456x1920 and 4x would be 4608x2560 for those targets. Other passes use other dimensions. Calling 3x "native 4K" would therefore be inaccurate. Fullscreen uses the desktop display mode; a 4K desktop can display the result, subject to runtime testing.

GPU work and many target allocations grow roughly with the square of the scale. Start with 2x. If performance or graphics regress, restart at 1x. F4 Save can persist settings; an explicit `-RenderScale 1` restores both axis overrides and neutralizes the shared scale setting.

## Multiple monitors and windowed mode

```powershell
.\scripts\Launch-Skate2.ps1 -FrameRate unlimited -Monitor 2
.\scripts\Launch-Skate2.ps1 -FrameRate unlimited -Windowed
```

Monitor 0 is automatic; positive indices follow the SDK's display enumeration. Selection on multiple physical displays remains untested. The SDK normally starts in borderless fullscreen at the desktop display mode. The launcher does not change Windows display settings.

## 3840x1080 and 32:9 ultrawide

**True 32:9 is not supported yet.** Keeping the original 16:9 aspect on a 3840x1080 desktop yields a centered 1920x1080 image with side bars. Filling the whole panel by stretching does not reveal more of the world and distorts proportions.

Window and guest-resolution settings are coupled in this SDK; setting a 3840x1080 window can change the video mode reported to the game. Leave those settings unchanged for render-quality tests. Disabling letterboxing alone is not a camera fix.

The [Xenia game-patch collection](https://github.com/xenia-canary/game-patches) provides an existing Skate 2 aspect-ratio lead. The relevant game value participates in double-precision projection math; a generic 32/9 float replacement has not been validated. Proper support requires wider horizontal world visibility with correct proportions, plus HUD/minimap, menus, culling, replay, cutscenes, and effects checks. This is the next display feature to investigate, not a switch this build can safely advertise as finished.
