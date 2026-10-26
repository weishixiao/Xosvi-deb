#include "LockCore.hpp"
#import "include/VMStoragePathHelper.h"
#include <Foundation/Foundation.h>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

namespace VMCore {

static std::string vansonRootPath() {
  NSString *root = [VMStoragePathHelper vansonModDirectory];
  std::string path = [root UTF8String];
  if (!path.empty() && path.back() != '/')
    path += "/";
  return path;
}

LockCore &LockCore::shared() {
  static LockCore instance;
  return instance;
}

void LockCore::addLock(const std::string &bundleID, const PointerChain &item) {
  auto &list = _cache[bundleID];
  bool found = false;
  for (auto &existing : list) {
    if (existing.uniqueId == item.uniqueId) {
      existing = item;
      found = true;
      break;
    }
  }
  if (!found)
    list.push_back(item);
  save(bundleID);
}

void LockCore::removeLock(const std::string &bundleID,
                          const std::string &uniqueId) {
  auto &list = _cache[bundleID];
  for (auto it = list.begin(); it != list.end(); ++it) {
    if (it->uniqueId == uniqueId) {

      std::string basePath = vansonRootPath();
      std::string typeDir = it->isSignatureMode ? "SIG/" : "PTR/";
      std::string ext = it->isSignatureMode ? ".vmsig" : ".vmpt";

      std::string fileName = it->fileName;

      if (fileName.empty()) {
        if (!it->note.empty()) {
          fileName = it->note;
          
          for (char &c : fileName) {
            if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' ||
                c == '"' || c == '<' || c == '>' || c == '|') {
              c = '_';
            }
          }
          fileName += ext;
        } else {
          fileName = it->uniqueId + ext;
        }
      }

      std::string fullPath = basePath + typeDir + bundleID + "/" + fileName;

      if (access(fullPath.c_str(), F_OK) != -1) {
        remove(fullPath.c_str());
      }

      list.erase(it);

      return;
    }
  }
}

std::vector<PointerChain> LockCore::getLocks(const std::string &bundleID) {
  if (_cache.find(bundleID) == _cache.end())
    load(bundleID);
  return _cache[bundleID];
}

void LockCore::saveLocks(const std::string &bundleID,
                         const std::vector<PointerChain> &items) {
  _cache[bundleID] = items;
  save(bundleID);
}

std::string LockCore::getStoragePath(const std::string &bundleID) {
  NSString *bid = [NSString stringWithUTF8String:bundleID.c_str()];
  NSString *dir = [VMStoragePathHelper pathForSubdirectory:@"PTR"
                                                  bundleID:bid
                                                    create:YES];
  std::string path = [dir UTF8String];
  if (!path.empty() && path.back() != '/')
    path += "/";

  return path;
}

