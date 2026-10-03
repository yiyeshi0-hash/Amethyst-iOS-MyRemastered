#import <SafariServices/SafariServices.h>

#include "jni.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <string.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/sysctl.h>

#include "utils.h"

CFTypeRef SecTaskCopyValueForEntitlement(void* task, NSString* entitlement, CFErrorRef  _Nullable *error);
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL getEntitlementValue(NSString *key) {
    void *secTask = SecTaskCreateFromSelf(NULL);
    CFTypeRef value = SecTaskCopyValueForEntitlement(SecTaskCreateFromSelf(NULL), key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    CFRelease(value);
    return ![(__bridge id)value isKindOfClass:NSNumber.class] || [(__bridge id)value boolValue];
}

BOOL isJITEnabled(BOOL checkCSFlags) {
    if (!checkCSFlags && (getEntitlementValue(@"dynamic-codesigning") || isJailbroken)) {
        return YES;
    }

    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}

void openLink(UIViewController* sender, NSURL* link) {
    if (NSClassFromString(@"SFSafariViewController") == nil) {
        NSData *data = [link.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        UIImage *image = [UIImage imageWithCIImage:filter.outputImage scale:1.0 orientation:UIImageOrientationUp];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(300, 300), NO, 0.0);
        CGRect frame = CGRectMake(0, 0, 300, 300);
        [image drawInRect:frame];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:frame];
        imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
            message:link.absoluteString
            preferredStyle:UIAlertControllerStyleAlert];

        UIViewController *vc = UIViewController.new;
        vc.view = imageView;
        [alert setValue:vc forKey:@"contentViewController"];

        UIAlertAction* doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil) style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:doneAction];
        [sender presentViewController:alert animated:YES completion:nil];
    } else {
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:link];
        [sender presentViewController:vc animated:YES completion:nil];
    }
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

NSError* saveJSONToFile(NSDictionary *dict, NSString *path) {
    // TODO: handle rename
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData == nil) {
        return error;
    }
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!success) {
        return error;
    }
    return nil;
}

// ★ [LANG-SWITCH] 启动器界面语言覆盖：持久化键。
// 刻意与系统的 AppleLanguages 分开——那是全局键，会牵动 App 内所有 bundle 的语言
// 选择，也不适合作为「跟随系统 / 指定语言」这种应用内偏好的保存位置。
NSString * const AmeLauncherLanguageDefaultsKey = @"ame_launcher_language";

// ★ [LANG-SWITCH] 读取用户选择；空串与 nil 一律视为「跟随系统」。
NSString *AmeLauncherPreferredLanguageOverride(void) {
    NSString *code = [[NSUserDefaults standardUserDefaults] stringForKey:AmeLauncherLanguageDefaultsKey];
    return (code.length > 0) ? code : nil;
}

// ★ [LANG-SWITCH] 写入/清除覆盖。code 为 nil 或空串时清除（回到跟随系统）。
void AmeLauncherSetPreferredLanguageOverride(NSString *code) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (code.length > 0) {
        [defaults setObject:code forKey:AmeLauncherLanguageDefaultsKey];
    } else {
        [defaults removeObjectForKey:AmeLauncherLanguageDefaultsKey];
    }
    [defaults synchronize];
}

// ★ [LANG-SWITCH] 语言代码 → 人读显示名，用系统当前语言本地化（NSLocale）：
// 例如系统为中文时 zh-Hans → 「简体中文」，系统为英文时 → 「Chinese, Simplified」。
NSString *AmeLauncherDisplayNameForLanguageCode(NSString *code) {
    if (code.length == 0) return @"";
    NSLocale *displayLocale = [NSLocale currentLocale];
    NSString *name = [displayLocale localizedStringForLanguageCode:code];
    return name.length > 0 ? name : code;
}

