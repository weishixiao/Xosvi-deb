#include "StorageCore.hpp"
#import "include/VMStoragePathHelper.h"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace VMCore {

StorageCore &StorageCore::shared() {
  static StorageCore instance;
  return instance;
}

std::string StorageCore::getTempPath() {
  @autoreleasepool {
    return [NSTemporaryDirectory() UTF8String];
  }
}

std::string StorageCore::getDocumentsPath() {
  @autoreleasepool {
    return [[VMStoragePathHelper documentsDirectory] UTF8String];
  }
}

std::string StorageCore::getWorkDir() {
  std::string path = getDocumentsPath() + "/MemoryEngine";
  ensureDir(path);
  return path;
}

void StorageCore::ensureDir(const std::string &path) {
  @autoreleasepool {
    NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
    [VMStoragePathHelper ensureDirectoryAtPath:nsPath];
  }
}

bool StorageCore::fileExists(const std::string &path) {
  struct stat buffer;
  return (stat(path.c_str(), &buffer) == 0);
}

std::string StorageCore::generateUniquePath(const std::string &baseName,
                                            const std::string &ext) {
  std::string tmpDir = getTempPath();
  std::string fullPath = tmpDir + "/" + baseName + "." + ext;
  int counter = 1;

  while (fileExists(fullPath)) {
    std::stringstream ss;
    ss << tmpDir << "/" << baseName << "-" << counter++ << "." << ext;
    fullPath = ss.str();
  }
  return fullPath;
}

bool StorageCore::exportPointerChain(const PointerChain &item,
                                     const std::string &filename) {
  std::string path = getWorkDir() + "/Exports/" + filename;
  ensureDir(getWorkDir() + "/Exports");
  
  return true;
}

void StorageCore::setString(const std::string &key, const std::string &val) {
  @autoreleasepool {
    [[NSUserDefaults standardUserDefaults]
        setObject:[NSString stringWithUTF8String:val.c_str()]
           forKey:[NSString stringWithUTF8String:key.c_str()]];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
}

std::string StorageCore::getString(const std::string &key,
                                   const std::string &defaultVal) {
  @autoreleasepool {
    NSString *val = [[NSUserDefaults standardUserDefaults]
        stringForKey:[NSString stringWithUTF8String:key.c_str()]];
    return val ? [val UTF8String] : defaultVal;
  }
}

void StorageCore::setInt(const std::string &key, int val) {
  @autoreleasepool {
    [[NSUserDefaults standardUserDefaults]
        setInteger:val
            forKey:[NSString stringWithUTF8String:key.c_str()]];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
}

int StorageCore::getInt(const std::string &key, int defaultVal) {
  @autoreleasepool {
    NSString *k = [NSString stringWithUTF8String:key.c_str()];
    if ([[NSUserDefaults standardUserDefaults] objectForKey:k]) {
      return (int)[[NSUserDefaults standardUserDefaults] integerForKey:k];
    }
    return defaultVal;
  }
}

void StorageCore::setBool(const std::string &key, bool val) {
  @autoreleasepool {
    [[NSUserDefaults standardUserDefaults]
        setBool:val
         forKey:[NSString stringWithUTF8String:key.c_str()]];
    [[NSUserDefaults standardUserDefaults] synchronize];
  }
}

bool StorageCore::getBool(const std::string &key, bool defaultVal) {
  @autoreleasepool {
    NSString *k = [NSString stringWithUTF8String:key.c_str()];
    if ([[NSUserDefaults standardUserDefaults] objectForKey:k]) {
      return [[NSUserDefaults standardUserDefaults] boolForKey:k];
    }
    return defaultVal;
  }
}

} 
