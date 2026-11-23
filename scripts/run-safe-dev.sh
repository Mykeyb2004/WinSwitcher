#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT_DIR}/build/WinSwitcher.app"
TIMEOUT_SECONDS="${1:-120}"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "WinSwitcher.app 未找到，正在构建..."
    "${ROOT_DIR}/scripts/build-app.sh" release
fi

echo "==> 以安全调试模式启动 WinSwitcher.app"
echo "    • 紧急强制退出热键：Ctrl + Option + Command + Esc"
echo "    • 看门狗保护：${TIMEOUT_SECONDS} 秒后若未按 Ctrl+C 取消，将自动终止 WinSwitcher"
echo ""

open "${APP_BUNDLE}"

(
    sleep "${TIMEOUT_SECONDS}"
    if pgrep -x WinSwitcher >/dev/null 2>&1; then
        echo ""
        echo "[Watchdog] 已到达 ${TIMEOUT_SECONDS} 秒保护时间，正在自动退出 WinSwitcher..."
        pkill -9 -x WinSwitcher || true
    fi
) &
WATCHDOG_PID=$!

trap 'kill "${WATCHDOG_PID}" 2>/dev/null || true; echo "已取消看门狗自动退出（WinSwitcher 将继续运行）。"; exit 0' INT TERM

echo "按 Ctrl+C 可解除本次看门狗定时退出并让 WinSwitcher 保持常驻..."
wait "${WATCHDOG_PID}"
