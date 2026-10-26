#import <Foundation/Foundation.h>
#import "VMPointerChain.h"
#import "VMRVAPatch.h"

@interface VMDataSession : NSObject <NSCoding, NSSecureCoding>

@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *appVersion;
@property (nonatomic, assign) NSTimeInterval createdAt;

@property (nonatomic, strong) NSArray *dataItems;

@property (nonatomic, copy) NSString *dataType;

+ (instancetype)sessionWithData:(NSArray *)dataItems bundleID:(NSString *)bundleID dataType:(NSString *)dataType;

- (NSData *)toJSONDataForExport;

- (NSData *)toJSONData;

+ (instancetype)fromJSONData:(NSData *)jsonData;

- (NSData *)toVerifierJSONData;
+ (instancetype)fromVerifierJSONData:(NSData *)jsonData;

- (NSData *)toVerifierBinaryData;
+ (instancetype)fromVerifierBinaryData:(NSData *)binaryData;

+ (instancetype)fromVerifierData:(NSData *)data;

@end
