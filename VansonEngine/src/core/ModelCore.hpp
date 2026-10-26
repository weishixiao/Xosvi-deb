#ifndef ModelCore_hpp
#define ModelCore_hpp

#include <cstdint>
#include <string>
#include <vector>

namespace VMCore {

enum class PointerUIMode : uint32_t { Input = 0, Switch = 1, Slider = 2 };

enum class PointerChainType : uint32_t {
  Static = 0,   
  Dynamic = 1,  
  Unknown = 2   
};

struct PointerChain {
  std::string uniqueId;
  std::string moduleName;
  uint64_t baseOffset;
  std::vector<int64_t> offsets;  
  uint64_t lastKnownValue;
  std::string note;
  double createdAt;
  double sortOrder = 0;  

  PointerChainType chainType = PointerChainType::Static;
  uint64_t heapBaseAddress = 0;  

  PointerUIMode uiMode;
  float uiMin;
  float uiMax = 0;
  std::string type = "card"; 
  
  std::string switchOnValue;   
  std::string switchOffValue;  
  std::string resultTitle;     

  std::string lockValue;
  bool lockEnabled;
  uint32_t lockType;

  std::string fileName; 
  std::string author;
  bool isImported;
  std::string bundleID;
  std::string appName;
  std::string appVersion;

  std::string signature;
  bool isSignatureMode;
  uint64_t cachedRuntimeAddress;
  bool isScanning;
  std::string scanError;
  
};

struct SignatureModel {
  std::string bundleID;
  std::string appName;
  std::string moduleName;
  std::string signature;
  int32_t offset;
  std::string note;
  std::string author;
  double createdAt;

  bool isScanning;
  std::string scanError;
  
};

} 

#endif /* ModelCore_hpp */
