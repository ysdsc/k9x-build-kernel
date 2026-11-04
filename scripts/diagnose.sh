#!/usr/bin/env bash
# 最小复现：只做 clone，验证到底卡在哪一步
# 在 GitHub Actions 上运行，把每一步的结果写入 step-status.log
set -uo pipefail

LOG="${1:-step-status.log}"
: > "$LOG"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

KERNEL_REPO="https://github.com/oppo-source/android_kernel_oppo_mt6833"
KERNEL_BRANCH="oppo/mt6833_t_13.0_a55_a53s_k9x_5g"
MODULES_REPO="https://github.com/oppo-source/android_kernel_modules_oppo_mt6833"
MODULES_BRANCH="oppo/mt6833_t_13.0_a55_a53s_k9x_5g"

log "=== 环境 ==="
log "PWD=$(pwd)"
log "git=$(git --version 2>&1)"
log "python3=$(python3 --version 2>&1)"
log "df: $(df -h . | tail -1)"

log "=== A. clone 内核主仓库 (depth=1, 单分支) ==="
rm -rf work-test
if git clone --depth=1 --single-branch --branch "$KERNEL_BRANCH" \
     --progress "$KERNEL_REPO" work-test >>"$LOG" 2>&1; then
  log "A1 分支 clone: 成功"
else
  log "A1 分支 clone: 失败 (exit=$?)"
fi
if [ -d work-test/.git ]; then
  log "A2 HEAD=$(git -C work-test rev-parse HEAD 2>&1)"
  log "A3 文件数=$(find work-test -type f 2>/dev/null | wc -l)"
  log "A4 大小=$(du -sm work-test 2>/dev/null | cut -f1) MB"
  log "A5 kernel/sched_assist 类型=$( if [ -L work-test/kernel/sched_assist ]; then echo "symlink -> $(readlink work-test/kernel/sched_assist)"; elif [ -f work-test/kernel/sched_assist ]; then echo "普通文件($(stat -c%s work-test/kernel/sched_assist) 字节)"; elif [ -d work-test/kernel/sched_assist ]; then echo 目录; else echo 缺失; fi )"
  log "A6 vendor/ 存在=$([ -d work-test/vendor ] && echo yes || echo no)"
else
  log "A2 work-test 目录不存在"
fi

log "=== B. clone 模块仓库 ==="
rm -rf mod-test
if git clone --depth=1 --single-branch --branch "$MODULES_BRANCH" \
     --progress "$MODULES_REPO" mod-test >>"$LOG" 2>&1; then
  log "B1 clone: 成功"
else
  log "B1 clone: 失败 (exit=$?)"
fi
if [ -d mod-test ]; then
  log "B2 顶层内容: $(ls mod-test 2>&1 | tr '\n' ' ')"
  log "B3 vendor 存在=$([ -d mod-test/vendor ] && echo yes || echo no)"
  log "B4 sched_assist/Kconfig=$([ -f mod-test/vendor/oplus/kernel/oplus_performance/sched_assist/Kconfig ] && echo yes || echo no)"
fi

log "=== C. 放置 vendor 并检查软链 ==="
if [ -d mod-test/vendor ] && [ -d work-test ]; then
  mv mod-test/vendor work-test/vendor
  log "C1 vendor 已移动"
  link=work-test/kernel/sched_assist
  log "C2 移动后 sched_assist 类型=$( if [ -L "$link" ]; then echo "symlink"; elif [ -f "$link" ]; then echo "普通文件"; elif [ -d "$link" ]; then echo 目录; else echo 缺失; fi )"
  log "C3 移动后是否可访问 Kconfig=$([ -f "$link/Kconfig" ] && echo yes || echo no)"
  log "C4 init/Kconfig:740 内容=$(sed -n '740p' work-test/init/Kconfig 2>&1)"
fi

log "=== D. 尝试生成 .config ==="
mkdir -p out-test
if make -C work-test O="$PWD/out-test" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     k6833v1_64_k419_defconfig > config-test.log 2>&1; then
  log "D1 defconfig: 成功"
  log "D2 CONFIG_KSU=$(grep -E '^CONFIG_KSU=' out-test/.config 2>/dev/null || echo 未找到)"
else
  log "D1 defconfig: 失败"
  log "D2 错误:"
  grep -E 'error|can.t open|Error' config-test.log 2>/dev/null | head -20 | while read -r l; do log "    $l"; done
fi

log "=== 结束 ==="
exit 0
