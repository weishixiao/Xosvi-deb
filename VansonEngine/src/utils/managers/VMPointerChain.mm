#import "include/VMPointerChain.h"
#import <Foundation/Foundation.h>

@implementation VMPointerChain {
  NSArray *_offsets;
}

#ifdef __cplusplus
- (VMCore::PointerChain)cppModel {
  return _cppModel;
}
- (void)setCppModel:(VMCore::PointerChain)cppModel {
  _cppModel = cppModel;
  _offsets = nil; 
}
#endif

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)init {
  if (self = [super init]) {
    
    _cppModel.createdAt = [[NSDate date] timeIntervalSince1970];
    _cppModel.lockEnabled = false;
    _cppModel.isImported = false;
    
    _cppModel.createdAt += (arc4random() % 1000) / 1000000.0;
    _cppModel.uniqueId = [[[NSUUID UUID] UUIDString] UTF8String];
    _cppModel.uiMode = VMCore::PointerUIMode::Input;
    _cppModel.uiMin = 0.0;
    _cppModel.uiMax = 100.0;
    _cppModel.signature = "";
    _cppModel.isSignatureMode = false;
    
    _cppModel.chainType = VMCore::PointerChainType::Static;
    _cppModel.heapBaseAddress = 0;
    
    _cppModel.switchOnValue = "";
    _cppModel.switchOffValue = "";
    _cppModel.resultTitle = "";

    _multiRuntimeAddresses = @[];
    _isExpanded = NO;
    _isScanning = NO;
    _isRuntimeValid = NO;
    _cachedRuntimeAddress = 0;
  }
  return self;
}

#pragma mark - Coding

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (self = [super init]) {
    
    self.moduleName = [coder decodeObjectOfClass:[NSString class]
                                          forKey:@"moduleName"];
    self.baseOffset = [coder decodeInt64ForKey:@"baseOffset"];
    self.offsets = [coder decodeObjectOfClass:[NSArray class]
                                       forKey:@"offsets"];
    self.lastKnownValue = [coder decodeInt64ForKey:@"lastKnownValue"];
    self.note = [coder decodeObjectOfClass:[NSString class] forKey:@"note"];
    self.createdAt = [coder decodeDoubleForKey:@"createdAt"];
    self.sortOrder = [coder decodeDoubleForKey:@"sortOrder"];
    self.lockValue = [coder decodeObjectOfClass:[NSString class]
                                         forKey:@"lockValue"];
    self.lockEnabled = [coder decodeBoolForKey:@"lockEnabled"];
    self.lockType = [coder decodeIntegerForKey:@"lockType"];
    self.author = [coder decodeObjectOfClass:[NSString class] forKey:@"author"];
    self.isImported = [coder decodeBoolForKey:@"isImported"];
    self.bundleID = [coder decodeObjectOfClass:[NSString class]
                                        forKey:@"bundleID"];
    self.appName = [coder decodeObjectOfClass:[NSString class]
                                       forKey:@"appName"];
    self.appVersion = [coder decodeObjectOfClass:[NSString class]
                                          forKey:@"appVersion"];

    self.uiMode = (VMPointerUIMode)[coder decodeIntegerForKey:@"uiMode"];
    self.uiMin = [coder decodeFloatForKey:@"uiMin"];
    self.uiMax = [coder decodeFloatForKey:@"uiMax"];

    self.signature = [coder decodeObjectOfClass:[NSString class]
                                         forKey:@"signature"];
    self.isSignatureMode = [coder decodeBoolForKey:@"isSignatureMode"];
    self.type = [coder decodeObjectOfClass:[NSString class] forKey:@"type"];
    
    self.chainType = (VMPointerChainType)[coder decodeIntegerForKey:@"chainType"];
    self.heapBaseAddress = [coder decodeInt64ForKey:@"heapBaseAddress"];
    
    self.switchOnValue = [coder decodeObjectOfClass:[NSString class] forKey:@"switchOnValue"] ?: @"";
    self.switchOffValue = [coder decodeObjectOfClass:[NSString class] forKey:@"switchOffValue"] ?: @"";
    self.resultTitle = [coder decodeObjectOfClass:[NSString class] forKey:@"resultTitle"] ?: @"";

    self.multiRuntimeAddresses = @[];
    self.cachedRuntimeAddress = 0;
    self.isScanning = NO;
    self.isExpanded = NO;
    self.scanError = nil;
    self.isRuntimeValid = NO;
    self.runtimeValue = nil;

    if (self.uniqueId.length == 0) {
      self.uniqueId = [[NSUUID UUID] UUIDString];
    }
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:self.moduleName forKey:@"moduleName"];
  [coder encodeInt64:self.baseOffset forKey:@"baseOffset"];
  [coder encodeObject:self.offsets forKey:@"offsets"];
  [coder encodeInt64:self.lastKnownValue forKey:@"lastKnownValue"];
  [coder encodeObject:self.note forKey:@"note"];
  [coder encodeDouble:self.createdAt forKey:@"createdAt"];
  [coder encodeDouble:self.sortOrder forKey:@"sortOrder"];
  [coder encodeObject:self.lockValue forKey:@"lockValue"];
  [coder encodeBool:self.lockEnabled forKey:@"lockEnabled"];
  [coder encodeInteger:self.lockType forKey:@"lockType"];
  [coder encodeObject:self.author forKey:@"author"];
  [coder encodeBool:self.isImported forKey:@"isImported"];
  [coder encodeObject:self.bundleID forKey:@"bundleID"];
  [coder encodeObject:self.appName forKey:@"appName"];
  [coder encodeObject:self.appVersion forKey:@"appVersion"];

  [coder encodeInteger:self.uiMode forKey:@"uiMode"];
  [coder encodeFloat:self.uiMin forKey:@"uiMin"];
  [coder encodeFloat:self.uiMax forKey:@"uiMax"];

  [coder encodeObject:self.signature forKey:@"signature"];
  [coder encodeBool:self.isSignatureMode forKey:@"isSignatureMode"];
  [coder encodeObject:self.type forKey:@"type"];
  
  [coder encodeInteger:self.chainType forKey:@"chainType"];
  [coder encodeInt64:self.heapBaseAddress forKey:@"heapBaseAddress"];
  
  [coder encodeObject:self.switchOnValue forKey:@"switchOnValue"];
  [coder encodeObject:self.switchOffValue forKey:@"switchOffValue"];
  [coder encodeObject:self.resultTitle forKey:@"resultTitle"];
}

