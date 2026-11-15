# AdlabKit — 通用 iOS 广告加速插件

注入任何 iOS app 都成立。它只 hook **系统 API**，不碰一行业务代码、不依赖任何具体 SDK 的类名或方法名。

适用：iOS 12.0+ / arm64 / TrollStore + TrollFools（或任何能注入 dylib 的手段）

---

## 为什么能加速（原理）

所有激励视频的「要看满 N 秒」都是靠**时间测量**得出的。测量方式只有三种：

| 方式 | 典型实现 | 本插件对应层 |
|---|---|---|
| 定时器递减 | `NSTimer` 每 1 秒 `remaining--` | 层次二 |
| 时间差计算 | `elapsed = now - startTime` | 层次一 |
| 播放器进度 | `AVPlayer.currentTime` / KVO | 层次三 |

把这三个时间源一起加速，三种实现都会被压缩。关键是：**广告确实播过**，曝光、点击、SDK 回调全是真实事件，只是时间轴被压缩了。所以对账过得去，不会像伪造领取那样被封。

---

## 层次结构（十层）

### 层次一 · 时间源
hook `+[NSDate date]` 与 `-[NSDate timeIntervalSinceReferenceDate]`。
虚拟时间 = 基准 + (真实时间 − 基准) × 倍速；切换倍速时重新定基准，保证单调不回退。

**不做** C 函数 hook（`CFAbsoluteTimeGetCurrent` / `gettimeofday` / `mach_absolute_time`）。
`__interpose` 拦 dyld 自己依赖的符号会在绑定期拿到 `NULL` 直接崩，这是 v1 闪退的根因。
实践上也不需要：广告倒计时几乎都走 `NSTimer` 或 `NSDate` 差值。

### 层次二 · 定时器
- `+[NSTimer scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:]`
- `+[NSTimer timerWithTimeInterval:target:selector:userInfo:repeats:]`
- `-[NSObject performSelector:withObject:afterDelay:]`

间隔除以倍速，下限 1 ms。`0` 与负数原样放行（`0` 是「下一轮 runloop」，除下去会变忙等拖死主线程）。

`CADisplayLink` 只统计不缩放——`frameInterval` 单位是「帧」且只能 ≥1，调小被系统钳回。

### 层次三 · 播放器
`-[AVPlayer setRate:]` 乘以倍速，上限 2.0（多数机型超过 2x 会静音或变调）。
`rate == 0` 是暂停，**不乘**——否则变成「极慢速播放」，画面冻住音频继续。

### 层次四 · 运行时发现
枚举所有已加载类 → 类名过宽松关键字 → 从**方法名**里找进度接口 → 按形状挂载。

**只挂零参数、返回 `double` 的方法。** 这是唯一能保证调用约定正确的形状。
参数多于 0 个时中间参数可能走浮点寄存器，用错误签名的 block 去接会把 `id` 当 `double` 读，直接 `SIGSEGV`——第三方插件（AdAccel）点广告闪退的根因就是给未知签名的方法强换实现。

**方向不能错：** 进度 = `currentTime / duration`。两个都乘倍速比值不变，进度条一动不动。
所以分子乘倍速、分母除倍速，`progress` 被放大 倍速² 倍。

### 层次五 · 摇一摇拦截
`-[UIWindow sendEvent:]` 判 `type == UIEventTypeTouches && subtype == UIEventSubtypeMotionShake`，直接吞掉。

### 层次五之二 · 阻止跳转外部 App
广告「点击」最终只有四条落地路径，全拦：

| 方法 | 说明 |
|---|---|
| `-[UIApplication openURL:]` | iOS 2~10 老路 |
| `-[UIApplication openURL:options:completionHandler:]` | iOS 10+ |
| `-[UIApplication open:options:completionHandler:]` | iOS 10+ 新名 |
| `-[UIViewController presentViewController:animated:completion:]` | 落地页弹窗 |

前三条按 scheme 判：自家 `maobei` / `kittypay` / `wx` / `alipay` 放行，外部 `itms-apps` / `https` / `http` / `maps` / `tel` / `sms` / `mailto` 拦掉。
第四条更保守——**只在目标类名像系统浏览器/商店时**才拦（`SFSafariViewController` / `SKStoreProductViewController` / `WKWebView`），
否则游戏自己的弹窗也会被误拦。

