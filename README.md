# Backseat

AI 在驾驶座写代码，你坐在后座指挥。Backseat 把 iPhone 和 Apple Watch 变成 Mac 上 AI 编程助手（Claude Code、Codex 等）的遥控器：

- **按住说话**：手机 / 手表当麦克风，Mac 上的语音输入法识别，文字直接进输入框。
- **触控板**：手机屏幕就是 Mac 触控板，单指指针、双指滚动和缩放、三指四指手势。
- **审批和进度**：Claude Code 需要权限时推到手机 / 手表上点允许；任务完成有震动提醒。
- **不开 App 也能说**：手机侧键、控制中心、锁屏按钮、手表侧键一按就录，灵动岛显示状态。
- **灵感收件箱**：连不上 Mac 时先存在手机上，连上后再发。

```
iPhone / Apple Watch ──局域网（配对后 token 鉴权）──► Mac 上的 Backseat ──► 键盘、鼠标、语音输入到前台 App
                                                          ▲
                                      Claude Code hooks ──┘（完成 / 等待输入 / 权限审批）
```

## 需要什么

- Mac：macOS 26 或更新。不需要安装任何第三方软件或音频驱动。
- Apple Watch（watchOS 11+）和 / 或 iPhone（iOS 18+），和 Mac 在同一个局域网。
- 目前手表和手机 App 需要自己用 Xcode 编译安装。

## 安装

**1. Mac 端**

```bash
bash scripts/start.sh
```

菜单栏会出现一个手表图标。第一次启动会自动完成配置：生成 token、把 Claude Code hooks 注册进 `~/.claude/settings.json`（原文件会先备份成 `settings.json.bak-backseat-*`）。

想要一个不依赖终端、可以登录时自动启动的 App：

```bash
bash scripts/build-app.sh
```

生成 `build/Backseat.app`，拖进「应用程序」后打开。

第一次启动会弹「辅助功能」授权：系统设置 → 隐私与安全性 → 辅助功能，打开 Backseat（用 `start.sh` 启动时是运行它的终端 App）。没有这个权限，手表发出的文字和按键无法输入到 Mac，提醒和审批不受影响。如果系统防火墙询问是否允许接收连接，选**允许**。

**2. 手表 / 手机 App**

```bash
bash scripts/setup.sh
```

这一步把你的 Apple 开发者团队写进 `apps/Config.local.xcconfig`，并用 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）生成 `apps/Backseat.xcodeproj`。打开它，运行目标选 iPhone（`Backseat`）或 Apple Watch（`BackseatWatch`），按 ⌘R。手表需要先打开开发者模式（设置 → 隐私与安全性 → 开发者模式）。

**3. 配对**

第一次打开 App 会进入配对页。点 Mac 菜单栏的手表图标，能看到**配对码**和**本机地址**：

- iPhone：同一局域网里的 Mac 会自动出现，选中后输入 6 位配对码。
- Apple Watch：填 Mac 地址（IP 或 `xxx.local`）和 6 位配对码。

配对一次即可，之后 Mac 的 IP 变了也能自动找回。要换一台 Mac，在 App 的设置里点「重新配对」。

## 语音输入

按住说话时，手表 / 手机的录音实时传到 Mac，有两种识别方式，自动选择：

| 方式 | 条件 | 效果 |
|---|---|---|
| **语音输入法**（推荐） | Mac 上装了豆包输入法 | 边说边上屏，识别质量由输入法决定 |
| Mac 内置识别 | 什么都不用装 | 说完后整段转成文字粘贴，目前只识别中文 |

用语音输入法时，Backseat 会创建一个叫 **Backseat Mic** 的虚拟麦克风（用系统自带能力实现，不安装驱动），把收到的声音送进去，同时替你按住输入法的语音快捷键。说话期间系统默认输入设备会临时切到它，说完自动还原。

需要在输入法里确认两件事：

- 麦克风选「跟随系统」或「Backseat Mic」。
- 语音输入用「长按」模式，快捷键是右 ⌘（豆包的默认设置）。

