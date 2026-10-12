#include "automatic_gpu_selection.h"

#include <rex/cvar.h>
#include <rex/logging.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <optional>

namespace {
std::optional<UINT> FindPreferredAdapter() {
  using Microsoft::WRL::ComPtr;
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return std::nullopt;
  ComPtr<IDXGIFactory6> preference_factory;
  if (FAILED(factory.As(&preference_factory))) return std::nullopt;

  for (UINT rank = 0;; ++rank) {
    ComPtr<IDXGIAdapter1> preferred;
    if (FAILED(preference_factory->EnumAdapterByGpuPreference(
            rank, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&preferred)))) {
      break;
    }
    DXGI_ADAPTER_DESC1 preferred_desc{};
    if (FAILED(preferred->GetDesc1(&preferred_desc)) ||
        (preferred_desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) continue;
    // A null output tests support without creating a device (success is S_FALSE).
    if (FAILED(D3D12CreateDevice(preferred.Get(), D3D_FEATURE_LEVEL_11_0,
                                __uuidof(ID3D12Device), nullptr))) continue;

    // The SDK consumes EnumAdapters1 indices, not performance-order indices.
    for (UINT index = 0;; ++index) {
      ComPtr<IDXGIAdapter1> adapter;
      if (FAILED(factory->EnumAdapters1(index, &adapter))) break;
      DXGI_ADAPTER_DESC1 desc{};
      if (SUCCEEDED(adapter->GetDesc1(&desc)) &&
          desc.AdapterLuid.HighPart == preferred_desc.AdapterLuid.HighPart &&
          desc.AdapterLuid.LowPart == preferred_desc.AdapterLuid.LowPart) {
        return index;
      }
    }
  }
  return std::nullopt;
}
}  // namespace
#endif

AutomaticGpuSelection::AutomaticGpuSelection() {
#if defined(_WIN32)
  // Config, environment and command-line preferences have all been loaded.
  // Checking the source also preserves an explicitly requested -1 or -2.
  if (!rex::cvar::GetFlagInfo("d3d12_adapter") ||
      rex::cvar::GetFlagSource("d3d12_adapter") != rex::cvar::Source::kDefault ||
      rex::cvar::Query<int32_t>("d3d12_adapter") != -1) return;
  auto adapter = FindPreferredAdapter();
  if (!adapter) {
    REXLOG_DEBUG("Automatic GPU selection unavailable; retaining the default adapter");
    return;
  }
  applied_ = rex::cvar::SetFlagByName("d3d12_adapter", std::to_string(*adapter));
  if (applied_) {
    REXLOG_INFO("Automatic high-performance GPU selection: DXGI adapter {}", *adapter);
  }
#endif
}

AutomaticGpuSelection::~AutomaticGpuSelection() {
  // Presentation owns the created provider, which guest GPU setup reuses.
  // Restore the default so Settings Save never stores this machine's index.
  if (applied_) rex::cvar::ResetToDefault("d3d12_adapter");
}