// ★ [LANG-SWITCH] 自动枚举 App 包里实际存在的 .lproj（不手写死清单）：
// 构建时 `cp -R Natives/resources/*` 会把各 <lang>.lproj 拷进 bundle，
// 这里以资源目录为准；只保留确实带 Localizable.strings 的语言，避免列出空壳目录。
NSArray<NSString *> *AmeLauncherAvailableLanguageCodes(void) {
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    NSString *resourcePath = [NSBundle mainBundle].resourcePath;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:resourcePath error:nil]) {
        if (![entry.pathExtension isEqualToString:@"lproj"]) continue;
        NSString *code = [entry stringByDeletingPathExtension];
        if (code.length == 0 || [code isEqualToString:@"Base"]) continue;
        NSString *stringsPath = [resourcePath stringByAppendingPathComponent:
                                 [entry stringByAppendingPathComponent:@"Localizable.strings"]];
        if (![fm fileExistsAtPath:stringsPath]) continue;
        [codes addObject:code];
    }
    // 按系统语言下的显示名排序，列表更符合直觉。
    [codes sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [AmeLauncherDisplayNameForLanguageCode(a) localizedCaseInsensitiveCompare:
                AmeLauncherDisplayNameForLanguageCode(b)];
    }];
    return codes;
}

// ★ [LANG-SWITCH] 缓存当前覆盖语言对应的 lproj bundle，避免每次取词都查磁盘。
// 语言变更时（键值不同）自动重建，所以切换语言无需重启即可生效。
static NSString *sAmeLocalizedLangCode = nil;
static NSBundle *sAmeLocalizedLangBundle = nil;

NSString* localize(NSString* key, NSString* comment) {
    // ★ [LANG-SWITCH] 优先使用用户在「设置 > 语言」里选择的语言包（自定义键持久化）。
    // 取不到（未设置 / 资源缺失 / 该 key 在目标语言里没定义）再回退下面的原有逻辑。
    NSString *override = AmeLauncherPreferredLanguageOverride();
    if (override.length > 0) {
        if (![override isEqualToString:sAmeLocalizedLangCode]) {
            NSString *path = [[NSBundle mainBundle] pathForResource:override ofType:@"lproj"];
            sAmeLocalizedLangCode = override;
            sAmeLocalizedLangBundle = path ? [NSBundle bundleWithPath:path] : nil;
        }
        if (sAmeLocalizedLangBundle) {
            NSString *overridden = [sAmeLocalizedLangBundle localizedStringForKey:key value:nil table:nil];
            if (overridden && ![overridden isEqualToString:key]) {
                return overridden;
            }
        }
    } else {
        // 跟随系统：清掉覆盖缓存，保证下次选择语言时重新建包。
        sAmeLocalizedLangCode = nil;
        sAmeLocalizedLangBundle = nil;
    }

    // —— 以下为原有回退逻辑（未改动语义）——
    NSString *value = NSLocalizedString(key, nil);
    if (![NSLocale.preferredLanguages[0] isEqualToString:@"en"] && [value isEqualToString:key]) {
        NSString* path = [NSBundle.mainBundle pathForResource:@"en" ofType:@"lproj"];
        NSBundle* languageBundle = [NSBundle bundleWithPath:path];
        value = [languageBundle localizedStringForKey:key value:nil table:nil];

        if ([value isEqualToString:key]) {
            value = [[NSBundle bundleWithIdentifier:@"com.apple.UIKit"] localizedStringForKey:key value:nil table:nil];
        }
    }

    return value;
}

// 该错误是否意味着设备根本连不上网。值得穷举：原来只认
// NSURLErrorDataNotAllowed（应用被关蜂窝数据这一种窄形态），而最常见的离线
// 形态——飞行模式、无 Wi-Fi——是 NSURLErrorNotConnectedToInternet。
BOOL isConnectivityError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:   // 飞行模式、无 Wi-Fi、无信号
        case NSURLErrorDataNotAllowed:           // 应用被关蜂窝数据
        case NSURLErrorNetworkConnectionLost:    // 请求中途掉线
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:          // captive portal 与坏 DNS
        case NSURLErrorTimedOut:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorResourceUnavailable:
            return YES;
        default:
            return NO;
    }
}

void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap; 
    va_start (ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    printf("%s", [body UTF8String]);
    if (![format hasSuffix:@"\n"]) {
        printf("\n");
    }
    va_end (ap);
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}

void setButtonPointerInteraction(UIButton *button) {
    button.pointerInteractionEnabled = YES;
    button.pointerStyleProvider = ^ UIPointerStyle* (UIButton* button, UIPointerEffect* proposedEffect, UIPointerShape* proposedShape) {
        UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:button];
        return [NSClassFromString(@"UIPointerStyle") styleWithEffect:[NSClassFromString(@"UIPointerHighlightEffect") effectWithPreview:preview] shape:proposedShape];
    };
}

