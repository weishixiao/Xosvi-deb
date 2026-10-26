#import "../../../include/VMLockManager.h"
#import "../../../include/VMMemoryEngine.h"
#import "../../../include/VMPointerChain.h"
#import "../../../include/VMSignatureModel.h"
#import "LockCore.hpp"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <vector>

@implementation VMLockManager

+ (instancetype)shared {
  static VMLockManager *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

#pragma mark - Public Methods

- (void)addPointerToLock:(VMPointerChain *)chain {
  NSString *bid = chain.bundleID ?: [[VMMemoryEngine shared] currentBundleID];
  if (!bid) bid = @"unknown.app";
  chain.bundleID = bid;

  VMCore::LockCore::shared().addLock([bid UTF8String], chain.cppModel);
  [[VMMemoryEngine shared] reloadLockedPointers];
}

- (void)addSignatureToLock:(VMSignatureModel *)sig {
  NSString *bid = sig.bundleID ?: [[VMMemoryEngine shared] currentBundleID];
  if (!bid) bid = @"Unassigned";
  sig.bundleID = bid;

  VMCore::PointerChain pc;
  pc.isSignatureMode = true;
  pc.signature = sig.signature ? [sig.signature UTF8String] : "";
  pc.note = sig.note ? [sig.note UTF8String] : "";
  pc.moduleName = sig.moduleName ? [sig.moduleName UTF8String] : "";
  pc.baseOffset = sig.offset;
  pc.bundleID = [bid UTF8String];
  pc.appName = sig.appName ? [sig.appName UTF8String] : "";
  pc.appVersion = sig.appVersion ? [sig.appVersion UTF8String] : "";
  pc.uniqueId = [[[NSUUID UUID] UUIDString] UTF8String];
  pc.author = sig.author ? [sig.author UTF8String] : "";
  pc.createdAt = sig.createdAt > 0 ? sig.createdAt : [[NSDate date] timeIntervalSince1970];
  pc.isImported = sig.isImported;
  pc.lockType = sig.lockType;
  pc.uiMin = sig.uiMin;
  pc.uiMax = sig.uiMax;
  
  pc.resultTitle = sig.resultTitle ? [sig.resultTitle UTF8String] : "";

  VMCore::LockCore::shared().addLock([bid UTF8String], pc);
}

- (void)saveLocks:(NSArray<VMPointerChain *> *)locks
           forApp:(NSString *)bundleID {
  if (!bundleID)
    return;
  std::vector<VMCore::PointerChain> items;
  for (VMPointerChain *p in locks) {
    items.push_back(p.cppModel);
  }
  VMCore::LockCore::shared().saveLocks([bundleID UTF8String], items);
}

- (void)removeSignature:(VMSignatureModel *)sig {
  NSString *bid = sig.bundleID ?: [[VMMemoryEngine shared] currentBundleID];
  if (!bid || !sig.signature)
    return;
  
  VMCore::LockCore::shared().load([bid UTF8String]);
  
  VMCore::LockCore::shared().removeLock([bid UTF8String],
                                        [sig.signature UTF8String]);
  [[VMMemoryEngine shared] reloadLockedPointers];
}

- (void)updateSignature:(VMSignatureModel *)sig {
  NSString *bid = sig.bundleID ?: [[VMMemoryEngine shared] currentBundleID];
  if (!bid) return;
  
  VMCore::LockCore::shared().load([bid UTF8String]);
  VMCore::LockCore::shared().removeLock([bid UTF8String], [sig.signature UTF8String]);
  [self addSignatureToLock:sig];
}

- (void)removePointer:(VMPointerChain *)chain {
  NSString *bid = chain.bundleID ?: [[VMMemoryEngine shared] currentBundleID];
  if (!bid)
    return;
  
  VMCore::LockCore::shared().load([bid UTF8String]);
  
  VMCore::LockCore::shared().removeLock([bid UTF8String],
                                        [chain.uniqueId UTF8String]);
  [[VMMemoryEngine shared] reloadLockedPointers];
}

- (NSArray<VMPointerChain *> *)loadLocksForApp:(NSString *)bundleID {
  if (!bundleID)
    return @[];
  std::vector<VMCore::PointerChain> items =
      VMCore::LockCore::shared().getLocks([bundleID UTF8String]);
  NSMutableArray *res = [NSMutableArray array];
  for (const auto &item : items) {
    if (!item.isSignatureMode) {
      VMPointerChain *p = [[VMPointerChain alloc] init];
      p.cppModel = item; 
      [res addObject:p];
    }
  }
  [res sortUsingComparator:^NSComparisonResult(VMPointerChain *obj1,
                                               VMPointerChain *obj2) {
    double s1 = obj1.sortOrder > 0 ? obj1.sortOrder : obj1.createdAt;
    double s2 = obj2.sortOrder > 0 ? obj2.sortOrder : obj2.createdAt;
    return s1 < s2 ? NSOrderedDescending : NSOrderedAscending;
  }];
  return res;
}

- (void)reloadLocksFromDiskForApp:(NSString *)bundleID {
  if (!bundleID)
    return;
  VMCore::LockCore::shared().load([bundleID UTF8String]);
}

- (NSArray<VMSignatureModel *> *)loadSignaturesForApp:(NSString *)bundleID {
  if (!bundleID)
    return @[];
  std::vector<VMCore::PointerChain> items =
      VMCore::LockCore::shared().getLocks([bundleID UTF8String]);
  NSMutableArray *res = [NSMutableArray array];
  for (const auto &item : items) {
    if (item.isSignatureMode) {
      VMSignatureModel *s = [[VMSignatureModel alloc] init];
      s.signature = [NSString stringWithUTF8String:item.signature.c_str()];
      s.note = [NSString stringWithUTF8String:item.note.c_str()];
      s.moduleName = [NSString stringWithUTF8String:item.moduleName.c_str()];
      s.offset = (int)item.baseOffset;
      s.bundleID = bundleID;
      s.fileName = [NSString stringWithUTF8String:item.fileName.c_str()];
      s.author = [NSString stringWithUTF8String:item.author.c_str()];
      s.appName = [NSString stringWithUTF8String:item.appName.c_str()];
      s.appVersion = [NSString stringWithUTF8String:item.appVersion.c_str()];
      s.createdAt = item.createdAt;
      s.sortOrder = item.sortOrder;
      s.isImported = item.isImported;
      s.lockType = item.lockType;
      s.uiMin = item.uiMin;
      s.uiMax = item.uiMax;
      
      s.resultTitle = [NSString stringWithUTF8String:item.resultTitle.c_str()];

      [res addObject:s];
    }
  }
  return res;
}

@end