#pragma mark - Properties Bridge

@synthesize multiRuntimeAddresses = _multiRuntimeAddresses;
@synthesize isExpanded = _isExpanded;
@synthesize isScanning = _isScanning;
@synthesize scanError = _scanError;
@synthesize cachedRuntimeAddress = _cachedRuntimeAddress;
@synthesize runtimeValue = _runtimeValue;
@synthesize isRuntimeValid = _isRuntimeValid;

- (NSString *)bundleID {
  return [NSString stringWithUTF8String:_cppModel.bundleID.c_str()] ?: @"";
}
- (void)setBundleID:(NSString *)v {
  _cppModel.bundleID = [v UTF8String] ?: "";
}

- (NSString *)appName {
  return [NSString stringWithUTF8String:_cppModel.appName.c_str()] ?: @"";
}
- (void)setAppName:(NSString *)v {
  _cppModel.appName = [v UTF8String] ?: "";
}

- (NSString *)appVersion {
  return [NSString stringWithUTF8String:_cppModel.appVersion.c_str()] ?: @"";
}
- (void)setAppVersion:(NSString *)v {
  _cppModel.appVersion = [v UTF8String] ?: "";
}

- (NSString *)moduleName {
  return [NSString stringWithUTF8String:_cppModel.moduleName.c_str()] ?: @"";
}
- (void)setModuleName:(NSString *)v {
  _cppModel.moduleName = [v UTF8String] ?: "";
}

- (uint64_t)baseOffset {
  return _cppModel.baseOffset;
}
- (void)setBaseOffset:(uint64_t)v {
  _cppModel.baseOffset = v;
}

- (void)setOffsets:(NSArray *)offsets {
  _offsets = offsets;
  _cppModel.offsets.clear();
  if (offsets) {
    for (NSNumber *n in offsets) {
      _cppModel.offsets.push_back([n longLongValue]);
    }
  }
}

- (NSArray *)offsets {
  if (!_offsets) {
    NSMutableArray *arr = [NSMutableArray array];
    for (const auto &off : _cppModel.offsets) {
      [arr addObject:@(off)];
    }
    _offsets = [NSArray arrayWithArray:arr];
  }
  return _offsets;
}

- (NSString *)note {
  return [NSString stringWithUTF8String:_cppModel.note.c_str()] ?: @"";
}
- (void)setNote:(NSString *)v {
  _cppModel.note = [v UTF8String] ?: "";
}

- (NSString *)author {
  return [NSString stringWithUTF8String:_cppModel.author.c_str()] ?: @"";
}
- (void)setAuthor:(NSString *)v {
  _cppModel.author = [v UTF8String] ?: "";
}

