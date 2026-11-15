// AdlabKit.m —— 通用广告加速器（不针对任何具体 app）
//
// 设计原则
// ========
// 这个 dylib 注入任何 iOS app 都成立，因为它只 hook **系统 API**，
// 不碰任何一行业务代码、不依赖任何具体 SDK 的类名或方法名。
//
// 为什么能加速广告
// ----------------
// 所有激励视频的「要看满 N 秒」都是靠时间测量得出的，测量方式只有三种：
//   ① 定时器递减：NSTimer 每 1 秒 remaining--          → 层次二
//   ② 时间差计算：elapsed = now - startTime            → 层次一
//   ③ 播放器进度：AVPlayer currentTime / KVO            → 层次三
// 把这三个时间源一起加速，三种实现都会被压缩，且不改变「广告确实播过」的事实
// —— 曝光、点击、回调全都是真的，只是时间轴被压缩了。
//
// 层次
// ====
//   一 时间源：CFAbsoluteTimeGetCurrent / NSDate / gettimeofday / mach_absolute_time
//   二 定时器：NSTimer 工厂 / performSelector:afterDelay: / CADisplayLink
//   三 播放器：AVPlayer setRate: / AVPlayerItem 相关
//   四 运行时发现：枚举所有已加载类，名字像广告播放器且实现了常见进度方法的，
//                  按方法名而非类名挂载 —— 这样 SDK 换版本、换名字都不影响。
//   五 摇一摇拦截：UIWindow sendEvent: 吞掉 MotionShake
//   六 反检测：IOSSecuritySuite 等按类名片段清理
//   七 悬浮球：hitTest 穿透，不挡游戏操作
//
// 安全约束（每一条都是踩过的坑）
// ============================
//   · 不用 __interpose（v1 用 interpose 拦 _dyld_get_image_name，绑定期返回 NULL 必崩）
//   · 不用 dlopen/dlsym 拿原实现（会走 interpose 重定向 → 自己拿自己 → 递归爆栈）
//   · 所有 hook 体 @try/@catch 兜底，异常回落原实现
//   · 时间源必须单调，切换倍速时重新定基准，不能回退
//   · 倍速 <= 1.0 时全部直通，零开销零风险
//   · 任何一层失败都不影响其他层（类不存在就是 NULL，直通）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <sys/time.h>
#import <time.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

#pragma mark - 配置

#define kDomainPrefix @"com.adlab.cfg."

static double gSpeed      = 1.0;   // 1.0 = 原速
static BOOL   gBlockShake = YES;

// ---- 方特三件套：通用开关 ----
static BOOL   gBlockJump   = YES;   // 阻止广告跳转到外部 App
static BOOL   gAutoClose   = YES;   // 广告页出现后自动关闭
static BOOL   gAutoReward  = YES;   // 把「已播完」判定强制为真
static double gAutoCloseDelay = 1.0;  // 自动关闭前等待秒数（太快会被判未播完）

// 统计
static int g_hitTime = 0, g_hitTimer = 0, g_hitPlayer = 0, g_hitDiscovered = 0;
static int g_hitShake = 0, g_hitStealth = 0;
static int g_classesScanned = 0, g_classesMatched = 0;
static int g_hitResweep = 0, g_hitDedup = 0;      // 增量发现次数 / 回灌去重命中数
static int g_hitJump = 0, g_hitAutoClose = 0;     // 拦截跳转次数 / 自动关闭次数
static int g_hitAutoReward = 0;                   // 强制「已播完」命中次数

// ---- P2：倍速抖动 ----
// 用户设的是目标倍速 gSpeed；实际生效的是 cur_speed()。
// 固定 3.00x 连续命中容易被识别成「脚本倍速」，所以每 6~14 秒在
// ±6% 区间重抽一次，肉眼无差别，但上报出去是一串不规则的小数。
// P1：已输出过的放大值（防回灌二次放大）。SDK 会把 getter 返回值写回字段，
// 下一帧再读就是放大值，不去重的话会变成平方级。
static NSMutableSet *g_ecpmOut = nil;

static double g_jitterMul = 1.0;      // 当前抖动系数
static double g_jitterAt  = 0.0;      // 上次重抽的真实时刻

static double cur_speed(void)
{
    if (gSpeed <= 1.0001) return 1.0;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    double now = (double)tv.tv_sec + (double)tv.tv_usec / 1e6;

    if (g_jitterAt <= 0.0 || now - g_jitterAt > 6.0 + (arc4random_uniform(800) / 100.0)) {
        // ±6%：0.94 ~ 1.06
        g_jitterMul = 0.94 + (arc4random_uniform(1201) / 10000.0);
        g_jitterAt  = now;
    }
    return gSpeed * g_jitterMul;
}
static int gSceneRetry = 0;      // UI 安装时「场景未就绪」的重试计数

static NSMutableArray<NSString *> *gLogLines = nil;
static NSLock *gLogLock = nil;
static FILE *gLogFile = NULL;

#pragma mark - 日志

static void klog(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    fprintf(stderr, "[adlab] %s\n", buf);
    if (!gLogLock) return;
    [gLogLock lock];
    if (gLogFile) {
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(gLogFile, "%02d:%02d:%02d %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, buf);
        fflush(gLogFile);
    }
    if (gLogLines && gLogLines.count < 400)
        [gLogLines addObject:[NSString stringWithUTF8String:buf]];
    [gLogLock unlock];
}

#define KLOG(...) do { klog(__VA_ARGS__); } while (0)

static void klog_init(void)
{
    static BOOL done = NO;
    if (done) return;
    done = YES;
    gLogLock = [NSLock new];
    gLogLines = [NSMutableArray array];
    @try {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"adlab.log"];
        gLogFile = fopen(p.UTF8String, "a");
    } @catch (__unused NSException *e) { }
}

#pragma mark - 按 app 分域配置

static NSString *cfg_domain(void)
{
    static NSString *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) bid = @"unknown";
        s = [kDomainPrefix stringByAppendingString:bid];
    });
    return s;
}

static void cfg_load(void)
{
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *k = cfg_domain();
        id v = [d objectForKey:[k stringByAppendingString:@".speed"]];
        if ([v isKindOfClass:[NSNumber class]]) {
            double s = [v doubleValue];
            if (s >= 1.0 && s <= 5.0) gSpeed = s;
        }
        id b = [d objectForKey:[k stringByAppendingString:@".shake"]];
        if ([b isKindOfClass:[NSNumber class]]) gBlockShake = [b boolValue];

        id j = [d objectForKey:[k stringByAppendingString:@".nojump"]];
        if ([j isKindOfClass:[NSNumber class]]) gBlockJump = [j boolValue];

        id a = [d objectForKey:[k stringByAppendingString:@".autoclose"]];
        if ([a isKindOfClass:[NSNumber class]]) gAutoClose = [a boolValue];

        id r = [d objectForKey:[k stringByAppendingString:@".autoreward"]];
        if ([r isKindOfClass:[NSNumber class]]) gAutoReward = [r boolValue];
    } @catch (__unused NSException *e) { }
}

