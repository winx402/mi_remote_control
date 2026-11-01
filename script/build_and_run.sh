#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MODE="${1:-run}"
BUNDLE_ID="com.miremote.controller"
INSTALL_DIR="${MIREMOTE_INSTALL_DIR:-/Applications}"
STAGE_DIR=""

fail() {
    echo "错误：$*" >&2
    exit 1
}

case "$MODE" in
    run|--verify|--logs|--debug) ;;
    *) echo "用法：$0 [run|--verify|--logs|--debug]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || fail "一次只支持一个运行模式。"
case "$INSTALL_DIR" in
    /*) ;;
    *) fail "MIREMOTE_INSTALL_DIR 必须是绝对路径。" ;;
esac

verify_app() {
    local app="$1" details requirement
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "bundle id 不符：$app"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" = "miremote" ] || fail "可执行文件声明不符：$app"
    /usr/bin/codesign --verify --strict "$app"
    details="$(/usr/bin/codesign -dvv "$app" 2>&1)"
    printf '%s\n' "$details" | /usr/bin/grep -Fxq 'Authority=MiRemote Dev' || fail "签名不是 MiRemote Dev：$app"
    requirement="$(/usr/bin/codesign -d -r- "$app" 2>&1)"
    printf '%s\n' "$requirement" | /usr/bin/grep -q '^designated => .*certificate leaf' || fail "签名未锚定 certificate leaf：$app"
}

process_is_target() {
    local pid="$1" binary args app identifier
    binary="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null)" || return 1
    args="$(/bin/ps -ww -p "$pid" -o args= 2>/dev/null)" || return 1
    # 只读/一次性子命令不持有服务锁，不能为重启 GUI 中断它们。
    case " $args " in
        *' --self-test '*|*' --doctor '*|*' --help '*|*' -h '*|*' --list-audio-devices '*|*' --login-item '*|*' --claude-hooks '*|*' --run-action '*) return 1 ;;
    esac
    case "$binary" in
        */Contents/MacOS/miremote)
            app="${binary%/Contents/MacOS/miremote}"
            identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" || return 1
            [ "$identifier" = "$BUNDLE_ID" ] || return 1
            ;;
        "$ROOT_DIR/.build/miremote")
            # 只接管本仓库明确启用的 CLI 服务，其他检出目录不在此入口的边界内。
            case " $args " in
                *' --keys '*|*' --doubao '*|*' --verbose '*|*' --output '*|*' --wav '*|*' --no-input-switch '*) ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    # comm 的名字不足以证明身份，还需确认进程实际打开的代码路径。
    /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/grep -Fx "n$binary" >/dev/null
}

target_pids() {
    local pid binary
    while read -r pid binary; do
        case "$binary" in
            */Contents/MacOS/miremote|"$ROOT_DIR/.build/miremote")
                if process_is_target "$pid"; then printf '%s\n' "$pid"; fi
                ;;
        esac
    done < <(/bin/ps -ww -axo pid=,comm=)
}

stop_existing() {
    local pid remaining attempt
    for pid in $(target_pids); do
        # 在发信号前复核，避免对退出后复用的 PID 发送 TERM。
        if process_is_target "$pid"; then
            echo "-- 等待 MiRemote 清理并退出（PID $pid）"
            /bin/kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for ((attempt = 0; attempt < 40; attempt++)); do
        remaining="$(target_pids)"
        [ -n "$remaining" ] || return 0
        /bin/sleep 0.25
    done
    fail "MiRemote 在 10 秒内未退出（PID：$(echo "$remaining" | tr '\n' ' ')）。请正常退出后重试；旧安装未替换。"
}

cleanup_stage() {
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        # 失败时保留含文件的暂存目录，绝不递归删除未知内容。
        /bin/rmdir "$STAGE_DIR" 2>/dev/null || echo "-- 暂存文件保留于：$STAGE_DIR" >&2
    fi
}
trap cleanup_stage EXIT

cd "$ROOT_DIR"
# package.sh 缺固定证书就失败；此入口不提供 unsigned 通道。
./scripts/package.sh
verify_app "$ROOT_DIR/dist/MiRemote.app"

/bin/mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
INSTALLED_APP="$INSTALL_DIR/MiRemote.app"
INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/miremote"
[ ! -L "$INSTALLED_APP" ] || fail "拒绝替换符号链接：$INSTALLED_APP"
if [ -e "$INSTALLED_APP" ]; then
    [ -d "$INSTALLED_APP" ] || fail "安装目标不是 app 目录：$INSTALLED_APP"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "安装目标属于其他 bundle：$INSTALLED_APP"
fi

# 同一文件系统内暂存并验签，停服务前就暴露复制/权限错误。
STAGE_DIR="$(/usr/bin/mktemp -d "$INSTALL_DIR/.miremote-install.XXXXXX")"
/usr/bin/ditto "$ROOT_DIR/dist/MiRemote.app" "$STAGE_DIR/MiRemote.app"
verify_app "$STAGE_DIR/MiRemote.app"
stop_existing

BACKUP_DIR=""
if [ -e "$INSTALLED_APP" ]; then
    BACKUP_DIR="$(/usr/bin/mktemp -d "$INSTALL_DIR/.miremote-backup.XXXXXX")"
    /bin/mv "$INSTALLED_APP" "$BACKUP_DIR/MiRemote.app"
    echo "-- 旧安装备份：$BACKUP_DIR/MiRemote.app"
fi
if ! /bin/mv "$STAGE_DIR/MiRemote.app" "$INSTALLED_APP"; then
    if [ -n "$BACKUP_DIR" ]; then
        /bin/mv "$BACKUP_DIR/MiRemote.app" "$INSTALLED_APP" || fail "安装和恢复失败，旧版保留于：$BACKUP_DIR/MiRemote.app"
    fi
    fail "安装失败；已恢复旧安装（如有）。"
fi
cleanup_stage
STAGE_DIR=""
verify_app "$INSTALLED_APP"
echo "-- 已安装：$INSTALLED_APP"

if [ "$MODE" = "--debug" ]; then
    exec /usr/bin/lldb -- "$INSTALLED_BINARY"
fi

/usr/bin/open -n "$INSTALLED_APP"
case "$MODE" in
    --verify)
        # lsof 的文件参数按实际文件身份匹配，避免旧 inode 或同名进程误报。
        for ((attempt = 0; attempt < 40; attempt++)); do
            for pid in $(target_pids); do
                if /usr/sbin/lsof -a -p "$pid" -d txt "$INSTALLED_BINARY" >/dev/null 2>&1; then
                    /bin/sleep 1
                    if /usr/sbin/lsof -a -p "$pid" -d txt "$INSTALLED_BINARY" >/dev/null 2>&1; then
                        echo "-- 运行验证通过：PID ${pid}，${INSTALLED_BINARY}"
                        exit 0
                    fi
                fi
            done
            /bin/sleep 0.25
        done
        fail "未检测到持续运行的已安装二进制：$INSTALLED_BINARY"
        ;;
    --logs)
        exec /usr/bin/log stream --info --style compact --predicate 'process == "miremote"'
        ;;
esac