拦截时返回「操作成功」（`return YES` / `cb(YES)`），调用方不会重试、不会走失败分支。

### 层次五之三 · 广告页自动关闭
`-[UIViewController viewDidAppear:]` 之后，若这个 VC **同时满足**「类名像广告」和「有 `presentingViewController`」，
等 `gAutoCloseDelay / cur_speed()` 秒后 `dismissViewControllerAnimated:NO`。

延时**除以倍速**是关键：奖励回调是 SDK 在「播完」时触发的，关早了 SDK 认为用户中途退出、不发奖。
3x 倍速下 1 秒墙钟 = 3 秒内容时长，6 秒的激励视频刚好播完。

用 `g_closingSet` 记正在关闭的 VC 指针，防重入。

### 层次四之三 · 强制「已播完」发奖
这条不能用安卓那套（Xposed 改 `onRewardVerify` 布尔值）——iOS 的奖励回调是 SDK 内部方法，名字随版本变、还可能是 block。

改法：**不改回调，改回调依赖的判定输入**。所有「看满 N 秒才发奖」最终都要问一次「播完了没」，
这个回答只能来自返回 `BOOL`/整型、名字含 `finish` / `complete` / `ended` / `played` 的**零参数**方法。
统一改成 `YES`，SDK 自己会去调奖励回调——那是它原本的路径，不是伪造的，内部状态、埋点、时序全部自洽。

只挂零参数：参数多的签名不可控，中间参数走浮点寄存器，把 `id` 当 `double` 读会直接 SIGSEGV（AdAccel 点广告闪退就是这么来的）。

### 层次六 · 反检测
`objc_getClassList` 遍历，按类名片段匹配（`IOSSecuritySuite` / `SecurityChecker` / `Jailbreak` / `Tamper` / `AntiDebug` / `FridaDetector` / `IntegrityCheck` …），
把 `amI*` 前缀方法改为返回 `0`/`nil`。参数个数从 selector 冒号数推，返回类型从 `method_getReturnType` 读。

不用 `NSClassFromString(@"IOSSecuritySuite")`——它是 Swift 模块，运行时类名是 mangled 的，硬编码必为 `nil`（v1 的第三个坑）。

### 层次七 · 悬浮窗
`AdlabWindow` 覆写 `hitTest:withEvent:`，命中 `self` 或 `rootViewController.view` 返回 `nil` → 事件穿透到游戏。
`windowLevel = UIWindowLevelAlert + 100`。
iOS 13+ 必须绑 `UIScene`，否则 window 永不显示（v1 的第四个坑）。

---

## 通用性设计

| 项 | 做法 |
|---|---|
| 配置存储 | 按 app 分域：`com.adlab.cfg.<bundleIdentifier>`，每个 app 独立倍速与四个开关 |
| SDK 类名 | 不写死任何类名，全部运行时发现 + 形状校验 |
| 失败行为 | 类不存在 → `objc_getClass` 返回 `NULL` → 静默跳过，不影响其他层 |
| 异常 | 每个 hook 体 `@try/@catch`，异常回落原实现 |
| 倍速 1.0 | 全部直通，零开销零风险 |
| 方法签名 | 只挂「零参数」的方法；带参数的中间参数可能走浮点寄存器，签名对不上会读到垃圾 |
| 增量发现 | `_dyld_register_func_for_add_image` + 轮询双触发，抓懒加载的 SDK 类 |

四个开关（全部按 app 独立保存）：

| 键 | 默认 | 作用 |
|---|---|---|
| `.speed` | 1.0 | 倍速 1.0~5.0 |
| `.shake` | ON | 吞摇一摇 |
| `.nojump` | ON | 拦外部跳转 |
| `.autoclose` | ON | 广告页自动关闭 |
| `.autoreward` | ON | 强制已播完 |

「通用」的准确含义：**能安全装在任何 app 上，装不上就不干活**。不是「对任何 app 都有效」——
如果一个 app 的广告倒计时既不用 `NSTimer` 也不用 `NSDate` 也不用 `AVPlayer`，那它加速不了。

---

## 构建

macOS 上：
```bash
./build.sh
```

