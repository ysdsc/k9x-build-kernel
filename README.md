# OPPO K9x 内核 Root 方案（ReSukiSU / BakaSU）

> 设备：OPPO K9x（MT6833 / PERM00），Linux 4.19.191，ColorOS 13
> 前提：**bootloader 已解锁**（用户已确认）

---

## 一、为什么不是 HyperSU

| 方案 | 适用内核 | 本设备可行性 |
|---|---|---|
| **ReSukiSU / BakaSU** | 3.4+，含 4.19 非 GKI | ✅ 采用 |
| HyperSU | GKI 5.10+，`.ko` 动态加载 | ❌ 4.19 非 GKI 不支持 |

关键事实（已核对）：

- `github.com/ReSukiSU/ReSukiSU` 现**重定向到** `Baka-SU/BakaSU`
- 上游集成脚本是仓库内 `kernel/setup.sh`，它会：
  1. clone 仓库到内核源码根 `KernelSU/`
  2. 软链 `KernelSU/kernel` → `drivers/kernelsu`
  3. `drivers/Makefile` 追加 `obj-$(CONFIG_KSU) += kernelsu/`
  4. `drivers/Kconfig` 的 `endmenu` 前插入 `source "drivers/kernelsu/Kconfig"`
- `kernel/Kconfig` 里 hook 方式是 **choice**，默认 `KSU_TRACEPOINT_HOOK`（仅 GKI 5.10+），
  4.19 必须显式选 `CONFIG_KSU_MANUAL_HOOK=y`，否则配置出错
- `CONFIG_KSU_SUSFS` 在非 GKI 内核上**必须关闭**，否则编译失败

---

## 二、目录结构

```
D:\k9x-build\
├── k9x-kernel\                     ← 内核源码（4.19.191，81734 个文件，1.15 GB）
├── scripts\
│   ├── k9x-cloud-build.sh          ← 云编译主脚本（在 GitHub Actions 上跑）
│   ├── apply-resukisu-shim.sh      ← 注入 4.19 手动 hook（stat/exec/faccess/reboot）
│   ├── apply-defconfig.sh          ← 追加 CONFIG_KSU 等配置
│   ├── simulate_patch.py           ← 补丁逻辑的本机预演器（已用于验证）
│   └── repack-boot.ps1             ← 本机：替换 kernel 段 → 重打包 →（可选）刷入
├── .github\workflows\
│   └── build-k9x-kernel.yml        ← GitHub Actions 定义
└── e2e\                            ← 端到端测试产物（可删）
```

---

## 三、操作步骤

### 步骤 1：把内核源码推到 GitHub

源码树不含 `.git`，且本机没装 git。你需要：

1. 安装 Git for Windows（或直接用 GitHub Desktop）
2. 在 `D:\k9x-build` 下执行：

```bash
git init
git add k9x-kernel scripts .github
git config core.quotepath false        # 中文路径不乱码
git commit -m "OPPO K9x kernel 4.19.191 + ReSukiSU integration"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> ⚠️ 仓库约 1.15 GB，首次推送较慢。GitHub 单仓库建议 < 1 GB，
> 若超限可开启 LFS 或只推送 `k9x-kernel` 的必要子集。
>
> 替代方案：把源码打成 zip 传到 Release，workflow 里改为下载解压。

### 步骤 2：运行云编译

- 进入仓库 → `Actions` → `Build K9x Kernel (ReSukiSU)` → `Run workflow`
- 参数：
  - `resukisu_ref`：默认 `main` 即可
- 预计耗时 **15–40 分钟**（4 核 runner）

编译成功后下载 artifact：`k9x-resukisu-<run_number>.zip`，
内含 `Image.gz`、`Image`、`dot.config`、`build.log`。

### 步骤 3：本机重打包

```powershell
# 解压 artifact，拿到 Image.gz 后：
& 'D:\k9x-build\scripts\repack-boot.ps1' -ImageGz 'D:\Downloads\k9x-resukisu-1\Image.gz'
```

脚本自动完成：
- 校验 gzip 魔数
- 备份原厂 boot.img 到 `scripts\backup\`（含 SHA256）
- 解包 → 解压 Image.gz 为 raw → 替换 kernel → repack
- 校验新镜像可被 magiskboot 解析
- 校验内核版本是 4.19.x（不匹配会要求二次确认）
- 输出 `boot-resukisu.img`

> **已在真机数据上端到端测试通过**（用原厂 kernel 做往返测试）：
> 输出 33,554,432 字节，header 字段与 RAMDISK/DTB 均保持不变。

### 步骤 4：刷入

```powershell
# 手机会先进入 fastboot 模式（关机后按住 音量下 + 电源键）
& 'D:\k9x-build\scripts\repack-boot.ps1' -ImageGz <Image.gz> -Flash
```

或手动：

```powershell
& 'D:\Downloads\platform-tools\fastboot.exe' flash boot 'D:\k9x-build\boot-resukisu.img'
& 'D:\Downloads\platform-tools\fastboot.exe' reboot
```

### 步骤 5：安装管理器

安装 BakaSU / ReSukiSU 的 Manager APK，打开后应显示 **"已工作 / Working"**。

验证：

```powershell
& 'D:\Downloads\platform-tools\adb.exe' shell uname -a
# 应显示 4.19.191
& 'D:\Downloads\platform-tools\adb.exe' shell su -c id
# 应返回 uid=0(root)
```

---

## 四、风险与回滚（重要）

### 刷入前必做

1. **确认备份存在**：`D:\k9x-build\scripts\backup\boot-original-*.img`
2. **确认备份 SHA256** 与 `855E040F6187B71ADFD5A846862CDFB1D95A5DB5F8D71920850BFD3C67926963` 一致
   （这是你机器上原厂 boot.img 的哈希）

### 回滚途径（按优先级）

```powershell
# 1. fastboot 可用
& 'D:\Downloads\platform-tools\fastboot.exe' flash boot '<备份路径>'