void LockCore::save(const std::string &bundleID) {
  auto &list = _cache[bundleID];

  for (auto &item : list) {
    @autoreleasepool {
      
      std::string basePath = vansonRootPath();
      std::string typeDir;
      std::string fileExt;

      if (item.isSignatureMode) {
        typeDir = basePath + "SIG/";
        fileExt = ".vmsig";
      } else {
        typeDir = basePath + "PTR/";
        fileExt = ".vmpt";
      }

      std::string appDir = typeDir + bundleID + "/";
      NSString *appPath = [NSString stringWithUTF8String:appDir.c_str()];
      [VMStoragePathHelper ensureDirectoryAtPath:appPath];

      NSMutableDictionary *dict = [NSMutableDictionary dictionary];

      dict[@"uniqueId"] = [NSString stringWithUTF8String:item.uniqueId.c_str()];
      dict[@"moduleName"] =
          [NSString stringWithUTF8String:item.moduleName.c_str()];
      dict[@"baseOffset"] = @(item.baseOffset);

      NSMutableArray *offsetsArray = [NSMutableArray array];
      for (int64_t offset : item.offsets) {
        [offsetsArray addObject:@(offset)];
      }
      dict[@"offsets"] = offsetsArray;

      dict[@"note"] = [NSString stringWithUTF8String:item.note.c_str()];
      dict[@"lockValue"] =
          [NSString stringWithUTF8String:item.lockValue.c_str()];
      dict[@"lockEnabled"] = @(item.lockEnabled);
      dict[@"lockType"] = @(item.lockType);
      dict[@"createdAt"] = @(item.createdAt);
      dict[@"sortOrder"] = @(item.sortOrder);
      dict[@"isSignatureMode"] = @(item.isSignatureMode);
      dict[@"signature"] =
          [NSString stringWithUTF8String:item.signature.c_str()];
      dict[@"uiMode"] = @((uint32_t)item.uiMode);
      dict[@"uiMin"] = @(item.uiMin);
      dict[@"uiMax"] = @(item.uiMax);
      dict[@"type"] =
          [NSString stringWithUTF8String:item.type.c_str()] ?: @"card";
      dict[@"bundleID"] = [NSString stringWithUTF8String:item.bundleID.c_str()];
      dict[@"appName"] = [NSString stringWithUTF8String:item.appName.c_str()];
      dict[@"appVersion"] =
          [NSString stringWithUTF8String:item.appVersion.c_str()];
      dict[@"author"] = [NSString stringWithUTF8String:item.author.c_str()];
      dict[@"isImported"] = @(item.isImported);
      
      dict[@"switchOnValue"] = [NSString stringWithUTF8String:item.switchOnValue.c_str()];
      dict[@"switchOffValue"] = [NSString stringWithUTF8String:item.switchOffValue.c_str()];
      dict[@"resultTitle"] = [NSString stringWithUTF8String:item.resultTitle.c_str()];

      NSError *error = nil;
      NSData *jsonData =
          [NSJSONSerialization dataWithJSONObject:dict
                                          options:NSJSONWritingPrettyPrinted
                                            error:&error];
      if (error) {
        continue;
      }

      std::string fileName;
      if (!item.fileName.empty()) {
        
        fileName = item.fileName;
        if (fileName.length() < fileExt.length() ||
            fileName.substr(fileName.length() - fileExt.length()) != fileExt) {
          fileName += fileExt;
        }
      } else {
        
        std::string typeName = item.isSignatureMode ? "signatures" : "pointers";
        if (!bundleID.empty()) {
          fileName = bundleID + "-" + typeName + fileExt;
        } else {
          fileName = typeName + fileExt;
        }
        
        std::string testPath = appDir + fileName;
        int counter = 1;
        while (access(testPath.c_str(), F_OK) != -1) {
          if (!bundleID.empty()) {
            fileName = bundleID + "-" + typeName + "-" + std::to_string(counter) + fileExt;
          } else {
            fileName = typeName + "-" + std::to_string(counter) + fileExt;
          }
          testPath = appDir + fileName;
          counter++;
        }
        item.fileName = fileName;
      }

      std::string filePath = appDir + fileName;

      FILE *f = fopen(filePath.c_str(), "wb");
      if (f) {
        fwrite(jsonData.bytes, 1, jsonData.length, f);
        fclose(f);
      }
    }
  }
}

