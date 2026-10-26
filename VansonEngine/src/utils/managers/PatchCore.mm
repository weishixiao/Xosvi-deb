#include "PatchCore.hpp"
#import "include/VMStoragePathHelper.h"
#include "StorageCore.hpp"
#include <Foundation/Foundation.h>
#include <algorithm>
#include <sys/stat.h>
#include <unistd.h>

PatchCore &PatchCore::getInstance() {
  static PatchCore instance;
  return instance;
}

std::string PatchCore::getPatchRootFolder() {
  NSString *path = [VMStoragePathHelper pathForSubdirectory:@"RVA"
                                                   bundleID:nil
                                                     create:YES];
  return [path UTF8String];
}

std::vector<PatchItem> PatchCore::loadPatches(const std::string &bundleID) {
  std::vector<PatchItem> patches;
  if (bundleID.empty())
    return patches;

  std::string bid = bundleID;
  std::replace(bid.begin(), bid.end(), '/', '_');

  std::string appDir = getPatchRootFolder() + "/" + bid;

  @autoreleasepool {
    NSString *folder = [NSString stringWithUTF8String:appDir.c_str()];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:folder error:nil];

    if (!files) {
      return patches;
    }

    NSPredicate *pred =
        [NSPredicate predicateWithFormat:@"self ENDSWITH '.vmrva'"];
    NSArray *vmrvaFiles = [files filteredArrayUsingPredicate:pred];

    for (NSString *fileName in vmrvaFiles) {
      NSString *filePath = [folder stringByAppendingPathComponent:fileName];
      NSData *fileData = [NSData dataWithContentsOfFile:filePath];

      if (!fileData || fileData.length == 0) {
        continue;
      }

      NSError *error = nil;
      NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:fileData
                                                           options:0
                                                             error:&error];
      if (error || ![dict isKindOfClass:[NSDictionary class]]) {
        continue;
      }

      NSArray *dataItems = dict[@"dataItems"];
      if (dataItems && [dataItems isKindOfClass:[NSArray class]]) {
        
        for (NSDictionary *itemDict in dataItems) {
          if (![itemDict isKindOfClass:[NSDictionary class]]) continue;
          
          PatchItem item;
          item.bundleID = bundleID;
          item.fileName = [fileName UTF8String];
          item.offset = [itemDict[@"offset"] unsignedLongLongValue];
          item.moduleName = [itemDict[@"moduleName"] UTF8String] ?: "";
          item.patchHex = [itemDict[@"patchHex"] UTF8String] ?: "";
          item.originalHex = [itemDict[@"originalHex"] UTF8String] ?: "";
          item.isOn = [itemDict[@"isOn"] boolValue];
          item.note = [itemDict[@"note"] UTF8String] ?: "";
          item.author = [itemDict[@"author"] UTF8String] ?: "";
          item.appName = [itemDict[@"appName"] UTF8String] ?: "";
          item.appVersion = [itemDict[@"appVersion"] UTF8String] ?: "";
          item.createdAt = [itemDict[@"createdAt"] doubleValue];
          item.sortOrder = [itemDict[@"sortOrder"] doubleValue];
          item.isImported = [itemDict[@"isImported"] boolValue];
          if (itemDict[@"bundleID"]) {
            item.bundleID = [itemDict[@"bundleID"] UTF8String];
          }

          patches.push_back(item);
        }
      } else {
        
        PatchItem item;
        item.bundleID = bundleID;
        item.fileName = [fileName UTF8String];
        item.offset = [dict[@"offset"] unsignedLongLongValue];
        item.moduleName = [dict[@"moduleName"] UTF8String] ?: "";
        item.patchHex = [dict[@"patchHex"] UTF8String] ?: "";
        item.originalHex = [dict[@"originalHex"] UTF8String] ?: "";
        item.isOn = [dict[@"isOn"] boolValue];
        item.note = [dict[@"note"] UTF8String] ?: "";
        item.author = [dict[@"author"] UTF8String] ?: "";
        item.appName = [dict[@"appName"] UTF8String] ?: "";
        item.appVersion = [dict[@"appVersion"] UTF8String] ?: "";
        item.createdAt = [dict[@"createdAt"] doubleValue];
        item.sortOrder = [dict[@"sortOrder"] doubleValue];
        item.isImported = [dict[@"isImported"] boolValue];
        if (dict[@"bundleID"]) {
          item.bundleID = [dict[@"bundleID"] UTF8String];
        }

        patches.push_back(item);
      }
    }
  }

  return patches;
}

