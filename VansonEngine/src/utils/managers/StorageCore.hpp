#ifndef StorageCore_hpp
#define StorageCore_hpp

#include "../../core/ModelCore.hpp"
#include <string>
#include <vector>

namespace VMCore {

class StorageCore {
public:
  static StorageCore &shared();

  std::string getDocumentsPath();
  std::string generateUniquePath(const std::string &baseName,
                                 const std::string &ext);
  bool fileExists(const std::string &path);
  void ensureDir(const std::string &path);
  std::string getWorkDir();
  std::string getTempPath();

  bool exportPointerChain(const PointerChain &item,
                          const std::string &filename);
  PointerChain importPointerChain(const std::string &filePath);

  void setString(const std::string &key, const std::string &val);
  std::string getString(const std::string &key,
                        const std::string &defaultVal = "");

  void setInt(const std::string &key, int val);
  int getInt(const std::string &key, int defaultVal = 0);

  void setBool(const std::string &key, bool val);
  bool getBool(const std::string &key, bool defaultVal = false);

private:
  StorageCore() = default;
  std::string _configPath;
};

} 

#endif
