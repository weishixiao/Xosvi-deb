#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

struct PatchItem {
  std::string moduleName;
  uint64_t offset;
  std::string patchHex;
  std::string originalHex;
  bool isOn;
  std::string note;
  std::string author;
  bool isImported;
  std::string bundleID;
  std::string appName;
  std::string appVersion;
  double createdAt;
  double sortOrder;
  std::string fileName; 
};

class PatchCore {
public:
  static PatchCore &getInstance();

  PatchCore(const PatchCore &) = delete;
  PatchCore &operator=(const PatchCore &) = delete;

  std::vector<PatchItem> loadPatches(const std::string &bundleID);

  void savePatches(const std::string &bundleID,
                   const std::vector<PatchItem> &patches);

  bool applyPatch(
      const PatchItem &item, bool enable, uint64_t baseAddress,
      std::function<bool(uint64_t addr, const void *data, size_t len)> writer);

  void removePatch(const std::string &bundleID, const PatchItem &item);

  std::string getPatchRootFolder();

private:
  PatchCore() = default;
  ~PatchCore() = default;

  std::vector<uint8_t> hexToBytes(const std::string &hex);
};