void PatchCore::savePatches(const std::string &bundleID,
                            const std::vector<PatchItem> &patches) {
  if (bundleID.empty())
    return;

  std::string bid = bundleID;
  std::replace(bid.begin(), bid.end(), '/', '_');
  std::string appDir = getPatchRootFolder() + "/" + bid;

  struct stat st = {0};
  if (stat(appDir.c_str(), &st) == -1) {
    NSString *path = [NSString stringWithUTF8String:appDir.c_str()];
    [VMStoragePathHelper ensureDirectoryAtPath:path];
  }

  for (const auto &item : patches) {
    @autoreleasepool {
      
      NSMutableDictionary *dict = [NSMutableDictionary dictionary];
      dict[@"offset"] = @(item.offset);
      dict[@"moduleName"] =
          [NSString stringWithUTF8String:item.moduleName.c_str()];
      dict[@"patchHex"] = [NSString stringWithUTF8String:item.patchHex.c_str()];
      dict[@"originalHex"] =
          [NSString stringWithUTF8String:item.originalHex.c_str()];
      dict[@"isOn"] = @(item.isOn);
      dict[@"note"] = [NSString stringWithUTF8String:item.note.c_str()];
      dict[@"author"] = [NSString stringWithUTF8String:item.author.c_str()];
      dict[@"appName"] = [NSString stringWithUTF8String:item.appName.c_str()];
      dict[@"appVersion"] =
          [NSString stringWithUTF8String:item.appVersion.c_str()];
      dict[@"createdAt"] = @(item.createdAt);
      dict[@"sortOrder"] = @(item.sortOrder);
      dict[@"bundleID"] = [NSString stringWithUTF8String:item.bundleID.c_str()];
      dict[@"isImported"] = @(item.isImported);

      NSError *error = nil;
      NSData *jsonData =
          [NSJSONSerialization dataWithJSONObject:dict
                                          options:NSJSONWritingPrettyPrinted
                                            error:&error];
      if (error) {
        continue;
      }

      std::string fname = item.fileName;
      if (fname.empty()) {
        
        if (!bundleID.empty()) {
          fname = bundleID + "-rva.vmrva";
        } else {
          fname = "rva.vmrva";
        }
        
        std::string testPath = appDir + "/" + fname;
        int counter = 1;
        while (access(testPath.c_str(), F_OK) != -1) {
          if (!bundleID.empty()) {
            fname = bundleID + "-rva-" + std::to_string(counter) + ".vmrva";
          } else {
            fname = "rva-" + std::to_string(counter) + ".vmrva";
          }
          testPath = appDir + "/" + fname;
          counter++;
        }
      }
      
      std::string fullPath = appDir + "/" + fname;

      FILE *f = fopen(fullPath.c_str(), "wb");
      if (f) {
        fwrite(jsonData.bytes, 1, jsonData.length, f);
        fclose(f);
      }
    }
  }
}

std::vector<uint8_t> PatchCore::hexToBytes(const std::string &hex) {
  std::vector<uint8_t> bytes;
  for (size_t i = 0; i < hex.length(); i += 2) {
    if (i + 1 < hex.length()) {
      std::string byteString = hex.substr(i, 2);
      uint8_t byte = (uint8_t)strtol(byteString.c_str(), nullptr, 16);
      bytes.push_back(byte);
    }
  }
  return bytes;
}

bool PatchCore::applyPatch(
    const PatchItem &item, bool enable, uint64_t baseAddress,
    std::function<bool(uint64_t addr, const void *data, size_t len)> writer) {
  if (!writer)
    return false;

  std::string targetHex = enable ? item.patchHex : item.originalHex;
  std::string cleanHex;
  for (char c : targetHex) {
    if (!isspace(c))
      cleanHex += c;
  }

  if (cleanHex.empty())
    return false;

  std::vector<uint8_t> data = hexToBytes(cleanHex);
  if (data.empty())
    return false;

  uint64_t finalAddr = baseAddress + item.offset;
  return writer(finalAddr, data.data(), data.size());
}

void PatchCore::removePatch(const std::string &bundleID, const PatchItem &item) {
    std::string bid = bundleID;
    std::replace(bid.begin(), bid.end(), '/', '_');

    std::string fileName = item.fileName;
    if (fileName.empty()) return; 

    std::string fullPath = getPatchRootFolder() + "/" + bid + "/" + fileName;

    remove(fullPath.c_str());
}
