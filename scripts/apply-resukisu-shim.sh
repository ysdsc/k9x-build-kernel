#!/usr/bin/env bash
#
# 内核 root 方案集成 —— 外部 KSU 目录 + 4.19 手动 hook 注入
# 目标内核: OPPO K9x / MT6833 / Linux 4.19.191 (arm64, CONFIG_KALLSYMS_ALL=y)
#
# 适用方案 (本脚本不区分, 完全共用):
#   * Baka-SU/BakaSU  (ReSukiSU)
#   * HyperSU-Team/HyperSU
#   两者 kernel/Kconfig 逐字节等价, 提供同名同签名的 ksu_handle_* 函数。
#
# 设计说明:
#   不使用 `curl setup.sh | bash`, 因为它依赖 git clone 且假设源码树是 git 仓库。
#   这里改为: CI 预先 clone 仓库到 KERNEL_ROOT/KernelSU,
#   由本脚本在宿主机侧完成全部源码改动, 便于审查与复现。
#
# 幂等: 每处替换都先检测标记 "[RESUKISU]", 已存在则跳过。
#
set -euo pipefail

KROOT="${1:?用法: $0 <kernel_dir>}"
MARK="[RESUKISU]"

cd "$KROOT"

log()  { printf '\033[1;36m[resukisu]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[resukisu] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f Makefile ] || fail "不是内核源码根目录: $KROOT"
[ -d KernelSU ] || fail "缺少 $KROOT/KernelSU (应先 clone 方案仓库例如 BakaSU/HyperSU)"

have_mark() { grep -qF "$MARK" "$1"; }

# python 侧公共前缀: 读文件 -> 带上下文错误输出
PYLIB='
import sys
def load(p):
    return open(p, encoding="utf-8", errors="surrogateescape").read()
def save(p, s):
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
def die(msg, path, anchor):
    sys.stderr.write("ERROR: %s in %s\n--- 期望上下文 ---\n%s\n---------------\n" % (msg, path, anchor))
    sys.exit(1)
'

# insert_before <file> <multi-line-anchor> <payload>
# 语义: 若 payload 已在文件中则跳过；否则在 anchor 前插入 payload(anchor 原样保留)。
insert_before() {
  local f="$1" anchor="$2" payload="$3"
  PAYLOAD="$payload" ANCHOR="$anchor" python3 -c "$PYLIB"'
import os
path, anchor = sys.argv[1], os.environ["ANCHOR"]
payload = os.environ["PAYLOAD"]
src = load(path)
if payload in src:
    print("SKIP"); sys.exit(0)
n = src.count(anchor)
if n != 1:
    die("锚点匹配 %d 次(需恰好 1 次)" % n, path, anchor)
save(path, src.replace(anchor, payload + anchor, 1))
print("PATCHED")
' "$f" || fail "insert_before 失败: $f"
}

# replace_once <file> <old> <new>
replace_once() {
  local f="$1" old="$2" new="$3"
  OLD="$old" NEW="$new" python3 -c "$PYLIB"'
import os
path, old = sys.argv[1], os.environ["OLD"]
new = os.environ["NEW"]
src = load(path)
if new in src:
    print("SKIP"); sys.exit(0)
n = src.count(old)
if n != 1:
    die("替换锚点匹配 %d 次(需恰好 1 次)" % n, path, old)
save(path, src.replace(old, new, 1))
print("PATCHED")
' "$f" || fail "replace_once 失败: $f"
}

log "=== 1/5 Kconfig: 挂载 ReSukiSU ==="
# 顶层 Kconfig 末尾追加 source，使源码树内出现 CONFIG_KSU / CONFIG_KSU_MANUAL_HOOK
if grep -qF "source \"KernelSU/Kconfig\"" Kconfig; then
  log "skip (已打)  Kconfig"
else
  printf '\n# %s ReSukiSU\nsource "KernelSU/Kconfig"\n' "$MARK" >> Kconfig
  log "patched      Kconfig"
fi

log "=== 2/5 fs/exec.c : execve hook (4.19 do_execveat_common) ==="
# 注意: 必须整段替换原函数。若用 insert_before 会在原函数前多出一条仅有声明+新函数体的
# 半截代码, 导致 "}static int ..." 重复定义。
replace_once fs/exec.c \
"static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
}" \
"/* $MARK execve hook (ReSukiSU manual hooks, 4.19) */
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
__attribute__((hot))
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags, int *retval);
#endif

static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	int retval;

	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	retval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
	ksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
	return retval;
#else
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
#endif
}"

log "=== 3/5 fs/stat.c : stat hook (newfstatat / newfstat32 / fstatat64 / fstat64) ==="
# 3a. 声明块 + newfstatat —— 一次性整体替换(单次操作, 避免"插入后再匹配"产生重复)。
#     注意: 本内核 fs/stat.c 的 newfstatat 紧跟 fstatat, 无空行分隔, 锚点必须是连续行;
#     若写成带空行的版本会吞掉前一个函数的收尾 '}'。
replace_once fs/stat.c \
"#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat(&stat, statbuf);
}
#endif" \
"/* $MARK stat hook (ReSukiSU manual hooks, 4.19) */
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);
__attribute__((hot))
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif

#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK */
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat(&stat, statbuf);
}
#endif"

# 3b. newfstat (64-bit, fd 形式)
replace_once fs/stat.c \
"SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;
}" \
"SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK */
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;
}"

# 3d. fstatat64 (32-bit app 走 arm64 的 compat 路径)
replace_once fs/stat.c \
"SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,
		struct stat64 __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat64(&stat, statbuf);
}" \
"SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,
		struct stat64 __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK 32-bit su */
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat64(&stat, statbuf);
}"

# 3e. fstat64 (32-bit)
replace_once fs/stat.c \
"SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;
}" \
"SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK 32-bit */
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;
}"

log "=== 4/5 fs/open.c : faccessat hook ==="
replace_once fs/open.c \
"SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);
}" \
"/* $MARK faccessat hook */
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif

SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK */
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);
}"

log "=== 5/5 kernel/reboot.c : sys_reboot hook ==="
replace_once kernel/reboot.c \
"SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */" \
"/* $MARK sys_reboot hook */
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				 void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK /* $MARK */
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
	/* We only trust the superuser with rebooting the system. */"

log "完成: 手动 hook 已注入。"
log "说明: setuid / sys_read / input 三项 hook 在 4.19 上由 CONFIG_KSU_MANUAL_HOOK_AUTO_* 自动完成，"
log "      故此处不手工注入；若编译报告缺失，再按 resukisu.org/guide/manual-integrate 补上。"
