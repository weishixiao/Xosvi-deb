#import "include/VMRVAPatch.h"
@implementation VMRVAPatch
+ (BOOL)supportsSecureCoding {
  return YES;
}

- (instancetype)init {
  if (self = [super init]) {
    _createdAt = [[NSDate date] timeIntervalSince1970];
    _isImported = NO;
    _isOn = NO;
    _createdAt += (arc4random() % 1000) / 1000000.0;
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:self.moduleName ?: @"" forKey:@"mod"];
  [coder encodeInt64:self.offset forKey:@"off"];
  [coder encodeObject:self.patchHex ?: @"" forKey:@"phex"];
  [coder encodeObject:self.originalHex ?: @"" forKey:@"ohex"];
  [coder encodeBool:self.isOn forKey:@"on"];
  [coder encodeObject:self.note ?: @"" forKey:@"note"];
  [coder encodeObject:self.author ?: @"" forKey:@"author"];
  [coder encodeBool:self.isImported forKey:@"isImported"];
  [coder encodeObject:self.bundleID ?: @"" forKey:@"bid"];
  [coder encodeObject:self.appName ?: @"" forKey:@"appName"];
  [coder encodeObject:self.appVersion ?: @"" forKey:@"appVersion"];
  [coder encodeObject:self.appVersion ?: @"" forKey:@"appVersion"];
  [coder encodeDouble:self.createdAt forKey:@"createdAt"];
  [coder encodeDouble:self.sortOrder forKey:@"sortOrder"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if (self = [super init]) {
    self.moduleName = [coder decodeObjectOfClass:[NSString class]
                                          forKey:@"mod"];
    self.offset = [coder decodeInt64ForKey:@"off"];
    self.patchHex = [coder decodeObjectOfClass:[NSString class] forKey:@"phex"];
    self.originalHex = [coder decodeObjectOfClass:[NSString class]
                                           forKey:@"ohex"];
    self.isOn = [coder decodeBoolForKey:@"on"];
    self.note = [coder decodeObjectOfClass:[NSString class] forKey:@"note"];
    self.author = [coder decodeObjectOfClass:[NSString class] forKey:@"author"];
    self.isImported = [coder decodeBoolForKey:@"isImported"];
    self.bundleID = [coder decodeObjectOfClass:[NSString class] forKey:@"bid"];
    self.appName = [coder decodeObjectOfClass:[NSString class]
                                       forKey:@"appName"];
    self.appVersion = [coder decodeObjectOfClass:[NSString class]
                                          forKey:@"appVersion"];
    self.appVersion = [coder decodeObjectOfClass:[NSString class]
                                          forKey:@"appVersion"];
    self.createdAt = [coder decodeDoubleForKey:@"createdAt"];
    self.sortOrder = [coder decodeDoubleForKey:@"sortOrder"];
  }
  return self;
}

- (NSString *)displayString {
  return
      [NSString stringWithFormat:@"%@ + 0x%llX", self.moduleName, self.offset];
}

- (NSDictionary *)toDictionary {
  return @{
    @"type" : @"rva",
    @"moduleName" : self.moduleName ?: @"",
    @"offset" : @(self.offset),
    @"patchHex" : self.patchHex ?: @"",
    @"originalHex" : self.originalHex ?: @"",
    @"isOn" : @(self.isOn),
    @"note" : self.note ?: @"",
    @"author" : self.author ?: @"",
    @"isImported" : @(self.isImported),
    @"bundleID" : self.bundleID ?: @"",
    @"appName" : self.appName ?: @"",
    @"appVersion" : self.appVersion ?: @"",

    @"createdAt" : @(self.createdAt),
    @"sortOrder" : @(self.sortOrder)

  };
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
  if (!dict)
    return nil;

  VMRVAPatch *patch = [[self alloc] init];
  patch.moduleName = dict[@"moduleName"];
  patch.offset = [dict[@"offset"] unsignedLongLongValue];
  patch.patchHex = dict[@"patchHex"];
  patch.originalHex = dict[@"originalHex"];
  patch.isOn = [dict[@"isOn"] boolValue];
  patch.note = dict[@"note"];

  patch.author = dict[@"author"];
  patch.isImported = [dict[@"isImported"] boolValue];
  patch.bundleID = dict[@"bundleID"];
  patch.appName = dict[@"appName"];
  patch.appVersion = dict[@"appVersion"];
  patch.appName = dict[@"appName"];
  patch.appVersion = dict[@"appVersion"];
  patch.createdAt = [dict[@"createdAt"] doubleValue];
  patch.sortOrder = [dict[@"sortOrder"] doubleValue];

  return patch;
}

@end