Windows 上（本仓库用法）：推到 GitHub，用 Actions 的 `macos-13` runner 出产物。见 `.github/workflows/build.yml`。

产物 `build/libadlab.dylib`，`LC_ID_DYLIB = @executable_path/Frameworks/libadlab.dylib`。

---

## 注入

1. 拿到 `libadlab.dylib`（**文件名不要带空格和括号**——TrollFools 处理带空格路径时 `install_name_tool -change` 会变空操作）
2. 传到 iPhone
3. TrollFools → 选目标 app → 注入
4. 启动 app，1 秒内右边缘出现悬浮球「倍」
5. 点悬浮球开面板，拖滑杆设倍速

---

## 验证

| 检查 | 命令 / 方法 |
|---|---|
| dylib 是否加载 | `ls /tmp/adlab.log`，或面板显示统计数字 |
| 时间源生效 | 面板 `时间源` 计数 > 0 |
| 定时器生效 | 面板 `定时器` 计数 > 0 |
| 播放器生效 | 面板 `播放器` 计数 > 0 |
| 摇一摇生效 | 摇手机，广告不跳转，`摇一摇` 计数 +1 |
| **阻止跳转** | 点广告，不跳出 app，`拦截跳转` 计数 +1 |
| **自动关闭** | 广告页出现后 1 秒左右自动消失，`自动关闭` 计数 +1 |
| **强制播完** | 广告被关掉后仍能领到奖励，`强制播完` 计数 > 0 |
| 反检测生效 | 面板 `反检测` 数字，或 `/tmp/adlab.log` 里 `清理 X 上 N 个检测方法` |

日志同时写 `stderr` 与 `NSTemporaryDirectory()/adlab.log`，每行 `fflush`。

### 面板长什么样

```
倍速 3.0x（33% 时间轴）
[========滑杆========]
[✓] 拦截摇一摇广告
[✓] 阻止跳转外部应用
[✓] 自动关闭广告页
[✓] 强制已播完发奖

域  com.adlab.cfg.com.maobei.idiom
时间源 12  定时器 8  播放器 1
摇一摇 0  反检测 0  类 557/58144
放大 34  增量 2  去重 6
拦截跳转 3  自动关闭 2  强制播完 2
```

前四行是开关，后面是实时统计。倍速拉到 3x 之后，`放大` 和 `增量` 应该开始涨。

### 如果出现「没有浮球」

先看 `/tmp/adlab.log`：

- 有 `==== AdlabKit loaded ====` 但没 `UI 已安装` → 宿主 window 没拿到，日志会打 `还没拿到宿主 window，1s 后重试（第 N 次）`
- 完全没有 `==== AdlabKit loaded ====` → dylib 没被加载，问题在注入链（TrollFools 挑错了 Mach-O，或文件名带空格括号）

---

## 踩过的坑（每一条都是真实闪退）

1. **`__interpose` 拦 `_dyld_get_image_name`** — dyld 绑定期即生效，但原实现指针要等 constructor 才赋值 → 中间返回 `NULL` → 立刻崩。已彻底删除。
2. **`dlsym(RTLD_DEFAULT, "fopen")`** — dyld 处理 interpose 后 `RTLD_DEFAULT` 返回替换函数自身 → 递归爆栈。已彻底不用 `dlopen`/`dlsym`。
3. **`NSClassFromString(@"IOSSecuritySuite")`** — Swift 模块，类名 mangled，恒为 `nil` → 检测方法一个没清 → 重签后 `amITampered` 返回 true → 主动退出。改为 `objc_getClassList` 遍历。
4. **无 `windowScene` 的 `UIWindow`** — iOS 13+ 永不显示。已加 scene 查找与重试。
5. **给未知签名的方法强换实现** — 参数个数/返回类型错位 → `SIGSEGV`。层次四用「零参数 + 返回 double」双重过滤堵死。
6. **`CGPointZero` 未链接** — 它是 CoreGraphics 的 extern const，不是内联常量。改用 `CGPointMake(0, 0)` 并链 `-framework CoreGraphics`。
7. **`file` 报 `Non-fat file` + Verify 判红** — CI 里 `grep -q '__interpose'` 命中的是旧版检查逻辑；且 `Upload` 用了 `if-no-files-found: error`，Verify 一红产物就被丢弃。已改 `if: always()` + `warn`。
