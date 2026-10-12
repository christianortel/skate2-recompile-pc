#pragma once

// Applies a machine-local adapter choice only while presentation is initialized.
class AutomaticGpuSelection {
 public:
  AutomaticGpuSelection();
  ~AutomaticGpuSelection();
  AutomaticGpuSelection(const AutomaticGpuSelection&) = delete;
  AutomaticGpuSelection& operator=(const AutomaticGpuSelection&) = delete;

 private:
  bool applied_ = false;
};
