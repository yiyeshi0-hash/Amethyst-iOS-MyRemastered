#pragma once

#import <UIKit/UIKit.h>

#include <stdbool.h>
#include <string.h>
#include "environ.h"
#include "jni.h"

// Remove date + time from NSLog, unneeded
#define NSLog(args...) customNSLog(__FILE__,__LINE__,__PRETTY_FUNCTION__,args);

// Control button actions
#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

#define BUTTON1_DOWN_MASK 1 << 10 // left btn
#define BUTTON2_DOWN_MASK 1 << 11 // mid btn
#define BUTTON3_DOWN_MASK 1 << 12 // right btn

// GLFW event types
#define EVENT_TYPE_CHAR 1000
#define EVENT_TYPE_CHAR_MODS 1001
#define EVENT_TYPE_CURSOR_ENTER 1002
#define EVENT_TYPE_CURSOR_POS 1003
#define EVENT_TYPE_FRAMEBUFFER_SIZE 1004
#define EVENT_TYPE_KEY 1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL 1007
#define EVENT_TYPE_WINDOW_POS 1008
#define EVENT_TYPE_WINDOW_SIZE 1009
#define EVENT_TYPE_MODIFIERS 1010

#define GLFW_FOCUSED 0x00020001
#define GLFW_VISIBLE 0x00020004

#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"
#define RENDERER_NAME_VULKAN "libMoltenVK.dylib"
// LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
// 复刻自官方 MojoLauncher/LTW 仓库，完美支持 Sodium + Iris 光影：
//   - 伪装成 OpenGL 3.3 Core Profile 让 MC 1.17+ 正常运行
//   - 主动声明 GL_ARB_buffer_storage 等 ARB 扩展，让 Sodium 的
//     persistent mapped buffers / texture buffers 正常工作
//   - Fragment shader 编译失败时忽略错误，让 BSL/Mellow 等光影包能运行
#define RENDERER_NAME_LTW "libltw.dylib"

// Metal 渲染器（metallum / MetalUniversal）：图形后端由 metallum agent 走原生 Metal
// （直接 MTLDevice），不经过 EGL 渲染器 —— 选中它时 JavaLauncher 只置
// AMETHYST_METAL=1（agent 据此打开渲染 patch），并把 AMETHYST_RENDERER 回落
// auto（Surface 的 GL 上下文仍由 ANGLE 提供），与 metallum 官方集成一致
// （渲染器只管 GL / Vulkan 回退）。
// 渲染器 dylib 由 agent jar 自带（natives/ios/libmetallum.dylib，运行期解出）。
#define RENDERER_NAME_METAL "libmetallum.dylib"

// Mithril 渲染器 - OpenGL 3.3 Core → Vulkan/Metal 转译层（libmithril.dylib）。
// 自带完整的 EGL 1.5 + GL 实现（Vulkan backend，经 MoltenVK 到 Metal），
// 必须从自身 dylib 解析 EGL 符号：若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal
// 上下文而非 Mithril 的 swapchain，且 eglChooseConfig 在 Mithril 的属性组合下
// 可能返回 0 个配置，触发 gl_init_context 的 assert(bundle->config)。
// 参考：Uniaball/Mithril-Wrapper 仓库 launcher-patch/ 下对 Air 的接入方式。
#define RENDERER_NAME_MITHRIL "libmithril.dylib"

// MobileGL - MobileGL-Dev 的桌面 OpenGL 实现（LGPL-3.0）。
// 两个变体共用同一个 libMobileGL.dylib 二进制，由环境变量
// MOBILEGL_BACKEND_TYPE 在运行时选择后端：
//   libMobileGL.dylib       -> DirectVulkan（GL -> Vulkan -> MoltenVK -> Metal）
//   libMobileGL-gles.dylib  -> DirectGLES（GL -> OpenGL ES）
// 与 Mithril 一样自带 EGL 实现，必须从自身 dylib 解析 EGL 符号。
// 参考：Swung0x48/Amethyst-iOS 提交 dc57bfd3d2 "feat: add MobileGL renderer support"。
#define RENDERER_NAME_MOBILEGL "libMobileGL.dylib"
#define RENDERER_NAME_MOBILEGL_GLES "libMobileGL-gles.dylib"

