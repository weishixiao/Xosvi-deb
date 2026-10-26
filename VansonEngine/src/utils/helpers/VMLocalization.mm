// Xosvi 集成版：VMLocalization 轻量替代实现。
//
// 原版 VansonMod 的 VMLocalization 依赖 LocalizationCore + 13 个语言表（约 1.1 万行，
// 面向 App 的 13 语言 UI 文案）。Xosvi 只需要引擎的错误/状态文案，不需要多语言表，
// 因此这里保留同样的接口（+shared / -localizedString: / -currentLanguage / -setLanguage:），
// 用一张精简的中英对照表实现，避免把整棵本地化树拖进来。
//
// 表内 key 由 `rg --no-filename -o 'TR\(@"[^"]+"\)' VansonEngine/src` 提取（共 9 个）。
// 新增引擎代码引用新 key 时，未命中的 key 会原样返回（便于发现遗漏，不会丢错误信息）。

#import "include/VMLocalization.h"

@implementation VMLocalization

+ (instancetype)shared {
  static VMLocalization *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [self new];
  });
  return s;
}

// key → @[ 英文, 简中 ]
static NSDictionary<NSString *, NSArray<NSString *> *> *VMEngineStrings(void) {
  static NSDictionary *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{
      @"Msg_Target_Not_Found" : @[ @"Target process not attached", @"未附加到目标进程" ],
      @"Set_Invalid_Value"    : @[ @"Invalid value", @"无效的数值" ],
      @"Msg_Search_Success"   : @[ @"Search completed", @"搜索完成" ],
      @"Msg_Search_No_Res"    : @[ @"No matching results", @"没有匹配结果" ],
      @"Msg_Filter_Success"   : @[ @"Filter completed", @"筛选完成" ],
      @"Msg_Filter_No_Res"    : @[ @"No results left after filter", @"筛选后无剩余结果" ],
      @"Msg_No_Snapshot"      : @[ @"No snapshot to restore", @"没有可恢复的快照" ],
      @"Msg_Snapshot_Failed"  : @[ @"Snapshot failed", @"快照失败" ],
      @"Mod_Fuzzy_Ready_Fmt"  : @[ @"Fuzzy search ready: %@", @"模糊搜索就绪：%@" ],
    };
  });
  return map;
}

- (BOOL)isChinese {
  NSString *lang = [self currentLanguage];
  if ([lang isEqualToString:@"Auto"]) {
    NSString *sysLang = [NSLocale preferredLanguages].firstObject ?: @"en";
    return [sysLang hasPrefix:@"zh"];
  }
  return [lang hasPrefix:@"zh"];
}

- (NSString *)currentLanguage {
  NSString *lang = [[NSUserDefaults standardUserDefaults] objectForKey:@"user_lang"];
  if (!lang || ![lang isKindOfClass:[NSString class]] || lang.length == 0) {
    return @"Auto";
  }
  return lang;
}

- (void)setLanguage:(NSString *)lang {
  [[NSUserDefaults standardUserDefaults] setObject:lang forKey:@"user_lang"];
}

- (NSString *)localizedString:(NSString *)key {
  if (!key || ![key isKindOfClass:[NSString class]] || key.length == 0) {
    return @"";
  }
  NSArray<NSString *> *pair = VMEngineStrings()[key];
  if (!pair) {
    return key; // 未入表：原样返回，便于发现遗漏
  }
  return [self isChinese] ? pair[1] : pair[0];
}

@end
