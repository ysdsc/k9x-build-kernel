#!/usr/bin/env bash
# OPPO K9x (MT6833) 内核云编译 —— 同时产出 BakaSU 与 HyperSU 两个版本
#
# 在 GitHub Actions (ubuntu-22.04) 上执行, 也可在任意 Linux 本机手动跑。
#
# ============================ 关键事实 (已核对) ============================
#   * 内核源码来自 OPPO 官方开源仓库:
#       https://github.com/oppo-source/android_kernel_oppo_mt6833
#       分支: oppo/mt6833_t_13.0_a55_a53s_k9x_5g
#       commit: a4ec4ac5070eaabbfc185f769dab1f26d3825000 (Linux 4.19.191)
#     该 commit 与本机 zip 内注释一致, 且与设备 boot.img 的内核版本串吻合。
#     因此本仓库**不需要存放内核源码**, 现场 clone 即可 —— 仓库仅几十 KB。
#   * https://github.com/ReSukiSU/ReSukiSU 现重定向到 Baka-SU/BakaSU
#   * HyperSU (HyperSU-Team/HyperSU) 的 kernel/Kconfig 与 BakaSU 等价,
#     提供同名同签名的 ksu_handle_* 函数 —— 同一套 hook 补丁对两者适用。
#   * hook 方式是 Kconfig choice, 默认 KSU_TRACEPOINT_HOOK(仅 GKI 5.10+),
#     非 GKI 必须显式 CONFIG_KSU_MANUAL_HOOK=y。
#   * CONFIG_KSU_SUSFS 在非 GKI 内核上必须关闭。
#
# ============================ 产出命名规则 ============================
#   k9x-resukisu-<commit>-4.19.191-<stamp>.zip   ← BakaSU / ReSukiSU 版
#   k9x-hypersu-<commit>-4.19.191-<stamp>.zip    ← HyperSU 版
#
# 环境变量:
#   WORK_DIR        工作根目录 (默认 $PWD/work)
#   KERNEL_DIR      内核源码目录 (默认 $WORK_DIR/k9x-kernel)
#   OUT_BASE        输出根目录   (默认 $PWD/out)
#   JOBS            并行数       (默认 nproc)
#   CLANG_DIR       clang-r383902 根目录 (应含 bin/clang)
#   BUILD_VARIANTS  要编译的方案 (默认 "bakasu hypersu")
#   SKIP_CLONE      设为 1 则跳过 clone (本机已备好源码时用)
#
set -euo pipefail

WORK_DIR="${WORK_DIR:-$PWD/work}"
KERNEL_DIR="${KERNEL_DIR:-$WORK_DIR/k9x-kernel}"
OUT_BASE="${OUT_BASE:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"
CLANG_DIR="${CLANG_DIR:-$PWD/clang-r383902}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_VARIANTS="${BUILD_VARIANTS:-bakasu hypersu}"
SKIP_CLONE="${SKIP_CLONE:-0}"

KERNEL_REPO="https://github.com/oppo-source/android_kernel_oppo_mt6833"
KERNEL_BRANCH="oppo/mt6833_t_13.0_a55_a53s_k9x_5g"
KERNEL_COMMIT="a4ec4ac5070eaabbfc185f769dab1f26d3825000"
# 模块仓库: 提供 vendor/oplus/** (主仓库的符号链接目标)
MODULES_REPO="https://github.com/oppo-source/android_kernel_modules_oppo_mt6833"
MODULES_BRANCH="oppo/mt6833_t_13.0_a55_a53s_k9x_5g"
DEFCONFIG=k6833v1_64_k419_defconfig

banner() { printf '\n\033[1;44;37m %s \033[0m\n' "$*"; }
die()    { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

resolve_repo() {
  case "$1" in
    bakasu)  echo "https://github.com/Baka-SU/BakaSU|resukisu" ;;
    hypersu) echo "https://github.com/HyperSU-Team/HyperSU|hypersu" ;;
    *) die "未知方案: $1 (可选: bakasu hypersu)" ;;
  esac
}

banner "0. 环境自检"
[ -x "$CLANG_DIR/bin/clang" ] || die "找不到 clang: $CLANG_DIR/bin/clang"
"$CLANG_DIR/bin/clang" --version | head -1
for t in make bison flex bc git python3 zip; do
  command -v "$t" >/dev/null || die "缺少构建依赖: $t"
done
echo "工作目录   : $WORK_DIR"
echo "内核目录   : $KERNEL_DIR"
echo "输出根目录 : $OUT_BASE"
echo "并行数     : $JOBS"
echo "编译方案   : $BUILD_VARIANTS"