static void cfg_save(void)
{
    @try {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *k = cfg_domain();
        [d setObject:@(gSpeed) forKey:[k stringByAppendingString:@".speed"]];
        [d setObject:@(gBlockShake) forKey:[k stringByAppendingString:@".shake"]];
        [d setObject:@(gBlockJump) forKey:[k stringByAppendingString:@".nojump"]];
        [d setObject:@(gAutoClose) forKey:[k stringByAppendingString:@".autoclose"]];
        [d setObject:@(gAutoReward) forKey:[k stringByAppendingString:@".autoreward"]];
        [d synchronize];
    } @catch (__unused NSException *e) { }
}

#pragma mark - swizzle（直接返回原 IMP，不做 out-param 指针双关）

static IMP kswizzle(Class cls, SEL sel, IMP replacement, BOOL isClassMethod)
{
    if (!cls || !sel || !replacement) return NULL;
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    if (orig == replacement) return orig;      // 已装过，幂等
    method_setImplementation(m, replacement);
    return orig;
}

#pragma mark - 层次一：时间源加速
//
// 核心：虚拟时间 = 基准 + (真实时间 - 基准) × 倍速
// 切换倍速时把当前虚拟时间定为新基准，保证单调不回退。

static double g_tReal0 = 0.0;    // 基准时刻（真实）
static double g_tVirt0 = 0.0;    // 基准时刻（虚拟）
static double g_curSpd = 1.0;    // 当前生效倍速

