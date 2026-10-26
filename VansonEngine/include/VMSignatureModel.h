#import <Foundation/Foundation.h>

@interface VMSignatureModel : NSObject <NSSecureCoding>

@property(nonatomic, copy) NSString *fileName; 
@property(nonatomic, copy) NSString *bundleID; 
@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *appVersion;

@property(nonatomic, copy) NSString *moduleName; 
@property(nonatomic, copy) NSString *signature;  
@property(nonatomic, assign) int offset;         
@property(nonatomic, assign) int lockType;       

@property(nonatomic, copy) NSString *note;    
@property(nonatomic, copy) NSString *author;  
@property(nonatomic, assign) BOOL isImported; 
@property(nonatomic, assign) NSTimeInterval createdAt;
@property(nonatomic, assign) double sortOrder;  
@property(nonatomic, assign) float uiMin;
@property(nonatomic, assign) float uiMax;
@property(nonatomic, copy) NSString *resultTitle; 

@property(nonatomic, assign) BOOL isScanning;
@property(nonatomic, copy) NSString *scanError;
@property(nonatomic, strong) NSArray<NSDictionary *>
    *runtimeResults; 
@property(nonatomic, copy) NSString *runtimeValue;
@property(nonatomic, assign) BOOL isRuntimeValid;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *>
    *resultConfig; 

- (NSString *)displayString;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end