# ---------------------------------------------------------------------------
# 1. 获取内核源码
# ---------------------------------------------------------------------------
if [ "$SKIP_CLONE" = "1" ] && [ -d "$KERNEL_DIR" ]; then
  banner "1. 使用现有内核源码 (SKIP_CLONE=1)"
  echo "   $KERNEL_DIR"
else
  banner "1. 从 OPPO 官方仓库 clone 内核源码"
  echo "   repo   : $KERNEL_REPO"
  echo "   branch : $KERNEL_BRANCH"
  echo "   commit : $KERNEL_COMMIT"

  mkdir -p "$WORK_DIR"
  rm -rf "$KERNEL_DIR"

  # --depth 1 只取需要的分支, 避免下载整个 2.4 GB 仓库历史
  # 不再用 2>/dev/null 吞掉错误 —— clone 失败时必须看到原因
  echo "-> 浅克隆主分支 (预计 280 MB)"
  set +e
  git clone --depth=1 --single-branch --branch "$KERNEL_BRANCH" \
      --progress "$KERNEL_REPO" "$KERNEL_DIR"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "   分支克隆失败 (exit=$rc), 改为按 commit 克隆"
    rm -rf "$KERNEL_DIR"
    mkdir -p "$KERNEL_DIR"
    git -C "$KERNEL_DIR" init -q
    git -C "$KERNEL_DIR" remote add origin "$KERNEL_REPO"
    set +e
    git -C "$KERNEL_DIR" fetch --depth=1 --progress origin "$KERNEL_COMMIT"
    rc2=$?
    set -e
    [ $rc2 -eq 0 ] || die "无法获取内核源码 (分支和 commit 两种方式都失败, exit=$rc/$rc2)"
    git -C "$KERNEL_DIR" checkout -q FETCH_HEAD
  else
    echo "   分支克隆成功"
  fi

  local_head="$(git -C "$KERNEL_DIR" rev-parse HEAD)"
  echo "   实际 HEAD: $local_head"
  if [ "$local_head" != "$KERNEL_COMMIT" ]; then
    echo "   警告: HEAD 与预期 commit 不同 (分支可能已更新), 继续"
  fi
  # 校验确实是 4.19.191
  grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) ' "$KERNEL_DIR/Makefile" | tr '\n' ' '
  echo
fi

# ---------------------------------------------------------------------------
# 2. 补上 vendor/oplus —— 主仓库里的符号链接目标, 位于独立仓库
#    OPPO 把内核拆成两个仓库发布:
#      android_kernel_oppo_mt6833          内核主代码 (含指向 vendor 的符号链接)
#      android_kernel_modules_oppo_mt6833  vendor/oplus/** 全部专有驱动
#    缺少模块仓库时, init/Kconfig source "kernel/sched_assist/Kconfig" 会直接失败
#    (该路径是指向 vendor/oplus/kernel/oplus_performance/sched_assist 的软链)。
# ---------------------------------------------------------------------------
if [ ! -e "$KERNEL_DIR/vendor/oplus/kernel" ]; then
  banner "2. 补上 vendor/oplus (模块仓库)"
  echo "   repo   : $MODULES_REPO"
  echo "   branch : $MODULES_BRANCH"
  MOD_TMP="$WORK_DIR/_modules"
  rm -rf "$MOD_TMP"
  if ! git clone --depth=1 --single-branch --branch "$MODULES_BRANCH" \
        "$MODULES_REPO" "$MOD_TMP" 2>/dev/null; then
    echo "   分支克隆失败, 尝试默认分支"
    rm -rf "$MOD_TMP"
    git clone --depth=1 "$MODULES_REPO" "$MOD_TMP" \
      || die "无法获取模块仓库 $MODULES_REPO"
  fi
  # 模块仓库根目录即 vendor/, 直接放到内核树根
  if [ -d "$MOD_TMP/vendor" ]; then
    mv "$MOD_TMP/vendor" "$KERNEL_DIR/vendor"
  else
    mkdir -p "$KERNEL_DIR/vendor"
    cp -a "$MOD_TMP/." "$KERNEL_DIR/vendor/"
  fi
  rm -rf "$MOD_TMP"
  echo "   vendor/ 已放置"
else
  banner "2. vendor/oplus 已存在, 跳过"
fi

# 验证关键符号链接目标是否就位
for p in vendor/oplus/kernel/oplus_performance/sched_assist/Kconfig \
         vendor/oplus/kernel/oplus_performance/klockopt/Kconfig; do
  if [ -e "$KERNEL_DIR/$p" ]; then
    echo "   OK   $p"
  else
    echo "   FAIL $p 不存在 —— 编译会在 Kconfig 阶段失败"
    die "vendor 不完整"
  fi