static double now_real_abs(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static double vtime(double real)
{
    if (g_curSpd <= 1.0001) return real;
    if (g_tReal0 == 0.0) return real;
    return g_tVirt0 + (real - g_tReal0) * g_curSpd;
}

// 倍速变更或首次调用时重新定基准，避免时间跳变
static void rebase_if_needed(void)
{
    double s = cur_speed();
    if (s <= 1.0001) s = 1.0;
    if (s == g_curSpd && g_tReal0 != 0.0) return;
    double real = now_real_abs();
    if (g_tReal0 == 0.0) {
        g_tReal0 = real;
        g_tVirt0 = real;
        g_curSpd = s;
        return;
    }
    // 用旧倍速算出此刻的虚拟时间，作为新基准
    double vNow = g_tVirt0 + (real - g_tReal0) * g_curSpd;
    g_tVirt0 = vNow;
    g_tReal0 = real;
    g_curSpd = s;
}

// --- 时间源 hook 体 ---
//
// CFAbsoluteTimeGetCurrent / gettimeofday / mach_absolute_time 是 C 函数，
// 不能用 method_setImplementation 挂。改它们的唯一干净办法是 __interpose，
// 但 v1 已经证明：用 __interpose 拦 dyld 自己依赖的符号，绑定期拿到 NULL 直接崩。
// 所以这里不碰 C 函数，只 hook Objective-C 层的时间源。
//
// 这已经够用：广告 SDK 的倒计时几乎都走 NSTimer 或 NSDate 差值。
// 裸调 gettimeofday 做倒计时的实现极少，且那种实现无法驱动进度条。

typedef double (*Imp_DblId)(id, SEL);
typedef id     (*Imp_IdV)(id, SEL);
typedef id     (*Imp_IdD)(id, SEL, double);

static Imp_IdV   g_o_nsDate  = NULL;
static Imp_IdD   g_o_nsDateNow = NULL;
static Imp_DblId g_o_timeIntOrig = NULL;   // 原始 timeIntervalSinceReferenceDate，只用于读真值

// 只挂「创建 NSDate」的类方法，**不挂** -timeIntervalSinceReferenceDate。
//
// 为什么不能两个都挂：`+date` 返回的 NSDate 内部已存虚拟时间，
// 调用方再读 timeIntervalSinceReferenceDate 时会第二次虚拟化 —— 时间被平方放大，
// 倒计时瞬间归零、日志时间戳乱跳。这是必须避免的组合错误。
//
// 只挂类方法的副作用：对「已经存在的 NSDate 实例」读时间不会被虚拟化。
// 实际影响很小——广告倒计时都是从 `[NSDate date]` 起算的。
static id k_nsDate(id self, SEL _cmd)
{
    id d = g_o_nsDate ? g_o_nsDate(self, _cmd) : nil;
    if (!d || gSpeed <= 1.0001) return d;
    g_hitTime++;
    rebase_if_needed();
    // 用原实现读真实时间，绕开被 hook 的实例方法
    double real = g_o_timeIntOrig
        ? g_o_timeIntOrig(d, sel_registerName("timeIntervalSinceReferenceDate"))
        : [d timeIntervalSinceReferenceDate];
    return [NSDate dateWithTimeIntervalSinceReferenceDate:vtime(real)];
}

// +[NSDate dateWithTimeIntervalSinceNow:]
static id k_nsDateNow(id self, SEL _cmd, double delta)
{
    if (!g_o_nsDateNow) return nil;
    if (gSpeed <= 1.0001) return g_o_nsDateNow(self, _cmd, delta);
    g_hitTime++;
    rebase_if_needed();
    // delta 是「从现在起多少秒」，同样要压缩
    return g_o_nsDateNow(self, _cmd, delta / cur_speed());
}

static void install_time_hooks(void)
{
    @try {
        Class nd = objc_getClass("NSDate");

        // 先拿到原始 timeIntervalSinceReferenceDate，供 k_nsDate 内部读真值
        Method m = class_getInstanceMethod(nd, sel_registerName("timeIntervalSinceReferenceDate"));
        if (m) g_o_timeIntOrig = (Imp_DblId)method_getImplementation(m);

        g_o_nsDate = (Imp_IdV)kswizzle(nd, sel_registerName("date"), (IMP)k_nsDate, YES);
        g_o_nsDateNow = (Imp_IdD)kswizzle(nd, sel_registerName("dateWithTimeIntervalSinceNow:"),
                                          (IMP)k_nsDateNow, YES);

        KLOG("时间层: NSDate.date=%d dateWithIntervalSinceNow=%d",
             g_o_nsDate != NULL, g_o_nsDateNow != NULL);
    } @catch (NSException *e) {
        KLOG("时间层异常 %s", e.reason.UTF8String);
    }
}



#pragma mark - 层次二：定时器压缩

typedef id   (*Imp_Timer)(id, SEL, NSTimeInterval, id, SEL, id, BOOL);
typedef id   (*Imp_Link)(id, SEL, id, SEL);
typedef void (*Imp_Perform)(id, SEL, SEL, id, NSTimeInterval);

static Imp_Timer   g_o_schedTimer = NULL;
static Imp_Timer   g_o_timer      = NULL;
static Imp_Link    g_o_displayLink = NULL;
static Imp_Perform g_o_perform     = NULL;

static NSTimeInterval k_scaled(NSTimeInterval iv)
{
    // 0 或负：0 间隔本来是「下一轮 runloop 立刻执行」，除下去会变忙等；
    // 负数在 NSTimer 里是非法值，原样传。
    if (iv <= 0.0) return iv;
    if (gSpeed <= 1.0001) return iv;
    NSTimeInterval r = iv / cur_speed();
    if (r < 0.001) r = 0.001;
    g_hitTimer++;
    return r;
}

static id k_schedTimer(id self, SEL _cmd, NSTimeInterval iv,
                       id target, SEL sel, id info, BOOL repeats)
{
    if (!g_o_schedTimer) return nil;
    return g_o_schedTimer(self, _cmd, k_scaled(iv), target, sel, info, repeats);
}

static id k_timer(id self, SEL _cmd, NSTimeInterval iv,
                  id target, SEL sel, id info, BOOL repeats)
{
    if (!g_o_timer) return nil;
    return g_o_timer(self, _cmd, k_scaled(iv), target, sel, info, repeats);
}

// CADisplayLink 的 frameInterval 单位是「帧」且只能 >=1，调小被系统钳回，
// 所以这一层只做统计，真正的快进靠时间源与播放器。
static id k_displayLink(id self, SEL _cmd, id target, SEL sel)
{
    if (!g_o_displayLink) return nil;
    return g_o_displayLink(self, _cmd, target, sel);
}

static void k_perform(id self, SEL _cmd, SEL sel, id arg, NSTimeInterval delay)
{
    if (!g_o_perform) return;
    g_o_perform(self, _cmd, sel, arg, k_scaled(delay));
}

static void install_timer_hooks(void)
{
    @try {
        Class t = objc_getClass("NSTimer");
        g_o_schedTimer = (Imp_Timer)kswizzle(
            t, sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
            (IMP)k_schedTimer, YES);
        g_o_timer = (Imp_Timer)kswizzle(
            t, sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
            (IMP)k_timer, YES);

        Class l = objc_getClass("CADisplayLink");
        g_o_displayLink = (Imp_Link)kswizzle(
            l, sel_registerName("displayLinkWithTarget:selector:"), (IMP)k_displayLink, YES);

        Class nso = objc_getClass("NSObject");
        g_o_perform = (Imp_Perform)kswizzle(
            nso, sel_registerName("performSelector:withObject:afterDelay:"),
            (IMP)k_perform, NO);

        KLOG("定时器层: NSTimer=%d/%d DisplayLink=%d perform=%d",
             g_o_schedTimer != NULL, g_o_timer != NULL,
             g_o_displayLink != NULL, g_o_perform != NULL);
    } @catch (NSException *e) {
        KLOG("定时器层异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次三：播放器速率

typedef void (*Imp_SetRate)(id, SEL, float);
static Imp_SetRate g_o_setRate = NULL;

static void k_setRate(id self, SEL _cmd, float rate)
{
    if (!g_o_setRate) return;
    float r = rate;
    // rate == 0 是暂停，乘上去会变成「极慢速播放」，画面冻住音频继续，反而更糟。
    if (rate != 0.0f && gSpeed > 1.0001) {
        r = (float)(rate * cur_speed());
        if (r > 2.0f) r = 2.0f;   // 多数机型 >2x 会静音或变调
        g_hitPlayer++;
    }
    g_o_setRate(self, _cmd, r);
}

static void install_player_hooks(void)
{
    @try {
        Class p = objc_getClass("AVPlayer");
        g_o_setRate = (Imp_SetRate)kswizzle(p, sel_registerName("setRate:"), (IMP)k_setRate, NO);
        KLOG("播放器层: AVPlayer.setRate=%d", g_o_setRate != NULL);
    } @catch (NSException *e) {
        KLOG("播放器层异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次四：运行时发现的广告播放器
//
// 不写死任何 SDK 类名。做法：
//   枚举所有已加载类 → 类名过一遍宽松关键字 → 再从该类的**方法名**里找进度类方法
//   → 只有「类名像广告 + 方法名像进度」同时命中才挂。
// 这样 SDK 换版本、改类名前缀都不影响；也不会误挂普通业务类。

// 类名关键字（宽松，只用于缩小扫描范围）
static const char *kNameHints[] = {
    "Ad", "AD", "ad", "Reward", "reward", "Video", "video",
    "Player", "player", "Inspire", "Interstitial", "Splash", NULL
};

// 方法名里出现这些，说明是「进度/时长」类接口
static const char *kMethodHints[] = {
    "currentPlayTime", "currentTime", "playProgress", "progress",
    "videoDuration", "duration", "totalTime", "playFinished", "didFinish",
    "rewardVerify", "onReward", "countdown", "remain", NULL
};

static BOOL name_looks_ad(const char *nm)
{
    if (!nm) return NO;
    for (int i = 0; kNameHints[i]; i++) {
        if (strstr(nm, kNameHints[i])) return YES;
    }
    return NO;
}

static BOOL sel_looks_progress(const char *nm)
{
    if (!nm) return NO;
    for (int i = 0; kMethodHints[i]; i++) {
        if (strstr(nm, kMethodHints[i])) return YES;
    }
    return NO;
}

// 通用「进度放大」。只挂 **零参数、返回 double** 的方法——
// 这是唯一能保证调用约定正确、绝不会因参数错位而崩的形状。
// 参数多于 0 个时，中间参数可能走浮点寄存器，用错误签名的 block 去接
// 会把 id 当 double 读，直接 SIGSEGV —— 第三方插件（AdAccel）点广告闪退的根因
// 就是给未知签名的方法强换实现。这里用「返回类型 + 参数个数」双重过滤堵死。
//
// ⚠ 方向很重要，不能无脑乘：
//   进度 = currentTime / duration
//   若两个都乘 倍速，比值不变，进度条一动不动。
//   正确做法：分子（当前进度）乘倍速，分母（总时长）除倍速，
//   于是 progress 被放大 倍速² 倍，播到终点的时间变成 1/倍速。
// ⚠ 方向修正（v3.1）
// 上面那段注释里的推导是错的，实测后改正：
//   progress = current / total
//   若 current *= k 且 total /= k，则 progress *= k²
//   k² 会让进度涨得快 —— 但「播完」的判定通常是 current >= total，
//   这个条件**不成立**（current 涨 k 倍，total 也变小 k 倍，但两者同步到达的值不是 1）。
// 所以正确做法是「只压时间，不压比例」：
//   分子（当前时间）* k  → total/current 比值不变，但 current 到达 total 的**墙钟时间**变成 1/k
//   分母（总时长）保持不动
// 这样：进度条按真实速度走完（视觉上快了 k 倍），且 current>=total 的判定仍成立。
// 之前的实现把分母也除了 k，导致 progress 涨 k² 倍，有些 SDK 的
// currentPlayTime 直接冲过 totalTime，反而让播放器 seek 越界 —— 这就是
// 「放大 0 个 getter」之外我担心的第二个问题，一并修掉。
static BOOL name_is_numerator(const char *sn)
{
    const char *num[] = {
        "currentPlayTime", "currentTime", "curTime", "playProgress", "progress",
        "elapsed", "playedTime", "watchedTime", "position", NULL
    };
    for (int i = 0; num[i]; i++) if (strstr(sn, num[i])) return YES;
    return NO;
}

static BOOL name_is_denominator(const char *sn)
{
    const char *den[] = {
        "duration", "totalTime", "videoDuration", "totalDuration",
        "length", "fullTime", NULL
    };
    for (int i = 0; den[i]; i++) if (strstr(sn, den[i])) return YES;
    return NO;
}

static BOOL hook_DoubleZeroArg(Class cls, Method m)
{
    char rt[8] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    if (rt[0] != 'd') return NO;                       // 必须返回 double

    SEL sel = method_getName(m);
    const char *sn = sel_getName(sel);
    if (strchr(sn, ':')) return NO;                    // 必须零参数

    BOOL isNum = name_is_numerator(sn);
    BOOL isDen = name_is_denominator(sn);
    if (!isNum && !isDen) return NO;                   // 名字不像进度/时长，不碰

    IMP orig = method_getImplementation(m);
    if (!orig) return NO;

    IMP repl;
    if (isNum && !isDen) {
        // 分子：当前播放时间 * 倍速。分母不动 → 比真实播完所需的墙钟时间 ÷ 倍速
        repl = imp_implementationWithBlock(^double(id self) {
            double v = ((double (*)(id, SEL))orig)(self, sel);
            if (gSpeed <= 1.0001 || v <= 0.0) return v;

            // P1 回灌去重：有些 SDK 会把我返回的放大值写回自己的字段，
            // 下一帧 getter 读到的就是放大值 → 再乘一次 = 平方级放大。
            // 这里记一份「我输出过的值」，命中就原样返回，不再二次放大。
            double key = floor(v * 1000.0) / 1000.0;
            @synchronized (g_ecpmOut) {
                if ([g_ecpmOut containsObject:@(key)]) {
                    g_hitDedup++;
                    return v;
                }
                if (g_ecpmOut.count > 2000) [g_ecpmOut removeAllObjects];
                [g_ecpmOut addObject:@(key)];
            }

            g_hitDiscovered++;
            return v * cur_speed();
        });
    } else if (isDen && !isNum) {
        // 分母：**保持原值**。不把总时长缩小，否则 current/total 会被放平方倍、
        // 触发播放器 seek 越界或「已播完」误判。
        // 这里仍然挂一遍：一是计数用，二是把值钳到合法范围防 NaN/负数。
        repl = imp_implementationWithBlock(^double(id self) {
            double v = ((double (*)(id, SEL))orig)(self, sel);
            if (v != v || v <= 0.0) return v;           // NaN / 非正 → 原样
            g_hitDiscovered++;
            return v;
        });
    } else {
        return NO;                                     // 同时像分子和分母，太模糊，放弃
    }
    if (!repl) return NO;

    method_setImplementation(m, repl);
    return YES;
}

// ---- 层次四之三：强制「已播完」判定为真 ----
//
// 安卓那套的「自动领取奖励」不能照抄——Android 用 Xposed 的 onRewardVerify
// 直接改布尔值，iOS 的奖励回调是 SDK 内部方法，名字随版本变、还可能是 block。
//
// 更稳的切法是**不改回调，改回调依赖的判定输入**：
// 所有「看满 N 秒才发奖」最终都要问一次「播完了没」，这个回答只能来自
// BOOL / 整型返回值、名字含 finish / complete / ended / played 的方法。
// 统一改成 YES，SDK 自己会去调奖励回调——那是它原本的路径，不是我们伪造的，
// 所以内部状态、埋点、时序全都自洽。
//
// 只动「零参数」的。参数多的签名不可控，一律不碰——AdAccel 点广告闪退
// 就是栽在这：给未知签名的方法硬换实现，中间参数走浮点寄存器，
// 把 id 当 double 读，直接 SIGSEGV。

static BOOL name_looks_finished(const char *sn)
{
    if (!sn) return NO;
    static const char *hints[] = {
        "isFinished", "isComplete", "isCompleted", "isEnded", "isPlayed",
        "isPlayFinished", "isPlayComplete", "isPlayEnd", "playFinished",
        "didFinishPlaying", "hasFinished", "hasCompleted", "isVideoEnd",
        "isVideoFinished", "isPlayOver", NULL
    };
    for (int i = 0; hints[i]; i++) {
        if (strstr(sn, hints[i])) return YES;
    }
    return NO;
}

static BOOL hook_BoolZeroArg(Class cls, Method m)
{
    char rt[8] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    char r = rt[0];
    BOOL isBool = (r == 'B' || r == 'c');
    BOOL isInt = (r == 'i' || r == 's' || r == 'q');
    if (!isBool && !isInt) return NO;

    SEL sel = method_getName(m);
    const char *sn = sel_getName(sel);
    if (strchr(sn, ':')) return NO;              // 零参数
    if (!name_looks_finished(sn)) return NO;

    IMP orig = method_getImplementation(m);
    if (!orig) return NO;

    IMP repl;
    if (isBool) {
        repl = imp_implementationWithBlock(^BOOL(id self) {
            if (!gAutoReward) return ((BOOL (*)(id, SEL))orig)(self, sel);
            g_hitAutoReward++;
            return YES;
        });
    } else {
        repl = imp_implementationWithBlock(^int(id self) {
            if (!gAutoReward) return ((int (*)(id, SEL))orig)(self, sel);
            g_hitAutoReward++;
            return 1;
        });
    }
    if (!repl) return NO;
    method_setImplementation(m, repl);
    return YES;
}

// ---- P0：增量类发现 ----
//
// 为什么必须增量：广告 SDK（穿山甲 / 优量汇 / 快手 / TopOn / 百度）全是懒加载的，
// 首次拉广告时才 dlopen，那些播放器类在 constructor 跑完时**根本还不存在**。
// 只扫一次 objc_getClassList 等于永远看不到它们。
//
// 两个触发源都要：
//   ① _dyld_register_func_for_add_image —— 镜像刚加载立刻补扫，抓得住
//   ② 前 30 秒每秒轮询 —— 有些类在镜像内但被 SDK 延后 +load / 反射才注册
// 用 seen 表保证每个类只处理一次，避免每秒重复 class_copyMethodList。

static void adlab_sweep_classes(BOOL initial)
{
    @try {
        static int   s_cap = 0;
        static const char **s_seen = NULL;
        static int   s_cnt = 0;

        int total = objc_getClassList(NULL, 0);
        if (total <= 0) return;

        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!classes) return;
        int real = objc_getClassList(classes, total);
        if (initial) g_classesScanned = real;

        int newly = 0;
        for (int i = 0; i < real; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!name_looks_ad(cn)) continue;

            // 去重：线性查 seen 表（量级 500 左右，无压力）
            BOOL dup = NO;
            for (int k = 0; k < s_cnt; k++) {
                if (strcmp(s_seen[k], cn) == 0) { dup = YES; break; }
            }
            if (dup) continue;

            if (s_cnt >= s_cap) {
                int nc = s_cap ? s_cap * 2 : 256;
                const char **np = (const char **)realloc(s_seen, sizeof(char *) * (size_t)nc);
                if (!np) { free(classes); return; }
                s_seen = np; s_cap = nc;
            }
            s_seen[s_cnt++] = strdup(cn);
            newly++;

            unsigned int mc = 0;
            Method *ms = class_copyMethodList(c, &mc);
            if (!ms) continue;

            BOOL classMatched = NO;
            int hooked = 0;
            int hookedFin = 0;
            for (unsigned int j = 0; j < mc; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                if (sel_looks_progress(sn)) {
                    classMatched = YES;
                    if (hook_DoubleZeroArg(c, ms[j])) hooked++;
                }
                // 顺带挂「播完了没」的判定：同一个广告类里一定同时存在
                // 进度 getter 和完成判定，一次遍历全拿到，不用再扫一遍
                if (hook_BoolZeroArg(c, ms[j])) hookedFin++;
            }
            free(ms);

            if (!classMatched && hookedFin == 0) continue;
            g_classesMatched++;
            if (hooked > 0 || hookedFin > 0) {
                KLOG("%s发现 %s 上 %d 个进度 getter、%d 个完成判定",
                     initial ? "首次" : "增量", cn, hooked, hookedFin);
            } else {
                KLOG("广告类 %s 有进度方法但形状不符（带参数），跳过", cn);
            }
        }
        free(classes);

        if (!initial && newly > 0) g_hitResweep++;

    } @catch (NSException *e) {
        KLOG("类扫描异常 %s", e.reason.UTF8String);
    }
}

// 镜像加载回调：新 SDK 一被 dlopen 就补扫
static void adlab_image_added(const struct mach_header *mh, intptr_t slide)
{
    (void)mh; (void)slide;
    // 注意：这个回调可能在非主线程、且在 dyld 持锁期间触发，
    // 所以只做「登记标记」，真正的扫描丢到主队列，避免死锁。
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        @try { adlab_sweep_classes(NO); } @catch (__unused NSException *e) { }
    });
}

// 轮询兜底：前 30 秒每秒一次
static void adlab_start_resweep(void)
{
    static int tick = 0;
    __block void (^blk)(void);
    blk = ^{
        @try { adlab_sweep_classes(NO); } @catch (__unused NSException *e) { }
        tick++;
        if (tick < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), blk);
        } else {
            KLOG("增量扫描收尾：共补扫 %d 轮，累计匹配 %d 个广告类，放大 %d 个 getter",
                 tick, g_classesMatched, g_hitDiscovered);
        }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), blk);
}

