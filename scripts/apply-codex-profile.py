#!/usr/bin/env python3
"""离线合并 Codex 预设；保留其他配置，验证成功后原子写入。"""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile


def merge(target, patch):
    for key, value in patch.items():
        # 动作是一个完整值：跨动作递归会把旧 mods/steps 等残留到新动作。
        if isinstance(value, dict) and "type" not in value and isinstance(target.get(key), dict):
            merge(target[key], value)
        else:
            target[key] = copy.deepcopy(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / "Library/Application Support/MiRemote/config.json")
    parser.add_argument("--binary", type=Path, default=Path("/Applications/MiRemote.app/Contents/MacOS/miremote"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if subprocess.run(["/usr/bin/pgrep", "-x", "miremote"], stdout=subprocess.DEVNULL).returncode == 0:
        parser.error("请先退出 MiRemote，避免运行中的 App 覆盖配置。")
    if not args.binary.is_file():
        parser.error("请先构建或安装 MiRemote，或用 --binary 指定构建产物。")

    original = args.config.read_bytes() if args.config.exists() else None
    default_json = subprocess.check_output([str(args.binary), "--print-default-config"])
    default_config = json.loads(default_json)
    original_json = default_json if original is None else original
    config = json.loads(original_json)
    if config.get("version", 0) < default_config["version"]:
        parser.error("现有配置版本较旧，请先运行新版 MiRemote 完成迁移，再退出并应用预设。")
    if not isinstance(config.get("profiles", {}).get("global"), dict):
        parser.error("现有配置没有 global 场景，停止操作以保留原文件。")
    patch_path = Path(__file__).resolve().parent.parent / "Resources/codex-profile.patch.json"
    merge(config, json.loads(patch_path.read_text()))
    config.setdefault("settings", {})["doubleMs"] = 250
    payload = (json.dumps(config, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()

    args.config.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=args.config.parent, prefix=".codex-profile-", suffix=".json", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(payload)
        subprocess.run([str(args.binary), "--validate-config", str(temporary)], check=True)
        if args.dry_run:
            print("预览通过：只合并全局 TV 键、Codex 场景和双击间隔，不写入配置。")
            return
        if original == payload:
            print("Codex 预设已应用，无需修改。")
            return
        if original is not None:
            backup_dir = args.config.parent / "backups"
            backup_dir.mkdir(exist_ok=True)
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            backup = backup_dir / f"config-before-codex-{stamp}.json"
            with backup.open("xb") as handle:
                handle.write(original)
            backup.chmod(0o600)
            print(f"旧配置备份：{backup}")
        os.replace(temporary, args.config)
        temporary = None
        print(f"Codex 预设已保存：{args.config}")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
