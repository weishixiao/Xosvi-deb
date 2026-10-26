// 编译期校验：确认 VansonMemoryBridge 实际调用的每个 VMMemoryEngine 方法签名都对得上。
// 用 clang -fsyntax-only -x objective-c++ 检查；任何签名不符都会直接报错。
// 这个文件不参与构建，只用于踩坑验证。

#import <Foundation/Foundation.h>
#import "VMMemoryEngine.h"
#import "VMLockEngine.h"

void verifySignatures(void) {
    VMMemoryEngine *eng = [VMMemoryEngine shared];

    // 属性
    (void)eng.currentBundleID;
    (void)eng.currentProcessName;
    (void)eng.resultCount;
    (void)eng.resultLimit;
    (void)eng.mainModuleAddress;

    // attach
    (void)[eng attachToPid:1234];

    // 扫描（签名 + 精确）
    [eng scanMemoryWithMode:VMSearchModeExact
                     valStr:@"100"
                   dataType:VMDataTypeInt32
                  fuzzyType:VMFuzzyChanged
               isNextSearch:NO
                 completion:^(NSUInteger count, NSString *msg) { (void)count; (void)msg; }];

    [eng scanMemoryWithMode:VMSearchModeFuzzy
                     valStr:@"100"
                   dataType:VMDataTypeInt32
                  fuzzyType:VMFuzzyGreater
               isNextSearch:NO
                 completion:^(NSUInteger count, NSString *msg) { (void)count; (void)msg; }];

    // 筛选
    [eng filterResultsWithMode:VMFilterModeGreater
                          val1:@"1"
                          val2:@"2"
                          type:VMDataTypeInt32
                    completion:^(NSUInteger count, NSString *msg) { (void)count; (void)msg; }];

    // 结果读取 —— 重点验证 getResultItemAtIndex:dataType: 的 Swift 导入名
    VMScanResultItem *item = [eng getResultItemAtIndex:0 dataType:VMDataTypeInt32];
    (void)item.address;
    (void)item.valueStr;

    // 读写 —— 重点验证 readStringAtAddress:encoding:maxBytes:
    (void)[eng readAddress:0x1000 type:VMDataTypeInt32];
    (void)[eng readStringAtAddress:0x1000 encoding:VMStringEncodingUTF8 maxBytes:64];
    (void)[eng writeAddress:0x1000 value:@"1" type:VMDataTypeInt32];
    (void)[eng writeStringAtAddress:0x1000 value:@"x" encoding:VMStringEncodingUTF8];
    (void)[eng writeStringAtAddress:0x1000 value:@"x" encoding:VMStringEncodingUTF8 byteCapacity:64];

    // 原始字节
    NSData *raw = [eng readRawMemory:0x1000 length:16];
    (void)[eng writeRawData:raw toAddress:0x1000];
    (void)[eng dataFromHexString:@"cafebabe"];

    // 会话
    [eng clearSession];
    (void)[eng undoLastManualWriteBatch];
}