// 首次全量扫描 + 注册增量源
static void install_discovered_hooks(void)
{
    adlab_sweep_classes(YES);
    _dyld_register_func_for_add_image(adlab_image_added);
    adlab_start_resweep();

    KLOG("运行时发现: 首扫 %d 类，匹配 %d 个广告类，放大 %d 个 getter（增量源已注册）",
         g_classesScanned, g_classesMatched, g_hitDiscovered);
}

#pragma mark - 层次五：摇一摇拦截

typedef void (*Imp_SendEvent)(id, SEL, UIEvent *);
static Imp_SendEvent g_o_sendEvent = NULL;

static void k_sendEvent(id self, SEL _cmd, UIEvent *e)
{
    if (!g_o_sendEvent) return;
    if (gBlockShake && e) {
        @try {
            if (e.type == UIEventTypeTouches && e.subtype == UIEventSubtypeMotionShake) {
                g_hitShake++;
                return;      // 吞掉，不转发给广告 SDK
            }
        } @catch (__unused NSException *x) { }
    }
    g_o_sendEvent(self, _cmd, e);
}

static void install_shake_block(void)
{
    @try {
        Class w = objc_getClass("UIWindow");
        g_o_sendEvent = (Imp_SendEvent)kswizzle(w, sel_registerName("sendEvent:"),
                                                (IMP)k_sendEvent, NO);
        KLOG("摇一摇拦截: %d", g_o_sendEvent != NULL);
    } @catch (NSException *e) {
        KLOG("摇一摇异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次五之二：阻止广告跳转外部 App

// 广告的「点击」最终都落到这几条路上：
//   -[UIApplication openURL:]                                iOS 2~10 老路
//   -[UIApplication openURL:options:completionHandler:]      iOS 10+
//   -[UIApplication open:options:completionHandler:]         iOS 10+ 新名
//   -[UIViewController presentViewController:animated:completion:]  落地页弹窗
// 前三条拦掉能挡九成；落地页那条必须判「目标是不是系统浏览器/商店」才拦，
// 否则连游戏自己的弹窗一起挡了。

typedef BOOL (*Imp_OpenURL1)(id, SEL, NSURL *);
typedef void (*Imp_OpenURL3)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL));
typedef void (*Imp_Open3)(id, SEL, NSURL *, NSDictionary *, void (^)(id));
typedef void (*Imp_Present)(id, SEL, UIViewController *, BOOL, void (^)(void));

static Imp_OpenURL1 g_o_openURL1 = NULL;
static Imp_OpenURL3 g_o_openURL3 = NULL;
static Imp_Open3    g_o_open3    = NULL;
static Imp_Present  g_o_present  = NULL;

static BOOL url_is_external(NSURL *u)
{
    if (!u) return NO;
    NSString *s = u.absoluteString;
    if (!s) return NO;

    NSString *sch = u.scheme.lowercaseString;
    if (!sch) return NO;

    // 自家的 scheme 一律放行（游戏内跳转、登录回调、支付回调）
    static const char *selfSchemes[] = { "maobei", "kittypay", "wx", "weixin",
                                         "alipay", "alipays", "wechat", NULL };
    for (int i = 0; selfSchemes[i]; i++) {
        if ([sch isEqualToString:[NSString stringWithUTF8String:selfSchemes[i]]]) return NO;
    }

    // 明确的外部：商店、网页、地图、电话、短信、邮件
    static const char *extSchemes[] = { "itms-apps", "itms-appss", "itms", "https", "http",
                                        "maps", "tel", "sms", "mailto", NULL };
    for (int i = 0; extSchemes[i]; i++) {
        if ([sch isEqualToString:[NSString stringWithUTF8String:extSchemes[i]]]) return YES;
    }
    return NO;
}

static BOOL k_openURL1(id self, SEL _cmd, NSURL *u)
{
    if (gBlockJump && url_is_external(u)) {
        g_hitJump++;
        if (g_hitJump <= 8) KLOG("拦截跳转: %s", u.absoluteString.UTF8String);
        return YES;      // 假装成功，调用方不会重试
    }
    return g_o_openURL1 ? g_o_openURL1(self, _cmd, u) : NO;
}

static void k_openURL3(id self, SEL _cmd, NSURL *u, NSDictionary *o, void (^cb)(BOOL))
{
    if (gBlockJump && url_is_external(u)) {
        g_hitJump++;
        if (g_hitJump <= 8) KLOG("拦截跳转2: %s", u.absoluteString.UTF8String);
        if (cb) cb(YES);
        return;
    }
    if (g_o_openURL3) g_o_openURL3(self, _cmd, u, o, cb);
}

static void k_open3(id self, SEL _cmd, NSURL *u, NSDictionary *o, void (^cb)(id))
{
    if (gBlockJump && url_is_external(u)) {
        g_hitJump++;
        if (g_hitJump <= 8) KLOG("拦截跳转3: %s", u.absoluteString.UTF8String);
        if (cb) cb(nil);
        return;
    }
    if (g_o_open3) g_o_open3(self, _cmd, u, o, cb);
}

static BOOL vc_is_external_landing(UIViewController *vc)
{
    if (!vc || !gBlockJump) return NO;
    NSString *cn = NSStringFromClass([vc class]);
    if (!cn) return NO;
    static const char *hints[] = {
        "SFSafariViewController", "SFAuthenticationViewController",
        "SKStoreProductViewController", "ASWebAuthenticationSession",
        "UIWebView", "WKWebView", NULL
    };
    for (int i = 0; hints[i]; i++) {
        if (strstr(cn.UTF8String, hints[i])) return YES;
    }
    return NO;
}

static void k_present(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^cb)(void))
{
    if (vc_is_external_landing(vc)) {
        g_hitJump++;
        if (g_hitJump <= 8) KLOG("拦截落地页: %@", NSStringFromClass([vc class]));
        if (cb) cb();
        return;
    }
    if (g_o_present) g_o_present(self, _cmd, vc, anim, cb);
}

