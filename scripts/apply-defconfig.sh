#!/usr/bin/env bash
# 为 K9x 的 k6833v1_64_k419_defconfig 追加内核 root 所需配置项
# 用法: ./apply-defconfig.sh <kernel_dir> [variant]
#
# 说明:
#   - 驱动的 Kconfig 由上游 setup.sh 挂到 drivers/kernelsu/Kconfig,
#     因此只要 CONFIG_KSU 出现在 arch/arm64/configs/<defconfig> 即可生效。
#   - BakaSU 与 HyperSU 的 Kconfig 等价, 本节配置对两者通用。
#   - 标记统一用 "# K9X-ROOT -- begin/end", 便于多方案编译时精确回滚。
#   - 幂等: 已存在则跳过。
set -euo pipefail

KROOT="${1:?用法: $0 <kernel_dir> [variant]}"
VARIANT="${2:-bakasu}"
DEFCONFIG="$KROOT/arch/arm64/configs/k6833v1_64_k419_defconfig"

log() { printf '\033[1;35m[defconfig]\033[0m %s\n' "$*"; }

[ -f "$DEFCONFIG" ] || { echo "找不到 defconfig: $DEFCONFIG" >&2; exit 1; }

# 先清除可能残留的旧标记块(保证多方案切换时干净)
python3 - "$DEFCONFIG" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
s2 = re.sub(r'\n# K9X-ROOT -- begin.*?# K9X-ROOT -- end\n', '\n', s, flags=re.S)
if s2 != s:
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s2)
    print("  已清除旧的 K9X-ROOT 配置块")
PY

if grep -qE '^CONFIG_KSU=y' "$DEFCONFIG"; then
  log "跳过: CONFIG_KSU 已存在"
else
  cat >> "$DEFCONFIG" <<EOF

# K9X-ROOT -- begin ($VARIANT)
# K9x (MT6833 / Linux 4.19.191, 非 GKI): 必须用 MANUAL_HOOK 注入内核 hook
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# 4.19 上 setuid / sys_read / input 三类 hook 由 AUTO_* 在 LSM 层自动完成
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
# SUSFS 不支持非 GKI 内核, 切勿开启:
# CONFIG_KSU_SUSFS is not set
# K9X-ROOT -- end
EOF
  log "已追加 CONFIG_KSU / CONFIG_KSU_MANUAL_HOOK ($VARIANT) 到 defconfig"
fi

log "--- 追加后确认 ---"
grep -nE 'KSU|SUSFS|K9X-ROOT' "$DEFCONFIG" || true
