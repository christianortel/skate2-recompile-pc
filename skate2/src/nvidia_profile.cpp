// NVIDIA driver application profile: optional "Prefer maximum performance".
//
// Based on nvidia_app_profile.cpp from the rexglue-skate3 fork of the ReXGlue
// SDK. Copyright (c) 2026, Tom Clay. Portions derived from the Xenia project,
// Copyright (c) 2022, Ben Vanik and Xenia project contributors. Distributed
// under the BSD 3-Clause License included with the ReXGlue license notice.
//
// Interface ids, structure layouts and setting values follow the public NVAPI
// SDK headers (nvapi_interface.h, nvapi.h, NvApiDriverSettings.h).

#include "nvidia_profile.h"

#include <rex/cvar.h>
#include <rex/logging.h>

#include <string>

REXCVAR_DEFINE_STRING(skate2_nvidia_max_performance, "off", "Skate 2",
    "NVIDIA GPUs only. on: set Power management mode to Prefer maximum performance in the "
    "NVIDIA driver profile for this executable, so the GPU keeps full clocks while the game is "
    "limited by the CPU. restore: remove that profile setting again. off: leave driver settings "
    "unchanged. The driver keeps the change until it is restored. Applied at startup.")
    .allowed({"off", "on", "restore"})
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <memory>