static void install_jump_block(void)
{
    @try {
        Class app = objc_getClass("UIApplication");
        g_o_openURL1 = (Imp_OpenURL1)kswizzle(app, sel_registerName("openURL:"),
                                              (IMP)k_openURL1, NO);
        g_o_openURL3 = (Imp_OpenURL3)kswizzle(app, sel_registerName("openURL:options:completionHandler:"),
                                              (IMP)k_openURL3, NO);
        g_o_open3    = (Imp_Open3)kswizzle(app, sel_registerName("open:options:completionHandler:"),
                                           (IMP)k_open3, NO);
        Class vc = objc_getClass("UIViewController");
        g_o_present  = (Imp_Present)kswizzle(vc, sel_registerName("presentViewController:animated:completion:"),
                                             (IMP)k_present, NO);
        KLOG("阻止跳转: openURL=%d openURL3=%d open3=%d present=%d",
             g_o_openURL1 != NULL, g_o_openURL3 != NULL, g_o_open3 != NULL, g_o_present != NULL);
    } @catch (NSException *e) {
        KLOG("阻止跳转异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次五之三：广告页自动关闭

// 安卓那边叫「6 秒自动跳广」——广告播够 N 秒就直接关掉页面。
// iOS 上没有「跳广告」这种系统行为，能做的等价物是：
//   广告视图控制器 viewDidAppear 之后，等 N 秒（默认 1 秒 × 倍速换算），
//   直接 dismiss 掉它。
//
// 关键点：不能关太快。奖励回调由 SDK 在「播完」时触发，关早了 SDK 认为
// 用户中途退出，不发奖。所以延时 = gAutoCloseDelay / cur_speed()，
// 配 3x 倍速时 1 秒墙钟 = 3 秒内容时长，足以让 6 秒的激励视频播完。
//
// 另一个关键点：只关「广告类」，不能关游戏自己的界面。判据用类名关键字
// + 是否 presented（modal），两个都满足才动手。

typedef void (*Imp_ViewDidAppear)(id, SEL, BOOL);

static Imp_ViewDidAppear g_o_viewDidAppear = NULL;
static NSMutableSet *g_closingSet = nil;    // 正在关闭中的 VC，防重入

static BOOL vc_looks_like_ad(UIViewController *vc)
{
    if (!vc) return NO;
    NSString *cn = NSStringFromClass([vc class]);
    if (!cn || cn.length == 0) return NO;
    const char *c = cn.UTF8String;

    static const char *hints[] = {
        // 穿山甲 / GroMore
        "CSJ", "BUNative", "BURewarded", "BUInterstitial", "BUSplash",
        "TTAd", "Pangle", "GMAd",
        // 优量汇
        "GDT", "GDTReward", "GDTInterstitial", "GDTSplash",
        // 快手
        "KSAd", "KSReward", "KSInterstitial", "KSSplash",
        // TopOn / AnyThink
        "ATReward", "ATInterstitial", "ATSplash", "ATAd",
        // 百度
        "BaiduMobAd", "BUNative",
        // 通用
        "RewardVideoVC", "InterstitialVC", "SplashVC",
        "AdViewController", "AdViewCtrl", NULL
    };
    for (int i = 0; hints[i]; i++) {
        if (strstr(c, hints[i])) return YES;
    }
    return NO;
}

static void k_viewDidAppear(id self, SEL _cmd, BOOL anim)
{
    if (g_o_viewDidAppear) g_o_viewDidAppear(self, _cmd, anim);

    if (!gAutoClose) return;
    if (![self isKindOfClass:[UIViewController class]]) return;

    UIViewController *vc = (UIViewController *)self;
    if (!vc_looks_like_ad(vc)) return;

    // 只处理被 present 出来的（有 presentingViewController），
    // 游戏自己的根控制器不动
    if (!vc.presentingViewController) return;

    if (!g_closingSet) g_closingSet = [NSMutableSet new];
    NSString *key = [NSString stringWithFormat:@"%p", vc];
    @synchronized (g_closingSet) {
        if ([g_closingSet containsObject:key]) return;
        [g_closingSet addObject:key];
        if (g_closingSet.count > 64) [g_closingSet removeAllObjects];
    }

    double spd = cur_speed();
    if (spd < 1.0) spd = 1.0;
    double wait = gAutoCloseDelay / spd;
    if (wait < 0.3) wait = 0.3;

    KLOG("广告页出现: %@，%.2fs 后自动关闭（倍速 %.2fx）",
         NSStringFromClass([vc class]), wait, spd);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if (vc.presentingViewController) {
                g_hitAutoClose++;
                [vc dismissViewControllerAnimated:NO completion:nil];
            }
        } @catch (NSException *e) {
            KLOG("自动关闭异常 %s", e.reason.UTF8String);
        } @synchronized (g_closingSet) {
            [g_closingSet removeObject:key];
        }
    });
}

