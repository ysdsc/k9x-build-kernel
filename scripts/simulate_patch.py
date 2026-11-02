# Python 版补丁执行器 —— 用于在 Windows 本机预演/验证补丁逻辑
# 用法: python simulate_patch.py <kernel_dir>
#
# 与 apply-resukisu-shim.sh 的锚点完全一致。模拟器会用桩文件替代真实内核源文件，
# 但锚点取自真实 4.19.191 源码，因此能验证"匹配是否唯一、结果是否语法正确"。
import os, re, sys, shutil

MARK = "[RESUKISU]"

LOG = []


def load(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def save(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(s)


def die(msg, path, anchor):
    sys.stderr.write("ERROR: %s\n文件: %s\n--- 期望上下文 ---\n%s\n---\n" % (msg, path, anchor))
    sys.exit(1)


def insert_before(kroot, f, anchor, payload):
    p = os.path.join(kroot, f)
    src = load(p)
    if payload in src:
        LOG.append(("SKIP", f))
        return
    n = src.count(anchor)
    if n != 1:
        die("锚点匹配 %d 次(需恰好 1 次)" % n, f, anchor)
    save(p, src.replace(anchor, payload + anchor, 1))
    LOG.append(("PATCHED", f))


def replace_once(kroot, f, old, new):
    p = os.path.join(kroot, f)
    src = load(p)
    if new in src:
        LOG.append(("SKIP", f))
        return
    n = src.count(old)
    if n != 1:
        die("替换锚点匹配 %d 次(需恰好 1 次)" % n, f, old)
    save(p, src.replace(old, new, 1))
    LOG.append(("PATCHED", f))


def apply_all(kroot):
    del LOG[:]

    # 1. Kconfig
    p = os.path.join(kroot, "Kconfig")
    src = load(p)
    if 'source "KernelSU/Kconfig"' not in src:
        save(p, src + '\n# %s ReSukiSU\nsource "KernelSU/Kconfig"\n' % MARK)
        LOG.append(("PATCHED", "Kconfig"))
    else:
        LOG.append(("SKIP", "Kconfig"))

    # 2. exec.c —— 必须用 replace_once: 整段替换原函数, 而非在其前插入
    replace_once(kroot, "fs/exec.c",
"static int do_execveat_common(int fd, struct filename *filename,\n"
"\t\t\t      struct user_arg_ptr argv,\n"
"\t\t\t      struct user_arg_ptr envp,\n"
"\t\t\t      int flags)\n"
"{\n"
"\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
"}",
"/* " + MARK + " execve hook (ReSukiSU manual hooks, 4.19) */\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK\n"
"__attribute__((hot))\n"
"extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
"\t\t\t\tvoid *argv, void *envp, int *flags);\n"
"__attribute__((hot))\n"
"extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,\n"
"\t\t\t\tvoid *argv, void *envp, int *flags, int *retval);\n"
"#endif\n\n"
"static int do_execveat_common(int fd, struct filename *filename,\n"
"\t\t\t      struct user_arg_ptr argv,\n"
"\t\t\t      struct user_arg_ptr envp,\n"
"\t\t\t      int flags)\n"
"{\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK\n"
"\tint retval;\n\n"
"\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
"\tretval = __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
"\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);\n"
"\treturn retval;\n"
"#else\n"
"\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);\n"
"#endif\n"
"}")

    HDR = "#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " */\n"

    # 3a. stat.c —— 声明块 + newfstatat 一次性整体替换(单次操作, 杜绝重复匹配)
    replace_once(kroot, "fs/stat.c",
"#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\n"
"SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n"
"\t\tstruct stat __user *, statbuf, int, flag)\n"
"{\n"
"\tstruct kstat stat;\n"
"\tint error;\n"
"\n"
"\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"
"\tif (error)\n"
"\t\treturn error;\n"
"\treturn cp_new_stat(&stat, statbuf);\n"
"}\n"
"#endif",
"/* " + MARK + " stat hook (ReSukiSU manual hooks, 4.19) */\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK\n"
"__attribute__((hot))\n"
"extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
"\t\t\t\tint *flags);\n"
"__attribute__((hot))\n"
"extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\n"
"#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)\n"
"extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);\n"
"#endif\n"
"#endif\n"
"\n"
"#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)\n"
"SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,\n"
"\t\tstruct stat __user *, statbuf, int, flag)\n"
"{\n"
"\tstruct kstat stat;\n"
"\tint error;\n"
"\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " */\n"
"\tksu_handle_stat(&dfd, &filename, &flag);\n"
"#endif\n"
"\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"
"\tif (error)\n"
"\t\treturn error;\n"
"\treturn cp_new_stat(&stat, statbuf);\n"
"}\n"
"#endif")

    HDR = "#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " */\n"
    END = "#endif\n"

    # 3b-3e: stat.c 其余四处 —— 必须整体替换函数体(尾部 return 不同, 避免重复插入)
    replace_once(kroot, "fs/stat.c",
"SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)\n"
"{\n\tstruct kstat stat;\n\tint error = vfs_fstat(fd, &stat);\n\n"
"\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n"
"\treturn error;\n}",
"SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)\n"
"{\n\tstruct kstat stat;\n\tint error = vfs_fstat(fd, &stat);\n\n"
"\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n"
+ HDR + "\tksu_handle_newfstat_ret(&fd, &statbuf);\n" + END +
"\treturn error;\n}")

    # 3d fstatat64
    replace_once(kroot, "fs/stat.c",
"SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"
"\t\tstruct stat64 __user *, statbuf, int, flag)\n"
"{\n\tstruct kstat stat;\n\tint error;\n\n"
"\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"
"\tif (error)\n\t\treturn error;\n"
"\treturn cp_new_stat64(&stat, statbuf);\n}",
"SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"
"\t\tstruct stat64 __user *, statbuf, int, flag)\n"
"{\n\tstruct kstat stat;\n\tint error;\n\n"
+ "#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " 32-bit su */\n"
  "\tksu_handle_stat(&dfd, &filename, &flag);\n" + END +
"\terror = vfs_fstatat(dfd, filename, &stat, flag);\n"
"\tif (error)\n\t\treturn error;\n"
"\treturn cp_new_stat64(&stat, statbuf);\n}")

    # 3e fstat64
    replace_once(kroot, "fs/stat.c",
"SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)\n"
"{\n\tstruct kstat stat;\n\tint error = vfs_fstat(fd, &stat);\n\n"
"\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n"
"\treturn error;\n}",
"SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)\n"
"{\n\tstruct kstat stat;\n\tint error = vfs_fstat(fd, &stat);\n\n"
"\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n"
+ "#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " 32-bit */\n"
  "\tksu_handle_fstat64_ret(&fd, &statbuf);\n" + END +
"\treturn error;\n}")

    # 4 open.c —— 整体替换函数体
    replace_once(kroot, "fs/open.c",
"SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
"{\n\treturn do_faccessat(dfd, filename, mode);\n}",
"/* " + MARK + " faccessat hook */\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK\n"
"__attribute__((hot))\n"
"extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
"\t\t\t\tint *mode, int *flags);\n"
"#endif\n\n"
"SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)\n"
"{\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " */\n"
"\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
"#endif\n"
"\treturn do_faccessat(dfd, filename, mode);\n}")

    # 5 reboot.c —— 声明 + 函数体首部整体替换
    replace_once(kroot, "kernel/reboot.c",
"SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
"\t\tvoid __user *, arg)\n"
"{\n"
"\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
"\tchar buffer[256];\n"
"\tint ret = 0;\n\n"
"\t/* We only trust the superuser with rebooting the system. */",
"/* " + MARK + " sys_reboot hook */\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK\n"
"extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n"
"\t\t\t\t void __user **arg);\n"
"#endif\n\n"
"SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
"\t\tvoid __user *, arg)\n"
"{\n"
"\tstruct pid_namespace *pid_ns = task_active_pid_ns(current);\n"
"\tchar buffer[256];\n"
"\tint ret = 0;\n\n"
"#ifdef CONFIG_KSU_MANUAL_HOOK /* " + MARK + " */\n"
"\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
"#endif\n"
"\t/* We only trust the superuser with rebooting the system. */")

    return LOG


if __name__ == "__main__":
    kroot = sys.argv[1]
    log = apply_all(kroot)
    for st, f in log:
        print("  %-8s %s" % (st, f))
    print("OK: %d 处补丁" % sum(1 for s, _ in log if s == "PATCHED"))