- (NSString *)uniqueId {
  return [NSString stringWithUTF8String:_cppModel.uniqueId.c_str()] ?: @"";
}
- (void)setUniqueId:(NSString *)v {
  _cppModel.uniqueId = [v UTF8String] ?: "";
}

- (NSString *)fileName {
  return [NSString stringWithUTF8String:_cppModel.fileName.c_str()] ?: @"";
}
- (void)setFileName:(NSString *)v {
  _cppModel.fileName = [v UTF8String] ?: "";
}

- (NSTimeInterval)createdAt {
  return _cppModel.createdAt;
}
- (void)setCreatedAt:(NSTimeInterval)v {
  _cppModel.createdAt = v;
}

- (double)sortOrder {
  return _cppModel.sortOrder;
}
- (void)setSortOrder:(double)v {
  _cppModel.sortOrder = v;
}

- (BOOL)isImported {
  return _cppModel.isImported;
}
- (void)setIsImported:(BOOL)v {
  _cppModel.isImported = v;
}

- (VMPointerChainType)chainType {
  return (VMPointerChainType)_cppModel.chainType;
}
- (void)setChainType:(VMPointerChainType)v {
  _cppModel.chainType = (VMCore::PointerChainType)v;
}

- (uint64_t)heapBaseAddress {
  return _cppModel.heapBaseAddress;
}
- (void)setHeapBaseAddress:(uint64_t)v {
  _cppModel.heapBaseAddress = v;
}

- (BOOL)isDynamic {
  return _cppModel.chainType == VMCore::PointerChainType::Dynamic;
}

- (NSString *)lockValue {
  return [NSString stringWithUTF8String:_cppModel.lockValue.c_str()] ?: @"";
}
- (void)setLockValue:(NSString *)v {
  _cppModel.lockValue = [v UTF8String] ?: "";
}

- (BOOL)lockEnabled {
  return _cppModel.lockEnabled;
}
- (void)setLockEnabled:(BOOL)v {
  _cppModel.lockEnabled = v;
}

- (NSUInteger)lockType {
  return (NSUInteger)_cppModel.lockType;
}
- (void)setLockType:(NSUInteger)v {
  _cppModel.lockType = (int)v;
}

- (uint64_t)lastKnownValue {
  return _cppModel.lastKnownValue;
}
- (void)setLastKnownValue:(uint64_t)v {
  _cppModel.lastKnownValue = v;
}

- (VMPointerUIMode)uiMode {
  return (VMPointerUIMode)_cppModel.uiMode;
}
- (void)setUiMode:(VMPointerUIMode)v {
  _cppModel.uiMode = (VMCore::PointerUIMode)v;
}

- (float)uiMin {
  return _cppModel.uiMin;
}
- (void)setUiMin:(float)v {
  _cppModel.uiMin = v;
}

- (float)uiMax {
  return _cppModel.uiMax;
}
- (void)setUiMax:(float)v {
  _cppModel.uiMax = v;
}

- (NSString *)type {
  return [NSString stringWithUTF8String:_cppModel.type.c_str()] ?: @"card";
}
- (void)setType:(NSString *)v {
  _cppModel.type = [v UTF8String] ?: "";
}

- (NSString *)switchOnValue {
  return [NSString stringWithUTF8String:_cppModel.switchOnValue.c_str()] ?: @"";
}
- (void)setSwitchOnValue:(NSString *)v {
  _cppModel.switchOnValue = [v UTF8String] ?: "";
}

- (NSString *)switchOffValue {
  return [NSString stringWithUTF8String:_cppModel.switchOffValue.c_str()] ?: @"";
}
- (void)setSwitchOffValue:(NSString *)v {
  _cppModel.switchOffValue = [v UTF8String] ?: "";
}

- (NSString *)resultTitle {
  return [NSString stringWithUTF8String:_cppModel.resultTitle.c_str()] ?: @"";
}
- (void)setResultTitle:(NSString *)v {
  _cppModel.resultTitle = [v UTF8String] ?: "";
}

- (NSString *)signature {
  return [NSString stringWithUTF8String:_cppModel.signature.c_str()] ?: @"";
}
- (void)setSignature:(NSString *)v {
  _cppModel.signature = [v UTF8String] ?: "";
}

- (BOOL)isSignatureMode {
  return _cppModel.isSignatureMode;
}
- (void)setIsSignatureMode:(BOOL)v {
  _cppModel.isSignatureMode = v;
}

#pragma mark - Methods

