#pragma once

// Applies skate2_nvidia_max_performance to the NVIDIA driver's application
// profile for this executable. Call once at startup, before any Direct3D
// device is created, so the driver reads the updated profile in this run.
// Does nothing unless the setting is "on" or "restore", or on systems without
// an NVIDIA driver.
void ApplySkate2NvidiaProfile();
