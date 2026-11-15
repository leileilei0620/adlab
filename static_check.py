# -*- coding: utf-8 -*-
# 静态自检 v2：修掉 v1 的检查器 bug
import io, re, sys, os

SRC = r"D:\ai项目\yydiary\adlab-ios\AdlabKit.m"
src = io.open(SRC, "r", encoding="utf-8").read()
ok = True


def chk(cond, msg):
    global ok
    print(("  PASS  " if cond else "  FAIL  ") + msg)
    if not cond:
        ok = False


def strip_comments(s):
    """去掉 /* */ 与 // 注释，保留字符串字面量原文"""
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    out = []
    i = 0
    n = len(s)
    instr = False
    esc = False
    while i < n:
        c = s[i]
        if instr:
            out.append(c)
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] != '\n':
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


code = strip_comments(src)

print("bytes=%d  lines=%d  code_chars=%d" % (os.path.getsize(SRC), src.count("\n") + 1, len(code)))
print()

# ---- 括号平衡 ----
chk(code.count("{") == code.count("}"), "花括号  { %d } %d" % (code.count("{"), code.count("}")))
chk(code.count("(") == code.count(")"), "圆括号  ( %d ) %d" % (code.count("("), code.count(")")))
chk(code.count("[") == code.count("]"), "方括号  [ %d ] %d" % (code.count("["), code.count("]")))

nif = len(re.findall(r'^@interface ', code, re.M))
nim = len(re.findall(r'^@implementation ', code, re.M))
nen = len(re.findall(r'^@end', code, re.M))
chk(nif == nim and nen == nif * 2, "@interface %d  @implementation %d  @end %d" % (nif, nim, nen))
print()

# ---- 声明顺序：在**去注释后的代码**里比较定义位置与真正调用位置 ----
# 变量：static ... name = 或 ;
# 函数：static <type> name(...)  {   ← 以 { 结尾
VARS = ["gSpeed", "gBlockShake", "g_classesMatched", "g_classesScanned",
        "g_hitDiscovered", "g_hitResweep", "g_hitDedup",
        "g_jitterMul", "g_jitterAt", "g_ecpmOut"]
FUNCS = ["cur_speed", "klog", "kswizzle", "k_scaled",
         "name_looks_ad", "sel_looks_progress",
         "name_is_numerator", "name_is_denominator",
         "hook_DoubleZeroArg", "adlab_sweep_classes",
         "adlab_image_added", "adlab_start_resweep",
         "install_discovered_hooks"]

for sym in VARS + FUNCS:
    # 找定义处。变量可能同行多声明（static int a = 0, b = 0, c = 0;），
    # 所以整条 static 语句内部出现该标识符即算声明，不能要求它紧跟 static。
    m = None
    for stmt in re.finditer(r'^static\b[^\n]*', code, re.M):
        line = stmt.group(0)
        if re.search(r'\b' + re.escape(sym) + r'\b', line):
            m = stmt
            break
    if not m:
        chk(False, "%-24s 未找到定义" % sym)
        continue
    decl_at = m.start()
    # 找首次「真正使用」：跳过定义本身，找下一次出现
    use_at = code.find(sym, m.end())
    if use_at < 0:
        chk(True, "%-24s 定义@%d 无后续使用" % (sym, decl_at))
        continue
    chk(decl_at < use_at, "%-24s 定义@%-6d 首用@%-6d" % (sym, decl_at, use_at))

print()

# ---- #import 与库函数可用性 ----
for n in ["arc4random", "floor", "strdup", "realloc", "strcmp", "gettimeofday",
          "_dyld_register_func_for_add_image", "imp_implementationWithBlock",
          "objc_getClassList", "class_copyMethodList"]:
    chk(n in code, "使用 %s" % n)

print()

# ---- 危险模式（只在代码区查）----
# dispatch_once(&once, ^{ 是合法且必要的单例保护，不算危险；
# 只禁「在可能重入的路径里用 dispatch_once」，本项目两处都是纯单例，放行。
for b in ["dlopen(", "dlsym(", "NSClassFromString", "__interpose"]:
    chk(b not in code, "代码区无 %s" % b)
chk(code.count("dispatch_once(&") <= 2,
    "dispatch_once 仅 %d 处（只用于单例）" % code.count("dispatch_once(&"))

print()
# ---- 三处改造是否真的在位 ----
chk("_dyld_register_func_for_add_image(adlab_image_added)" in code, "P0 dyld 回调已注册")
chk("adlab_start_resweep()" in code, "P0 轮询兜底已启用")
chk("static void adlab_sweep_classes(BOOL initial)" in code, "P0 增量扫描函数存在")
chk("s_seen" in code and "strdup(cn)" in code, "P0 seen 表去重存在")
chk("@synchronized (g_ecpmOut)" in code, "P1 回灌去重加锁")
chk("containsObject:@(key)" in code, "P1 值集合查询")
chk("arc4random_uniform(1201)" in code, "P2 ±6% 抖动")
chk("return gSpeed * g_jitterMul;" in code, "P2 cur_speed 返回抖动后倍速")
n_cur = len(re.findall(r'cur_speed\(\)', code))
chk(n_cur >= 5, "cur_speed() 被 %d 处调用（应 >=5）" % n_cur)

print()
print("结果: " + ("PASS  全部静态检查通过" if ok else "FAIL"))
sys.exit(0 if ok else 1)
