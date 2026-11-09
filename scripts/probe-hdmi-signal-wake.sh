#!/bin/bash
# Observe whether this TV wakes when macOS restores its display output.
# This requests display sleep/wake, not HDMI-CEC, HPD, or a physical cable reset.
set -euo pipefail

run=false
standby_first=false
for argument in "$@"; do
    case "$argument" in
        --run) run=true ;;
        --standby-first) standby_first=true ;;
        --help|-h)
            echo '用法：probe-hdmi-signal-wake.sh [--run] [--standby-first]'
            echo '默认只预览；--run 请求 Mac 显示器熄屏 5 秒，再自动恢复。'
            echo '--standby-first 先通过已安装 MiRemote 请求电视待机。'
            echo 'Mac 保持运行，不修改持久电源设置；电视是否亮屏须人工观察。'
            exit 0 ;;
        *) echo "未知参数：$argument" >&2; exit 2 ;;
    esac
done

if ! "$run"; then
    if "$standby_first"; then echo '预览：请求已配置的小米电视待机，等待 5 秒。'; fi
    echo '预览：临时保持 Mac 运行，先安排 5 秒后的显示唤醒，再请求显示器熄屏。'
    echo '尚未执行；添加 --run 开始。'
    exit 0
fi

[[ "$(/usr/bin/uname -s)" == Darwin ]] || { echo '此测试仅支持 macOS。' >&2; exit 2; }

keep_awake_pid=''
restore_pid=''
needs_restore=false
cleanup() {
    trap - EXIT HUP INT TERM
    # Restore before cancelling the backup job, including an interrupted test.
    if "$needs_restore"; then /usr/bin/caffeinate -u -t 2 >/dev/null 2>&1 & fi
    if [[ -n "$restore_pid" ]]; then
        kill "$restore_pid" 2>/dev/null || true
        wait "$restore_pid" 2>/dev/null || true
    fi
    if [[ -n "$keep_awake_pid" ]]; then
        kill "$keep_awake_pid" 2>/dev/null || true
        wait "$keep_awake_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# -i/-s keep the Mac running, while deliberately allowing display sleep.
/usr/bin/caffeinate -i -s -t 45 >/dev/null 2>&1 &
keep_awake_pid=$!

if "$standby_first"; then
    binary='/Applications/MiRemote.app/Contents/MacOS/miremote'
    [[ -x "$binary" ]] || { echo '未找到已安装的 MiRemote。' >&2; exit 1; }
    echo '请求电视待机；回执不等同于电视已经黑屏。'
    "$binary" --tv standby
    /bin/sleep 5
fi

echo '先安排显示恢复，再请求 Mac 显示器熄屏 5 秒。'
needs_restore=true
(
    /bin/sleep 5
    /usr/bin/caffeinate -u -t 3
) &
restore_pid=$!
/usr/bin/pmset displaysleepnow
wait "$restore_pid"
restore_pid=''
needs_restore=false
echo 'Mac 显示唤醒请求已完成；这不代表电视已开机，请记录实际画面。'
