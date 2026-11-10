// Draw-distance and LOD-distance scaling.
//
// World object cull (skate2_draw_distance_scale)
// ----------------------------------------------
// Once per frame the render update (sub_823A6E98) refreshes the active view
// through sub_82327A88. That function copies the view frustum into the cull
// object embedded at view+384 and reloads the cull tuning from the view's
// attribute layout (layout pointer at view+5668):
//
//   view+5632  pixel scale, a copy of view+224
//   view+5636  radius bias added to every bounding sphere   (layout +84)
//   view+5640  minimum projected size                       (layout +44)
//   view+5648  screen-contribution threshold                (layout +52)
//   view+5652  contribution engage distance                 (layout +48)
//   view+5656  contribution factor                          (layout +28)
//
// The vectorized cull job (sub_826AAB28, via sub_823B9980) keeps an object
// while  r * scale / (d - r) >= min_size,  where r is its bounding radius
// plus the bias and d its distance from the camera. Batches that also carry
// extents additionally need  extent * factor / depth^2 >= threshold  once the
// view depth reaches the engage distance. These tests decide when world
// meshes stop being drawn at range; the result only gates visibility (the
// consumers keep or drop an entry by testing it against zero).
//
// To move the cut-offs out by k: the projected size falls as 1/d, so the
// minimum size is divided by k; the contribution term falls as 1/d^2, so its
// threshold is divided by k^2; the engage distance is a plain distance and is
// multiplied by k. Together they scale  max(engage, contribution limit)  by
// exactly k.
//
// Entity LOD bands (skate2_lod_distance_scale)
// --------------------------------------------
// The scene culling manager's per-frame cull pass (sub_8237A790) starts by
// calling sub_8234EE40, which reads two three-element float attributes from
// the manager's attribute instance (manager+21336) and stores each element
// squared: manager+21312/21316/21320 and manager+21324/21328/21332. The
// per-frame LOD pass (sub_8237B398 -> sub_823B3B08 -> sub_823B3A38) compares
// an entity's squared distance from the camera (camera position at
// manager+21296) against the first two values of a set: nearer than the first
// selects LOD 0, nearer than the second LOD 1, otherwise LOD 2. Only render
// entities of type 0x22 take this path: character models (flags 0x2022, the
// class constructed by sub_8267F1A0) use the first set, vehicle models (flags
// 0x422, sub_8267F548, which binds the wheel bones) the second. Static world
// geometry is not routed through these bands.
//
// The values are squared distances, so pushing the switches out by k means
// multiplying them by k^2.
//
// Both refresh functions rewrite their values from attribute data on every
// call, so rescaling right after the original runs never compounds and a
// changed setting applies on the next frame.

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

REXCVAR_DEFINE_DOUBLE(skate2_draw_distance_scale, 1.0, "Skate 2",
    "Scale the view-cull distances at which the game stops drawing world meshes (street "
    "furniture, building detail and other small world objects). 1 = original console "
    "behavior. Range 0.5 to 8. Larger values draw more objects and cost GPU and CPU time. "
    "Only geometry the game has already loaded can appear; this does not load more of "
    "the world. Applies immediately.")
    .range(0.5, 8.0)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_DOUBLE(skate2_lod_distance_scale, 1.0, "Skate 2",
    "Scale how far away character and vehicle models keep full detail before switching to "
    "lower-detail versions. 1 = original console behavior. Range 0.5 to 8. Larger values "
    "keep detailed models over a longer distance and cost GPU time. Does not change where "
    "pedestrians and props appear. Applies immediately.")
    .range(0.5, 8.0)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

extern "C" REX_FUNC(__imp__sub_82327A88);
extern "C" REX_FUNC(__imp__sub_8234EE40);

namespace {

constexpr double kMinScale = 0.5;
constexpr double kMaxScale = 8.0;

// View cull tuning, rewritten by sub_82327A88.
constexpr uint32_t kViewPixelScale = 5632;
constexpr uint32_t kViewRadiusBias = 5636;
constexpr uint32_t kViewMinProjectedSize = 5640;
constexpr uint32_t kViewContributionThreshold = 5648;
constexpr uint32_t kViewEngageDistance = 5652;
constexpr uint32_t kViewContributionFactor = 5656;
constexpr uint32_t kViewAttributeLayout = 5668;

// Squared LOD switch distances, rewritten by sub_8234EE40.
constexpr uint32_t kManagerLodBands = 21312;
constexpr uint32_t kLodBandCount = 6;

double ClampScale(double value) {
  if (!std::isfinite(value)) return 1.0;
  if (value < kMinScale) return kMinScale;
  if (value > kMaxScale) return kMaxScale;
  return value;
}

// A scale cvar as read by the guest render thread. The value is re-read on
// every call (once per frame), so runtime edits, config reloads and resets
// all take effect on the next frame. The storage is an aligned double that
// the registry assigns in one store, so on x64 this unlocked read cannot see
// a torn value; at worst it sees the previous setting for one more frame.
class ScaleSetting {
 public:
  explicit ScaleSetting(double& (*storage)()) : storage_(storage) {}

  double Current() const {
    return ClampScale(*static_cast<volatile const double*>(&storage_()));
  }

  // True once for the first application and once per later change of scale.
  bool ShouldLog(double scale) {
    return logged_.exchange(scale, std::memory_order_relaxed) != scale;
  }