__attribute__((noinline,optnone,naked))
void* JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}
// ★ [POCKETJ-JIT] Universal JIT 协议第 0 号调用:显式请求调试器脱离。
//   参考:EricoEC/PocketJLauncher · Vendor/StikJIT/Resources/universal.js(commands[0])
//   与 Vendor/StikJIT/INTEGRATION.md「Implement the universal protocol」给出的签名:
//     void JIT26Detach(void) { mov x16, #0; brk #0xf00d; ret }
//   x16=0 ⇒ universal.js 的 JIT26Detach() ⇒ 向 debugserver 发 "D" 并结束脚本循环。
//   ⚠ 调用时机(INTEGRATION.md 强制):必须先对【所有】初始 RX 区完成
//     JIT26PrepareRegion、建好可写别名,再调本函数;脚本一旦脱离,后加入的 RX 区
//     就无法再被服务。本仓库现有启动流程靠 universal.js 的 detachAfterFirstBr
//     在 dyld 补丁阶段的 JIT26PrepareRegion / JIT26PrepareRegionForPatching 之后
//     隐式脱离,故这里只补齐协议原语,不在启动路径上另加调用点 —— 擅自提前脱离会让
//     dyld_bypass_validation.m 里未包安全网的 brk 直接 SIGTRAP 崩溃。详见
//     Natives/pocketj_jit/PORTING_NOTES.md。
__attribute__((noinline,optnone,naked))
void JIT26Detach(void) {
    asm("mov x16, #0 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void* JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
   asm("mov x16, #2 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
   asm("mov x16, #3 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
   asm("mov x16, #4 \n"
       "brk #0xf00d \n"
       "ret");
}
void JIT26SendJITScript(NSString* script) {
    NSCAssert(script, @"Script must not be nil");
    BreakSendJITScript((char*)script.UTF8String, script.length);
}

// brk #0x69 无人应答时的 SIGTRAP 安全网：裸函数会直接致死（议题 #133
// "开启 JIT 后闪退"），这里在调用窗口内捕获并返回 NULL，把必死崩溃转成
// 调用方的优雅报错；调试器正常应答时走调试器例外端口/ptrace，本处理器
// 不会被触发，行为不变。
static sigjmp_buf g_jit26TrapEnv;
static volatile sig_atomic_t g_jit26TrapArmed = 0;

static void JIT26TrapCatch(int sig) {
    if (!g_jit26TrapArmed) {
        // 不属于本安全网的 SIGTRAP：恢复默认语义原样致死，不吞异常
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    g_jit26TrapArmed = 0;
    siglongjmp(g_jit26TrapEnv, 1);
}

void* JIT26CreateRegionLegacySafe(size_t len) {
    struct sigaction sa, oldsa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = JIT26TrapCatch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGTRAP, &sa, &oldsa);

    void *result = NULL;
    if (sigsetjmp(g_jit26TrapEnv, 1) == 0) {
        g_jit26TrapArmed = 1;
        result = JIT26CreateRegionLegacy(len);
        g_jit26TrapArmed = 0;
    } else {
        result = NULL;
    }
    sigaction(SIGTRAP, &oldsa, NULL);
    return result;
}

// ★ [POCKETJ-JIT] JIT26Detach 的 SIGTRAP 安全网版:与 JIT26CreateRegionLegacySafe
//   同款。调试器已脱离时 brk #0xf00d 无人应答,捕获后直接返回,不使进程致死;
//   调试器在岗时 brk 由调试器例外端口服务,本处理器不触发,行为与裸函数一致。
void JIT26DetachSafe(void) {
    struct sigaction sa, oldsa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = JIT26TrapCatch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGTRAP, &sa, &oldsa);

    if (sigsetjmp(g_jit26TrapEnv, 1) == 0) {
        g_jit26TrapArmed = 1;
        JIT26Detach();
        g_jit26TrapArmed = 0;
    }
    sigaction(SIGTRAP, &oldsa, NULL);
}

// ============================================================================
// ★ [POCKETJ-JIT] PocketJ 内置 JIT 前置门禁
//   (EricoEC/PocketJLauncher · Vendor/StikJIT/INTEGRATION.md
//    「Built-in StikJIT: Gate every entry point」)
//
//   内置 StikJIT 需要同时满足:iOS ≥ 17.4 · 宿主进程 get-task-allow ·
//   可读配对文件。注意 get-task-allow 属于宿主进程,必须在宿主侧检查。
//
//   ⚠ 本仓库暂未接入 Helper 扩展(进程不能自附加调试器 —— 见 PocketJ
//     Natives/stikdebug/StikDebugEngine.m 顶部同款注释),因此这里【只检测、
//     只记日志/供 UI 展示】,不做任何 vAttach 动作。等 Helper 扩展落地后,
//     这三个门禁就是启动 Helper 前的 guard。
// ============================================================================

BOOL AMEJITDeviceSupportsBuiltInStikJIT(void) {
    if (@available(iOS 17.4, *)) {
        return YES;
    }
    return NO;
}

// 宿主进程是否带 get-task-allow。使用 Security 框架 SPI(SecTask*),
// 原型见本文件顶部的 extern 声明;与 INTEGRATION.md 的 ObjC 示例同构,
// 但按文档写法释放正确(不复用本文件既有 getEntitlementValue —— 它有一处
// 释放后使用)。
BOOL AMEJITHasGetTaskAllow(void) {
    void *task = SecTaskCreateFromSelf(NULL);
    if (task == NULL) {
        return NO;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, @"get-task-allow", NULL);
    BOOL result = (value == kCFBooleanTrue);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return result;
}

// 配对文件推荐位置(INTEGRATION.md「Store and import the pairing file」):
//   Documents/StikJIT/pairingFile.plist
// Info.plist 已置 UIFileSharingEnabled=true,用户可经 Finder/AFC 拷入。
NSString *AMEJITPairingFilePath(void) {
    NSURL *documents = [NSFileManager.defaultManager
        URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask
       appropriateForURL:nil create:YES error:nil];
    if (!documents) {
        return nil;
    }
    NSURL *dir = [documents URLByAppendingPathComponent:@"StikJIT" isDirectory:YES];
    return [[dir URLByAppendingPathComponent:@"pairingFile.plist"] path];
}

BOOL AMEJITHasPairingFile(void) {
    NSString *path = AMEJITPairingFilePath();
    return path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path];
}

// 在一次 JIT 获取动作前把门禁状态打到日志(只读,无副作用)。
void AMEJITLogPocketJReadiness(NSString *context) {
    NSLog(@"[JIT] [POCKETJ-JIT] readiness(%@): ios17_4=%@ get-task-allow=%@ pairing=%@ path=%@",
          context ?: @"?",
          AMEJITDeviceSupportsBuiltInStikJIT() ? @"YES" : @"NO",
          AMEJITHasGetTaskAllow() ? @"YES" : @"NO",
          AMEJITHasPairingFile() ? @"YES" : @"NO",
          AMEJITPairingFilePath() ?: @"(nil)");
}

#ifndef P_TRACED
#define P_TRACED 0x00000800 /* process is being traced by a debugger (ptrace) */
#endif

// 向内核查询当前进程是否存在活的 ptrace 关系。P_TRACED 在调试器附加的
// 整个生命周期内置位、脱离瞬间清零，是"调试器还在"的准确信号。
BOOL JIT26DebuggerAttachedViaPtrace(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// 检测通过 Mach 异常端口持有本任务的调试器。lldb/debugserver 以
// ptrace(PT_ATTACH) 拿到任务端口后 PT_DETACH 但保留端口——此后 P_TRACED
// 为 0 而调试器完全存活、持续服务 EXC_BREAKPOINT（JIT26 的 brk #0x69 /
// brk #0xf00d 正是这样被服务的）。任务级 BREAKPOINT/SOFTWARE 非空
// handler 即"JIT26 调试器就位"的可靠信号。
BOOL JIT26DebuggerViaExceptionPorts(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(mach_task_self(),
                                                EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE,
                                                masks, &count, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (handlers[i] != MACH_PORT_NULL) {
            return YES;
        }
    }
    return NO;
}

BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    // 调试器 spawn 的进程 ppid != 1（launchd 为 1）。
    if (getppid() != 1) {
        return YES;
    }
    // StikJIT/SideJIT 对已运行进程按 pid 附加，ppid 恒为 1；且启用工具可能
    // 退出导致进程被重挂到 launchd（ppid 回 1）而 CS_DEBUGGED 残留——单看
    // ppid 会把完全可用的会话误判为"无调试器"。回退到活的 ptrace 标志：
    // 附加期间恒置位，脱离即清零，既不错过附加流，也不漏掉真脱离。
    if (JIT26DebuggerAttachedViaPtrace()) {
        return YES;
    }
    // lldb/debugserver PT_DETACH 后 P_TRACED 回 0，但仍通过任务级异常端口
    // 服务 EXC_BREAKPOINT。把活的任务级 BREAKPOINT/SOFTWARE handler 视为
    // "调试器在岗"——它正是必须服务 brk #0x69 的实体。
    return JIT26DebuggerViaExceptionPorts();
}

// JIT 等待轮询的有界版本：最长 timeout 秒（超时返回 NO，调用方走超时
// 重试弹窗），每 10s 一条心跳日志，挂起间隙（迭代间隔 >2s）不计入超时预算。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label) {
    NSDate *start = [NSDate date];
    NSDate *ame179_lastIter = [NSDate date];
    BOOL ame181_foreground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    int ame181_csFlags = 0;
    csops(getpid(), 0, &ame181_csFlags, sizeof(ame181_csFlags));
    NSLog(@"[JIT] %@ wait begin: startForeground=%d traced=%d exn=%d csdbg=%d",
          label ?: @"JIT", ame181_foreground, JIT26DebuggerAttachedViaPtrace(),
          JIT26DebuggerViaExceptionPorts(), (ame181_csFlags & CS_DEBUGGED) != 0);
    for (;;) {
        if (condition()) {
            NSTimeInterval ame181_waited = -[start timeIntervalSinceNow];
            NSLog(@"[JIT] %@ condition satisfied after %.1fs (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_waited, JIT26DebuggerAttachedViaPtrace(),
                  JIT26DebuggerViaExceptionPorts());
            return YES;
        }
        BOOL ame181_nowForeground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
        if (ame181_nowForeground != ame181_foreground) {
            NSLog(@"[JIT] %@ app %s while waiting (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_nowForeground ? "returned to FOREGROUND" : "went to BACKGROUND",
                  JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            ame181_foreground = ame181_nowForeground;
        }
        // 挂起间隙豁免：stikjit:// 把 App 切后台后 iOS 可能挂起进程，墙钟
        // 空转会烧穿等待预算；迭代间隔 >2s（正常节拍 0.2s）视为挂起，前推
        // start 补回预算。
        NSTimeInterval ame179_gap = -[ame179_lastIter timeIntervalSinceNow];
        if (ame179_gap > 2.0) {
            NSLog(@"[JIT] %@: suspension gap of %.0fs excluded from timeout budget",
                  label ?: @"JIT", ame179_gap);
            start = [start dateByAddingTimeInterval:ame179_gap];
        }
        ame179_lastIter = [NSDate date];
        NSTimeInterval waited = -[start timeIntervalSinceNow];
        if (waited >= timeout) {
            NSLog(@"[JIT] %@ wait TIMED OUT after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            return NO;
        }
        if (fmod(waited, 10.0) < 0.2) {
            NSLog(@"[JIT] %@: still waiting after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
        }
        usleep(1000 * 200);
    }
}

// JIT 等待成功后的自愈式主队列派发：后台被楔死的主线程上 dispatch_async
// 的续接块可能永不执行。三道防线：①常规派发；②前台激活重派；③后台看门狗
//（120s 窗口，仅前台未达时重派并钉死锚点）。delivered 只在主队列读写，
// 多重派发不会导致块双跑。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label) {
    if (!block) return;
    __block volatile BOOL delivered = NO;
    __block id ame185_obs = nil;
    void (^ame185_cleanup)(void) = ^{
        if (ame185_obs) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame185_obs];
            ame185_obs = nil;
        }
    };
    dispatch_block_t attempt = ^{
        if (delivered) return;
        delivered = YES;
        ame185_cleanup();
        block();
    };
    dispatch_async(dispatch_get_main_queue(), attempt);
    ame185_obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *ame185_note) {
        if (delivered) { ame185_cleanup(); return; }
        NSLog(@"[JIT] self-healing dispatch: refire on foreground (label=%@)", label);
        dispatch_async(dispatch_get_main_queue(), attempt);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (int ame185_i = 0; ame185_i < 60; ame185_i++) {
            if (delivered) { ame185_cleanup(); return; }
            usleep(2 * 1000 * 1000);
            if (delivered) { ame185_cleanup(); return; }
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                NSLog(@"[JIT] self-healing dispatch: watchdog redispatch #%d (label=%@)", ame185_i + 1, label);
                dispatch_async(dispatch_get_main_queue(), attempt);
            }
        }
        if (!delivered) {
            NSLog(@"[JIT] self-healing dispatch: NOT delivered after 120s -- main queue wedged (label=%@)", label);
        }
        ame185_cleanup();
    });
}