static void install_auto_close(void)
{
    @try {
        Class vc = objc_getClass("UIViewController");
        g_o_viewDidAppear = (Imp_ViewDidAppear)kswizzle(vc, sel_registerName("viewDidAppear:"),
                                                        (IMP)k_viewDidAppear, NO);
        KLOG("自动关闭广告: %d", g_o_viewDidAppear != NULL);
    } @catch (NSException *e) {
        KLOG("自动关闭异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次六：反检测

static BOOL class_name_risky(const char *nm)
{
    if (!nm) return NO;
    const char *hints[] = {
        "IOSSecuritySuite", "SecurityChecker", "Jailbreak", "Tamper",
        "FridaDetector", "ReverseEngineer", "AntiDebug", "AntiHook",
        "IntegrityCheck", "SecurityCheck", NULL
    };
    for (int i = 0; hints[i]; i++) {
        if (strstr(nm, hints[i])) return YES;
    }
    return NO;
}

// 把方法改成返回 0 / nil，参数个数从 selector 冒号数推
static BOOL neutralize(Class cls, SEL sel, BOOL isClassMethod)
{
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    char rt[8] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    char r = rt[0];
    BOOL intRet = (r == 'c' || r == 'B' || r == 'i' || r == 's' || r == 'q' ||
                   r == 'C' || r == 'I' || r == 'Q' || r == 'l' || r == 'L');
    BOOL objRet = (r == '@' || r == '#');
    if (!intRet && !objRet) return NO;

    NSUInteger na = [[NSStringFromSelector(sel) componentsSeparatedByString:@":"] count];
    na = (na > 0) ? (na - 1) : 0;
    if (na > 4) return NO;

    IMP imp = NULL;
    if (intRet) {
        switch (na) {
            case 0: imp = imp_implementationWithBlock(^long(id s){ return 0; }); break;
            case 1: imp = imp_implementationWithBlock(^long(id s, id a){ return 0; }); break;
            case 2: imp = imp_implementationWithBlock(^long(id s, id a, id b){ return 0; }); break;
            case 3: imp = imp_implementationWithBlock(^long(id s, id a, id b, id c){ return 0; }); break;
            case 4: imp = imp_implementationWithBlock(^long(id s, id a, id b, id c, id d){ return 0; }); break;
            default: break;
        }
    } else {
        switch (na) {
            case 0: imp = imp_implementationWithBlock(^id(id s){ return nil; }); break;
            case 1: imp = imp_implementationWithBlock(^id(id s, id a){ return nil; }); break;
            case 2: imp = imp_implementationWithBlock(^id(id s, id a, id b){ return nil; }); break;
            case 3: imp = imp_implementationWithBlock(^id(id s, id a, id b, id c){ return nil; }); break;
            case 4: imp = imp_implementationWithBlock(^id(id s, id a, id b, id c, id d){ return nil; }); break;
            default: break;
        }
    }
    if (!imp) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static int clean_class(Class cls)
{
    if (!cls) return 0;
    int n = 0;
    Class meta = object_getClass(cls);

    for (int pass = 0; pass < 2; pass++) {
        Class target = (pass == 0) ? meta : cls;
        BOOL isCls = (pass == 0);
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(target, &mc);
        if (!ms) continue;
        for (unsigned int i = 0; i < mc; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            // 只清 amI* 前缀（IOSSecuritySuite 的命名约定）+ 名字里带 Jail/Tamper/Debug
            BOOL hit = (strncmp(sn, "amI", 3) == 0) ||
                       strstr(sn, "ailbreak") || strstr(sn, "amper") ||
                       strstr(sn, "ebugged") || strstr(sn, "ooked");
            if (!hit) continue;
            if (neutralize(target, method_getName(ms[i]), isCls)) n++;
        }
        free(ms);
    }
    return n;
}

static void install_stealth(void)
{
    @try {
        int total = objc_getClassList(NULL, 0);
        if (total <= 0) return;
        Class *cs = (Class *)malloc(sizeof(Class) * (size_t)total);
        if (!cs) return;
        int real = objc_getClassList(cs, total);
        int matched = 0;
        for (int i = 0; i < real; i++) {
            if (!class_name_risky(class_getName(cs[i]))) continue;
            matched++;
            int n = clean_class(cs[i]);
            if (n > 0) {
                g_hitStealth += n;
                KLOG("清理 %s 上 %d 个检测方法", class_getName(cs[i]), n);
            }
        }
        free(cs);
        KLOG("反检测: 扫描 %d 类，命中 %d 类，清理 %d 方法", real, matched, g_hitStealth);
        if (matched == 0) KLOG("未发现检测类（本 app 可能没集成）");
    } @catch (NSException *e) {
        KLOG("反检测异常 %s", e.reason.UTF8String);
    }
}

#pragma mark - 层次七：悬浮球 UI

@interface AdlabBall : UIButton
@end

@interface AdlabPanel : UIView
@property (nonatomic, strong) UILabel *titleLab;
@property (nonatomic, strong) UILabel *statLab;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedLab;
@property (nonatomic, strong) UISwitch *shakeSwitch;
@property (nonatomic, strong) UISwitch *jumpSwitch;
@property (nonatomic, strong) UISwitch *closeSwitch;
@property (nonatomic, strong) UISwitch *rewardSwitch;
@property (nonatomic, strong) UITextView *logView;
@end

@interface AdlabWindow : UIWindow
@end

@interface AdlabOverlay : NSObject
@property (nonatomic, strong) UIWindow *win;   // 仅记录宿主 window，不持有独立窗口
@property (nonatomic, strong) AdlabBall *ball;
@property (nonatomic, strong) AdlabPanel *panel;
+ (instancetype)shared;
- (void)install;
- (void)refresh;
@end

#pragma mark - 悬浮窗（hitTest 穿透，不挡游戏）

@implementation AdlabWindow
// 自己或自己的 rootViewController.view 命中时返回 nil，
// 事件落到下层游戏窗口 —— 这是悬浮球能「点得到自己、又挡不住游戏」的关键。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

#pragma mark - 悬浮球

@implementation AdlabBall
- (instancetype)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.layer.cornerRadius = f.size.width / 2.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:0.9].CGColor;
    self.clipsToBounds = YES;
    [self setTitle:@"倍" forState:UIControlStateNormal];
    [self setTitleColor:[UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0]
               forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    return self;
}
@end

#pragma mark - 面板

@implementation AdlabPanel
- (instancetype)initWithFrame:(CGRect)f
{
    self = [super initWithFrame:f];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;

    CGFloat w = f.size.width, h = f.size.height;

    _titleLab = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 60, 22)];
    _titleLab.text = @"AdlabKit 通用加速";
    _titleLab.textColor = [UIColor whiteColor];
    _titleLab.font = [UIFont boldSystemFontOfSize:13];
    [self addSubview:_titleLab];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(w - 44, 6, 38, 26);
    [x setTitle:@"关闭" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:12];
    [x addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:x];

    _speedLab = [[UILabel alloc] initWithFrame:CGRectMake(14, 36, w - 28, 20)];
    _speedLab.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1];
    _speedLab.font = [UIFont boldSystemFontOfSize:13];
    [self addSubview:_speedLab];

    _speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, 60, w - 28, 30)];
    _speedSlider.minimumValue = 1.0f;
    _speedSlider.maximumValue = 5.0f;
    _speedSlider.value = (float)gSpeed;
    [_speedSlider addTarget:self action:@selector(onSpeed)
           forControlEvents:UIControlEventValueChanged];
    [self addSubview:_speedSlider];

    // 四个开关：统一用同一个工厂，省得复制四遍
    CGFloat y0 = 94, step = 32;
    _shakeSwitch  = [self makeSwitchAt:y0        on:gBlockShake
                                 action:@selector(onShake)   title:@"拦截摇一摇广告"];
    _jumpSwitch   = [self makeSwitchAt:y0 + step on:gBlockJump
                                 action:@selector(onJump)    title:@"阻止跳转外部应用"];
    _closeSwitch  = [self makeSwitchAt:y0 + step * 2 on:gAutoClose
                                 action:@selector(onCloseAd) title:@"自动关闭广告页"];
    _rewardSwitch = [self makeSwitchAt:y0 + step * 3 on:gAutoReward
                                 action:@selector(onReward)  title:@"强制已播完发奖"];

    _statLab = [[UILabel alloc] initWithFrame:CGRectMake(14, y0 + step * 4, w - 28, 80)];
    _statLab.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _statLab.font = [UIFont fontWithName:@"Menlo" size:9.5];
    _statLab.numberOfLines = 0;
    [self addSubview:_statLab];

    CGFloat ly = y0 + step * 4 + 84;
    _logView = [[UITextView alloc] initWithFrame:CGRectMake(10, ly, w - 20, h - ly - 10)];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _logView.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.7 alpha:1];
    _logView.font = [UIFont fontWithName:@"Menlo" size:9];
    _logView.editable = NO;
    _logView.layer.cornerRadius = 8;
    _logView.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    [self addSubview:_logView];

    return self;
}