// SimpleFPEWrapper（MobileGL-Dev，LGPL-3.0）—— 固定管线 (GL 1.x) 仿真层。
// 接入方式对齐安卓 AngelAuraMC/Amethyst-Android @ feat/sfpew_angle：SFPEW 顶替
// 渲染器被 LWJGL dlopen，真正的后端 EGL 由环境变量 SFPEW_EGL 指定，SFPEW 内部
// dlopen 它并转发调用。安卓是 Tools.useSFPEW + SFPEW_EGL + 把 renderLibrary
// 换成 libSimpleFPEWrapper.so；iOS 侧 AMETHYST_RENDERER 本身就是最终库名，
// 故只需补 SFPEW_EGL（见 JavaLauncher.m）。
#define RENDERER_NAME_SFPEW "libSimpleFPEWrapper.dylib"

static inline bool isSFPEWRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_SFPEW);
}

// SFPEW 只能叠加在「OpenGL ES 后端」之上（对齐安卓 JREUtils：gl4es / system-gles /
// zink 一律 Tools.useSFPEW=false，只有 MobileGlues 这类 GLES 后端才叠加）。
// 桌面 GL→GLES 的 MobileGL-gles 同样属于 GLES 后端，故一并允许。
static inline bool isSFPEWOverlayEligibleRenderer(const char *renderer) {
    if (!renderer) return false;
    return !strcmp(renderer, RENDERER_NAME_MOBILEGLUES) ||
           !strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES);
}

static inline bool isMobileGLRenderer(const char *renderer) {
    return renderer && (!strcmp(renderer, RENDERER_NAME_MOBILEGL) ||
                        !strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES));
}

static inline bool isMithrilRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_MITHRIL);
}

// 自带 EGL 实现的渲染器：EGL 符号要从渲染器自己的 dylib 解析，不能用 ANGLE。
static inline bool isSelfEglRenderer(const char *renderer) {
    return isMithrilRenderer(renderer) || isMobileGLRenderer(renderer);
}

// 导出 desktop OpenGL（而非 OpenGL ES）的渲染器：
// 需要 EGL_OPENGL_BIT 配置 + eglBindAPI(EGL_OPENGL_API)。
static inline bool isDesktopGLRenderer(const char *renderer) {
    return isMobileGLRenderer(renderer) || isMithrilRenderer(renderer) ||
           (renderer && !strcmp(renderer, RENDERER_NAME_MTL_ANGLE));
}

#define SPECIALBTN_KEYBOARD -1
#define SPECIALBTN_TOGGLECTRL -2
#define SPECIALBTN_MOUSEPRI -3
#define SPECIALBTN_MOUSESEC -4
#define SPECIALBTN_VIRTUALMOUSE -5
#define SPECIALBTN_MOUSEMID -6
#define SPECIALBTN_SCROLLUP -7
#define SPECIALBTN_SCROLLDOWN -8
#define SPECIALBTN_MENU -9

#define NSDebugLog(...) if (debugLogEnabled) { NSLog(__VA_ARGS__); }
BOOL debugLogEnabled, isJailbroken;

//__weak UIViewController *viewController;

#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
BOOL isJITEnabled(BOOL checkCSOps);
// legacy method used to check if we're using universal script
void* JIT26CreateRegionLegacy(size_t len);
// JIT26 调试器存活探针（议题 #133）：CS_DEBUGGED 只是"曾经启用过"的持久标志，
// 外部工具瞬时附加后退出会残留置位；TXM 机型上 launchJVM 的 brk #0x69 必须由
// 活的调试器现场服务，否则 EXC_BREAKPOINT 秒闪退。状态显示继续用 isJITEnabled，
// 启动决策用这组探针（三探针任一命中即在岗：ppid!=1 / P_TRACED / 任务异常端口）。
BOOL JIT26IsLikelyDebuggerKeepAttached(void);
BOOL JIT26DebuggerAttachedViaPtrace(void);
BOOL JIT26DebuggerViaExceptionPorts(void);
// brk #0x69 的 SIGTRAP 安全网包装：无人应答时返回 NULL 而不是致死崩溃，
// 由调用方走优雅报错路径；调试器正常应答时行为与裸函数完全一致。
void* JIT26CreateRegionLegacySafe(size_t len);
// JIT 等待轮询的有界版本（最长 timeout 秒，每 10s 心跳日志，挂起间隙不计入
// 超时预算，超时返回 NO）。替代裸 while(!isJITEnabled) 死循环。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label);
// JIT 等待成功后的自愈式主队列派发（三道防线：常规派发 / 前台激活重派 /
// 后台看门狗重派并钉死未送达锚点），防主队列续接块丢失导致启动卡死。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label);
// used for large memory regions
void* JIT26PrepareRegion(void *addr, size_t len);
// ★ [POCKETJ-JIT] Universal JIT 协议第 0 号调用:请求调试器脱离
//   (mov x16,#0; brk #0xf00d)。与 JIT26PrepareRegion 同族,是 PocketJ/StikJIT
//   universal.js 的 commands[0]。⚠ 只能在【所有】初始 RX 区都已 PrepareRegion
//   之后调用(见 utils.m 内注释与 Natives/pocketj_jit/PORTING_NOTES.md)。
void JIT26Detach(void);
// JIT26Detach 的 SIGTRAP 安全网版:调试器已脱离时 brk #0xf00d 无人应答,
// 捕获后返回 NO(降级),不使进程致死(与 JIT26CreateRegionLegacySafe 同款)。
BOOL JIT26DetachSafe(void);
// ★ [POCKETJ-JIT] PocketJ 内置 StikJIT 的前置门禁(INTEGRATION.md「Gate every
//   entry point」):iOS ≥17.4 + 宿主 get-task-allow + 可读配对文件。
//   本仓库暂未接入 Helper 扩展,以下仅用于检测/日志/UI 提示,不做自附加调试器。
BOOL AMEJITDeviceSupportsBuiltInStikJIT(void);
BOOL AMEJITHasGetTaskAllow(void);
NSString *AMEJITPairingFilePath(void);   // Documents/StikJIT/pairingFile.plist
BOOL AMEJITHasPairingFile(void);
void AMEJITLogPocketJReadiness(NSString *context);
// same as JIT26PrepareRegion, but used for smaller memory regions
// and retain content instead of filling 0x69
void JIT26PrepareRegionForPatching(void *addr, size_t len);
void JIT26SetDetachAfterFirstBr(BOOL value);
void JIT26SendJITScript(NSString* script);

