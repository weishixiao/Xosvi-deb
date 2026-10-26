#import "include/VMStoragePathHelper.h"
#include <unistd.h>

@implementation VMStoragePathHelper

+ (BOOL)ensureDirectoryAtPath:(NSString *)path {
  if (path.length == 0)
    return NO;

  BOOL isDir = NO;
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
    return isDir;
  }

  return [fm createDirectoryAtPath:path
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
}

+ (BOOL)isWritableDocumentRoot:(NSString *)root {
  if (root.length == 0)
    return NO;

  if (![self ensureDirectoryAtPath:root])
    return NO;

  NSString *vansonRoot = [root stringByAppendingPathComponent:@"MemoryEngine"];
  if (![self ensureDirectoryAtPath:vansonRoot])
    return NO;

  NSString *probeName =
      [NSString stringWithFormat:@".write-test-%d", getpid()];
  NSString *probe = [vansonRoot stringByAppendingPathComponent:probeName];
  NSData *data = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
  BOOL ok = [data writeToFile:probe atomically:YES];
  if (ok) {
    [[NSFileManager defaultManager] removeItemAtPath:probe error:nil];
  }
  return ok;
}

+ (NSArray<NSString *> *)documentCandidates {
  NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];

  NSString *doc = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  if (doc.length > 0)
    [set addObject:doc];

  NSString *home = NSHomeDirectory();
  if (home.length > 0)
    [set addObject:[home stringByAppendingPathComponent:@"Documents"]];

  const char *envHome = getenv("HOME");
  if (envHome && envHome[0] != '\0') {
    NSString *envPath =
        [[NSString stringWithUTF8String:envHome]
            stringByAppendingPathComponent:@"Documents"];
    if (envPath.length > 0)
      [set addObject:envPath];
  }

  [set addObject:@"/var/mobile/Documents"];
  [set addObject:@"/private/var/mobile/Documents"];

  NSString *support = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  if (support.length > 0)
    [set addObject:support];

  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSString *path in set) {
    [paths addObject:[path stringByStandardizingPath]];
  }
  return paths;
}

+ (NSString *)documentsDirectory {
  static NSString *cachedPath = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    for (NSString *candidate in [self documentCandidates]) {
      if ([self isWritableDocumentRoot:candidate]) {
        cachedPath = [candidate copy];
        break;
      }
    }

    if (cachedPath.length == 0) {
      cachedPath = [NSTemporaryDirectory() stringByStandardizingPath];
      [self ensureDirectoryAtPath:
                [cachedPath stringByAppendingPathComponent:@"MemoryEngine"]];
    }
  });

  return cachedPath;
}

+ (NSString *)vansonModDirectory {
  NSString *root =
      [[self documentsDirectory] stringByAppendingPathComponent:@"MemoryEngine"];
  [self ensureDirectoryAtPath:root];
  return root;
}

+ (NSString *)pathForSubdirectory:(NSString *)subdirectory
                          bundleID:(NSString *)bundleID
                            create:(BOOL)create {
  NSString *path = [self vansonModDirectory];
  if (subdirectory.length > 0) {
    path = [path stringByAppendingPathComponent:subdirectory];
  }
  if (bundleID.length > 0) {
    path = [path stringByAppendingPathComponent:bundleID];
  }
  if (create) {
    [self ensureDirectoryAtPath:path];
  }
  return path;
}

@end