BOOL DeviceCanCreateRXMap(void) {
    // This is only guaranteed to be accurate when JIT is already enabled. Obviously this is only useful for vphone and similar internal environments where JIT is always enabled.
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) {
        NSLog(@"DeviceCanCreateRXMap: mmap failed: %s", strerror(errno));
        return NO;
    }
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC) | mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

static BOOL DeviceLikelyHasTXMFromChipID(void) {
    NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
    if (MGGetSInt64Answer == NULL) {
        // Failing closed would select the legacy mapping path on the exact
        // systems where Apple made Preboot unreadable. Prefer the TXM-safe
        // path on recent systems when MobileGestalt is unavailable.
        if (@available(iOS 19.0, *)) return YES;
        return NO;
    }

    switch (MGGetSInt64Answer(@"ChipID")) {
        case 0x8020: // A12
        case 0x8027: // A12X/Z
            return NO;
        case 0x8030: // A13
        case 0x8101: // A14
        case 0x8103: // M1
            if (@available(iOS 27.0, *)) return YES;
            return NO;
        default:
            if (@available(iOS 19.0, *)) return YES;
            return NO;
    }
}

BOOL DeviceHasTXM(void) {
    // Try the direct active-Preboot path before falling back to legacy
    // directory enumeration.
    static const char *modernTXMPath =
        "/System/Volumes/Preboot/boot/usr/standalone/firmware/FUD/"
        "Ap,TrustedExecutionMonitor.img4";
    if (access(modernTXMPath, F_OK) == 0) return YES;

    DIR *d = opendir("/private/preboot");
    if (!d) {
        // /private/preboot is no longer readable on iOS 26.6 and iOS 27.
        // Fall back to a conservative hardware/OS heuristic.
        return DeviceLikelyHasTXMFromChipID();
    }

    struct dirent *dir;
    BOOL hasTXM = NO;
    while ((dir = readdir(d)) != NULL) {
        if(strlen(dir->d_name) == 96) {
            char txmPath[PATH_MAX] = {0};
            int length = snprintf(txmPath, sizeof(txmPath),
                "/private/preboot/%s/usr/standalone/firmware/FUD/"
                "Ap,TrustedExecutionMonitor.img4", dir->d_name);
            if (length > 0 && (size_t)length < sizeof(txmPath) &&
                    access(txmPath, F_OK) == 0) {
                hasTXM = YES;
                break;
            }
        }
    }
    closedir(d);
    return hasTXM;
}