namespace {

using NvStatus = int32_t;
using NvSession = void*;
using NvProfile = void*;

constexpr NvStatus kNvOk = 0;
constexpr NvStatus kNvInvalidUserPrivilege = -137;
constexpr NvStatus kNvSettingNotFound = -160;
constexpr NvStatus kNvExecutableNotFound = -166;

// nvapi64.dll exports only nvapi_QueryInterface; every function is resolved
// through it by these ids from nvapi_interface.h.
constexpr uint32_t kIdInitialize = 0x0150E828;
constexpr uint32_t kIdCreateSession = 0x0694D52E;
constexpr uint32_t kIdDestroySession = 0xDAD9CFF8;
constexpr uint32_t kIdLoadSettings = 0x375DBD6B;
constexpr uint32_t kIdSaveSettings = 0xFCBC7E14;
constexpr uint32_t kIdFindProfileByName = 0x7E4A9A0B;
constexpr uint32_t kIdCreateProfile = 0xCC176068;
constexpr uint32_t kIdFindApplicationByName = 0xEEE566B2;
constexpr uint32_t kIdCreateApplication = 0x4347A9DE;
constexpr uint32_t kIdGetSetting = 0x73BF8338;
constexpr uint32_t kIdSetSetting = 0x577DD202;
constexpr uint32_t kIdDeleteProfileSetting = 0xE4A26362;

// PREFERRED_PSTATE_ID and PREFERRED_PSTATE_PREFER_MAX ("Power management
// mode" = "Prefer maximum performance").
constexpr uint32_t kPowerManagementModeId = 0x1057EB71;
constexpr uint32_t kPreferMaximumPerformance = 1;

constexpr uint32_t kDwordSetting = 0;                   // NVDRS_DWORD_TYPE
constexpr uint32_t kLocationCurrentProfile = 0;         // NVDRS_CURRENT_PROFILE_LOCATION
constexpr const wchar_t* kProfileName = L"Skate 2 PC";  // Used only when none exists.

constexpr uint32_t kStringMax = 2048;  // NVAPI_UNICODE_STRING_MAX
using NvString = uint16_t[kStringMax];

constexpr uint32_t StructVersion(size_t size, uint32_t version) {
  return uint32_t(size) | (version << 16);
}

struct NvApplicationV1 {
  uint32_t version;
  uint32_t is_predefined;
  NvString app_name;
  NvString user_friendly_name;
  NvString launcher;
};

struct NvProfileV1 {
  uint32_t version;
  NvString profile_name;
  uint32_t gpu_support;
  uint32_t is_predefined;
  uint32_t num_of_apps;
  uint32_t num_of_settings;
};

struct NvBinarySetting {
  uint32_t value_length;
  uint8_t value_data[4096];
};

struct NvSettingV1 {
  uint32_t version;
  NvString setting_name;
  uint32_t setting_id;
  uint32_t setting_type;
  uint32_t setting_location;
  uint32_t is_current_predefined;
  uint32_t is_predefined_valid;
  union {
    uint32_t u32_predefined_value;
    NvBinarySetting binary_predefined_value;
    NvString string_predefined_value;
  };
  union {
    uint32_t u32_current_value;
    NvBinarySetting binary_current_value;
    NvString string_current_value;
  };
};

static_assert(sizeof(NvApplicationV1) == 8 + 3 * 4096, "NVDRS_APPLICATION_V1 layout");
static_assert(sizeof(NvProfileV1) == 20 + 4096, "NVDRS_PROFILE_V1 layout");
static_assert(sizeof(NvSettingV1) == 24 + 4096 + 2 * 4100, "NVDRS_SETTING_V1 layout");

void Fill(NvString& out, const std::wstring& text) {
  std::memset(out, 0, sizeof(NvString));
  const size_t count = std::min(text.size(), size_t(kStringMax - 1));
  for (size_t i = 0; i < count; ++i) out[i] = uint16_t(text[i]);
}

std::string Narrow(const std::wstring& text) {
  std::string out;
  out.reserve(text.size());
  for (wchar_t c : text) out.push_back(c < 0x80 ? char(c) : '?');
  return out;
}

struct NvApi {
  NvStatus (*initialize)() = nullptr;
  NvStatus (*create_session)(NvSession*) = nullptr;
  NvStatus (*destroy_session)(NvSession) = nullptr;
  NvStatus (*load_settings)(NvSession) = nullptr;
  NvStatus (*save_settings)(NvSession) = nullptr;
  NvStatus (*find_profile_by_name)(NvSession, uint16_t*, NvProfile*) = nullptr;
  NvStatus (*create_profile)(NvSession, NvProfileV1*, NvProfile*) = nullptr;
  NvStatus (*find_application_by_name)(NvSession, uint16_t*, NvProfile*,
                                       NvApplicationV1*) = nullptr;
  NvStatus (*create_application)(NvSession, NvProfile, NvApplicationV1*) = nullptr;
  NvStatus (*get_setting)(NvSession, NvProfile, uint32_t, NvSettingV1*) = nullptr;
  NvStatus (*set_setting)(NvSession, NvProfile, NvSettingV1*) = nullptr;
  NvStatus (*delete_profile_setting)(NvSession, NvProfile, uint32_t) = nullptr;

  bool Load() {
    // The driver installs nvapi64.dll in System32; never search the game
    // folder for it.
    HMODULE module = LoadLibraryExW(L"nvapi64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return false;
    using QueryInterface = void* (*)(uint32_t);
    const auto query =
        reinterpret_cast<QueryInterface>(GetProcAddress(module, "nvapi_QueryInterface"));
    if (!query) return false;
    Resolve(query, kIdInitialize, initialize);
    Resolve(query, kIdCreateSession, create_session);
    Resolve(query, kIdDestroySession, destroy_session);
    Resolve(query, kIdLoadSettings, load_settings);
    Resolve(query, kIdSaveSettings, save_settings);
    Resolve(query, kIdFindProfileByName, find_profile_by_name);
    Resolve(query, kIdCreateProfile, create_profile);
    Resolve(query, kIdFindApplicationByName, find_application_by_name);
    Resolve(query, kIdCreateApplication, create_application);
    Resolve(query, kIdGetSetting, get_setting);
    Resolve(query, kIdSetSetting, set_setting);
    Resolve(query, kIdDeleteProfileSetting, delete_profile_setting);
    // The library stays loaded: NvAPI has been initialized from it, and the
    // driver loads it into Direct3D processes anyway.
    return initialize && create_session && destroy_session && load_settings && save_settings &&
           find_profile_by_name && create_profile && find_application_by_name &&
           create_application && get_setting && set_setting && delete_profile_setting;
  }

 private:
  template <typename Function>
  static void Resolve(void* (*query)(uint32_t), uint32_t id, Function& out) {
    out = reinterpret_cast<Function>(query(id));
  }
};

void ReportFailure(const char* operation, NvStatus status) {
  if (status == kNvInvalidUserPrivilege) {
    REXLOG_WARN(
        "NVIDIA driver profile: changing driver settings needs administrator rights on this PC. "
        "Set Power management mode for skate2.exe in the NVIDIA Control Panel instead.");
    return;
  }
  REXLOG_WARN("NVIDIA driver profile: {} failed (NvAPI status {})", operation, status);
}

std::wstring ExecutableName() {
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), DWORD(path.size()));
  if (length == 0 || length >= path.size()) return {};
  path.resize(length);
  const size_t separator = path.find_last_of(L"\\/");
  std::wstring name = separator == std::wstring::npos ? path : path.substr(separator + 1);
  std::transform(name.begin(), name.end(), name.begin(),
                 [](wchar_t c) { return wchar_t(std::towlower(c)); });
  return name;
}

