# DMS SPlayer Lyrics

一个用于 **DankMaterialShell (DMS)** 的实时歌词插件，通过 WebSocket 连接 **SPlayer**，将当前播放歌曲的同步歌词显示在 DankBar 与桌面上。

## 说明

- 本插件数据源来自 SPlayer WebSocket (歌词、时间轴、翻译、罗马音全部由 SPlayer 提供，无需自行解析 LRC)。  
- 本插件不修改 DMS 核心文件，完全独立运行。
- **非官方项目**: 本插件不是 SPlayer 官方维护的项目，与 SPlayer 官方无关联，请勿向 SPlayer 官方反馈本插件问题。

## 致谢

[LiveLyrics](https://gitlab.com/noahpolimon/dms-plugin-livelyrics)  
[SPlayerLyric](https://github.com/iwvw/SPlayerLyric)  

## 预览

> 演示环境 Fedora 44 + Niri 26.04

![水平 Bar 效果](horizontal.png) 
![垂直 Bar 效果](vertical.png)
![桌面部件效果](desktop.png)

## 特性

- 连接 SPlayer WebSocket (默认 `127.0.0.1:25885`) ，自动重连
- 处理 `song-change` / `lyric-change` / `progress-change` / `status-change`
- 根据播放进度自动高亮当前歌词行 (播放中本地平滑推进，切换流畅)  
- 详情页歌词列表三行显示: 原文 (大) → 中文翻译 (较小) → 罗马音 (最小斜体) 
- 逐字歌词: SPlayer 推送 `yrcData` 时按字高亮当前演唱到哪一字 (无则回退整行高亮) 
- 行切换渐变动画: 高亮条平滑滑动、当前行字号 / 颜色渐变过渡
- 点击歌词行 → 播放进度跳转到该行开始处 (MPRIS seek) 
- 状态栏 (Bar) 歌词样式: 原文 / 中文翻译 / 原文+翻译 / 隐藏 (仅保留音乐图标)
- 水平 Bar: 歌词过长时自动跑马灯滚动 (速度可调) 
- 垂直 Bar (左右侧): 竖排歌词逐字显示，超长自动向上滚动 (速度可调) 
- 详情页显示: 连接状态条 (可开关) 、歌曲信息 (歌名/作者/专辑独立行) 、专辑封面、波形进度条、歌词预览
- 详情页控制按钮行 (进度条下方): 上一曲 / 播放·暂停 / 下一曲
- 波形进度条播放动画可关闭 (桌面组件常驻时降低 CPU 占用) 
- 无歌词时显示歌曲标题 (可关闭) 
- SPlayer 进程未启动时自动隐藏组件 (每 5 秒检测一次，可关闭，SPlayer 启动后自动恢复) 
- **MPRIS 自愈**: SPlayer/DMS 重启后自动重新激活 MPRIS 播放器，封面/控制/进度恢复 (无需手动操作) 
- **控制回退**: MPRIS 不可用时播放/暂停/上下曲自动回退 SPlayer WebSocket `control` 命令
- **桌面组件**: 与 Bar 插件同源 (共享逻辑与配置) ，完整复用详情页样式——歌曲卡片 (歌名/作者/专辑) 、波形进度条、封面 + 控制按钮、歌词三行列表 (逐字高亮/点击 seek) ，可自由缩放移动；支持独立自定义: 显示模式 (全部/仅播放器/仅歌词) 、强调色 (主色/辅色/自定义) 、背景透明度、显示器选择

## 安装

1. 将插件目录复制到 DMS 插件目录 (目录名必须是 `livelyrics`，插件内部依赖该路径定位 bridge 脚本) : 

   ```bash
   git clone https://github.com/ayyyyano/DMS-SPlayer-Lyrics.git ~/.config/DankMaterialShell/plugins/livelyrics
   # 或手动复制: 
   # cp -r <本目录> ~/.config/DankMaterialShell/plugins/livelyrics
   ```

2. 安装 bridge 依赖 (Python 3 + websockets) : 

   ```bash
   pip install --user websockets
   # 或使用系统包管理器: sudo dnf install python3-websockets / sudo apt install python3-websockets
   ```

3. 打开 DMS 设置 → 插件，点击「扫描」，启用 **DMS SPlayer Lyrics**。

4. 将插件添加到 DankBar 组件列表 (设置 → 外观 → DankBar 布局)。

5. 重启 shell: 

   ```bash
   dms restart
   ```

6. 确认 SPlayer 已启动，且在 SPlayer 设置 → 网络与连接 中启用 WebSocket (WebSocket 服务默认监听 `127.0.0.1:25885`)。

## 配置

DMS 设置 → 插件 → DMS SPlayer Lyrics。设置分为**全局设置**（插件设置页，影响 Bar 与桌面组件通用行为）与**实例设置**（右键桌面组件 → 设置，仅影响该组件）:

### 全局设置

| 区块 | 设置项 | 说明 | 默认值 |
|------|--------|------|--------|
| SPlayer 连接 | 主机地址 | SPlayer WebSocket 服务地址 | `127.0.0.1` |
| SPlayer 连接 | 端口 | SPlayer WebSocket 端口 | `25885` |
| 通用 | SPlayer 未启动时自动隐藏 | SPlayer 进程未启动时隐藏 Bar 组件与桌面组件 (每 5 秒检测，启动后自动恢复) | 开 |
| 通用 | 波形进度条动画 | 详情页/桌面组件波形进度条播放时波动动画 (桌面组件常驻时关闭可降低 CPU 占用) | 开 |
| Bar 显示 | 无歌词时显示歌曲标题 | 无歌词时在 Bar 上显示歌曲标题 | 开 |
| Bar 显示 | 详情页连接状态 | 详情页顶部显示连接状态条 (已连接/未连接) | 开 |
| Bar 显示 | 状态栏歌词样式 | 原文 / 中文翻译 / 原文+翻译 / 隐藏 (仅保留音乐图标) | 原文 |
| Bar 显示 | 歌词滚动速度 | 水平/垂直 Bar 歌词滚动速度 (px/帧，每 25ms 一帧，支持一位小数) | 2.5 |

### 桌面组件实例设置 (右键组件 → 设置)

| 设置项 | 说明 | 默认值 |
|--------|------|--------|
| 显示模式 | 全部显示 / 仅播放器 / 仅歌词 | 全部显示 |
| 强调色 | 主色 / 辅色 / 自定义色 (弹窗选色或直接输入 `#RRGGBB` 后回车) | 主色 |
| 背景透明度 | 组件背景不透明度 (0 = 全透明，100 = 不透明) | 60 |
| 显示器选择 | 组件显示在哪个显示器 (仅实例设置可见) | 全部 |

## 架构

```
SPlayer (ws://127.0.0.1:25885)
    │  WebSocket JSON events (song-change / lyric-change / progress-change / status-change) 
    ▼
bridge/splayer_bridge.py    —— Python 客户端: 自动重连 (指数退避) ，
    │                          stdout 每行输出一个 JSON
    ▼
Quickshell Process + SplitParser("\n")   —— 读取 bridge 输出
    ▼
LiveLyrics.qml / LiveLyricsCore.qml  —— JSON 解析、事件分发、按 currentTime 查找当前歌词
    ▲                                │      (核心逻辑，Bar 与桌面组件共享同源实现)
    │ stdin 控制命令 (control)        ▼
    └──────────────────────────────── Bar Pill / 详情页 —— 歌词显示 (三行歌词: 原文 / 翻译 / 罗马音、歌词预览) 
    ▼
MPRIS (可选)               —— 专辑封面、波形进度条、播放/暂停/上下曲控制、点击歌词 seek

桌面组件 (LiveLyricsDesktop.qml) 通过 Loader 加载 LiveLyricsCore.qml 作为逻辑核心，
UI 复用详情页样式，并支持实例级自定义 (显示模式/强调色/透明度/显示器) ；
Bar 与桌面组件可同时运行 (SPlayer 支持多 WebSocket 连接) 。
```

## 调试

插件日志前缀 `[LiveLyrics]`，bridge 日志前缀 `[LiveLyrics][bridge]`。

```bash
# 查看 DMS 日志
journalctl --user -u dankmaterialshell -f | grep -i livelyrics

# 查看插件加载状态
 dms ipc call plugin-scan status liveLyrics

# 单独测试 bridge (不经过 DMS)  : 
python3 ~/.config/DankMaterialShell/plugins/livelyrics/bridge/splayer_bridge.py 127.0.0.1 25885
# 正常输出应为每行一个 JSON，例如: 
# {"type": "__status", "data": {"connected": true, ...}}
# {"type": "__event", "data": {"type": "song-change", ...}}

# 环境变量覆盖 (可选)  
DMS_LIVELYRICS_BRIDGE=/path/to/splayer_bridge.py   # 自定义 bridge 脚本路径
DMS_LIVELYRICS_PYTHON=/path/to/python              # 自定义 python (如 venv)  
```
SPlayer WebSocket 协议 (实测确认) : 

- 连接后 SPlayer 推送 `welcome` 事件。
- **主动请求**: 发送 `get-song-info` 可获取当前歌曲完整状态 (含 `lrcData`/`yrcData` 歌词) ，插件用于重启后状态恢复。
- **控制命令**: 发送 `{"type": "control", "data": {"command": "toggle|play|pause|next|prev"}}` 控制播放，插件作为 MPRIS 不可用时的回退通道。
- **心跳**: 发送 `PING` 收到 `PONG`。
- `progress-change` 约每 500ms 推送一次，含 `timestamp` 字段。
- `song-change` 的 `title` 为「歌名 - 歌手」组合格式，`name` 为纯歌名。
- `lyric-change` 的 `lrcData` 每项是一行: 
  - `words`: 逐字时间轴 (`startTime`/`endTime`/`word`，毫秒) 
  - `translatedLyric` / `romanLyric`: 翻译 / 罗马音 (字符串或数组) 
  - 行级 `startTime`/`endTime` 字段 (插件优先使用) 
  - 无歌词时 `lrcData` 为空数组
- 时间单位均为毫秒；SPlayer 不重放当前状态，仅推送新事件 (插件通过 `get-song-info` 主动恢复) 。
- **拖动进度条 / 点击歌词 seek / 单曲循环回退 / 暂停·恢复播放时，SPlayer 都会重推同一首歌的
  `song-change`，但不重推 `lyric-change`** (歌词数据仍有效，插件会识别同曲并保留歌词，仅刷新时长)。

## 常见问题

- **Bar 上的歌词组件完全消失 (不是显示「未连接」)**: 正常行为——插件每 5 秒检测一次 SPlayer 进程。
- **SPlayer 进程未启动时组件自动隐藏**。启动 SPlayer 后最多 5 秒内组件自动恢复。可在插件设置中关闭「SPlayer 未启动时自动隐藏」开关（DMS 设置 → 插件 → DMS SPlayer Lyrics）。
- **Bar 上显示「SPlayer 未连接」**: 说明 SPlayer 进程在运行但 WebSocket 尚未就绪 (或端口设置错误)。确认 SPlayer 设置 → 网络与连接 已启用 WebSocket (默认 `127.0.0.1:25885`)；bridge 会自动重连，无需重启 DMS。
- **歌词一直显示「等待歌词」**: 多为首次连接尚未收到 `lyric-change`；连接后插件会主动 `get-song-info` 恢复歌词，重启 DMS 后无需等切歌。
- **点击歌词行不跳转**: 需要 MPRIS 支持 seek (绝大多数播放器支持)；MPRIS 不可用时提示不支持 (SPlayer 协议无 seek 命令)。
- **详情页无专辑封面/波形**: 插件从 MPRIS 获取封面与进度，确认 SPlayer 已通过 MPRIS 注册 (DMS 媒体控件能显示即可)；MPRIS 失效时自动回退 WebSocket 模式。
- **建议设置 SPlayer 开机自启**: 防止可能的不必要空间占用与重连等待。

## 文件结构

```
plugins/livelyrics/
├── plugin.json               # 插件清单 (widget + desktop 双 surface)
├── LiveLyrics.qml            # Bar 组件: bridge 生命周期、事件分发、歌词查找、UI
├── LiveLyricsCore.qml        # 桌面组件逻辑核心: 与 LiveLyrics.qml 同源的解析/查找/控制逻辑
├── LiveLyricsDesktop.qml     # 桌面组件: 内嵌 LiveLyricsCore.qml 逻辑核心 + 详情页样式 UI
├── LiveLyricsSettings.qml    # 设置页 (全局 + 桌面组件实例设置)
└── bridge/
    └── splayer_bridge.py     # Python WebSocket 客户端 → stdout JSON lines
```

## 许可协议

[MIT](LICENSE)