**换成别的语音输入法**（比如微信输入法；只实测过豆包）：在 `~/.backseat/config.json` 里加上输入源 ID 和它的长按快捷键，然后重启 Backseat。

```json
{"token": "…", "port": 8787, "voiceIME": {"source": "输入源 ID", "holdKey": "rightCommand"}}
```

`holdKey` 可选 `rightCommand`、`rightOption`、`rightControl`、`rightShift`、`fn`。输入源 ID 用这条命令查：

```bash
defaults read com.apple.HIToolbox AppleEnabledInputSources
```

## 用法

### iPhone

只有一个主屏，从上到下：

| 区域 | 作用 |
|---|---|
| 状态卡 | Claude 是在工作、完成了还是在等你回复；连不上 Mac 时这里会提示 |
| 触控板 | 单指移动指针、轻点单击、双击、三击；按住半秒再移动（或轻点后马上按住）= 拖拽；双指滚动、捏合缩放、双指轻点右键；三指 / 四指轻扫在设置里选动作。右上角可以切到全屏触控板 |
| 快捷短语 | 一点就发，在设置里增删改、隐藏、排序 |
| 说话条 | 按住说话，松手后文字留在 Mac 输入框；上滑取消并删掉这一轮说的字。左边 ✕ 清空输入框，右边 ↑ 发送 |
| 常用键 | 逗号、换行、⌘⏎、退格（在 Mac 光标处删）、更多按键。iPhone Duo 上它们在右侧状态栏下方 |

**不开 App 说话**：App 提供「开始 / 结束说话」快捷操作和「Backseat 说话」控制项，可以绑到手机侧键、控制中心、锁屏按钮，或在「辅助功能 → 触控 → 轻点背面」里绑到双击背面。录音时灵动岛显示状态，说完在锁屏卡片上点发送。

**灵感收件箱**：连不上 Mac 时说的话会存在手机上，用系统自带识别转成文字；连上后在主屏的收件箱里发给 Claude。

**设置**：目标应用（默认跟随 Mac 前台应用，也可以固定为某个应用）、鼠标灵敏度、三指 / 四指手势、快捷短语。

### Apple Watch

| 页 | 作用 |
|---|---|
| 对讲 | 按住说话，松手后文字进 Mac 输入框；下方是清空、退格、发送 |
| 快捷 | 逗号、⌘⏎、换行，以及常用短语 |
| 滚轮 | 转表冠 = 滚动 Mac 上的内容 |
| 按键 | Esc、Tab、1/2/3、方向键、回车 |

**侧键**：手表「设置 → 操作按钮」，动作选「体能训练」，App 选 Backseat，按一下就打开并开始录音。

### 离开电脑（遥控模式）

打开后，Claude Code 的权限审批不再弹在电脑上，而是推到手机 / 手表：

- 点「允许」放行，高风险命令（`git push`、`--force`、`reset --hard`、`sudo` 等）会用红色标出。
- 点「在电脑上处理」，审批交还给电脑上的对话框。
- 280 秒没响应，或设备断线超过 45 秒，审批自动交还给电脑。

手表上这个模式借用一个**不保存**的「体能训练」会话保持后台运行，比平时费电，回到电脑后记得关掉。

### 支持哪些应用

输入作用在 Mac 的前台应用（或设置里选定的目标应用），Claude 桌面版、终端里的 Claude Code / Codex、Cursor、ChatGPT 都可以。进度提醒和审批来自 Claude Code 的 hooks，其他工具没有这两项。

## 卸载 hooks

删除 `~/.claude/settings.json` 里命令为 `~/.backseat/hook.sh …` 的条目即可。不删也行：Backseat 没在运行时，这些 hook 会立即静默退出。

## 文件

- `mac/`：Mac 端（Swift，无第三方依赖）。HTTP 服务、状态与审批队列、键盘注入、虚拟麦克风、菜单栏。
- `apps/`：watchOS 和 iOS App（XcodeGen 生成工程，`project.yml`）。
- `scripts/`：`start.sh` 从终端启动，`build-app.sh` 打包菜单栏 App，`setup.sh` 写入 App 签名团队。

## 许可

MIT