JITFlags DeviceGetJITFlags(BOOL refresh) {
    static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
    static JITFlags cachedFlags = 0;
    static BOOL cacheInitialized = NO;

    os_unfair_lock_lock(&cacheLock);
    if (refresh || !cacheInitialized) {
        JITFlags flags = 0;
        const char *s = getenv("JIT_FLAGS");
        if (s) {
            if (s[0] == '0' && tolower(s[1]) == 'b') {
                flags = strtoul(s + 2, NULL, 2);
            } else {
                flags = strtoul(s, NULL, 0);
            }
            NSLog(@"[JIT] Using overridden JIT flags: 0x%X", flags);
        } else {
            if (@available(iOS 26.0, *)) {
                flags |= JIT_FLAG_IS_IOS_26;
                if (!DeviceCanCreateRXMap()) {
                    flags |= JIT_FLAG_FORCE_MIRRORED;
                }
            }
            if (DeviceHasTXM()) {
                flags |= JIT_FLAG_HAS_TXM;
            }
        }

        cachedFlags = flags;
        cacheInitialized = YES;
    }
    JITFlags result = cachedFlags;
    os_unfair_lock_unlock(&cacheLock);
    return result;
}

BOOL DeviceHasJITFlags(JITFlags flags) {
    return (DeviceGetJITFlags(NO) & flags) == flags;
}

BOOL DeviceNeedsDebugJITMapping(void) {
    // This is a capability decision, not a TXM firmware-detection decision.
    // MirrorMappedCodeCache now means that the Universal JIT script has been
    // installed and HotSpot may request its RX mapping from the debugger.
    return DeviceHasJITFlags(JIT_FLAG_IS_IOS_26 | JIT_FLAG_FORCE_MIRRORED);
}

void dismissModalViewController(UIViewController *viewController) {
    [viewController.navigationController dismissViewControllerAnimated:YES completion:nil];
}
