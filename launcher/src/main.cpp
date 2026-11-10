// SPDX-License-Identifier: MIT
#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cwchar>
#include <string>
#include <vector>

namespace {
constexpr size_t kCaptureLimit = 64 * 1024;

class Handle {
 public:
  explicit Handle(HANDLE value = nullptr) : value_(value) {}
  ~Handle() { reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
  void reset(HANDLE value = nullptr) {
    if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
    value_ = value;
  }
 private:
  HANDLE value_;
};

struct Result {
  bool check_only = false;
  bool truncated = false;
  DWORD exit_code = 1;
  // Empty: not passed; the value saved in skate2.toml applies, or the game's
  // default profile (unlimited, 2x) when none is saved.
  std::wstring frame_rate;
  std::wstring render_scale;
  std::wstring frame_limit;  // Empty: not passed; the saved or default value applies.
  std::wstring nvidia_max_performance;  // Empty: not passed; the saved or default value applies.
  std::wstring draw_distance_scale;  // Empty: not passed; the saved or default value applies.
  std::wstring lod_distance_scale;  // Empty: not passed; the saved or default value applies.
  std::wstring report;
  std::wstring root;
  std::wstring script;
  std::wstring powershell;
  std::wstring error;
  std::string output;
};

std::wstring WindowsError(const wchar_t* action, DWORD code = GetLastError()) {
  wchar_t* message = nullptr;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, code, 0, reinterpret_cast<wchar_t*>(&message), 0, nullptr);
  std::wstring result = std::wstring(action) + L" (Windows error " +
                        std::to_wstring(code) + L").";
  if (message) {
    result += L"\n";
    result += message;
    LocalFree(message);
  }
  return result;
}

std::wstring Decode(const std::string& bytes, UINT code_page) {
  if (bytes.empty()) return {};
  const int count = MultiByteToWideChar(code_page, 0, bytes.data(),
                                      static_cast<int>(bytes.size()), nullptr, 0);
  if (count <= 0) return L"[Output could not be decoded.]";
  std::wstring text(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(code_page, 0, bytes.data(), static_cast<int>(bytes.size()),
                      text.data(), count);
  return text;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string bytes(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      bytes.data(), count, nullptr, nullptr);
  return bytes;
}

std::string Json(const std::wstring& value) {
  std::string result = "\"";
  constexpr char hex[] = "0123456789abcdef";
  for (unsigned char ch : Utf8(value)) {
    if (ch == '"' || ch == '\\') {
      result += '\\';
      result += static_cast<char>(ch);
    } else if (ch < 32) {
      result += "\\u00";
      result += hex[ch >> 4];
      result += hex[ch & 15];
    } else {
      result += static_cast<char>(ch);
    }
  }
  return result + '"';
}

// CommandLineToArgvW-compatible quoting, without invoking a command shell.
std::wstring Quote(const std::wstring& argument) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t ch : argument) {
    if (ch == L'\\') {
      ++slashes;
    } else {
      result.append(slashes * (ch == L'"' ? 2 : 1), L'\\');
      slashes = 0;
      if (ch == L'"') result += L'\\';
      result += ch;
    }
  }
  result.append(slashes * 2, L'\\');
  return result + L'"';
}

bool AbsolutePath(const std::wstring& path) {
  return (path.size() >= 3 && path[1] == L':' &&
          (path[2] == L'\\' || path[2] == L'/')) ||
         (path.size() >= 3 && path[0] == L'\\' && path[1] == L'\\');
}

// off, auto, or a whole frame rate from 20 to 1000. Digits only, so nothing
// else can reach the PowerShell command line.
bool ValidFrameLimit(const std::wstring& value) {
  if (value == L"off" || value == L"auto") return true;
  if (value.empty() || value.size() > 4) return false;
  for (wchar_t ch : value) {
    if (ch < L'0' || ch > L'9') return false;
  }
  const int rate = std::stoi(value);
  return rate >= 20 && rate <= 1000;
}

// Exact lowercase off, on or restore, so nothing else can reach the PowerShell
// command line.
bool ValidNvidiaMaxPerformance(const std::wstring& value) {
  return value == L"off" || value == L"on" || value == L"restore";
}

