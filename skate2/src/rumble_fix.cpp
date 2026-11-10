// Controller rumble: no idle vibration on pads reported as wireless.
//
// The game's rumble path
// ----------------------
// Each controller object (one per user, 0x20 bytes apart) keeps:
//
//   pad+8   user index
//   pad+14  requested left (low-frequency) motor speed, u16
//   pad+16  left speed last sent
//   pad+18  requested right (high-frequency) motor speed, u16
//   pad+20  right speed last sent
//   pad+22  XINPUT_VIBRATION handed to XInputSetState
//
// The rumble manager resets (sub_825AC4A8) and ticks (sub_825AC5C0, which
// also decays and retires effects) by summing its active effects per motor, clamping each sum to
// [0, 1] and passing it to the motor setter sub_827B8698(pad, motor,
// intensity). With no active effect the intensity is exactly 0.0. The pad
// update (sub_827B85F0) calls XInputSetState (sub_82C72500) only when a
// requested speed differs from the last one sent.
//
// The setter queries XInputGetCapabilities, and for a gamepad that reports
// XINPUT_CAPS_WIRELESS it remaps the intensity before scaling it to 0..65535:
//
//   left  = clamp(1.20 * i - 0.02, 0, 1)
//   right = clamp(1.05 * i + 0.05, 0, 1)
//
// The right motor curve has a 5% floor, so "off" becomes speed 3276. The curve
// was tuned for Xbox 360 wireless controller motors, where that floor is not
// felt. Host pads that the runtime reports as wireless (SDL does so for
// Bluetooth controllers, for example) do spin at 5%. The game sends (0, 3276) once at boot
// and then nothing, because the request never changes. SDL arms each rumble
// request for at most 65.5 seconds, so the buzz stops about a minute later,
// and it comes back whenever an in-game rumble effect ends.
//
// The fix
// -------
// Zero means off. When the game asks for no vibration on a motor, the setter
// receives -1.0 instead. That lies below both curve offsets: the wireless
// branch clamps it to 0, and the wired branch converts the negative product to
// 0. Either way the original function stores speed 0. It still runs in full,
// including its capability query. Any intensity above zero passes through
// unchanged, so in-game rumble keeps the game's own curve. The substitution
// happens before the original runs, so the pad update thread never sees the
// floor value, not even briefly.

#include <rex/logging.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

#include <atomic>
#include <cstdint>
#include <cstring>

extern "C" REX_FUNC(__imp__sub_827B8698);

namespace {

// Offset of the requested left motor speed; the right one follows 4 bytes on.
constexpr uint32_t kPadRequestedSpeed = 14;
constexpr uint32_t kMotorStride = 4;
constexpr uint32_t kMotorCount = 2;

// Below both wireless curve offsets (-0.02 and +0.05 against gains of 1.2 and
// 1.05), and negative for the wired branch.
constexpr double kOffIntensity = -1.0;

std::atomic<bool> g_logged_active{false};
std::atomic<bool> g_logged_mismatch{false};

uint16_t LoadU16(uint8_t* base, uint32_t address) {
  uint16_t raw;
  // Controller objects live in the guest heap, below the 0xE0000000 mirror.
  std::memcpy(&raw, base + address, sizeof(raw));
  return __builtin_bswap16(raw);
}

}  // namespace

extern "C" REX_FUNC(sub_827B8698) {
  const uint32_t pad = ctx.r3.u32;
  const uint32_t motor = ctx.r4.u32;
  // NaN, negative and zero all mean no vibration; the game clamps to [0, 1].
  const bool off = motor < kMotorCount && !(ctx.f1.f64 > 0.0);
  if (off) {
    ctx.f1.f64 = kOffIntensity;
  }

  __imp__sub_827B8698(ctx, base);

  if (!off) {
    return;
  }
  if (!g_logged_active.exchange(true, std::memory_order_relaxed)) {
    REXLOG_INFO(
        "Skate 2 rumble: motors the game turns off are sent as stopped, without the "
        "wireless-controller idle floor");
  }
  const uint16_t stored = LoadU16(base, pad + kPadRequestedSpeed + motor * kMotorStride);
  if (stored != 0 && !g_logged_mismatch.exchange(true, std::memory_order_relaxed)) {
    REXLOG_WARN("Skate 2 rumble: pad 0x{:08X} motor {} still requested speed {} when turned off",
                pad, motor, stored);
  }
}