// Finds the driver profile that applies to the executable. Returns kNvOk with
// a profile, kNvExecutableNotFound when no profile lists it, or another error.
NvStatus FindApplicationProfile(const NvApi& api, NvSession session, const std::wstring& exe,
                                NvProfile* profile) {
  NvString exe_name;
  Fill(exe_name, exe);
  auto application = std::make_unique<NvApplicationV1>();
  application->version = StructVersion(sizeof(NvApplicationV1), 1);
  *profile = nullptr;
  const NvStatus status = api.find_application_by_name(session, exe_name, profile,
                                                        application.get());
  if (status == kNvOk && !*profile) return kNvExecutableNotFound;
  return status;
}

void EnableMaximumPerformance(const NvApi& api, NvSession session, const std::wstring& exe) {
  const std::string name = Narrow(exe);
  NvProfile profile = nullptr;
  NvStatus status = FindApplicationProfile(api, session, exe, &profile);
  if (status == kNvExecutableNotFound) {
    // No profile lists the executable yet. Reuse the profile created by an
    // earlier run if the executable was since removed from it.
    NvString profile_name;
    Fill(profile_name, kProfileName);
    if (api.find_profile_by_name(session, profile_name, &profile) != kNvOk || !profile) {
      auto info = std::make_unique<NvProfileV1>();
      info->version = StructVersion(sizeof(NvProfileV1), 1);
      Fill(info->profile_name, kProfileName);
      profile = nullptr;
      status = api.create_profile(session, info.get(), &profile);
      if (status != kNvOk || !profile) {
        ReportFailure("creating a profile", status);
        return;
      }
    }
    auto application = std::make_unique<NvApplicationV1>();
    application->version = StructVersion(sizeof(NvApplicationV1), 1);
    Fill(application->app_name, exe);
    Fill(application->user_friendly_name, kProfileName);
    status = api.create_application(session, profile, application.get());
    if (status != kNvOk) {
      ReportFailure("adding the executable to the profile", status);
      return;
    }
  } else if (status != kNvOk) {
    ReportFailure("finding the executable's profile", status);
    return;
  }

  auto current = std::make_unique<NvSettingV1>();
  current->version = StructVersion(sizeof(NvSettingV1), 1);
  if (api.get_setting(session, profile, kPowerManagementModeId, current.get()) == kNvOk &&
      current->setting_location == kLocationCurrentProfile &&
      current->u32_current_value == kPreferMaximumPerformance) {
    REXLOG_INFO(
        "NVIDIA driver profile: power management mode for {} is already Prefer maximum "
        "performance",
        name);
    return;
  }

  auto setting = std::make_unique<NvSettingV1>();
  setting->version = StructVersion(sizeof(NvSettingV1), 1);
  setting->setting_id = kPowerManagementModeId;
  setting->setting_type = kDwordSetting;
  setting->u32_current_value = kPreferMaximumPerformance;
  status = api.set_setting(session, profile, setting.get());
  if (status != kNvOk) {
    ReportFailure("changing the power management mode", status);
    return;
  }
  status = api.save_settings(session);
  if (status != kNvOk) {
    ReportFailure("saving driver settings", status);
    return;
  }
  REXLOG_INFO(
      "NVIDIA driver profile: set power management mode to Prefer maximum performance for {}. "
      "Use skate2_nvidia_max_performance=restore to undo.",
      name);
}

