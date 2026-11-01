# Fork 维护与 Codex 预设

本 fork 保留上游的应用名称、Bundle ID 和设备协议。新增统一构建安装入口、可重复应用的 Codex 场景，以及 SIGINT/SIGTERM 的正常清理路径。

## 本机构建与安装

首次按上游 `scripts/setup-signing.sh` 建立本机 `MiRemote Dev` 签名身份，然后运行：

```sh
./script/build_and_run.sh --verify
```

入口复用 `scripts/package.sh`，构建并验签成功后再停止旧进程，安装到 `/Applications/MiRemote.app` 并启动。已有安装会保存在同目录的 `.miremote-backup.*` 临时备份中。也支持 `--logs` 和 `--debug`；调试时使用已安装 bundle 内的二进制。Codex 的 Run action 已连接到该入口。

证书、私钥、钥匙串授权、macOS 隐私权限和设备记录只保留本机，不提交仓库。重建时保持同一签名身份与安装路径；权限状态仍应以系统设置和应用体检为准。

## 应用 Codex 场景

先从菜单退出 MiRemote，再执行：

```sh
python3 scripts/apply-codex-profile.py --dry-run
python3 scripts/apply-codex-profile.py
open /Applications/MiRemote.app
```

源预设是 `Resources/codex-profile.patch.json`。脚本保留其他应用、全局键位和设备设置，将动作作为完整值替换，避免遗留旧修饰键。已有配置会在本机配置目录的 `backups/` 中备份；新配置从当前二进制导出的完整默认配置生成，再合并预设。过旧的配置会要求先启动新版应用完成迁移，不会直接抬高版本号。

`--binary` 可指定其他构建产物，`--config` 可指定独立测试配置；两个纯 CLI 命令 `--print-default-config` / `--validate-config <path>` 不启动蓝牙或按键引擎。

### 使用方式

在其他应用短按 TV，切回 Codex；在 Codex 短按 TV，进入或退出 App 控制模式。TV 配置了双击，因此单击需要约 250ms 判定，等提示条出现后再按方向。

| 操作 | 效果 |
| --- | --- |
| 基础模式方向键、返回、OK | 光标导航、删除、Return |
| 控制模式左 / 右 | 上一个 / 下一个聊天或标签（Cmd+Option+Left/Right） |
| 控制模式上 / 下 | PageUp / PageDown；滚动目标取决于当前焦点 |
| 控制模式返回 / OK | Esc / Return，具体效果取决于焦点或确认框 |
| Codex 菜单短按 | 命令菜单（Cmd+Shift+P） |
| Codex 主页长按 | 新建聊天（Cmd+N） |
| Codex TV 双击 | 模型选择器（Control+Shift+M） |
| 音量 + / − | 基础和 Codex 控制模式中均调系统音量 |
| 电源长按 | 进入 / 退出方向键鼠标模式 |
| 菜单长按 1.5 秒 | 退出功能模式和浮层 |

鼠标模式优先于 App 控制模式；此时 OK 点击、菜单右击、返回退出鼠标模式。控制层空闲 20 秒自动返回基础层。默认窗口控制和 TV 长按 App 轮盘继续保留。

快捷键依据 [OpenAI Commands](https://learn.chatgpt.com/docs/reference/commands)。应用名称可能显示 ChatGPT，Codex 场景仍绑定 `com.openai.codex`。同一个进程的其他工作模式也共用该标识；使用 ChatGPT/Work 时可以用 TV 退出遥控器控制层。

### 验证与边界

```sh
.build/miremote --self-test
git diff --check
bash -n script/build_and_run.sh
```

自检只验证逻辑。真实按键应先在独立空白文档中测试 Return、删除、鼠标模式，再在 Codex 测试命令菜单和模型选择；不要在含有待发送文字的聊天输入框测试 Return。“识别按键”页仍会执行映射，不是隔离测试环境。

上游仍有设备来源过滤限制：全局事件 tap 会把真实键盘的 F13–F20、小键盘 Clear、除号和乘号当成中转输入。使用这些键时应完全退出 MiRemote；暂停只卸载设备映射，不能完全避开该限制。安全输入期间遥控器方向键也可能不能正常工作。语音是独立的可选配置，按键控制不依赖 BlackHole 或输入法。

## 同步上游

`origin` 指向个人 fork，`upstream` 指向原项目。在干净工作区中拉取上游并审查差异，再选择合并或变基；存在本地改动时先保留，不覆盖配置。

```sh
git fetch upstream
git log --oneline --left-right HEAD...upstream/main
git diff HEAD...upstream/main
```

合并后重新构建、自检并检查真实按键。只推送源码、预设和通用开发入口；本机配置、日志、证书与设备数据保持在仓库外或忽略目录内。
