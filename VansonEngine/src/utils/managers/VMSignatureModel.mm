#import "include/VMSignatureModel.h"

@implementation VMSignatureModel

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)init {
  if (self = [super init]) {
    _createdAt = [[NSDate date] timeIntervalSince1970];
    _runtimeResults = @[];
    _resultConfig = [NSMutableDictionary dictionary];
    _runtimeValue = @"";
    _isRuntimeValid = NO;
    _resultTitle = @"";
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:_bundleID forKey:@"bid"];
  [coder encodeObject:_appName forKey:@"aname"];
  [coder encodeObject:_appVersion forKey:@"appVersion"];
  [coder encodeObject:_moduleName forKey:@"mod"];
  [coder encodeObject:_signature forKey:@"sig"];
  [coder encodeInt:_offset forKey:@"off"];
  [coder encodeInt:_lockType forKey:@"lockType"];
  [coder encodeObject:self.note forKey:@"note"];
  [coder encodeObject:self.author forKey:@"author"];
  [coder encodeBool:self.isImported forKey:@"isImported"];
  [coder encodeDouble:self.createdAt forKey:@"createdAt"];
  [coder encodeDouble:self.sortOrder forKey:@"sortOrder"];
  [coder encodeFloat:self.uiMin forKey:@"uiMin"];
  [coder encodeFloat:self.uiMax forKey:@"uiMax"];
  [coder encodeObject:self.resultTitle forKey:@"resultTitle"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (self = [super init]) {
    _bundleID = [coder decodeObjectOfClass:[NSString class] forKey:@"bid"];
    _appName = [coder decodeObjectOfClass:[NSString class] forKey:@"aname"];
    _appVersion = [coder decodeObjectOfClass:[NSString class] forKey:@"appVersion"];
    _moduleName = [coder decodeObjectOfClass:[NSString class] forKey:@"mod"];
    _signature = [coder decodeObjectOfClass:[NSString class] forKey:@"sig"];
    _offset = [coder decodeIntForKey:@"off"];
    _lockType = [coder decodeIntForKey:@"lockType"];
    self.note = [coder decodeObjectOfClass:[NSString class] forKey:@"note"];
    self.author = [coder decodeObjectOfClass:[NSString class] forKey:@"author"];
    self.isImported = [coder decodeBoolForKey:@"isImported"];
    self.createdAt = [coder decodeDoubleForKey:@"createdAt"];
    self.sortOrder = [coder decodeDoubleForKey:@"sortOrder"];
    self.uiMin = [coder decodeFloatForKey:@"uiMin"];
    self.uiMax = [coder decodeFloatForKey:@"uiMax"];
    self.resultTitle = [coder decodeObjectOfClass:[NSString class] forKey:@"resultTitle"] ?: @"";
    _runtimeResults = @[];
    _resultConfig = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSString *)displayString {
  if (_moduleName.length > 0)
    return [NSString stringWithFormat:@"[%@] %@", _moduleName, _signature];
  return _signature;
}

- (NSDictionary *)toDictionary {
  return @{
    @"type" : @"signature",
    @"bundleID" : _bundleID ?: @"",
    @"appName" : _appName ?: @"",
    @"appVersion" : _appVersion ?: @"",
    @"moduleName" : _moduleName ?: @"",
    @"signature" : _signature ?: @"",
    @"offset" : @(_offset),
    @"lockType" : @(_lockType),
    @"note" : self.note ?: @"",
    @"author" : self.author ?: @"",
    @"isImported" : @(self.isImported),
    @"createdAt" : @(self.createdAt),
    @"sortOrder" : @(self.sortOrder),
    @"uiMin" : @(self.uiMin),
    @"uiMax" : @(self.uiMax),
    @"resultTitle" : self.resultTitle ?: @""
  };
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
  VMSignatureModel *m = [VMSignatureModel new];
  m.bundleID = dict[@"bundleID"] ?: dict[@"bid"];
  m.appName = dict[@"appName"] ?: dict[@"aname"];
  m.appVersion = dict[@"appVersion"];
  m.moduleName = dict[@"moduleName"] ?: dict[@"mod"];
  m.signature = dict[@"signature"] ?: dict[@"sig"];
  m.offset = [dict[@"offset"] ?: dict[@"off"] intValue];
  m.lockType = [dict[@"lockType"] intValue];
  m.note = dict[@"note"];
  m.author = dict[@"author"];
  m.isImported = [dict[@"isImported"] boolValue];
  m.createdAt = [dict[@"createdAt"] doubleValue];
  m.sortOrder = [dict[@"sortOrder"] doubleValue];
  m.uiMin = [dict[@"uiMin"] floatValue];
  m.uiMax = [dict[@"uiMax"] floatValue];
  m.resultTitle = dict[@"resultTitle"] ?: @"";

  return m;
}
@end