// ★ [JIT-NOCRASH] 其余 JIT26 brk(#0xf00d)协议调用的 SIGTRAP 安全网包装。
//   与 JIT26CreateRegionLegacySafe / JIT26DetachSafe 共用同一套 handler /
//   sigjmp / armed 机制(分层、支持嵌套)。调试器在岗时行为与裸函数一致；无人
//   应答时降级:返回 NO(或 NULL) 并仅在失败分支打日志,由调用方跳过该步,
//   不再 SIGTRAP 致死。安全网只在"无人应答"时兜底,不干扰正常 JIT。
//   JIT26PrepareRegionSafe 丢弃裸函数的 void* 返回值(无任何调用方使用),
//   只回报"是否被调试器服务"。
BOOL JIT26PrepareRegionSafe(void *addr, size_t len);
BOOL JIT26PrepareRegionForPatchingSafe(void *addr, size_t len);
BOOL JIT26SendJITScriptSafe(NSString *script);
BOOL JIT26SetDetachAfterFirstBrSafe(BOOL value);

// Device JIT flags（同步自上游 AngelAuraMC/Amethyst-iOS）
// 支持 iOS 26.6+ / 27 的现代 Preboot 路径 + ChipID 硬件 fallback + capability 查询
typedef enum {
    JIT_FLAG_IS_IOS_26 = 1 << 0,
    JIT_FLAG_FORCE_MIRRORED = 1 << 1,
    JIT_FLAG_HAS_TXM = 1 << 2,
} JITFlags;
JITFlags DeviceGetJITFlags(BOOL refresh);
BOOL DeviceHasJITFlags(JITFlags flags);
BOOL DeviceNeedsDebugJITMapping(void);

// Init functions
void init_bypassDyldLibValidation();
void init_hookFunctions();

// Zink (Mesa 25.0.7) + MoltenVK vertex stride 4 字节对齐 fix
// 仅在 zink 渲染器被选中时激活（需在 AMETHYST_RENDERER 环境变量设置后调用）
// 详见 main_hook.m 中的实现注释
void installZinkStrideFix();
// 在新 image（libOSMesa / libMoltenVK）加载后调用，重新执行 fishhook
// 捕获新 image 对 Vulkan loader 函数的符号引用
void rebindZinkStrideFixForNewImage();
void init_hookUIKitConstructor();
void init_setupMultiDir();

BOOL PLPatchMachOPlatformForFile(const char *path);

UIViewController* currentVC();
void openLink(UIViewController* sender, NSURL* link);
void handle_fatal_exit(int code);

NSString* localize(NSString* key, NSString* comment);

