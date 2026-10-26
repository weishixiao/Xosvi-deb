#import <Foundation/Foundation.h>

#define VMLocal(key) [[VMLocalization shared] localizedString:key]

@interface VMLocalization : NSObject
+ (instancetype)shared;
- (NSString *)localizedString:(NSString *)key;
- (void)setLanguage:(NSString *)lang;
- (NSString *)currentLanguage;
@end
