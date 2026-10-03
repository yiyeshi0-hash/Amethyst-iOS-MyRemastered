//
//  BackgroundManager.h
//  Amethyst
//
//  Background wallpaper manager - Global support for all view controllers
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BackgroundType) {
    BackgroundTypeNone = 0,
    BackgroundTypeImage,
    BackgroundTypeVideo
};

typedef NS_ENUM(NSInteger, BackgroundUIEffect) {
    BackgroundUIEffectTranslucent = 0,  // 半透明
    BackgroundUIEffectBlur              // 毛玻璃效果
};

@interface BackgroundManager : NSObject

+ (instancetype)sharedManager;

// Background type
@property (nonatomic, readonly) BackgroundType currentType;
@property (nonatomic, readonly, nullable) NSString *currentBackgroundPath;

// UI effect settings (for custom background)
@property (nonatomic, assign) BackgroundUIEffect uiEffect;
@property (nonatomic, assign) CGFloat uiOpacity;  // 0.0 ~ 1.0
@property (nonatomic, assign) CGFloat blurIntensity; // 0.0 ~ 1.0, 背景模糊程度

// Global background container
@property (nonatomic, strong, readonly, nullable) UIView *globalBackgroundContainer;

// Apply background globally
- (void)applyBackgroundToWindow:(UIWindow *)window;
- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC;
- (void)removeGlobalBackground;

// Legacy compatibility
- (void)applyBackgroundToView:(UIView *)view;
- (void)removeBackgroundFromView:(UIView *)view;

// Set background
- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)clearBackground;

// Check if has background
- (BOOL)hasBackground;
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;

// Get background preview
- (nullable UIImage *)backgroundPreview;

// Pause/Resume video (for app lifecycle)
- (void)pauseVideo;
- (void)resumeVideo;

// Update background frame (call on rotation)
- (void)updateBackgroundFrame;

// Make view controllers transparent (for global background visibility)
- (void)makeViewControllerTransparent:(UIViewController *)viewController;
- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC;

// Apply UI effect to any UIView (blur or translucent based on settings)
/// ★ [RIM-UI] 高光描边开关(默认开;背景设置页可关)
@property(nonatomic, assign) BOOL glassRimEnabled;
/// ★ [RIM-UI] 高光强度 0…1(默认 1.0;设置页可调,0 等于关)
@property(nonatomic, assign) CGFloat glassRimStrength;

// ★ [MOTION-BG] 默认背景「流动光效」(对标 ShardLauncher 的缓慢流光)
//   仅当未设自定义背景图/视频(currentType == BackgroundTypeNone)时生效;
//   开关/速度用 NSUserDefaults 持久化(键 background_motion_enabled / background_motion_speed)。
@property (nonatomic, assign) BOOL motionBackgroundEnabled;    // 默认 YES
@property (nonatomic, assign) CGFloat motionBackgroundSpeed;   // 0.3…1.6,默认 1.0(越大越快)
/// ★ [MOTION-BG] 当前环境是否允许跑光效:
///   开关打开 && 未开「减弱动态效果」&& 非低电量模式 && 非低端(<=2GB)设备。任一不满足即降为静态渐变。
- (BOOL)motionBackgroundAllowed;

- (void)applyEffectToView:(UIView *)view;
- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell;
- (void)applyEffectToCell:(UITableViewCell *)cell;
// 适配 UISearchBar：移除默认不透明背景，让 searchBar 透出底层自定义启动器背景
- (void)applyEffectToSearchBar:(UISearchBar *)searchBar;

// Apply UI effect to navigation bar and toolbar
- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar;
- (void)applyEffectToToolbar:(UIToolbar *)toolbar;

// Apply UI effect settings to current split view controller
- (void)refreshUIEffect;

@end

NS_ASSUME_NONNULL_END