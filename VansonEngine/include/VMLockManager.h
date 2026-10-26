#ifndef VMLockManager_h
#define VMLockManager_h

#import "VMPointerChain.h"
#import "VMSignatureModel.h"
#import <Foundation/Foundation.h>

@interface VMLockManager : NSObject

+ (instancetype)shared;

- (void)addPointerToLock:(VMPointerChain *)chain;
- (void)addSignatureToLock:(VMSignatureModel *)sig;
- (void)removePointer:(VMPointerChain *)chain;
- (void)removeSignature:(VMSignatureModel *)sig;
- (void)updateSignature:(VMSignatureModel *)sig;

- (NSArray<VMPointerChain *> *)loadLocksForApp:(NSString *)bundleID;
- (void)reloadLocksFromDiskForApp:(NSString *)bundleID;
- (void)saveLocks:(NSArray<VMPointerChain *> *)locks
           forApp:(NSString *)bundleID;
- (NSArray<VMSignatureModel *> *)loadSignaturesForApp:(NSString *)bundleID;

@end

#endif
