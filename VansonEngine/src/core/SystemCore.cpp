#include "SystemCore.hpp"
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <sys/stat.h>
#include <unistd.h>

struct dyld_image_info_64 {
  uint64_t imageLoadAddress;
  uint64_t imageFilePath;
  uint64_t imageFileModDate;
};

struct dyld_all_image_infos_64 {
  uint32_t version;
  uint32_t infoArrayCount;
  uint64_t infoArray;
  uint64_t notification;
  bool processDetachedFromSharedRegion;
  bool libSystemInitialized;
};

extern "C" {
kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t,
                                     mach_vm_size_t, mach_vm_address_t,
                                     mach_vm_size_t *);
}

namespace VMCore {

SystemCore &SystemCore::getInstance() {
  static SystemCore instance;
  return instance;
}

std::vector<ModuleInfo> SystemCore::getRemoteModules(mach_port_t task) {
  std::vector<ModuleInfo> modules;
  if (task == MACH_PORT_NULL)
    return modules;

  task_dyld_info_data_t dyld_info;
  mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;

  if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count) !=
      KERN_SUCCESS)
    return modules;

  uint64_t all_infos_addr = dyld_info.all_image_info_addr;
  if (all_infos_addr == 0)
    return modules;

  struct dyld_all_image_infos_64 infos;
  mach_vm_size_t read_size = sizeof(infos);
  if (mach_vm_read_overwrite(task, all_infos_addr, read_size,
                             (mach_vm_address_t)&infos,
                             &read_size) != KERN_SUCCESS)
    return modules;

  uint32_t cnt = infos.infoArrayCount;
  if (cnt > 5000)
    cnt = 5000;

  mach_vm_size_t arrSize = cnt * sizeof(struct dyld_image_info_64);
  void *buf = malloc(arrSize);
  if (!buf)
    return modules;

  mach_vm_size_t actualSize = arrSize;
  if (mach_vm_read_overwrite(task, infos.infoArray, arrSize,
                             (mach_vm_address_t)buf,
                             &actualSize) == KERN_SUCCESS) {
    struct dyld_image_info_64 *imgs = (struct dyld_image_info_64 *)buf;

    for (uint32_t i = 0; i < (uint32_t)cnt; i++) {
      ModuleInfo m;
      m.loadAddress = imgs[i].imageLoadAddress;

      char path[1024];
      mach_vm_size_t pSize = 1024;
      mach_vm_size_t readPSize = pSize;
      if (mach_vm_read_overwrite(task, imgs[i].imageFilePath, pSize,
                                 (mach_vm_address_t)path,
                                 &readPSize) == KERN_SUCCESS) {
        if (readPSize > 0) {
          path[readPSize < 1024 ? readPSize : 1023] = '\0';
          m.path = path;

          size_t lastSlash = m.path.find_last_of('/');
          if (lastSlash != std::string::npos) {
            m.name = m.path.substr(lastSlash + 1);
          } else {
            m.name = m.path;
          }

          m.size = calculateMachOSize(task, m.loadAddress);
          modules.push_back(m);
        }
      }
    }
  }
  free(buf);

  return modules;
}