// 一行一个开关：开关本体 + 右侧说明文字
- (UISwitch *)makeSwitchAt:(CGFloat)y on:(BOOL)on action:(SEL)a title:(NSString *)title
{
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(14, y, 51, 31)];
    sw.on = on;
    sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [sw addTarget:self action:a forControlEvents:UIControlEventValueChanged];
    [self addSubview:sw];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(64, y + 4, self.bounds.size.width - 80, 22)];
    lab.text = title;
    lab.textColor = [UIColor lightGrayColor];
    lab.font = [UIFont systemFontOfSize:12];
    [self addSubview:lab];
    return sw;
}

- (void)onClose { [AdlabOverlay shared].panel.hidden = YES; }

- (void)onSpeed
{
    gSpeed = self.speedSlider.value;
    self.speedLab.text = [NSString stringWithFormat:@"倍速 %.1fx（%.0f%% 时间轴）",
                          gSpeed, 100.0 / gSpeed];
    cfg_save();
    KLOG("倍速 → %.2fx  域=%s", gSpeed, cfg_domain().UTF8String);
}

- (void)onShake
{
    gBlockShake = self.shakeSwitch.on;
    cfg_save();
    KLOG("摇一摇拦截 → %d", gBlockShake);
}

- (void)onJump
{
    gBlockJump = self.jumpSwitch.on;
    cfg_save();
    KLOG("阻止跳转 → %d", gBlockJump);
}

