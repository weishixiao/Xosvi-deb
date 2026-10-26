#import <Foundation/Foundation.h>
#ifdef __cplusplus
#include "src/core/ModelCore.hpp"
#endif

typedef enum : NSUInteger {
  VMPointerUIModeInput = 0,
  VMPointerUIModeSwitch = 1,
  VMPointerUIModeSlider = 2
} VMPointerUIMode;

typedef enum : NSUInteger {
  VMPointerChainTypeStatic = 0,   
  VMPointerChainTypeDynamic = 1,  
  VMPointerChainTypeUnknown = 2   
} VMPointerChainType;

@interface VMPointerChain : NSObject <NSCoding, NSSecureCoding> {
#ifdef __cplusplus
  VMCore::PointerChain _cppModel;
#endif
}

#ifdef __cplusplus
@property(nonatomic, assign) VMCore::PointerChain cppModel;
#endif

@property(nonatomic, copy) NSString *moduleName;
@property(nonatomic, assign) uint64_t baseOffset;
@property(nonatomic, strong) NSArray<NSNumber *> *offsets;
@property(nonatomic, assign) uint64_t lastKnownValue;
@property(nonatomic, copy) NSString *note;
@property(nonatomic, assign) NSTimeInterval createdAt;
@property(nonatomic, assign) double sortOrder;  

@property(nonatomic, assign) VMPointerChainType chainType;
@property(nonatomic, assign) uint64_t heapBaseAddress;  

@property(nonatomic, copy) NSString *uniqueId;

@property(nonatomic, copy) NSString *fileName;

@property(nonatomic, assign) NSInteger fileIndex;

@property(nonatomic, copy) NSString *runtimeValue;
@property(nonatomic, assign) BOOL isRuntimeValid;

@property(nonatomic, copy) NSString *lockValue;
@property(nonatomic, assign) BOOL lockEnabled;
@property(nonatomic, assign) NSUInteger lockType;

@property(nonatomic, copy) NSString *author;
@property(nonatomic, assign) BOOL isImported;
@property(nonatomic, copy) NSString *bundleID;

@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *appVersion;

@property(nonatomic, copy) NSString *type;
@property(nonatomic, assign) VMPointerUIMode uiMode;
@property(nonatomic, assign) float uiMin;
@property(nonatomic, assign) float uiMax;

@property(nonatomic, copy) NSString *switchOnValue;   
@property(nonatomic, copy) NSString *switchOffValue;  
@property(nonatomic, copy) NSString *resultTitle;     

@property(nonatomic, copy) NSString *signature;
@property(nonatomic, assign) BOOL isSignatureMode;
@property(nonatomic, assign) uint64_t cachedRuntimeAddress;
@property(nonatomic, assign) BOOL isScanning;
@property(nonatomic, copy) NSString *scanError;

@property(nonatomic, strong) NSArray<NSNumber *> *multiRuntimeAddresses;
@property(nonatomic, assign) BOOL isExpanded;

- (BOOL)isDynamic;  

- (NSString *)displayString;
- (NSString *)exportString;

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end
