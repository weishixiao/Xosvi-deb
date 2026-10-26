// Xosvi VansonEngine 桥接辅助（Swift 可见）
//
// 用 C 函数把需要传枚举常量的调用点包起来，避免 Swift 侧对
// VMStringEncoding（NS_ENUM）的导入名猜测出错。
#import <Foundation/Foundation.h>
#import "VMMemoryEngine.h"

VMStringEncoding XosviVansonUTF8Encoding(void);