// A scale from 0.5 to 8 with at most three decimals, such as 1, 2.5 or 0.75:
// one digit, then optionally a dot and one to three digits. Digits and the dot
// only, so nothing else can reach the PowerShell command line, and a decimal
// comma cannot be misread.
bool ValidDistanceScale(const std::wstring& value) {
  if (value.empty() || value.size() > 5) return false;
  if (value[0] < L'0' || value[0] > L'9') return false;
  int thousandths = (value[0] - L'0') * 1000;
  if (value.size() > 1) {
    if (value[1] != L'.' || value.size() == 2) return false;
    int place = 100;
    for (size_t i = 2; i < value.size(); ++i) {
      if (value[i] < L'0' || value[i] > L'9') return false;
      thousandths += (value[i] - L'0') * place;
      place /= 10;
    }
  }
  return thousandths >= 500 && thousandths <= 8000;
}

bool ParseArguments(Result& result) {
  int count = 0;
  wchar_t** args = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!args) {
    result.error = WindowsError(L"Could not read launcher arguments");
    return false;
  }
  // Suppress dialogs even when another argument is invalid in a fixture run.
  for (int i = 1; i < count; ++i) {
    if (std::wcscmp(args[i], L"--check-only") == 0) result.check_only = true;
    if (std::wcscmp(args[i], L"--report") == 0 && i + 1 < count) result.report = args[i + 1];
  }
  for (int i = 1; i < count && result.error.empty(); ++i) {
    const std::wstring name = args[i];
    if (name == L"--check-only") continue;
    if (name != L"--report" && name != L"--frame-rate" && name != L"--render-scale" &&
        name != L"--frame-limit" && name != L"--nvidia-max-performance" &&
        name != L"--draw-distance" && name != L"--lod-distance") {
      result.error = L"Unknown launcher option: " + name;
      break;
    }
    if (++i == count) {
      result.error = L"Missing value for " + name;
      break;
    }
    const std::wstring value = args[i];
    if (name == L"--report") result.report = value;
    if (name == L"--render-scale") {
      if (value != L"1" && value != L"2" && value != L"3" && value != L"4")
        result.error = L"Render scale must be 1, 2, 3, or 4.";
      else result.render_scale = value;
    }
    if (name == L"--frame-rate") {
      const std::vector<std::wstring> supported = {
          L"original", L"60", L"120", L"144", L"165", L"200", L"240", L"unlimited"};
      if (std::find(supported.begin(), supported.end(), value) == supported.end())
        result.error = L"Frame rate must be original, 60, 120, 144, 165, 200, 240, or unlimited.";
      else result.frame_rate = value;
    }
    if (name == L"--frame-limit") {
      if (!ValidFrameLimit(value))
        result.error = L"Frame limit must be off, auto, or a frame rate from 20 to 1000.";
      else result.frame_limit = value;
    }
    if (name == L"--nvidia-max-performance") {
      if (!ValidNvidiaMaxPerformance(value))
        result.error = L"NVIDIA max performance must be off, on, or restore.";
      else result.nvidia_max_performance = value;
    }
    if (name == L"--draw-distance") {
      if (!ValidDistanceScale(value))
        result.error = L"Draw distance must be a number from 0.5 to 8 with at most three "
                       L"decimals and a dot as the decimal separator, such as 1.5.";
      else result.draw_distance_scale = value;
    }
    if (name == L"--lod-distance") {
      if (!ValidDistanceScale(value))
        result.error = L"LOD distance must be a number from 0.5 to 8 with at most three "
                       L"decimals and a dot as the decimal separator, such as 1.5.";
      else result.lod_distance_scale = value;
    }
  }
  LocalFree(args);
  if (!result.report.empty() && (!result.check_only || !AbsolutePath(result.report)))
    result.error = L"--report requires --check-only and an absolute output path.";
  if (result.check_only && result.report.empty())
    result.error = L"--check-only requires --report followed by an absolute output path.";
  return result.error.empty();
}

