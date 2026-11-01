#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// NoAdsSlot - 水果老虎机 (com.flyfish.Slot) 去广告
// 广告栈: Google AdMob (中介) -> Pangle(穿山甲) + SKAdNetwork
// 策略: 拦截 AdMob 全屏广告的 present，让广告"加载成功但不展示"，
//       这样游戏"看广告领奖励"逻辑不卡死；同时拦截 banner 加载。
// ============================================================

static void noads_log(NSString *msg) {
    NSLog(@"[NoAdsSlot] %@", msg);
}

// ---------- 1. 插屏广告：不展示 ----------
%hook GADInterstitialAd
- (void)presentFromRootViewController:(UIViewController *)vc {
    noads_log(@"blocked GADInterstitialAd present");
}
%end

// ---------- 2. 激励视频：不展示，但立即回调"已获得奖励" ----------
%hook GADRewardedAd
- (void)presentFromRootViewController:(UIViewController *)vc
             userDidEarnRewardHandler:(void (^)(void))handler {
    noads_log(@"blocked GADRewardedAd present, fire reward");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler();
        });
    }
}
%end

// ---------- 3. 开屏广告：不展示 ----------
%hook GADAppOpenAd
- (void)presentFromRootViewController:(UIViewController *)vc {
    noads_log(@"blocked GADAppOpenAd present");
}
%end

// ---------- 4. Banner 广告：加载请求直接吞掉 ----------
%hook GADBannerView
- (void)loadRequest:(id)request {
    noads_log(@"blocked GADBannerView loadRequest");
}
- (void)loadWithAdResponseString:(NSString *)s {
    noads_log(@"blocked GADBannerView loadWithAdResponseString");
}
%end

%ctor {
    noads_log(@"NoAdsSlot loaded (AdMob interceptor)");
}
