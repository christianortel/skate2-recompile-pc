#include "crash_diagnostics.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dbghelp.h>

#include <cstdarg>
#include <csignal>
#include <cstdio>
#include <filesystem>

namespace {
constexpr size_t kPathCapacity = 32768;
constexpr DWORD kStatusHeapCorruption = 0xC0000374;
wchar_t report_path[kPathCapacity]{};
wchar_t dump_path[kPathCapacity]{};
HANDLE crash_requested = nullptr;
HANDLE crash_finished = nullptr;
DWORD writer_thread_id = 0;
DWORD fault_thread_id = 0;
LONG crash_claimed = 0;
EXCEPTION_RECORD fault_record{};
CONTEXT fault_context{};
EXCEPTION_POINTERS fault_pointers{&fault_record, &fault_context};
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;
using SignalHandler = void (*)(int);
SignalHandler previous_abort_handler = SIG_DFL;
const char* report_kind = "unhandled native exception";

void WriteLine(HANDLE file, const char* format, ...) noexcept {
  if (file == INVALID_HANDLE_VALUE) return;
  char text[2048];
  va_list arguments;
  va_start(arguments, format);
  const int length = vsnprintf(text, sizeof(text), format, arguments);
  va_end(arguments);
  if (length <= 0) return;
  DWORD written = 0;
  const DWORD bytes = static_cast<DWORD>(
      length < sizeof(text) ? length : sizeof(text) - 1);
  WriteFile(file, text, bytes, &written, nullptr);
}

DWORD WINAPI WriteCrashReport(void*) noexcept {
  if (WaitForSingleObject(crash_requested, INFINITE) != WAIT_OBJECT_0) return 0;
  const HANDLE report = CreateFileW(report_path, GENERIC_WRITE, FILE_SHARE_READ,
      nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  WriteLine(report, "Skate 2 %s\r\n"
      "ProcessId: %lu\r\nThreadId: %lu\r\nExceptionCode: 0x%08lX\r\n"
      "ExceptionFlags: 0x%08lX\r\nExceptionAddress: %p\r\n",
      report_kind, GetCurrentProcessId(), fault_thread_id, fault_record.ExceptionCode,
      fault_record.ExceptionFlags, fault_record.ExceptionAddress);
  for (DWORD i = 0; i < fault_record.NumberParameters &&
       i < EXCEPTION_MAXIMUM_PARAMETERS; ++i) {
    WriteLine(report, "ExceptionInformation[%lu]: 0x%016llX\r\n", i,
        static_cast<unsigned long long>(fault_record.ExceptionInformation[i]));
  }
#if defined(_M_X64) || defined(__x86_64__)
  const auto instruction = fault_context.Rip;
  WriteLine(report, "RIP: 0x%016llX\r\nRSP: 0x%016llX\r\nRBP: 0x%016llX\r\n"
      "RAX: 0x%016llX\r\nRBX: 0x%016llX\r\nRCX: 0x%016llX\r\nRDX: 0x%016llX\r\n"
      "RSI: 0x%016llX\r\nRDI: 0x%016llX\r\nR8: 0x%016llX\r\nR9: 0x%016llX\r\n"
      "R10: 0x%016llX\r\nR11: 0x%016llX\r\nR12: 0x%016llX\r\nR13: 0x%016llX\r\n"
      "R14: 0x%016llX\r\nR15: 0x%016llX\r\nEFLAGS: 0x%08lX\r\n",
      fault_context.Rip, fault_context.Rsp, fault_context.Rbp,
      fault_context.Rax, fault_context.Rbx, fault_context.Rcx, fault_context.Rdx,
      fault_context.Rsi, fault_context.Rdi, fault_context.R8, fault_context.R9,
      fault_context.R10, fault_context.R11, fault_context.R12, fault_context.R13,
      fault_context.R14, fault_context.R15, fault_context.EFlags);
#elif defined(_M_ARM64) || defined(__aarch64__)
  const auto instruction = fault_context.Pc;
  WriteLine(report, "PC: 0x%016llX\r\nSP: 0x%016llX\r\n",
      fault_context.Pc, fault_context.Sp);
#else
  const auto instruction = reinterpret_cast<ULONG_PTR>(fault_record.ExceptionAddress);
#endif
  MEMORY_BASIC_INFORMATION memory{};
  if (VirtualQuery(reinterpret_cast<void*>(instruction), &memory, sizeof(memory))) {
    WriteLine(report, "ModuleBase: %p\r\nModuleOffset: 0x%llX\r\n",
        memory.AllocationBase, static_cast<unsigned long long>(instruction -
            reinterpret_cast<ULONG_PTR>(memory.AllocationBase)));
    // Persist the core report before loader or dump APIs that may fail after a crash.
    if (report != INVALID_HANDLE_VALUE) FlushFileBuffers(report);
    wchar_t module_path[kPathCapacity]{};
    if (GetModuleFileNameW(static_cast<HMODULE>(memory.AllocationBase),
                          module_path, static_cast<DWORD>(kPathCapacity))) {
      char utf8_path[4096]{};
      if (WideCharToMultiByte(CP_UTF8, 0, module_path, -1, utf8_path,
                             sizeof(utf8_path), nullptr, nullptr)) {
        WriteLine(report, "Module: %s\r\n", utf8_path);
      }
    }
  }
  unsigned char bytes[32]{};
  SIZE_T bytes_read = 0;
  if (ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(instruction),
                        bytes, sizeof(bytes), &bytes_read)) {
    WriteLine(report, "InstructionBytes:");
    for (SIZE_T i = 0; i < bytes_read; ++i) WriteLine(report, " %02X", bytes[i]);
    WriteLine(report, "\r\n");
  }
  if (report != INVALID_HANDLE_VALUE) FlushFileBuffers(report);

  const HANDLE dump = CreateFileW(dump_path, GENERIC_WRITE, FILE_SHARE_READ,
      nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (dump != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION exception_info{fault_thread_id, &fault_pointers, FALSE};
    const auto type = static_cast<MINIDUMP_TYPE>(
        MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules);
    const BOOL success = MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(),
        dump, type, &exception_info, nullptr, nullptr);
    const DWORD error = success ? ERROR_SUCCESS : GetLastError();
    WriteLine(report, "MiniDumpWriteDump: %s (error 0x%08lX)\r\n",
        success ? "success" : "failed", error);
    FlushFileBuffers(dump);
    CloseHandle(dump);
  } else {
    WriteLine(report, "CreateDumpFile failed: 0x%08lX\r\n", GetLastError());
  }
  if (report != INVALID_HANDLE_VALUE) {
    FlushFileBuffers(report);
    CloseHandle(report);
  }
  SetEvent(crash_finished);
  return 0;
}

void RequestExceptionReport(EXCEPTION_POINTERS* exception, const char* kind) noexcept {
  if (!exception || !exception->ExceptionRecord || !exception->ContextRecord) return;
  if (GetCurrentThreadId() != writer_thread_id) {
    if (InterlockedCompareExchange(&crash_claimed, 1, 0) == 0) {
      report_kind = kind;
      fault_thread_id = GetCurrentThreadId();
      fault_record = *exception->ExceptionRecord;
      fault_record.ExceptionRecord = nullptr;
      fault_context = *exception->ContextRecord;
      SetEvent(crash_requested);
    }
    // Reporting is best effort: retain the failing stack while the worker runs,
    // but do not leave a failed process waiting indefinitely for a dump.
    WaitForSingleObject(crash_finished, 30000);
  }
}

LONG WINAPI ReportHeapCorruption(EXCEPTION_POINTERS* exception) noexcept {
  // Heap corruption can bypass the top-level filter. Observe only that fatal
  // status; leave access violations, MMIO and every other exception untouched.
  if (exception && exception->ExceptionRecord &&
      exception->ExceptionRecord->ExceptionCode == kStatusHeapCorruption) {
    RequestExceptionReport(exception, "native heap corruption (vectored observation)");
  }
  // Reporting never handles the exception or resumes the corrupted process.
  return EXCEPTION_CONTINUE_SEARCH;
}

LONG WINAPI ReportUnhandledException(EXCEPTION_POINTERS* exception) noexcept {
  RequestExceptionReport(exception, "unhandled native exception");
  return previous_filter ? previous_filter(exception) : EXCEPTION_CONTINUE_SEARCH;
}

void ReportAbort(int signal_number) noexcept {
  if (GetCurrentThreadId() != writer_thread_id) {
    if (InterlockedCompareExchange(&crash_claimed, 1, 0) == 0) {
      report_kind = "fatal abort snapshot (synthetic exception record)";
      fault_thread_id = GetCurrentThreadId();
      RtlCaptureContext(&fault_context);
      fault_record = {};
      // STATUS_FATAL_APP_EXIT describes this diagnostic snapshot; it is not
      // the later Windows fail-fast exception raised by the CRT's abort().
      fault_record.ExceptionCode = 0x40000015;
      fault_record.ExceptionFlags = EXCEPTION_NONCONTINUABLE;
#if defined(_M_X64) || defined(__x86_64__)
      fault_record.ExceptionAddress = reinterpret_cast<void*>(fault_context.Rip);
#elif defined(_M_ARM64) || defined(__aarch64__)
      fault_record.ExceptionAddress = reinterpret_cast<void*>(fault_context.Pc);
#endif
      SetEvent(crash_requested);
    }
    WaitForSingleObject(crash_finished, 30000);
  }
  if (previous_abort_handler && previous_abort_handler != SIG_IGN &&
      previous_abort_handler != SIG_ERR) {
    previous_abort_handler(signal_number);
  }
  // Returning lets abort() retain its normal fatal termination behavior.
}
}  // namespace