bool FindPaths(Result& result) {
  std::vector<wchar_t> path(512);
  for (;;) {
    const DWORD count = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!count) {
      result.error = WindowsError(L"Could not locate the launcher");
      return false;
    }
    if (count < path.size()) {
      result.root.assign(path.data(), count);
      result.root.resize(result.root.find_last_of(L"\\/"));
      break;
    }
    if (path.size() >= 32768) {
      result.error = L"The launcher path is too long.";
      return false;
    }
    path.resize(path.size() * 2);
  }
  result.script = result.root + L"\\scripts\\Launch-Skate2.ps1";
  const DWORD attributes = GetFileAttributesW(result.script.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    result.error = L"scripts\\Launch-Skate2.ps1 is missing. Extract the complete player package, "
                   L"then open Launch Skate 2.exe from that folder.";
    return false;
  }
  path.resize(MAX_PATH + 1);
  UINT count = GetSystemDirectoryW(path.data(), static_cast<UINT>(path.size()));
  if (count >= path.size()) {
    path.resize(static_cast<size_t>(count) + 1);
    count = GetSystemDirectoryW(path.data(), static_cast<UINT>(path.size()));
  }
  if (!count || count >= path.size()) {
    result.error = WindowsError(L"Could not locate Windows PowerShell");
    return false;
  }
  result.powershell.assign(path.data(), count);
  result.powershell += L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  return true;
}

std::vector<wchar_t> ChildEnvironment() {
  wchar_t* block = GetEnvironmentStringsW();
  if (!block) return {};
  std::vector<std::wstring> entries;
  for (const wchar_t* entry = block; *entry; entry += std::wcslen(entry) + 1) {
    if (_wcsnicmp(entry, L"PSModulePath=", 13) != 0) entries.emplace_back(entry);
  }
  FreeEnvironmentStringsW(block);
  // PowerShell constructs its native module defaults when this entry is absent.
  std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
    return _wcsicmp(a.c_str(), b.c_str()) < 0;
  });
  std::vector<wchar_t> result;
  for (const auto& entry : entries) {
    result.insert(result.end(), entry.begin(), entry.end());
    result.push_back(L'\0');
  }
  result.push_back(L'\0');
  if (result.size() == 1) result.push_back(L'\0');
  return result;
}

void Capture(Result& result, const char* bytes, size_t count) {
  if (result.output.size() + count > kCaptureLimit) {
    const size_t remove = result.output.size() + count - kCaptureLimit;
    result.output.erase(0, std::min(remove, result.output.size()));
    result.truncated = true;
  }
  result.output.append(bytes, count);
}

bool DrainOutput(HANDLE pipe, Result& result) {
  // Bound each drain so a continuously noisy child cannot starve process checks.
  for (unsigned i = 0; i != 64; ++i) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
      if (GetLastError() != ERROR_BROKEN_PIPE && result.error.empty())
        result.error = WindowsError(L"Could not read launcher output");
      return false;
    }
    if (!available) return true;
    char buffer[4096];
    DWORD count = 0;
    if (!ReadFile(pipe, buffer, std::min<DWORD>(available, sizeof(buffer)), &count, nullptr)) {
      if (GetLastError() != ERROR_BROKEN_PIPE && result.error.empty())
        result.error = WindowsError(L"Could not capture launcher output");
      return false;
    }
    Capture(result, buffer, count);
  }
  return true;
}

