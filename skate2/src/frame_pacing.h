#pragma once

// Host frame limiter for the guest render loop.
//
// skate2_frame_limit paces each guest swap on an absolute schedule so frames
// are submitted at an even rate instead of the irregular intervals an
// unlimited guest produces. "auto" targets slightly below the refresh rate of
// the monitor that shows the game window (the usual variable-refresh setup).

// Validates the configured value, installs live-change handling and records
// the game window used by "auto". Call once on the startup thread after the
// window exists. Returns false after reporting an invalid configured value.
bool ConfigureSkate2FrameLimit(void* native_window);

// Called by the guest swap hook once per guest frame. Returns immediately
// while the limiter is off.
void PaceSkate2Frame();
