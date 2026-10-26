#import <Foundation/Foundation.h>

@interface VMRVAPatch : NSObject <NSSecureCoding>
@property(nonatomic, copy) NSString *moduleName;
@property(nonatomic, assign) uint64_t offset;
@property(nonatomic, copy) NSString *patchHex;
@property(nonatomic, copy) NSString *originalHex;
@property(nonatomic, assign) BOOL isOn;
@property(nonatomic, copy) NSString *note;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, assign) BOOL isImported;
@property(nonatomic, copy) NSString *bundleID;

@property(nonatomic, copy) NSString *fileName;

@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *appVersion;
@property(nonatomic, assign) NSTimeInterval createdAt;
@property(nonatomic, assign) double sortOrder;  

- (NSString *)displayString;

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end