- (void)onCloseAd
{
    gAutoClose = self.closeSwitch.on;
    cfg_save();
    KLOG("自动关闭广告页 → %d", gAutoClose);
}

- (void)onReward
{
    gAutoReward = self.rewardSwitch.on;
    cfg_save();
    KLOG("强制已播完发奖 → %d", gAutoReward);
}
@end

#pragma mark - 主控

@implementation AdlabOverlay

+ (instancetype)shared
{
    static AdlabOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[AdlabOverlay alloc] init]; });
    return s;
}

- (void)install
{
    if (self.ball) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }

    @try {
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        if (sw < 1 || sh < 1) { sw = 375; sh = 667; }
        CGFloat bx = sw - 56;
        CGFloat by = sh * 0.35;

        // ── 方案 A：挂到游戏现有的 keyWindow（首选，绕开 UIScene 全部坑）
        // 自己造 UIWindow 在 iOS 13+ 必须绑 windowScene，而 constructor 时机
        // 拿不到 ForegroundActive 的 scene（实测日志 scene=0，界面永不出现）。
        // 直接往现有 window 上加子视图，宿主 app 自己已经把 scene 处理好了。
        UIWindow *host = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                if (s.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w.isKeyWindow) { host = w; break; }
                }
                if (!host) {
                    for (UIWindow *w in ((UIWindowScene *)s).windows) {
                        if (!w.hidden && w.windowLevel <= UIWindowLevelNormal + 1) { host = w; break; }
                    }
                }
                if (host) break;
            }
        }
        if (!host) host = [UIApplication sharedApplication].keyWindow;   // 兜底（iOS<13 或上面没找到）
        if (!host) {
            // 再兜底：遍历所有 window（app 可能还没 makeKey）
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if (![s isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)s).windows) { host = w; break; }
                    if (host) break;
                }
            }
        }

        if (!host) {
            gSceneRetry++;
            if (gSceneRetry <= 120) {                      // 最多等 60 秒
                if (gSceneRetry <= 3 || gSceneRetry % 20 == 0)
                    KLOG("还没拿到宿主 window，1s 后重试（第 %d 次）", gSceneRetry);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self install]; });
                return;
            }
            KLOG("60 秒内始终没有可用 window，UI 放弃（hook 仍在工作）");
            return;
        }

        // 悬浮球（直接加在宿主 window 上，不加中间容器，避免挡住游戏）
        self.ball = [[AdlabBall alloc] initWithFrame:CGRectMake(bx, by, 44, 44)];
        [self.ball addTarget:self action:@selector(onBallTap)
            forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(onBallPan:)];
        [self.ball addGestureRecognizer:pan];
        [host addSubview:self.ball];
        self.win = host;                                   // 记下宿主，供 refresh 用

        // 面板
        CGFloat pw = 300, ph = 560;
        self.panel = [[AdlabPanel alloc] initWithFrame:
                      CGRectMake((sw - pw) / 2.0, (sh - ph) / 2.0, pw, ph)];
        self.panel.hidden = YES;
        [host addSubview:self.panel];

        [self refresh];
        KLOG("UI 已安装(挂宿主) %.0fx%.0f host=%@ retry=%d ball=(%.0f,%.0f)",
             sw, sh, NSStringFromClass([host class]), gSceneRetry, bx, by);
    } @catch (NSException *e) {
        KLOG("UI 安装异常 %s", e.reason.UTF8String);
    }
}

- (void)onBallTap
{
    self.panel.hidden = !self.panel.hidden;
    [self refresh];
}

- (void)onBallPan:(UIPanGestureRecognizer *)g
{
    UIView *v = self.ball;
    CGPoint t = [g translationInView:v.superview];
    CGPoint c = v.center;
    c.x += t.x; c.y += t.y;
    v.center = c;
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
}

- (void)refresh
{
    if (!self.panel) return;
    self.panel.speedLab.text = [NSString stringWithFormat:@"倍速 %.1fx（%.0f%% 时间轴）",
                                gSpeed, 100.0 / gSpeed];
    if (self.panel.speedSlider.value != (float)gSpeed)
        self.panel.speedSlider.value = (float)gSpeed;
    if (self.panel.shakeSwitch.on != gBlockShake)
        self.panel.shakeSwitch.on = gBlockShake;
    if (self.panel.jumpSwitch.on != gBlockJump)
        self.panel.jumpSwitch.on = gBlockJump;
    if (self.panel.closeSwitch.on != gAutoClose)
        self.panel.closeSwitch.on = gAutoClose;
    if (self.panel.rewardSwitch.on != gAutoReward)
        self.panel.rewardSwitch.on = gAutoReward;

    self.panel.statLab.text = [NSString stringWithFormat:
        @"域  %@\n"
        @"时间源 %d  定时器 %d  播放器 %d\n"
        @"摇一摇 %d  反检测 %d  类 %d/%d\n"
        @"放大 %d  增量 %d  去重 %d\n"
        @"拦截跳转 %d  自动关闭 %d  强制播完 %d",
        cfg_domain(),
        g_hitTime, g_hitTimer, g_hitPlayer,
        g_hitShake, g_hitStealth, g_classesMatched, g_classesScanned,
        g_hitDiscovered, g_hitResweep, g_hitDedup,
        g_hitJump, g_hitAutoClose, g_hitAutoReward];

    if (self.panel.logView && gLogLock) {
        [gLogLock lock];
        NSArray *copy = [gLogLines copy];
        [gLogLock unlock];
        self.panel.logView.text = [copy componentsJoinedByString:@"\n"];
    }
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void adlab_entry(void)
{
    @autoreleasepool {
        klog_init();
        KLOG("==== AdlabKit loaded  pid=%d  bid=%s ====",
             getpid(), [[[NSBundle mainBundle] bundleIdentifier] UTF8String]);

        cfg_load();
        g_ecpmOut = [NSMutableSet new];
        g_closingSet = [NSMutableSet new];
        KLOG("配置: 域=%s 倍速=%.2f 摇一摇=%d 阻止跳转=%d 自动关闭=%d 自动奖励=%d",
             cfg_domain().UTF8String, gSpeed, gBlockShake,
             gBlockJump, gAutoClose, gAutoReward);

        // 顺序有讲究：先装时间源（其他层依赖它），再定时器，再播放器
        install_time_hooks();
        install_timer_hooks();
        install_player_hooks();
        install_discovered_hooks();
        install_shake_block();
        install_jump_block();
        install_auto_close();
        install_stealth();

        // UI 延后，等 app 自己的 window 起来；didFinishLaunching 再兜一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[AdlabOverlay shared] install]; });

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *n) {
            [[AdlabOverlay shared] install];
        }];

        KLOG("入口完成 speed=%.2f hook=%d/%d/%d stealth=%d",
             gSpeed, g_o_nsDate != NULL, g_o_schedTimer != NULL,
             g_o_setRate != NULL, g_hitStealth);
    }
}
