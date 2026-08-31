#pragma once

#include <Foundation/Foundation.h>
#include "jni.h"

typedef jint JLI_Launch_func(int argc, const char ** argv, /* main argc, argc */
        int jargc, const char** jargv,          /* java args */
        int appclassc, const char** appclassv,  /* app classpath */
        const char* fullversion,                /* full version defined */
        const char* dotversion,                 /* dot version defined */
        const char* pname,                      /* program name */
        const char* lname,                      /* launcher name */
        jboolean javaargs,                      /* JAVA_ARGS */
        jboolean cpwildcard,                    /* classpath wildcard*/
        jboolean javaw,                         /* windows-only javaw */
        jint ergo                               /* ergonomics class policy */
);
JLI_Launch_func *pJLI_Launch;

int launchJVM(NSString *accountId, id launchTarget, int width, int height, int minVersion);

// Headless JVM：在当前进程内以最小参数（无 caciocavallo/LWJGL/渲染）启动 JVM，
// 运行指定 main 类。用于 Forge/NeoForge 直装执行 install_profile 的 processors。
// 返回 JLI_Launch 的返回值（0 = 成功）；负数为启动器侧错误：
//   -1 JIT 未启用 / legacy JIT 脚本需要重启
//   -2 JLI_Launch 符号缺失
//   -3 无可用 JRE 运行时
//   -4 dlopen libjli 失败
//   -5 进程内 JVM 已创建过（需重启 app）
int launchHeadlessJVM(NSString *mainClass, NSArray<NSString *> *args, int minJavaVersion);

// 当前进程是否已创建过 JVM（游戏或 headless 任一次）。
// 进程内 JVM 只能创建一次，再次 JLI_Launch 会崩溃；调用方据此提示用户重启 app。
BOOL JVMUsedInProcess(void);
