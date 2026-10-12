#pragma once

#include <rex/ppc/context.h>

// Configure once before GPU setup. Saved refresh values are normalized here;
// the generated instruction hook only reads the resulting immutable settings.
void ConfigureSkate2FrameRate();

// Called after the GPU plugin registers its flags, before guest GPU startup.
// Reports startup conflicts and guards VSync edits in active optional modes.
// Rejected edits leave the existing flag value and source unchanged.
bool ValidateSkate2FrameRate();

// C++ linkage and PPCRegister& match RexGlue's generated mid-assembly hook ABI.
void Skate2PresentationInterval(PPCRegister& r11);