void InstallCrashDiagnostics() noexcept {
  static const bool installed = []() noexcept {
    try {
      wchar_t exe_path[kPathCapacity]{};
      const DWORD length = GetModuleFileNameW(nullptr, exe_path,
                                             static_cast<DWORD>(kPathCapacity));
      if (!length || length >= kPathCapacity) return false;
      const auto directory = std::filesystem::path(exe_path).parent_path() /
          "logs" / "crashes";
      std::error_code error;
      std::filesystem::create_directories(directory, error);
      if (error) return false;
      SYSTEMTIME now{};
      GetSystemTime(&now);
      wchar_t stem[96]{};
      swprintf_s(stem, L"skate2-%04u%02u%02u-%02u%02u%02u-%03u-p%lu",
          now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
          now.wSecond, now.wMilliseconds, GetCurrentProcessId());
      if (swprintf_s(report_path, L"%ls\\%ls.txt", directory.c_str(), stem) < 0 ||
          swprintf_s(dump_path, L"%ls\\%ls.dmp", directory.c_str(), stem) < 0) {
        return false;
      }
      crash_requested = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      crash_finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      if (!crash_requested || !crash_finished) {
        if (crash_requested) CloseHandle(crash_requested);
        if (crash_finished) CloseHandle(crash_finished);
        return false;
      }
      const HANDLE worker = CreateThread(nullptr, 0, WriteCrashReport,
                                          nullptr, 0, &writer_thread_id);
      if (!worker) {
        CloseHandle(crash_requested);
        CloseHandle(crash_finished);
        return false;
      }
      CloseHandle(worker);
      // Runtime MMIO/access handling remains in its existing vectored handler.
      // Append the strict heap observer; later first-priority SDK handlers keep
      // their normal precedence. This application handler lives until exit.
      if (!AddVectoredExceptionHandler(0, ReportHeapCorruption)) {
        OutputDebugStringW(L"Skate 2 heap corruption observer installation failed.\n");
      }
      previous_filter = SetUnhandledExceptionFilter(ReportUnhandledException);
      previous_abort_handler = std::signal(SIGABRT, ReportAbort);
      return true;
    } catch (...) {
      return false;
    }
  }();
  if (!installed) OutputDebugStringW(L"Skate 2 crash report initialization failed.\n");
}
#else
void InstallCrashDiagnostics() noexcept {}
#endif