# 2. fastboot 不可用 → MTK BROM 模式（关机，按住音量下插 USB）
#    用 SP Flash Tool + D:\Downloads\MTK\mt6833\MTK_AllInOne_DA.bin
#    只勾选 boot 分区刷回

# 3. 都用不了 → D:\Downloads\gongju\oppok9x\oppo k9x字库ColorOs13.7z
#    这是完整字库（含 boot.img.zstd），可整机恢复
```

### 关于 AVB / dm-verity

原厂 boot.img 带 VBMETA。magiskboot repack 默认会重算 AVB 签名，
但使用 AOSP 通用密钥 —— **与你设备 vbmeta 中记录的验证密钥不匹配**。

如果设备启用了严格的 vbmeta 校验，可能出现：

- 开机时出现分区校验失败提示，但能继续启动（多数 MTK 机型）
- 或卡在 bootloader 无法继续

**若遇到卡 bootloader**，需额外刷入一个禁用了验证的 vbmeta：

```powershell
# 先导出 vbmeta（如已解锁可直接刷空 vbmeta 关闭校验）
& $fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
```

> 这一步需要你自备 `vbmeta.img`，可以从字库包中提取，或由原厂 boot.img 同批获取。
> 如果第一次刷入后能正常开机，就说明不需要这一步。

---

## 五、已验证事实清单

| 项 | 结论 | 依据 |
|---|---|---|
| 内核版本匹配 | ✅ 源码 4.19.191 = 设备 4.19.191 | `Makefile` vs boot.img 内核串 |
| 编译器匹配 | ✅ clang 11.0.1 (r383902) | boot.img 内核串含 `clang version 11.0.1` |
| defconfig | ✅ `k6833v1_64_k419_defconfig`（703 行，原无 KSU 条目） | 源码 `arch/arm64/configs/` |
| SELinux 符号导出 | ✅ 无需处理 | `CONFIG_KALLSYMS_ALL=y` 已开启 |
| hook 点存在 | ✅ 5 处全部匹配（唯一） | `fs/stat.c`、`fs/open.c`、`fs/exec.c`、`kernel/reboot.c` |
| 补丁幂等性 | ✅ 二次运行全部 SKIP | `simulate_patch.py` |
| 重打包流程 | ✅ 端到端通过 | `repack-boot.ps1` 实测 |
| 32 位支持 | ✅ arm64 有 `SYSCALL_DEFINE2(fstat64)` / `SYSCALL_DEFINE4(fstatat64)` | 源码实测，已一并 hook |

### 过程中修复的两个严重 bug（已记录在脚本注释里）

1. **`insert_before` 误用**：给 `do_execveat_common` 用"插入"语义，
   导致原函数保留 + 新函数体多出一份 → `}static int ...` 重复定义。
   改为 `replace_once` 整段替换。

2. **锚点吞掉前一个函数的 `}`**：`fs/stat.c` 中 `newfstatat` 紧跟 `fstatat`，
   没有空行分隔；锚点里写了 `\n\n` 导致匹配到前一个函数的收尾。
   改为连续行锚点 + 一次性整体替换。

---

## 六、已知限制

- **SUSFS 不可用**：非 GKI 内核，ReSukiSU 文档明确不支持。若需隐藏 root，走其他方案。
- **本机无法编译**：Pentium E5700 无 EPT → WSL2 装不了；4 GB 内存 + 剩余磁盘也不够。
  这就是走云编译的原因。
- **`D:\Downloads\gongju\oppok9x\kernel4.14.186+resukisuboot.img` 不要用**：
  内核 4.14.186，与本设备 4.19.191 不匹配，刷入必砖。
- **`D:\Downloads\gongju\KernelSU-patch\patch.bat` 不要用**：
  只处理 GKI 5.10+，`.ko` 是无法使用的占位文件，对 K9x 无效。