void LockCore::load(const std::string &bundleID) {
  _cache[bundleID].clear();

  std::string basePath = vansonRootPath();

  struct LoadConfig {
    std::string dir;
    std::string ext;
    std::string name;
  };

  std::vector<LoadConfig> configs = {
      {basePath + "PTR/" + bundleID + "/", ".vmpt", "指针"},
      {basePath + "SIG/" + bundleID + "/", ".vmsig", "特征码"}};

  for (const auto &config : configs) {
    @autoreleasepool {
      NSString *folder = [NSString stringWithUTF8String:config.dir.c_str()];
      NSFileManager *fm = [NSFileManager defaultManager];
      NSArray *files = [fm contentsOfDirectoryAtPath:folder error:nil];

      if (!files) {
        continue;
      }

      NSString *extStr = [NSString stringWithUTF8String:config.ext.c_str()];
      NSPredicate *pred =
          [NSPredicate predicateWithFormat:@"self ENDSWITH %@", extStr];
      NSArray *targetFiles = [files filteredArrayUsingPredicate:pred];

      for (NSString *fileName in targetFiles) {
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
            
            NSString *itemType = itemDict[@"type"];
            BOOL isSignature = [itemType isEqualToString:@"signature"];
            
            PointerChain item;
            item.uniqueId = [itemDict[@"uniqueId"] UTF8String] ?: [[[NSUUID UUID] UUIDString] UTF8String];
            item.moduleName = [itemDict[@"moduleName"] UTF8String] ?: "";
            
            if (isSignature) {
              item.baseOffset = [itemDict[@"offset"] unsignedLongLongValue];
            } else {
              item.baseOffset = [itemDict[@"baseOffset"] unsignedLongLongValue];
            }

            NSArray *offsetsArray = itemDict[@"offsets"];
            if ([offsetsArray isKindOfClass:[NSArray class]]) {
              for (NSNumber *num in offsetsArray) {
                item.offsets.push_back([num longLongValue]);  
              }
            }

            item.note = [itemDict[@"note"] UTF8String] ?: "";
            item.lockValue = [itemDict[@"lockValue"] UTF8String] ?: "";
            item.lockEnabled = [itemDict[@"lockEnabled"] boolValue];
            item.lockType = [itemDict[@"lockType"] unsignedIntValue];
            item.createdAt = [itemDict[@"createdAt"] doubleValue];
            item.sortOrder = [itemDict[@"sortOrder"] doubleValue];
            
            item.isSignatureMode = isSignature || [itemDict[@"isSignatureMode"] boolValue];
            item.signature = [itemDict[@"signature"] UTF8String] ?: "";
            item.uiMode = (PointerUIMode)[itemDict[@"uiMode"] unsignedIntValue];
            item.uiMin = [itemDict[@"uiMin"] floatValue];
            item.uiMax = [itemDict[@"uiMax"] floatValue];
            
            NSString *typeVal = itemDict[@"valType"] ?: itemDict[@"type"];
            item.type = typeVal ? [typeVal UTF8String] : "card";
            item.bundleID = [itemDict[@"bundleID"] UTF8String] ?: bundleID;
            item.appName = [itemDict[@"appName"] UTF8String] ?: "";
            item.appVersion = [itemDict[@"appVersion"] UTF8String] ?: "";
            item.fileName = [fileName UTF8String];
            item.author = [itemDict[@"author"] UTF8String] ?: "";
            item.isImported = [itemDict[@"isImported"] boolValue];
            
            item.switchOnValue = [itemDict[@"switchOnValue"] UTF8String] ?: "";
            item.switchOffValue = [itemDict[@"switchOffValue"] UTF8String] ?: "";
            item.resultTitle = [itemDict[@"resultTitle"] UTF8String] ?: "";

            _cache[bundleID].push_back(item);
          }
        } else {
          
          PointerChain item;
          item.uniqueId = [dict[@"uniqueId"] UTF8String] ?: "";
          item.moduleName = [dict[@"moduleName"] UTF8String] ?: "";
          item.baseOffset = [dict[@"baseOffset"] unsignedLongLongValue];

          NSArray *offsetsArray = dict[@"offsets"];
          if ([offsetsArray isKindOfClass:[NSArray class]]) {
            for (NSNumber *num in offsetsArray) {
              item.offsets.push_back([num longLongValue]);  
            }
          }

          item.note = [dict[@"note"] UTF8String] ?: "";
          item.lockValue = [dict[@"lockValue"] UTF8String] ?: "";
          item.lockEnabled = [dict[@"lockEnabled"] boolValue];
          item.lockType = [dict[@"lockType"] unsignedIntValue];
          item.createdAt = [dict[@"createdAt"] doubleValue];
          item.sortOrder = [dict[@"sortOrder"] doubleValue];
          item.isSignatureMode = [dict[@"isSignatureMode"] boolValue];
          item.signature = [dict[@"signature"] UTF8String] ?: "";
          item.uiMode = (PointerUIMode)[dict[@"uiMode"] unsignedIntValue];
          item.uiMin = [dict[@"uiMin"] floatValue];
          item.uiMax = [dict[@"uiMax"] floatValue];
          item.type = [dict[@"type"] UTF8String] ?: "card";
          item.bundleID = [dict[@"bundleID"] UTF8String] ?: bundleID;
          item.appName = [dict[@"appName"] UTF8String] ?: "";
          item.appVersion = [dict[@"appVersion"] UTF8String] ?: "";

          item.fileName = [fileName UTF8String]; 
          item.author = [dict[@"author"] UTF8String] ?: "";
          item.isImported = [dict[@"isImported"] boolValue];
          
          item.switchOnValue = [dict[@"switchOnValue"] UTF8String] ?: "";
          item.switchOffValue = [dict[@"switchOffValue"] UTF8String] ?: "";
          item.resultTitle = [dict[@"resultTitle"] UTF8String] ?: "";

          _cache[bundleID].push_back(item);
        }
      }
    }
  }
}

std::vector<uint8_t> LockCore::serializeItem(const PointerChain &item) {
  return std::vector<uint8_t>(); 
}

PointerChain LockCore::deserializeItem(const std::vector<uint8_t> &data,
                                       size_t &offset) {
  return PointerChain(); 
}

} 