done

[ -d "$KERNEL_DIR" ] || die "内核源码目录不存在: $KERNEL_DIR"
[ -f "$KERNEL_DIR/Makefile" ] || die "内核源码不完整: 缺少 Makefile"
[ -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ] || die "缺少 defconfig: $DEFCONFIG"

# ---------------------------------------------------------------------------
# 工具链环境
# ---------------------------------------------------------------------------
export PATH="$CLANG_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER="k9x"
export KBUILD_BUILD_HOST="dsh"
export KBUILD_BUILD_VERSION="1"

mkdir -p "$OUT_BASE" dist
STAMP="$(date +%Y%m%d-%H%M)"

# ---------------------------------------------------------------------------
# 单方案编译
# ---------------------------------------------------------------------------
build_one() {
  local variant="$1" repo="$2" tag="$3"
  local out="$OUT_BASE/$variant"

  banner "===== 开始编译 $variant ($tag) ====="
  cd "$KERNEL_DIR"

  # --- 还原被上一轮修改过的源码, 保证两轮互不污染 ---
  echo "-> 还原源码到基线"
  if [ -d .resukisu-backup ]; then
    cp -a .resukisu-backup/fs/exec.c        fs/exec.c
    cp -a .resukisu-backup/fs/stat.c        fs/stat.c
    cp -a .resukisu-backup/fs/open.c        fs/open.c
    cp -a .resukisu-backup/kernel/reboot.c  kernel/reboot.c
    cp -a .resukisu-backup/Kconfig          Kconfig
    rm -rf .resukisu-backup
  fi
  rm -rf KernelSU
  [ -L drivers/kernelsu ] && rm -f drivers/kernelsu
  sed -i '/kernelsu/d' drivers/Makefile
  sed -i '/drivers\/kernelsu\/Kconfig/d' drivers/Kconfig
  sed -i '/# K9X-ROOT -- begin/,/# K9X-ROOT -- end/d' "arch/arm64/configs/$DEFCONFIG"
  sed -i '/# ReSukiSU -- begin/,/# ReSukiSU -- end/d' "arch/arm64/configs/$DEFCONFIG"

  grep -q 'kernelsu' drivers/Makefile && die "drivers/Makefile 未清理干净"
  grep -q 'CONFIG_KSU=y' "arch/arm64/configs/$DEFCONFIG" && die "defconfig 未清理干净"
  echo "   源码已回到基线"

  # --- 备份将被修改的文件 ---
  mkdir -p .resukisu-backup/fs .resukisu-backup/kernel
  cp -a fs/exec.c        .resukisu-backup/fs/exec.c
  cp -a fs/stat.c        .resukisu-backup/fs/stat.c
  cp -a fs/open.c        .resukisu-backup/fs/open.c
  cp -a kernel/reboot.c  .resukisu-backup/kernel/reboot.c
  cp -a Kconfig          .resukisu-backup/Kconfig

  # --- 拉取方案仓库 ---
  echo "-> 拉取 $repo"
  git clone --depth=1 "$repo" KernelSU
  local head
  head="$(git -C KernelSU rev-parse --short HEAD)"
  echo "   HEAD: $head"
  [ -f KernelSU/kernel/Kconfig ]   || die "$tag: 缺少 KernelSU/kernel/Kconfig"
  [ -f KernelSU/kernel/setup.sh ]  || die "$tag: 缺少 KernelSU/kernel/setup.sh"

  # --- 上游 setup.sh 接入驱动 ---
  echo "-> 运行 setup.sh"
  sh KernelSU/kernel/setup.sh main >/dev/null 2>&1 || \
    sh KernelSU/kernel/setup.sh >/dev/null 2>&1 || true
  [ -L drivers/kernelsu ] || die "$tag: drivers/kernelsu 软链建立失败"
  grep -q 'kernelsu' drivers/Makefile || die "$tag: drivers/Makefile 修改失败"
  grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || die "$tag: drivers/Kconfig 修改失败"
  echo "   接入完成"

  # --- 注入 4.19 手动 hook ---
  echo "-> 注入 4.19 手动 hook"
  bash "$SCRIPT_DIR/apply-resukisu-shim.sh" "$KERNEL_DIR"

  # --- 追加 defconfig ---
  echo "-> 追加 defconfig"
  bash "$SCRIPT_DIR/apply-defconfig.sh" "$KERNEL_DIR" "$variant"

  # --- 生成 .config 并校验 ---
  rm -rf "$out"; mkdir -p "$out"
  echo "-> 生成 .config"
  if ! make -C "$KERNEL_DIR" O="$out" ARCH=arm64 LLVM=1 LLVM_IAS=1 "$DEFCONFIG" \
        > "$out/config.log" 2>&1; then
    echo
    echo "########## .config 生成失败, config.log 全文 ##########"
    cat "$out/config.log"
    echo "######################################################"
    echo "---- drivers/Kconfig 中的 kernelsu ----"
    grep -n 'kernelsu' drivers/Kconfig || echo "(无)"
    echo "---- drivers/Makefile 中的 kernelsu ----"
    grep -n 'kernelsu' drivers/Makefile || echo "(无)"
    echo "---- 顶层 Kconfig 尾部 10 行 ----"
    tail -10 Kconfig
    die "$tag: .config 生成失败"
  fi

  local miss=0
  for cfg in CONFIG_KSU CONFIG_KSU_MANUAL_HOOK CONFIG_KALLSYMS_ALL; do
    if grep -q "^${cfg}=y" "$out/.config"; then
      echo "   OK   $cfg=y"
    else
      echo "   MISS $cfg"; miss=1
    fi
  done
  grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y' "$out/.config" && \
    die "$tag: 选中的是 TRACEPOINT_HOOK, 4.19 非 GKI 不支持"
  grep -q '^CONFIG_KSU_SUSFS=y' "$out/.config" && \
    die "$tag: CONFIG_KSU_SUSFS 不应在非 GKI 启用"
  [ "$miss" -eq 0 ] || die "$tag: 关键 Kconfig 未生效"

  # --- 编译 ---
  echo "-> 编译中"
  make -C "$KERNEL_DIR" O="$out" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
       -j"$JOBS" Image.gz 2>&1 | tee "$out/build.log" || die "$tag: 编译失败"

  local img="$out/arch/arm64/boot/Image.gz"
  [ -f "$img" ] || die "$tag: 未生成 Image.gz"

  # --- 打包 ---
  local pkg="k9x-$tag-${head}-4.19.191-$STAMP"
  local cnt
  cnt="$(stat -c%s "$img")"
  mkdir -p "dist/$pkg"
  cp "$img" "dist/$pkg/Image.gz"
  cp "$out/arch/arm64/boot/Image" "dist/$pkg/Image" 2>/dev/null || true
  cp "arch/arm64/configs/$DEFCONFIG" "dist/$pkg/$DEFCONFIG.patched"
  cp "$out/.config" "dist/$pkg/dot.config"

  local other="hypersu"
  [ "$variant" = "hypersu" ] && other="resukisu"

  cat > "dist/$pkg/README.txt" <<EOF
========================================================
 OPPO K9x 内核 —— $tag 版
========================================================
本包标识  : variant=$variant / tag=$tag / commit=$head
内核源码  : $KERNEL_REPO
            $KERNEL_BRANCH @ $KERNEL_COMMIT (Linux 4.19.191)
Root 方案 : $tag  ($repo @ $head)
编译器    : clang-r383902 (clang 11.0.1, 与设备原厂一致)
defconfig : $DEFCONFIG
hook 方式 : CONFIG_KSU_MANUAL_HOOK (非 GKI 4.19)
构建时间  : $STAMP
Image.gz  : $cnt 字节

>>> 另一方案的包名以 "k9x-$other-" 开头, 请勿混淆 <<<

刷入步骤:
 1. 备份原厂 boot.img
    (原厂 boot.img SHA256 =
     855E040F6187B71ADFD5A846862CDFB1D95A5DB5F8D71920850BFD3C67926963)
 2. magiskboot unpack boot.img
 3. 用本包 Image.gz 覆盖 kernel 段(需先解压为 raw)
 4. magiskboot repack boot.img new-boot.img
 5. fastboot flash boot new-boot.img
 6. 安装 "$tag" 对应的 Manager APK 验证

回滚: fastboot flash boot <原厂 boot.img 备份>
EOF

  ( cd dist && zip -rq "$pkg.zip" "$pkg" )
  echo "-> 产物: dist/$pkg.zip ($(stat -c%s "dist/$pkg.zip") 字节)"
  cd - >/dev/null
}

banner "开始编译 (方案: $BUILD_VARIANTS)"
for variant in $BUILD_VARIANTS; do
  IFS='|' read -r repo tag <<< "$(resolve_repo "$variant")"
  build_one "$variant" "$repo" "$tag"
done

banner "全部完成"
ls -la dist/