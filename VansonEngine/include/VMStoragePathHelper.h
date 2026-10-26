#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VMStoragePathHelper : NSObject

+ (NSString *)documentsDirectory;
+ (NSString *)vansonModDirectory;
+ (NSString *)pathForSubdirectory:(NSString *)subdirectory
                          bundleID:(nullable NSString *)bundleID
                            create:(BOOL)create;
+ (BOOL)ensureDirectoryAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