// ★ [LANG-SWITCH] 启动器界面语言覆盖（独立于系统 AppleLanguages）：
// 用户在「设置 > 语言」里选择后写入 NSUserDefaults（键名 ame_launcher_language），
// localize() 会优先用它对应的 <lang>.lproj 包，取不到再回退系统语言。
extern NSString * const AmeLauncherLanguageDefaultsKey;
/// 用户选择的语言代码（如 @"zh-Hans"）；返回 nil 表示「跟随系统」。
NSString *AmeLauncherPreferredLanguageOverride(void);
/// 写入/清除语言覆盖。code 为 nil 或空串时清除（回到跟随系统）。
void AmeLauncherSetPreferredLanguageOverride(NSString *code);
/// 语言代码 → 人读显示名（用系统当前语言本地化）；取不到时回退返回 code 本身。
NSString *AmeLauncherDisplayNameForLanguageCode(NSString *code);
/// 枚举 App 包内实际存在 .lproj 且带 Localizable.strings 的语言代码（不含 Base），按显示名排序。
NSArray<NSString *> *AmeLauncherAvailableLanguageCodes(void);
// YES 表示 NSError 是"当前没有可用网络"，而非服务器返回了不喜欢的内容。
// 账户刷新只认 NSURLErrorDataNotAllowed 会漏掉飞行模式/无 Wi-Fi 等常见离线形态。
BOOL isConnectivityError(NSError *error);
NSMutableDictionary* parseJSONFromFile(NSString *path);
NSError* saveJSONToFile(NSDictionary *dict, NSString *path);
void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...);

static inline CGFloat clamp(CGFloat x, CGFloat lower, CGFloat upper) {
    return fmin(upper, fmax(x, lower));
}
CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max);
CGFloat dpToPx(CGFloat dp);
CGFloat pxToDp(CGFloat px);
void setButtonPointerInteraction(UIButton *button);
void _CGDataProviderReleaseBytePointerCallback(void *info,const void *pointer);
void dismissModalViewController(UIViewController *viewController);

jboolean attachThread(bool isAndroid, JNIEnv** secondJNIEnvPtr);

void sendData(short type, int i1, int i2, short i3, short i4);
void sendDataFloat(short type, float i1, float i2, short i3, short i4);

void closeGLFWWindow();
void callback_LauncherViewController_installMinecraft();
void callback_SurfaceViewController_launchMinecraft(int width, int height);
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y);

// FPS 计数器：在 pojavSwapBuffers() 中累加，调用此函数读取并重置（参照 FCL/ZL2）
unsigned int pojavGetAndResetFps();
// 显式递增 FPS 计数器（供 Vulkan 模式 CADisplayLink fallback 使用）
void pojavIncrementFpsCounter();
// 运行时判定 MC 真实渲染路径是否为 Vulkan（clientAPI == GLFW_NO_API）。
// 比 SurfaceViewController 在 viewDidLoad 时的静态字符串推断更准确：
// - 真正 Vulkan 路径（graphicsApi=prefer_vulkan 或 default 走 Vulkan）→ 返回 true
// - Vulkan 渲染器但 MC 实际选 OpenGL 路径（prefer_opengl）→ 返回 false，避免双重计数
// 此函数读取 egl_bridge.m 中的 clientAPI 全局变量，由 pojavSetWindowHint(GLFW_CLIENT_API, ...) 写入。
bool pojavIsActualVulkanPath();

void CallbackBridge_nativeSetInputReady(BOOL inputReady);
BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */);
BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods);
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y);
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
// Task83：控件按钮键盘打字——按下时按 US ANSI 布局补发一个字符事件
// （MC 1.13+ 聊天框只认 charTyped/text-input，纯 key 事件不进文本）。
// 仅由按钮路径调用（SurfaceViewController executebtn），硬件键盘不走这里。
BOOL CallbackBridge_buttonKeySynthesizeText(int key);
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
void CallbackBridge_nativeSendScreenSize(int width, int height);
void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset);
void CallbackBridge_sendKeycode(int keycode, jchar keychar, int scancode, int modifiers, BOOL isDown);
void CallbackBridge_pauseGameIfNeed();
// issue #27 修复（参照 FCL commit 08c0716）：物理键盘 modifier 同步
// 显式同步 MC 1.21.9+ 内部的 InputConstants modifier 缓存。
// 由 KeyboardInput.m 在物理键盘按下/释放事件中调用。
void CallbackBridge_syncModifiersToMC(int mods);
void CallbackBridge_queueModifierSync(int mods);

// ---- Air 对齐：gl_bridge.m 实现的取证/呈现层接口（见 gl_bridge.m 内定义）----
void ame_egl_swap_stats(unsigned long *ok, unsigned long *fail);
void ame_egl_swap_framegap(unsigned int *maxGapMs, unsigned int *avgGapMs);
void ame_egl_swap_phase_stats(unsigned int *presentAvgMs, unsigned int *presentMaxMs,
                              unsigned int *buildAvgMs, unsigned int *buildMaxMs);
bool ame_gl_surface_owns_layer(void);
bool ame_gl_surface_transposed(void);
