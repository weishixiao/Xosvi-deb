#include "SessionCore.hpp"
#import <Foundation/Foundation.h>
#include <sys/stat.h>

SessionCore &SessionCore::getInstance() {
  static SessionCore instance;
  return instance;
}

std::string SessionCore::generateSnapshotPath() {
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *uuid = [[NSUUID UUID] UUIDString];
  NSString *path = [tmpDir
      stringByAppendingPathComponent:[NSString stringWithFormat:@"snap_%@.bin",
                                                                uuid]];
  return [path UTF8String];
}

void SessionCore::pushSnapshot(const std::string &currentFilePath,
                               size_t resultCount) {
  if (currentFilePath.empty() || resultCount == 0) {
    _snapshots.push_back({"", 0, true});
    return;
  }

  std::string snapPath = generateSnapshotPath();

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *src = [NSString stringWithUTF8String:currentFilePath.c_str()];
  NSString *dst = [NSString stringWithUTF8String:snapPath.c_str()];

  NSError *error = nil;
  if ([fm fileExistsAtPath:src]) {
    if ([fm copyItemAtPath:src toPath:dst error:&error]) {
      _snapshots.push_back({snapPath, resultCount, false});
    } else {
      
      _snapshots.push_back({"", 0, true});
    }
  } else {
    _snapshots.push_back({"", 0, true});
  }
}

bool SessionCore::popSnapshot(std::string &outFilePath, size_t &outCount) {
  if (_snapshots.empty())
    return false;

  SessionSnapshot snap = _snapshots.back();
  _snapshots.pop_back();

  if (snap.isEmpty) {
    outFilePath = "";
    outCount = 0;
    return true; 
  }

  outFilePath = snap.filePath;
  outCount = snap.resultCount;
  return true;
}

void SessionCore::clearSnapshots() {
  NSFileManager *fm = [NSFileManager defaultManager];
  for (const auto &snap : _snapshots) {
    if (!snap.isEmpty && !snap.filePath.empty()) {
      NSString *path = [NSString stringWithUTF8String:snap.filePath.c_str()];
      [fm removeItemAtPath:path error:nil];
    }
  }
  _snapshots.clear();
}

bool SessionCore::hasSnapshots() const { return !_snapshots.empty(); }

size_t SessionCore::getSnapshotCount() const { return _snapshots.size(); }