uint32_t SystemCore::calculateMachOSize(mach_port_t task, uint64_t loadAddr) {
  if (task == MACH_PORT_NULL)
    return 0;

  struct mach_header_64 header;
  mach_vm_size_t headerSize = sizeof(header);
  mach_vm_size_t readSize = headerSize;
  if (mach_vm_read_overwrite(task, loadAddr, headerSize,
                             (mach_vm_address_t)&header,
                             &readSize) != KERN_SUCCESS)
    return 0;

  if (header.magic != MH_MAGIC_64)
    return 0;

  uint32_t sizeofcmds = header.sizeofcmds;
  uint8_t *cmdsBuffer = (uint8_t *)malloc(sizeofcmds);
  if (!cmdsBuffer)
    return 0;

  mach_vm_size_t cmdsSize = sizeofcmds;
  mach_vm_size_t readCmdsSize = cmdsSize;
  if (mach_vm_read_overwrite(task, loadAddr + sizeof(header), cmdsSize,
                             (mach_vm_address_t)cmdsBuffer,
                             &readCmdsSize) != KERN_SUCCESS) {
    free(cmdsBuffer);
    return 0;
  }

  uint64_t totalVMSize = 0;
  uint8_t *cursor = cmdsBuffer;

  for (uint32_t i = 0; i < header.ncmds; i++) {
    struct load_command *lc = (struct load_command *)cursor;
    if (lc->cmd == LC_SEGMENT_64) {
      struct segment_command_64 *seg = (struct segment_command_64 *)lc;
      if (strcmp(seg->segname, "__LINKEDIT") != 0) {
        totalVMSize += seg->vmsize;
      }
    }
    cursor += lc->cmdsize;
    if (cursor >= cmdsBuffer + sizeofcmds)
      break;
  }
  free(cmdsBuffer);

  return (uint32_t)totalVMSize;
}

bool SystemCore::isDeviceJailbroken() {
  const char *paths[] = {"/var/jb",
                         "/Applications/Cydia.app",
                         "/Applications/Sileo.app",
                         "/var/binpack",
                         "/Library/MobileSubstrate/MobileSubstrate.dylib",
                         "/usr/sbin/sshd",
                         "/etc/apt",
                         "/var/containers/Bundle/.jbroot",
                         "/var/mobile/.jbroot"};

  for (int i = 0; i < 9; i++) {
    struct stat s;
    if (stat(paths[i], &s) == 0) {
      return true;
    }
  }

  // roothide: jbroot paths are randomized, check via dyld
  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; i++) {
    const char *name = _dyld_get_image_name(i);
    if (name && strstr(name, "roothide")) {
      return true;
    }
  }

  return false;
}

int SystemCore::getPidByBundleID(const std::string &bundleID) {
  if (bundleID.empty())
    return 0;

  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0)
    return 0;

  struct kinfo_proc *procList = (struct kinfo_proc *)malloc(size);
  if (!procList)
    return 0;

  if (sysctl(mib, 4, procList, &size, NULL, 0) == 0) {
    int count = size / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
      int pid = procList[i].kp_proc.p_pid;
      if (pid <= 0)
        continue;

      char pathBuffer[1024];
      int mib_path[4] = {CTL_KERN, KERN_PROCARGS, pid, 0};
      size_t pathSize = sizeof(pathBuffer);

      if (sysctl(mib_path, 4, pathBuffer, &pathSize, NULL, 0) == 0) {
        if (strstr(pathBuffer, bundleID.c_str())) {
          free(procList);
          return pid;
        }
      }
    }
  }

  free(procList);
  return 0;
}

std::vector<ProcessInfo> SystemCore::getProcessList() {
  std::vector<ProcessInfo> list;

  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size = 0;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) == -1)
    return list;

  struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
  if (!procs)
    return list;

  if (sysctl(mib, 4, procs, &size, NULL, 0) == -1) {
    free(procs);
    return list;
  }

  int count = size / sizeof(struct kinfo_proc);
  pid_t myPid = getpid();

  for (int i = 0; i < count; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0 || pid == myPid)
      continue;

    ProcessInfo info;
    info.pid = pid;
    info.name = procs[i].kp_proc.p_comm;

    char pathBuffer[4096];
    int mib_path[4] = {CTL_KERN, KERN_PROCARGS, pid, 0};
    size_t pathSize = sizeof(pathBuffer);

    if (sysctl(mib_path, 4, pathBuffer, &pathSize, NULL, 0) == 0) {
      info.path = pathBuffer;

      std::string fullPath = info.path;
      size_t appPos = fullPath.find(".app/");
      if (appPos != std::string::npos) {
        std::string bundlePath = fullPath.substr(0, appPos + 4);
        std::string plistPath = bundlePath + "/Info.plist";

        info.bundleID = ""; 
      }
    }

    list.push_back(info);
  }

  free(procs);
  return list;
}

} 
