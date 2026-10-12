#pragma once

// Best-effort local reports for unhandled native exceptions. Does not recover
// from, suppress, or modify the exception, and does nothing on other platforms.
void InstallCrashDiagnostics() noexcept;