 private:
  double& (*storage_)();
  std::atomic<double> logged_{0.0};
};

ScaleSetting g_draw_scale(&FLAGS_skate2_draw_distance_scale_storage_);
ScaleSetting g_lod_scale(&FLAGS_skate2_lod_distance_scale_storage_);

bool IsActive(double scale) { return std::fabs(scale - 1.0) > 1e-6; }

bool PlausibleObject(uint32_t address, uint32_t size) {
  return address >= 0x10000u && address <= 0xFFFFFFFFu - size;
}

uint8_t* GuestPtr(uint8_t* base, uint32_t address) {
  // Matches the generated code's view of the 0xE0000000 physical mirror.
  return base + address + (address >= 0xE0000000u ? 0x1000u : 0u);
}

float LoadF32(uint8_t* base, uint32_t address) {
  uint32_t raw;
  std::memcpy(&raw, GuestPtr(base, address), sizeof(raw));
  raw = __builtin_bswap32(raw);
  float value;
  std::memcpy(&value, &raw, sizeof(value));
  return value;
}

uint32_t LoadU32(uint8_t* base, uint32_t address) {
  uint32_t raw;
  std::memcpy(&raw, GuestPtr(base, address), sizeof(raw));
  return __builtin_bswap32(raw);
}

void StoreF32(uint8_t* base, uint32_t address, float value) {
  uint32_t raw;
  std::memcpy(&raw, &value, sizeof(raw));
  raw = __builtin_bswap32(raw);
  std::memcpy(GuestPtr(base, address), &raw, sizeof(raw));
}

bool UsablePositive(float value) { return std::isfinite(value) && value > 0.0f; }

// Distance in meters for logging a squared band; negative values pass through.
double BandMeters(float squared) {
  return squared > 0.0f ? std::sqrt(double(squared)) : double(squared);
}

void ScaleViewCull(uint8_t* base, uint32_t view) {
  const double scale = g_draw_scale.Current();
  const float min_size = LoadF32(base, view + kViewMinProjectedSize);
  const float threshold = LoadF32(base, view + kViewContributionThreshold);
  const float engage = LoadF32(base, view + kViewEngageDistance);
  float new_min_size = min_size;
  float new_threshold = threshold;
  float new_engage = engage;
  if (IsActive(scale)) {
    if (UsablePositive(min_size)) new_min_size = float(double(min_size) / scale);
    if (UsablePositive(threshold)) new_threshold = float(double(threshold) / (scale * scale));
    if (UsablePositive(engage)) new_engage = float(double(engage) * scale);
    StoreF32(base, view + kViewMinProjectedSize, new_min_size);
    StoreF32(base, view + kViewContributionThreshold, new_threshold);
    StoreF32(base, view + kViewEngageDistance, new_engage);
  }
  if (g_draw_scale.ShouldLog(scale)) {
    REXLOG_INFO(
        "Skate 2 draw distance x{:.2f}: view 0x{:08X} min projected size {} -> {}, "
        "contribution threshold {} -> {}, engage distance {} -> {} "
        "(pixel scale {}, radius bias {}, contribution factor {}, layout 0x{:08X})",
        scale, view, min_size, new_min_size, threshold, new_threshold, engage, new_engage,
        LoadF32(base, view + kViewPixelScale), LoadF32(base, view + kViewRadiusBias),
        LoadF32(base, view + kViewContributionFactor),
        LoadU32(base, view + kViewAttributeLayout));
  }
}

void ScaleLodBands(uint8_t* base, uint32_t manager) {
  const double scale = g_lod_scale.Current();
  const double squared_scale = scale * scale;
  float before[kLodBandCount];
  float after[kLodBandCount];
  for (uint32_t i = 0; i < kLodBandCount; ++i) {
    const uint32_t address = manager + kManagerLodBands + i * 4;
    before[i] = LoadF32(base, address);
    after[i] = before[i];
    if (IsActive(scale) && UsablePositive(before[i])) {
      after[i] = float(double(before[i]) * squared_scale);
      StoreF32(base, address, after[i]);
    }
  }
  if (g_lod_scale.ShouldLog(scale)) {
    REXLOG_INFO(
        "Skate 2 LOD distance x{:.2f}: manager 0x{:08X} switch distances (m) "
        "characters {:.1f}/{:.1f}/{:.1f} -> {:.1f}/{:.1f}/{:.1f}, "
        "vehicles {:.1f}/{:.1f}/{:.1f} -> {:.1f}/{:.1f}/{:.1f}",
        scale, manager, BandMeters(before[0]), BandMeters(before[1]), BandMeters(before[2]),
        BandMeters(after[0]), BandMeters(after[1]), BandMeters(after[2]),
        BandMeters(before[3]), BandMeters(before[4]), BandMeters(before[5]),
        BandMeters(after[3]), BandMeters(after[4]), BandMeters(after[5]));
  }
}

}  // namespace

// Per-frame view cull refresh. r3 is the view; the original rewrites the cull
// tuning from attribute data, then the configured scale is applied on top.
extern "C" REX_FUNC(sub_82327A88) {
  const uint32_t view = ctx.r3.u32;
  __imp__sub_82327A88(ctx, base);
  if (!PlausibleObject(view, kViewAttributeLayout + 4)) return;
  ScaleViewCull(base, view);
}

// Per-frame LOD band refresh. r3 is the scene culling manager; the original
// stores the six squared switch distances, then the configured scale is
// applied on top.
extern "C" REX_FUNC(sub_8234EE40) {
  const uint32_t manager = ctx.r3.u32;
  __imp__sub_8234EE40(ctx, base);
  if (!PlausibleObject(manager, kManagerLodBands + kLodBandCount * 4)) return;
  ScaleLodBands(base, manager);
}