void Launch(Result& result) {
  auto environment = ChildEnvironment();
  if (environment.empty()) {
    result.error = WindowsError(L"Could not prepare the launcher environment");
    return;
  }
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  HANDLE read_raw = nullptr, write_raw = nullptr;
  if (!CreatePipe(&read_raw, &write_raw, &security, 0)) {
    result.error = WindowsError(L"Could not create the launcher output pipe");
    return;
  }
  Handle read(read_raw), write(write_raw);
  if (!SetHandleInformation(read.get(), HANDLE_FLAG_INHERIT, 0)) {
    result.error = WindowsError(L"Could not configure the launcher output pipe");
    return;
  }
  Handle input(CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (input.get() == INVALID_HANDLE_VALUE) {
    result.error = WindowsError(L"Could not prepare launcher input");
    return;
  }
  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
  std::vector<unsigned char> attributes(attribute_size);
  auto* attribute_list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  if (!InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size)) {
    result.error = WindowsError(L"Could not prepare launcher process attributes");
    return;
  }
  HANDLE inherited[] = {write.get(), input.get()};
  if (!UpdateProcThreadAttribute(attribute_list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited, sizeof(inherited), nullptr, nullptr)) {
    result.error = WindowsError(L"Could not isolate launcher handles");
    DeleteProcThreadAttributeList(attribute_list);
    return;
  }
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.StartupInfo.wShowWindow = SW_HIDE;
  startup.StartupInfo.hStdInput = input.get();
  startup.StartupInfo.hStdOutput = write.get();
  startup.StartupInfo.hStdError = write.get();
  startup.lpAttributeList = attribute_list;
  std::wstring command = Quote(result.powershell) +
      L" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
      Quote(result.script);
  if (!result.frame_rate.empty()) command += L" -FrameRate " + Quote(result.frame_rate);
  if (!result.render_scale.empty()) command += L" -RenderScale " + Quote(result.render_scale);
  if (!result.frame_limit.empty()) command += L" -FrameLimit " + Quote(result.frame_limit);
  if (!result.nvidia_max_performance.empty())
    command += L" -NvidiaMaxPerformance " + Quote(result.nvidia_max_performance);
  if (!result.draw_distance_scale.empty())
    command += L" -DrawDistanceScale " + Quote(result.draw_distance_scale);
  if (!result.lod_distance_scale.empty())
    command += L" -LodDistanceScale " + Quote(result.lod_distance_scale);
  if (result.check_only) command += L" -CheckOnly";
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(result.powershell.c_str(), command.data(),
      nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
      environment.data(), result.root.c_str(), &startup.StartupInfo, &process);
  const DWORD create_error = created ? ERROR_SUCCESS : GetLastError();
  DeleteProcThreadAttributeList(attribute_list);
  if (!created) {
    result.error = WindowsError(L"Could not start Windows PowerShell", create_error);
    return;
  }
  Handle child(process.hProcess), thread(process.hThread);
  write.reset();
  input.reset();
  bool pipe_open = true;
  for (;;) {
    if (pipe_open) pipe_open = DrainOutput(read.get(), result);
    const DWORD wait = WaitForSingleObject(child.get(), 20);
    if (wait == WAIT_OBJECT_0) break;
    if (wait != WAIT_TIMEOUT) {
      result.error = WindowsError(L"Could not wait for the launch helper");
      return;
    }
  }
  // A descendant may retain a pipe writer. Drain available bytes, never wait for
  // EOF after the launch helper exits (the helper already waits for the game).
  if (pipe_open) DrainOutput(read.get(), result);
  if (!GetExitCodeProcess(child.get(), &result.exit_code)) {
    result.error = WindowsError(L"Could not read the launch helper exit status");
    result.exit_code = 1;
  }
  if (!result.error.empty() && result.exit_code == 0) result.exit_code = 1;
}

bool WriteReport(const Result& result) {
  if (result.report.empty() || !AbsolutePath(result.report)) return false;
  const std::string json = "{\n  \"schemaVersion\": 1,\n  \"checkOnly\": true,\n  \"exitCode\": " +
      std::to_string(result.exit_code) + ",\n  \"frameRate\": " + Json(result.frame_rate) +
      ",\n  \"renderScale\": " +
      (result.render_scale.empty() ? std::string("null") : Utf8(result.render_scale)) +
      ",\n  \"frameLimit\": " + Json(result.frame_limit) +
      ",\n  \"nvidiaMaxPerformance\": " + Json(result.nvidia_max_performance) +
      ",\n  \"drawDistanceScale\": " + Json(result.draw_distance_scale) +
      ",\n  \"lodDistanceScale\": " + Json(result.lod_distance_scale) +
      ",\n  \"workingDirectory\": " + Json(result.root) +
      ",\n  \"script\": " + Json(result.script) + ",\n  \"powerShell\": " + Json(result.powershell) +
      ",\n  \"launcherError\": " + Json(result.error) + ",\n  \"outputTruncated\": " +
      (result.truncated ? "true" : "false") + ",\n  \"output\": " +
      Json(Decode(result.output, GetOEMCP())) + "\n}\n";
  Handle file(CreateFileW(result.report.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
      nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (file.get() == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  return WriteFile(file.get(), json.data(), static_cast<DWORD>(json.size()), &written, nullptr) &&
         written == json.size();
}
}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  Result result;
  if (ParseArguments(result) && FindPaths(result)) Launch(result);
  if (result.check_only) {
    if (!WriteReport(result)) return 1;
  } else if (result.exit_code != 0) {
    std::wstring message = result.error;
    if (message.empty()) message = L"The launch helper exited with code " + std::to_wstring(result.exit_code) + L".";
    std::wstring output = Decode(result.output, GetOEMCP());
    if (output.size() > 8000) output.erase(0, output.size() - 8000);
    if (!output.empty()) message += L"\n\n" + output;
    MessageBoxW(nullptr, message.c_str(), L"Skate 2 could not start", MB_OK | MB_ICONERROR);
  }
  return static_cast<int>(result.exit_code);
}
