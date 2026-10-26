#ifndef SystemCore_hpp
#define SystemCore_hpp

#include <mach/mach.h>
#include <string>
#include <sys/sysctl.h>
#include <vector>

namespace VMCore {

struct ModuleInfo {
  uint64_t loadAddress;
  uint32_t size;
  std::string path;
  std::string name;
};

struct ProcessInfo {
  int pid;
  std::string bundleID;
  std::string path;
  std::string name;
};

class SystemCore {
public:
  static SystemCore &getInstance();

  std::vector<ModuleInfo> getRemoteModules(mach_port_t task);

  uint32_t calculateMachOSize(mach_port_t task, uint64_t loadAddr);

  bool isDeviceJailbroken();

  int getPidByBundleID(const std::string &bundleID);

  std::vector<ProcessInfo> getProcessList();

private:
  SystemCore() = default;
  ~SystemCore() = default;
  SystemCore(const SystemCore &) = delete;
  SystemCore &operator=(const SystemCore &) = delete;
};

} 

#endif /* SystemCore_hpp */