void RestorePowerManagement(const NvApi& api, NvSession session, const std::wstring& exe) {
  const std::string name = Narrow(exe);
  NvProfile profile = nullptr;
  NvStatus status = FindApplicationProfile(api, session, exe, &profile);
  if (status == kNvExecutableNotFound) {
    REXLOG_INFO("NVIDIA driver profile: no profile lists {}; nothing to restore", name);
    return;
  }
  if (status != kNvOk) {
    ReportFailure("finding the executable's profile", status);
    return;
  }

  auto current = std::make_unique<NvSettingV1>();
  current->version = StructVersion(sizeof(NvSettingV1), 1);
  status = api.get_setting(session, profile, kPowerManagementModeId, current.get());
  if (status == kNvSettingNotFound ||
      (status == kNvOk && current->setting_location != kLocationCurrentProfile)) {
    REXLOG_INFO("NVIDIA driver profile: power management mode for {} already follows the "
                "global setting",
                name);
    return;
  }
  if (status != kNvOk) {
    ReportFailure("reading the power management mode", status);
    return;
  }
  if (current->u32_current_value != kPreferMaximumPerformance) {
    // Not the value this setting writes: the user chose it, so keep it.
    REXLOG_INFO(
        "NVIDIA driver profile: power management mode for {} was set to another value; left "
        "unchanged",
        name);
    return;
  }
  status = api.delete_profile_setting(session, profile, kPowerManagementModeId);
  if (status != kNvOk) {
    ReportFailure("removing the power management mode", status);
    return;
  }
  status = api.save_settings(session);
  if (status != kNvOk) {
    ReportFailure("saving driver settings", status);
    return;
  }
  REXLOG_INFO("NVIDIA driver profile: power management mode for {} restored to the driver "
              "default",
              name);
}

}  // namespace

void ApplySkate2NvidiaProfile() {
  std::string mode = rex::cvar::GetFlagByName("skate2_nvidia_max_performance");
  std::transform(mode.begin(), mode.end(), mode.begin(),
                 [](unsigned char c) { return char(std::tolower(c)); });
  if (mode == "off" || mode.empty()) return;
  const bool enable = mode == "on";
  if (!enable && mode != "restore") {
    REXLOG_WARN("skate2_nvidia_max_performance '{}' ignored: use off, on or restore", mode);
    return;
  }

  NvApi api;
  if (!api.Load() || api.initialize() != kNvOk) {
    REXLOG_INFO("NVIDIA driver profile: no NVIDIA driver found; skate2_nvidia_max_performance "
                "has no effect");
    return;
  }
  const std::wstring exe = ExecutableName();
  if (exe.empty()) return;

  NvSession session = nullptr;
  NvStatus status = api.create_session(&session);
  if (status != kNvOk || !session) {
    ReportFailure("opening a driver settings session", status);
    return;
  }
  status = api.load_settings(session);
  if (status != kNvOk) {
    ReportFailure("loading driver settings", status);
  } else if (enable) {
    EnableMaximumPerformance(api, session, exe);
  } else {
    RestorePowerManagement(api, session, exe);
  }
  api.destroy_session(session);
}

#else  // !_WIN32

void ApplySkate2NvidiaProfile() {}

#endif  // _WIN32