- (NSString *)displayString {
  if (self.isSignatureMode) {
    return self.signature ?: @"";
  }

  NSMutableString *str = [NSMutableString
      stringWithFormat:@"[%@+0x%llX]", self.moduleName, self.baseOffset];
  for (NSNumber *offset in self.offsets) {
    
    int64_t off = [offset longLongValue];
    if (off >= 0) {
      [str appendFormat:@"+0x%llX", (uint64_t)off];
    } else {
      [str appendFormat:@"-0x%llX", (uint64_t)(-off)];
    }
  }
  return str;
}

- (NSString *)exportString {
  NSMutableString *str = [NSMutableString
      stringWithFormat:@"[%@+0x%llX]", self.moduleName, self.baseOffset];
  for (NSNumber *offset in self.offsets) {
    
    int64_t off = [offset longLongValue];
    if (off >= 0) {
      [str appendFormat:@"+0x%llX", (uint64_t)off];
    } else {
      [str appendFormat:@"-0x%llX", (uint64_t)(-off)];
    }
  }
  return str;
}

- (NSDictionary *)toDictionary {
  return @{
    @"type" : @"pointer",
    @"moduleName" : self.moduleName ?: @"",
    @"baseOffset" : @(self.baseOffset),
    @"offsets" : self.offsets ?: @[],
    @"lastKnownValue" : @(self.lastKnownValue),
    @"note" : self.note ?: @"",
    @"createdAt" : @(self.createdAt),
    @"sortOrder" : @(self.sortOrder),

    @"lockValue" : self.lockValue ?: @"",
    @"lockEnabled" : @(self.lockEnabled),
    @"lockType" : @(self.lockType),

    @"author" : self.author ?: @"",
    @"isImported" : @(self.isImported),
    @"bundleID" : self.bundleID ?: @"",
    @"appName" : self.appName ?: @"",
    @"appVersion" : self.appVersion ?: @"",

    @"uiMode" : @(self.uiMode),
    @"uiMin" : @(self.uiMin),
    @"uiMax" : @(self.uiMax),
    @"valType" : self.type ?: @"card",
    
    @"chainType" : @(self.chainType),
    @"heapBaseAddress" : @(self.heapBaseAddress),
    
    @"switchOnValue" : self.switchOnValue ?: @"",
    @"switchOffValue" : self.switchOffValue ?: @"",
    @"resultTitle" : self.resultTitle ?: @"",

    @"signature" : self.signature ?: @"",
    @"isSignatureMode" : @(self.isSignatureMode)
  };
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
  if (!dict)
    return nil;

  NSString *type = dict[@"type"];
  BOOL isValidType =
      !type || type.length == 0 || 
      [type isEqualToString:@"pointer"] || [type isEqualToString:@"card"] ||
      [type isEqualToString:@"卡片"] || [type isEqualToString:@"slider"] ||
      [type isEqualToString:@"滑块"];
  if (!isValidType)
    return nil;

  VMPointerChain *chain = [[self alloc] init];
  chain.moduleName = dict[@"moduleName"];
  chain.baseOffset = [dict[@"baseOffset"] unsignedLongLongValue];
  chain.offsets = dict[@"offsets"];
  chain.lastKnownValue = [dict[@"lastKnownValue"] unsignedLongLongValue];
  chain.note = dict[@"note"];
  chain.createdAt = [dict[@"createdAt"] doubleValue];
  chain.sortOrder = [dict[@"sortOrder"] doubleValue];

  chain.lockValue = dict[@"lockValue"];
  chain.lockEnabled = [dict[@"lockEnabled"] boolValue];
  chain.lockType = [dict[@"lockType"] unsignedIntegerValue];

  chain.author = dict[@"author"];
  chain.isImported = [dict[@"isImported"] boolValue];
  chain.bundleID = dict[@"bundleID"];
  chain.appName = dict[@"appName"];
  chain.appVersion = dict[@"appVersion"];

  chain.uiMode = (VMPointerUIMode)[dict[@"uiMode"] unsignedIntegerValue];
  chain.uiMin = [dict[@"uiMin"] floatValue];
  chain.uiMax = [dict[@"uiMax"] floatValue];
  chain.type = dict[@"valType"] ?: @"card";
  
  chain.chainType = (VMPointerChainType)[dict[@"chainType"] unsignedIntegerValue];
  chain.heapBaseAddress = [dict[@"heapBaseAddress"] unsignedLongLongValue];

  chain.signature = dict[@"signature"];
  chain.isSignatureMode = [dict[@"isSignatureMode"] boolValue];
  
  chain.switchOnValue = dict[@"switchOnValue"] ?: @"";
  chain.switchOffValue = dict[@"switchOffValue"] ?: @"";
  chain.resultTitle = dict[@"resultTitle"] ?: @"";

  return chain;
}

@end
