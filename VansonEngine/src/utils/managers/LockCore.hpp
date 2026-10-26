#ifndef LockCore_hpp
#define LockCore_hpp

#include "../../core/ModelCore.hpp"
#include <map>
#include <string>
#include <vector>

namespace VMCore {

class LockCore {
public:
  static LockCore &shared();

  void addLock(const std::string &bundleID, const PointerChain &item);
  void removeLock(const std::string &bundleID, const std::string &uniqueId);
  std::vector<PointerChain> getLocks(const std::string &bundleID);
  void saveLocks(const std::string &bundleID,
                 const std::vector<PointerChain> &items);

  void save(const std::string &bundleID);
  void load(const std::string &bundleID);

private:
  std::map<std::string, std::vector<PointerChain>> _cache;
  std::string getStoragePath(const std::string &bundleID);

  std::vector<uint8_t> serializeItem(const PointerChain &item);
  PointerChain deserializeItem(const std::vector<uint8_t> &data,
                               size_t &offset);
};

} 

#endif /* LockCore_hpp */
