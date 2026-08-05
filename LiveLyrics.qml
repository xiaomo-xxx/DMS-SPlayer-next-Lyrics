import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// ─────────────────────────────────────────────────────────────────────────────
//  LiveLyrics (SPlayer edition)
//
//  数据流：
//    SPlayer (ws://127.0.0.1:25885)
//        │ WebSocket JSON events
//        ▼
//    bridge/splayer_bridge.py   (自动重连，stdout 输出 JSON lines)
//        │
//        ▼
//    Process + SplitParser("\n")  →  _onBridgeLine() 事件分发
//        │
//        ▼
//    本组件状态（歌曲信息 / 歌词行 / 播放进度）→  Bar Pill / Popout
//
//  职责划分：
//    LiveLyrics.qml        —— WebSocket 生命周期（经 bridge）、JSON 解析、
//                              事件分发、按 currentTime 查找当前歌词
//    LiveLyricsSettings.qml —— 配置 UI（host/port/显示选项）
// ─────────────────────────────────────────────────────────────────────────────

PluginComponent {
    id: root

    // ─────────────────────────────────────────────────────────────────────
    // 配置（来自 pluginData，由设置页写入）
    // ─────────────────────────────────────────────────────────────────────
    property string splayerHost: pluginData.splayerHost ?? "127.0.0.1"
    property string splayerPort: pluginData.splayerPort ?? "25885"
    property bool showTitleFallback: pluginData.showTitleFallback ?? true
    // 状态栏（Bar）歌词显示样式："original" 原文 | "translation" 中文翻译
    // | "both" 原文+翻译 | "hidden" 隐藏（仅保留音乐图标）
    property string barLyricMode: pluginData.barLyricMode ?? "original"
    // 歌词滚动速度（px/帧，每 25ms 一帧；水平/垂直 Bar 共用，默认 2.5）
    // 设置页为文本输入（一位小数），此处解析字符串
    property real vScrollSpeed: {
        var raw = parseFloat(pluginData.vScrollSpeed)
        return raw > 0 ? raw : 2.5
    }
    // SPlayer 进程未启动时自动隐藏 Bar 组件（可在设置页切换）
    property bool autoHideWhenClosed: pluginData.autoHideWhenClosed ?? true

    // ─────────────────────────────────────────────────────────────────────
    // 可见性：SPlayer 进程未启动时隐藏 Bar 组件（区别于"未连接"）
    // DMS 机制：visibilityCommand 每 visibilityInterval 秒经 sh -c 执行，
    // 退出码 0 → 显示，非 0 → 隐藏。用 -x 精确匹配进程名（不用 -i，
    // 否则会误匹配 bridge 脚本 splayer_bridge.py）
    // 通过绑定 autoHideWhenClosed 实现设置项动态开关：
    //   - 开启：visibilityCommand 非空 → 立即检查；visibilityInterval>0 → 定时轮询
    //   - 关闭：visibilityCommand 置空 → 强制显示；visibilityInterval=0 → 停止轮询
    // ─────────────────────────────────────────────────────────────────────
    visibilityCommand: root.autoHideWhenClosed ? "pgrep -x SPlayer" : ""
    visibilityInterval: root.autoHideWhenClosed ? 5 : 0

    // ─────────────────────────────────────────────────────────────────────
    // SPlayer 推送的状态
    // ─────────────────────────────────────────────────────────────────────
    property bool connected: false
    property string lastError: ""

    property string currentTitle: ""
    property string currentSongName: ""   // 纯歌名（SPlayer 的 name 字段）
    property string currentArtist: ""
    property string currentAlbum: ""
    property int currentDuration: 0      // ms（来自 song-change / progress-change）
    property int currentTime: 0          // ms（来自 progress-change，播放中本地平滑推进）
    property bool isPlaying: false

    // 歌词行：[{ startTime, endTime, text, translated, roman, words }]（ms）
    property var lyricsLines: []
    property int currentLineIndex: -1
    property int currentWordIndex: -1   // 当前行的逐字索引（无 yrc 时恒为 -1）

    // 本地进度平滑用的时间戳
    property int _lastReportedTime: 0
    property int _lastProgressAt: 0

    // ─────────────────────────────────────────────────────────────────────
    // bridge 进程管理
    // ─────────────────────────────────────────────────────────────────────

    // 插件目录不是注入属性，按 DMS 约定路径构造；
    // 可用环境变量 DMS_LIVELYRICS_BRIDGE 覆盖（自定义安装位置 / 调试）。
    function _bridgeScriptPath() {
        var override = Quickshell.env("DMS_LIVELYRICS_BRIDGE");
        if (override && override !== "")
            return override;
        var configHome = Quickshell.env("XDG_CONFIG_HOME");
        if (!configHome || configHome === "")
            configHome = (Quickshell.env("HOME") || "") + "/.config";
        return configHome + "/DankMaterialShell/plugins/livelyrics/bridge/splayer_bridge.py";
    }

    // 可用 DMS_LIVELYRICS_PYTHON 覆盖 python 可执行文件（如 venv 里的 python）
    function _pythonBin() {
        var override = Quickshell.env("DMS_LIVELYRICS_PYTHON");
        return (override && override !== "") ? override : "python3";
    }

    property string bridgeScript: _bridgeScriptPath()
    property int _restartDelay: 0          // 崩溃退避（秒）

    Process {
        id: bridgeProcess
        command: [root._pythonBin(), root.bridgeScript, root.splayerHost, root.splayerPort]
        running: false
        stdinEnabled: true   // 允许向 bridge 发送控制命令（转发给 SPlayer）
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root._onBridgeLine(data)
        }
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                var line = (data || "").trim()
                if (line !== "")
                    console.warn("[LiveLyrics][bridge] " + line)
            }
        }
        onStarted: console.info("[LiveLyrics] bridge 已启动 (pid " + processId + ")")
        onExited: (exitCode, exitStatus) => {
            root.connected = false
            console.warn("[LiveLyrics] bridge 退出 (code " + exitCode + ")，"
                         + root._restartDelay + "s 后重启")
            root._scheduleRestart()
        }
    }

    // 通过 bridge 向 SPlayer 发送命令（stdin 通道）
    // 用于 MPRIS 不可用时的控制回退：{"type":"control","data":{"command":"toggle"}}
    function _wsCommand(command) {
        if (!bridgeProcess.running) {
            console.warn("[LiveLyrics] bridge 未运行，无法发送命令: " + command)
            return
        }
        bridgeProcess.write(JSON.stringify({ type: "control", data: { command: command } }) + "\n")
        console.info("[LiveLyrics] 📤 已发送 control/" + command)
    }

    function _scheduleRestart() {
        if (!root._bridgeWanted)
            return
        var delayMs = Math.min(Math.max(root._restartDelay, 1), 30) * 1000
        root._restartDelay = Math.min(root._restartDelay * 2 + 1, 30)
        bridgeRestartTimer.interval = delayMs
        bridgeRestartTimer.restart()
    }

    Timer {
        id: bridgeRestartTimer
        repeat: false
        onTriggered: {
            if (root._bridgeWanted)
                bridgeProcess.running = true
        }
    }

    // bridge 是否应当运行（组件激活且配置了端口）
    readonly property bool _bridgeWanted: splayerPort !== ""

    on_BridgeWantedChanged: {
        if (_bridgeWanted) {
            bridgeProcess.running = true
        } else {
            bridgeProcess.running = false
        }
    }

    // 配置变化 → 重启 bridge
    onSplayerHostChanged: _restartBridge()
    onSplayerPortChanged: _restartBridge()

    function _restartBridge() {
        root._restartDelay = 0
        bridgeRestartTimer.stop()
        bridgeProcess.running = false
        bridgeProcess.running = true
    }

    // ─────────────────────────────────────────────────────────────────────
    // 事件分发：bridge stdout 的每一行 JSON
    // ─────────────────────────────────────────────────────────────────────

    function _onBridgeLine(rawLine) {
        var line = (rawLine || "").trim()
        if (line === "")
            return
        var msg
        try {
            msg = JSON.parse(line)
        } catch (e) {
            console.warn("[LiveLyrics] bridge 输出无法解析: " + line.substring(0, 120))
            return
        }
        if (!msg || typeof msg !== "object")
            return

        switch (msg.type) {
        case "__event":
            root._onSPlayerEvent(msg.data)
            break
        case "__status":
            root.connected = msg.data && msg.data.connected === true
            if (root.connected)
                console.info("[LiveLyrics] 已连接 SPlayer " + root.splayerHost + ":" + root.splayerPort)
            else
                console.warn("[LiveLyrics] SPlayer 连接断开")
            break
        case "__error":
            root.lastError = msg.data && msg.data.message ? msg.data.message : ""
            console.warn("[LiveLyrics] bridge 错误: " + root.lastError)
            break
        default:
            break
        }
    }

    function _onSPlayerEvent(data) {
        if (!data || typeof data !== "object")
            return
        switch (data.type) {
        case "song-change":     root._onSongChange(data.data || {});      break
        case "song-info":       root._onSongInfo(data.data || {});        break
        case "lyric-change":    root._onLyricChange(data.data || {});     break
        case "progress-change": root._onProgressChange(data.data || {});  break
        case "status-change":   root._onStatusChange(data.data || {});    break
        default:
            break
        }
    }

    // song-info：连接后 bridge 主动请求的当前状态快照（SPlayer 不重放事件，
    // 重启 DMS/bridge 后靠它恢复歌曲信息、进度、播放状态与歌词）
    // 实测：响应含 lrcData/yrcData（文档确认），可完整恢复
    function _onSongInfo(d) {
        if (!d)
            return
        var title = d.playName || d.name || d.title || ""
        var artist = d.artistName || d.artist || ""
        var album = d.albumName || d.album || ""

        // 与 song-change 相同的宽容同曲判断：避免覆盖已有歌词状态
        var curTitle = root.currentTitle
        var sameTrack = false
        if (curTitle === title && root.currentArtist === artist) {
            sameTrack = true
        } else if (title && title !== "" && curTitle.indexOf(title) >= 0) {
            sameTrack = true
        } else if (curTitle && curTitle !== "" && title.indexOf(curTitle) >= 0) {
            sameTrack = true
        }

        root.currentTitle = title
        root.currentSongName = d.name || title
        root.currentArtist = artist
        root.currentAlbum = album
        if (d.duration > 0)
            root.currentDuration = d.duration

        if (!sameTrack) {
            // 恢复期间未听过此歌：清空歌词等待推送
            root.lyricsLines = []
            root.currentLineIndex = -1
            root.currentWordIndex = -1
            console.info("[LiveLyrics] 📡 状态恢复: \"" + title + "\" — " + artist)
        }

        // 恢复歌词（song-info 实测含 lrcData/yrcData）
        var hasLyricData = (Array.isArray(d.lrcData) && d.lrcData.length > 0)
            || (Array.isArray(d.yrcData) && d.yrcData.length > 0)
        if (hasLyricData && !sameTrack) {
            root._onLyricChange({ lrcData: d.lrcData, yrcData: d.yrcData })
            console.info("[LiveLyrics] 📡 歌词恢复: " + root.lyricsLines.length + " 行")
        }

        // 恢复播放进度（currentTime 为毫秒）
        if (typeof d.currentTime === "number" && d.currentTime >= 0) {
            root.currentTime = d.currentTime
            root._lastReportedTime = d.currentTime
            root._lastProgressAt = d.playStatus === true ? Date.now() : 0
            root._updateCurrentLine()
        }

        // 恢复播放状态
        if (d.playStatus !== undefined)
            root._onStatusChange({ status: d.playStatus === true })
    }

    function _onSongChange(d) {
        // 实测：SPlayer 的 title 为 "歌名 - 歌手" 组合格式，name 为纯歌名
        var title = d.title || d.name || ""
        var artist = d.artist || ""
        var songName = d.name || ""
        // 实测：SPlayer 在「拖动进度条」「seek 跳转」「单曲循环回退」时会重推
        // 同一首歌的 song-change，但不会重推 lyric-change。若按新歌处理会清空
        // 歌词，导致歌词丢失。因此只有真正换歌才清空歌词与进度。
        //
        // 同曲判断（宽容匹配）：
        //   - title+artist 完全一致
        //   - 或 name（纯歌名）一致 + 当前 title 包含该 name
        //   - 或当前 title 与新 title 都包含相同 name（忽略 " - 歌手" 后缀差异）
        var curTitle = root.currentTitle
        var curArtist = root.currentArtist
        var curName = root.currentSongName

        var sameTrack = false
        if (curTitle === title && curArtist === artist) {
            sameTrack = true
        } else if (songName && songName !== "" && curTitle.indexOf(songName) >= 0) {
            // 新 song-change 带纯歌名，且当前标题包含该歌名 → 同曲
            sameTrack = true
        } else if (curName && curName !== "" && title.indexOf(curName) >= 0) {
            // 当前有纯歌名，且新标题包含它 → 同曲
            sameTrack = true
        }

        root.currentTitle = title
        root.currentSongName = songName
        root.currentArtist = artist
        root.currentAlbum = d.album || ""
        root.currentDuration = d.duration > 0 ? d.duration : 0

        if (sameTrack) {
            // 同曲重推（拖动/循环/seek）：保留歌词与 currentTime，仅刷新时长
            console.info("[LiveLyrics] ↻ 同曲重推 (拖动/循环/seek): \"" + root.currentTitle + "\"")
            root._updateCurrentLine()
        } else {
            // 真换歌：清空歌词，等待随后的 lyric-change
            root.currentTime = 0
            root._lastProgressAt = 0
            root.lyricsLines = []
            root.currentLineIndex = -1
            root.currentWordIndex = -1
            console.info("[LiveLyrics] ▶ 歌曲: \"" + root.currentTitle + "\" — " + root.currentArtist)
        }
    }

    // lrcData 每项是一行：words（逐字时间轴）+ translatedLyric + romanLyric
    function _onLyricChange(d) {
        // yrcData 存在且非空时优先使用（逐字粒度），否则回退 lrcData（逐词粒度）
        var source = (Array.isArray(d.yrcData) && d.yrcData.length > 0) ? d.yrcData : d.lrcData
        var hadYrc = source === d.yrcData
        root.lyricsLines = root._parseLyricData(source)
        root.currentLineIndex = -1
        root.currentWordIndex = -1
        console.info("[LiveLyrics] 歌词更新: " + root.lyricsLines.length + " 行"
                     + (hadYrc ? " (逐字 yrc)" : " (逐词 lrc)"))
        root._updateCurrentLine()
    }

    function _onProgressChange(d) {
        if (typeof d.currentTime === "number" && d.currentTime >= 0)
            root.currentTime = d.currentTime
        if (d.duration > 0)
            root.currentDuration = d.duration
        if (root.isPlaying) {
            root._lastReportedTime = root.currentTime
            root._lastProgressAt = Date.now()
        }
        root._updateCurrentLine()
    }

    function _onStatusChange(d) {
        var playing = d.status === true
        if (playing !== root.isPlaying)
            console.info("[LiveLyrics] 播放状态: " + (playing ? "播放" : "暂停"))
        root.isPlaying = playing
        if (playing) {
            root._lastReportedTime = root.currentTime
            root._lastProgressAt = Date.now()
        } else {
            root._lastProgressAt = 0
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 歌词解析
    // ─────────────────────────────────────────────────────────────────────

    // translatedLyric / romanLyric 可能是字符串，也可能是逐词数组
    function _coerceText(v) {
        if (v === undefined || v === null)
            return ""
        if (typeof v === "string")
            return v
        if (Array.isArray(v))
            return v.map(x => (x && typeof x === "object") ? (x.text || x.word || "") : String(x)).join(" ")
        return String(v)
    }

    // lrcData 每项是一行：words（逐词时间轴）+ translatedLyric + romanLyric，
    // 实测还包含行级 startTime/endTime（优先使用，words 首末词时间兜底）
    // yrcData 与 lrcData 完全同构，仅 words 粒度更细（逐字），
    // 因此统一走本解析器，仅在有 yrc 时传入 yrcData
    function _parseLyricData(lrcData) {
        var lines = []
        if (!Array.isArray(lrcData))
            return lines
        for (var i = 0; i < lrcData.length; i++) {
            var item = lrcData[i]
            if (!item || !Array.isArray(item.words) || item.words.length === 0)
                continue
            var text = ""
            var startTime = (typeof item.startTime === "number") ? item.startTime : -1
            var endTime = (typeof item.endTime === "number") ? item.endTime : -1
            var words = []
            for (var j = 0; j < item.words.length; j++) {
                var w = item.words[j]
                if (!w)
                    continue
                var word = w.word || ""
                // 拼接：word 自带前导空格（yrc 实测如 " に"）时不再叠加空格，
                // 否则会出现双空格（详情页非当前行/Bar 显示异常）
                if (text !== "" && word !== "" && !word.startsWith(" ") && !text.endsWith(" "))
                    text += " "
                text += word
                if (startTime < 0 && typeof w.startTime === "number")
                    startTime = w.startTime
                if (typeof w.endTime === "number" && w.endTime > endTime)
                    endTime = w.endTime
                // 保留逐词/逐字时间轴，用于字级高亮
                words.push({
                    startTime: typeof w.startTime === "number" ? w.startTime : -1,
                    endTime: typeof w.endTime === "number" ? w.endTime : -1,
                    word: word
                })
            }
            // 整行空格规范化：多空格合并为单空格，去除首尾
            text = text.replace(/\s+/g, " ").trim()
            if (startTime < 0 || text === "")
                continue
            lines.push({
                startTime: startTime,
                endTime: endTime,
                text: text,
                translated: root._coerceText(item.translatedLyric),
                roman: root._coerceText(item.romanLyric),
                words: words
            })
        }
        lines.sort((a, b) => a.startTime - b.startTime)
        return lines
    }

    // ─────────────────────────────────────────────────────────────────────
    // 根据 currentTime 查找当前歌词行
    // ─────────────────────────────────────────────────────────────────────

    function _updateCurrentLine() {
        var lines = root.lyricsLines
        if (lines.length === 0) {
            root.currentLineIndex = -1
            return
        }
        var t = root.currentTime
        var idx = -1
        // lines 按 startTime 升序；找到最后一个 startTime <= t 的行
        for (var i = 0; i < lines.length; i++) {
            if (t >= lines[i].startTime)
                idx = i
            else
                break
        }
        // 行间间隙：t 已超过当前行 endTime 但还没到下一行 → 保持当前行
        // 超过最后一行 endTime → 保持最后一行（等待下一首 song-change）
        if (idx >= 0 && lines[idx].endTime > 0 && t > lines[idx].endTime) {
            var next = idx + 1 < lines.length ? lines[idx + 1].startTime : -1
            if (next > 0 && t >= next) {
                idx++
                while (idx + 1 < lines.length && t >= lines[idx + 1].startTime)
                    idx++
            }
        }
        if (idx !== root.currentLineIndex)
            root.currentLineIndex = idx

        // 逐字高亮：当前行内找最后一个 startTime <= t 的字
        var wordIdx = -1
        if (idx >= 0 && lines[idx].words && lines[idx].words.length > 0) {
            for (var k = 0; k < lines[idx].words.length; k++) {
                if (t >= lines[idx].words[k].startTime && lines[idx].words[k].startTime >= 0)
                    wordIdx = k
                else if (lines[idx].words[k].startTime < 0)
                    continue
                else
                    break
            }
        }
        if (wordIdx !== root.currentWordIndex)
            root.currentWordIndex = wordIdx
    }

    // 生成逐字高亮富文本：已唱到的字用主题色，未唱到的用常规色
    // 仅当前行且有 words 时使用；否则返回 null（delegate 回退普通文本）
    function _wordHighlightHtml(line, isCurrent) {
        if (!line || !line.words || line.words.length === 0)
            return null
        if (!isCurrent || root.currentWordIndex < 0)
            return null
        var html = ""
        var emitted = false   // 是否已输出过可见词（决定是否补词间空格）
        for (var i = 0; i < line.words.length; i++) {
            var w = line.words[i]
            if (!w || w.word === undefined || w.word === null)
                continue
            // trim 掉 word 自带的前导/尾随空格（yrc 如 " に"），
            // 词间统一补单空格 → 渲染结果与规范化的 line.text 完全一致
            var word = w.word.trim()
            if (word === "")
                continue
            if (emitted)
                html += " "
            var spanColor = (i <= root.currentWordIndex) ? Theme.primary : Theme.surfaceText
            html += "<span style='color:" + spanColor + ";'>" + word + "</span>"
            emitted = true
        }
        return html
    }

    // 播放中：基于最近一次 progress-change 本地平滑推进，保证歌词切换流畅
    Timer {
        id: positionTicker
        interval: 200
        repeat: true
        running: root.isPlaying && root.connected
        onTriggered: {
            if (root._lastProgressAt > 0) {
                root.currentTime = root._lastReportedTime
                    + (Date.now() - root._lastProgressAt)
                root._updateCurrentLine()
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 显示状态
    // ─────────────────────────────────────────────────────────────────────

    // MPRIS：DMS 媒体控件可用时作为专辑封面与波形进度条的数据源
    // （SPlayer 的 WebSocket 不推送封面，封面只能从 MPRIS 获取）
    readonly property MprisPlayer mprisPlayer: MprisController.activePlayer

    // MPRIS 是否"可用"：SPlayer 重启后 MPRIS D-Bus 名称变化（instance+PID），
    // 旧 player 引用会失效但 DMS 可能未及时刷新 → 健康检查后置为 false，
    // 使封面/控制/进度条整体隐藏（而非显示失效状态）
    property bool mprisUsable: false

    // MPRIS 健康检查：每 3 秒验证 activePlayer 是否仍有效，并主动寻找 SPlayer。
    // SPlayer 重启后 MPRIS D-Bus 名称变化（instance+PID），Quickshell 的
    // Mpris.players 模型更新可能不触发 DMS 的 availablePlayers 信号，
    // 导致 activePlayer 停留在旧引用。因此这里：
    //   1) 直接遍历 Mpris.players 找 identity 含 "splayer" 的 player
    //   2) 若找到且与当前 activePlayer 不同 → 强制 MprisController.setActivePlayer()
    //   3) 找不到 SPlayer 或读取异常 → mprisUsable = false（回退 WebSocket）
    Timer {
        id: mprisHealthTimer
        interval: 3000
        repeat: true
        running: true
        onTriggered: {
            // 步骤 1：直接从 Quickshell 底层 players 找 SPlayer
            var splayer = null
            try {
                var players = Mpris.players.values
                for (var i = 0; i < players.length; i++) {
                    var identity = (players[i].identity || "").toLowerCase()
                    if (identity.indexOf("splayer") >= 0) {
                        splayer = players[i]
                        break
                    }
                }
            } catch (e) {}

            // 步骤 2：找到 SPlayer 且不是当前 activePlayer → 强制激活
            if (splayer) {
                if (root.mprisPlayer !== splayer) {
                    console.info("[LiveLyrics] 🔄 MPRIS 重激活: " + splayer.identity)
                    try {
                        MprisController.setActivePlayer(splayer)
                    } catch (e) {
                        console.warn("[LiveLyrics] setActivePlayer 失败: " + e)
                    }
                }
                root.mprisUsable = true
                return
            }

            // 步骤 3：找不到 SPlayer 的 MPRIS（进程未注册或未启动）
            if (root.mprisPlayer) {
                // 当前有 activePlayer 但可能不是 SPlayer（如其他播放器）：
                // 若当前播放的是 SPlayer 歌曲，回退 WebSocket 模式
                console.warn("[LiveLyrics] MPRIS 中未找到 SPlayer，回退 WebSocket 模式")
            }
            root.mprisUsable = false
        }
    }

    // 纯歌名：优先 SPlayer 的 name 字段，否则回退到 title
    readonly property string displayTitle: root.currentSongName !== ""
        ? root.currentSongName
        : root.currentTitle

    readonly property var currentLine: currentLineIndex >= 0 && currentLineIndex < lyricsLines.length
        ? lyricsLines[currentLineIndex]
        : null

    // 详情页歌词始终显示三行（原文/翻译/罗马音），无需开关
    readonly property string currentLineText: root.currentLine ? root.currentLine.text : ""

    // 状态栏（Bar）歌词显示文本，按 barLyricMode 选择
    readonly property string barLyricText: {
        var line = root.currentLine
        if (!line)
            return ""
        switch (root.barLyricMode) {
        case "hidden":
            return ""   // 隐藏模式：Bar 上不显示歌词
        case "translation":
            return line.translated !== "" ? line.translated : line.text
        case "both":
            return line.text + (line.translated !== "" ? "  ·  " + line.translated : "")
        default:
            return line.text
        }
    }

    // Bar 主文本（水平/垂直通用）：优先歌词，其次歌名（showTitleFallback 控制）
    readonly property string pillText: {
        if (!root.connected)
            return "SPlayer 未连接"
        if (root.barLyricText !== "")
            return root.barLyricText
        // 无歌词：showTitleFallback 开 → 显示歌名；关 → 等待提示
        if (root.currentTitle && root.showTitleFallback)
            return root.currentTitle
        if (root.currentTitle)
            return root.currentTitle
        return "等待歌词…"
    }

    // ─────────────────────────────────────────────────────────────────────
    // 播放/暂停控制：优先 MPRIS，失效时回退 WebSocket control 命令
    function togglePlayPause() {
        var player = root.mprisPlayer
        if (root.mprisUsable && player && player.canTogglePlaying) {
            player.togglePlaying()
            return
        }
        // MPRIS 不可用 → 通过 bridge 发 WebSocket 命令
        root._wsCommand("toggle")
    }

    // 点击歌词行 → 将播放进度 seek 到该行开始处
    // （优先 MPRIS position 写入；MPRIS 失效时回退 WebSocket：
    //   SPlayer 协议无 seek 命令，通过 seek 命令无法实现，故仅提示）
    function seekToLine(index) {
        if (index < 0 || index >= root.lyricsLines.length)
            return
        var player = root.mprisPlayer
        if (root.mprisUsable && player && player.canSeek) {
            var startMs = root.lyricsLines[index].startTime
            if (startMs < 0)
                return
            player.position = startMs / 1000
            console.info("[LiveLyrics] ⏩ 跳转到歌词行 " + index + " (" + root._fmtTime(startMs) + ")")
            return
        }
        console.warn("[LiveLyrics] MPRIS 不可用，无法 seek 歌词跳转（SPlayer 协议无 seek 命令）")
    }

    // 上一曲：优先 MPRIS，失效时回退 WebSocket control
    function prevTrack() {
        var player = root.mprisPlayer
        if (root.mprisUsable && player && player.canGoPrevious) {
            player.previous()
            return
        }
        root._wsCommand("prev")
    }

    // 下一曲：优先 MPRIS，失效时回退 WebSocket control
    function nextTrack() {
        var player = root.mprisPlayer
        if (root.mprisUsable && player && player.canGoNext) {
            player.next()
            return
        }
        root._wsCommand("next")
    }

    // 退出 SPlayer（终止全部相关进程；Bar 组件会经 visibilityCommand 自动隐藏）
    // SPlayer 是 Electron 应用，除主进程外还有 zygote/gpu/renderer 等子进程
    // （命令行均含 /opt/SPlayer/SPlayer），需 -f 匹配全部；先 SIGTERM 优雅退出，
    // 2 秒后未退干净则 SIGKILL 兜底，避免托盘残留
    function quitSPlayer() {
        console.info("[LiveLyrics] ⏻ 退出 SPlayer")
        Quickshell.execDetached(["pkill", "-f", "^/opt/SPlayer/SPlayer"])
        quitKillTimer.restart()
    }

    // 兜底：SIGTERM 后 2 秒仍未退出 → SIGKILL
    Timer {
        id: quitKillTimer
        interval: 2000
        repeat: false
        onTriggered: {
            Quickshell.execDetached(["pkill", "-9", "-f", "^/opt/SPlayer/SPlayer"])
        }
    }

    function _fmtTime(ms) {
        if (ms <= 0)
            return "0:00"
        var total = Math.floor(ms / 1000)
        var m = Math.floor(total / 60)
        var s = total % 60
        return m + ":" + ("0" + s).slice(-2)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Bar Pills
    // ─────────────────────────────────────────────────────────────────────

    horizontalBarPill: hPillComponent

    Component {
        id: hPillComponent
        Row {
            spacing: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter

            // 状态图标：播放中=主题色，暂停=前景/背景互换（中性底+深色图标），未连接=红色
            // 背景 14px，更接近 Bar 聚焦应用图标大小
            Rectangle {
                width: 14
                height: 14
                radius: 7
                anchors.verticalCenter: parent.verticalCenter
                color: root.connected
                    ? (root.isPlaying
                        ? Theme.withAlpha(Theme.primary, 0.15)
                        : Theme.withAlpha(Theme.surfaceVariantText, 0.6))   // 暂停背景=中性60%
                    : Theme.withAlpha(Theme.error, 0.12)

                DankIcon {
                    anchors.centerIn: parent
                    name: root.connected ? "music_note" : "cloud_off"
                    size: 10
                    color: root.connected
                        ? (root.isPlaying
                            ? Theme.primary
                            : Theme.surfaceContainerHighest)  // 暂停图标=浅底
                        : Theme.error
                }
            }

            Item {
                id: lyricMarquee
                clip: true
                width: Math.min(marqueeText.contentWidth, 240)
                height: marqueeText.implicitHeight
                anchors.verticalCenter: parent.verticalCenter
                visible: root.barLyricMode !== "hidden"   // 隐藏模式只留图标

                readonly property real overflow: marqueeText.contentWidth - width
                readonly property bool overflowing: overflow > 0

                function resetScroll() {
                    lyricScroll.stop()
                    marqueeText.x = 0
                    if (overflowing)
                        lyricScroll.start()
                }

                onWidthChanged: Qt.callLater(resetScroll)
                onOverflowingChanged: Qt.callLater(resetScroll)
                Component.onCompleted: Qt.callLater(resetScroll)

                // 速度变化时重启滚动（root 属性需用 Connections 监听）
                Connections {
                    target: root
                    function onVScrollSpeedChanged() {
                        lyricMarquee.resetScroll()
                    }
                }

                StyledText {
                    id: marqueeText
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    anchors.verticalCenter: parent.verticalCenter

                    onTextChanged: Qt.callLater(lyricMarquee.resetScroll)
                    onContentWidthChanged: Qt.callLater(lyricMarquee.resetScroll)

                    SequentialAnimation {
                        id: lyricScroll
                        PauseAnimation { duration: 1200 }
                        NumberAnimation {
                            target: marqueeText
                            property: "x"
                            to: -lyricMarquee.overflow
                            // 速度与垂直 Bar 一致：总时长 = 距离 / 速度 × 帧间隔
                            duration: Math.max(200, (lyricMarquee.overflow / root.vScrollSpeed) * 25)
                            easing.type: Easing.InOutQuad
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: vPillComponent

    Component {
        id: vPillComponent
        Column {
            spacing: Theme.spacingXS

            // 状态图标（音乐/未连接）＋圆形蒙版（与水平 Bar 一致）
            // 播放中=主题色，暂停=前景/背景互换（中性底+深色图标），未连接=红色
            // 背景 14px，更接近 Bar 聚焦应用图标大小
            Rectangle {
                width: 14
                height: 14
                radius: 7
                anchors.horizontalCenter: parent.horizontalCenter
                color: root.connected
                    ? (root.isPlaying
                        ? Theme.withAlpha(Theme.primary, 0.15)
                        : Theme.withAlpha(Theme.surfaceVariantText, 0.6))   // 暂停背景=中性60%
                    : Theme.withAlpha(Theme.error, 0.12)

                DankIcon {
                    anchors.centerIn: parent
                    name: root.connected ? "music_note" : "cloud_off"
                    size: 10
                    color: root.connected
                        ? (root.isPlaying
                            ? Theme.primary
                            : Theme.surfaceContainerHighest)  // 暂停图标=浅底
                        : Theme.error
                }
            }

            // 竖排歌词：每个字符垂直排列（左右 Bar 窄，横排放不下）
            // 高度自适应：歌词短时贴合内容（不占多余空间），
            // 超长时封顶 180px 自动向上滚动显示
            // hidden 模式下隐藏（只保留音乐图标，详情页仍可点击打开）
            Item {
                id: vLyricWrap
                width: Theme.fontSizeSmall + 6        // 单字符宽度
                height: Math.min(vLyricText.implicitHeight, 180)   // 自适应 + 封顶
                clip: true
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.barLyricMode !== "hidden"

                StyledText {
                    id: vLyricText
                    width: parent.width
                    // 逐字竖排：字间换行
                    text: root.pillText !== "" ? root._verticalize(root.pillText) : "…"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WrapAnywhere
                    horizontalAlignment: Text.AlignHCenter
                    lineHeight: 1.2
                    maximumLineCount: 999
                    anchors.horizontalCenter: parent.horizontalCenter

                    // 超出高度时向上滚动（垂直跑马灯）
                    readonly property real overflow: implicitHeight - vLyricWrap.height
                    readonly property bool overflowing: overflow > 0

                    // 换行/高度变化时处理滚动状态：
                    //   - 新歌词短于容器 → 回顶部静态显示
                    //   - 新歌词超长 → 每句都从顶部（起始）开始滚动，
                    //     短暂暂停后滚到底（保证每句完整从头展示）
                    function resetScroll() {
                        vScrollTimer.stop()
                        vScrollPause.stop()
                        if (!overflowing) {
                            y = 0
                            return
                        }
                        y = 0
                        vScrollPause.start()
                    }

                    onTextChanged: Qt.callLater(resetScroll)
                    onOverflowingChanged: Qt.callLater(resetScroll)
                    Component.onCompleted: Qt.callLater(resetScroll)

                    // 速度变化时重启滚动（root 属性需用 Connections 监听）
                    Connections {
                        target: root
                        function onVScrollSpeedChanged() {
                            vLyricText.resetScroll()
                        }
                    }

                    // 滚动执行器：每 25ms 上移 vScrollSpeed px（默认 2.4），滚到底停止
                    // （用 Timer 而非 SequentialAnimation：动画 stop/start 会重置
                    //   到暂停阶段且 from==to 时瞬间完成，导致换行后"不滚"）
                    Timer {
                        id: vScrollTimer
                        interval: 25
                        repeat: true
                        onTriggered: {
                            var target = -vLyricText.overflow
                            vLyricText.y = Math.max(vLyricText.y - root.vScrollSpeed, target)
                            if (vLyricText.y <= target)
                                stop()
                        }
                    }

                    // 滚动前短暂停留（让新歌词开头先可见）
                    Timer {
                        id: vScrollPause
                        interval: 800
                        repeat: false
                        onTriggered: vScrollTimer.start()
                    }
                }
            }
        }
    }

    // 将文本转为逐字竖排（每字一行，空格保留为占位）
    function _verticalize(text) {
        if (!text)
            return "…"
        var out = ""
        for (var i = 0; i < text.length; i++) {
            var ch = text.charAt(i)
            if (ch === " ")
                continue      // 跳过空格：不输出占位行，避免挤占竖排屏幕面积
            out += ch
            out += "\n"
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────
    // Popout：现在播放 + 连接状态 + 歌词预览
    // ─────────────────────────────────────────────────────────────────────

    popoutContent: Component {
        PopoutComponent {
            headerText: "SPlayer"
            // 副标题移除：歌曲标题与下方歌曲信息卡重复
            showCloseButton: true

            // 右上角操作区：退出 SPlayer 电源按钮（关闭按钮左侧）
            // 播放控制（上一曲/播放暂停/下一曲）已移到播放卡片标题右侧
            headerActions: Component {
                // 退出 SPlayer（电源按钮：红色 hover 警示，参照关闭按钮风格）
                Rectangle {
                    width: 32
                    height: 32
                    radius: 16
                    color: powerBtn.containsMouse
                        ? Theme.withAlpha(Theme.error, 0.15)
                        : "transparent"

                    MouseArea {
                        id: powerBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.quitSPlayer()
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        name: "power_settings_new"
                        size: Theme.iconSize - 4
                        color: powerBtn.containsMouse ? Theme.error : Theme.surfaceText
                    }
                }
            }

            // 固定布局：窗口高度 = implicitHeight（恒定），歌词列表为固定高度
            // 独立滚动区，顶部连接状态与歌曲信息始终可见，不会被歌词内容挤走
            Column {
                id: popoutCol
                width: parent.width
                spacing: Theme.spacingM

                    // ── 连接状态 ──
                    Rectangle {
                        width: parent.width
                        height: statusRow.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadius
                        color: root.connected
                            ? Theme.withAlpha(Theme.primary, 0.08)
                            : Theme.withAlpha(Theme.error, 0.08)

                        Row {
                            id: statusRow
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: Theme.spacingM
                            rightPadding: Theme.spacingM
                            spacing: Theme.spacingS

                            DankIcon {
                                name: root.connected ? "link" : "link_off"
                                size: 16
                                color: root.connected ? Theme.primary : Theme.error
                                anchors.verticalCenter: parent.verticalCenter
                            }

                        StyledText {
                            text: root.connected
                                ? ("已连接  " + root.splayerHost + ":" + root.splayerPort
                                   + (root.isPlaying ? "  ·  播放中" : "  ·  已暂停"))
                                : ("未连接  " + root.splayerHost + ":" + root.splayerPort
                                   + (root.lastError !== "" ? "  (" + root.lastError + ")" : "  ·  自动重连中"))
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.connected ? Theme.primary : Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // ── 歌曲信息 + 进度 + 封面 ──
                Rectangle {
                    width: parent.width
                    height: nowPlayingRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.4)

                    Row {
                        id: nowPlayingRow
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: Theme.spacingM
                        }
                        spacing: Theme.spacingM

                        // 信息列（歌名 / 作者 / 专辑 / 进度）
                        Column {
                            id: popoutTitleCol
                            width: rightCol.visible ? parent.width - rightCol.width - parent.spacing : parent.width
                            spacing: Theme.spacingS

                            // 歌名（独立大标题，最多两行，超长省略）
                            StyledText {
                                width: parent.width
                                text: root.displayTitle !== "" ? root.displayTitle : "没有正在播放的歌曲"
                                font.pixelSize: Theme.fontSizeLarge + 2
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                wrapMode: Text.WordWrap
                            }

                            // 作者（独立行 + person 图标）
                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS
                                visible: root.currentArtist !== ""

                                DankIcon {
                                    name: "person"
                                    size: 14
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // 宽度受限于父 Row（不延伸到专辑封面区域），超长省略号
                                StyledText {
                                    width: parent.width - 14 - parent.spacing
                                    text: root.currentArtist
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                }
                            }

                            // 专辑（独立行 + album 图标）
                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS
                                visible: root.currentAlbum !== ""

                                DankIcon {
                                    name: "album"
                                    size: 14
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // 宽度受限于父 Row（不延伸到专辑封面区域），超长省略号
                                StyledText {
                                    width: parent.width - 14 - parent.spacing
                                    text: root.currentAlbum
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                }
                            }

                            // 波形进度条（M3WaveProgress 直接实例化，自定义颜色）：
                            // DMS 的 DankSeekbar 波形 track 用 MediaAccentService.accentTrack
                            // （封面主色 28% 透明度），深色封面时几乎不可见；
                            // 这里直接使用波形组件本身，track 用浅色 surfaceVariant 保证可见，
                            // 波形动画（播放时波动）完整保留
                            M3WaveProgress {
                                id: progressBar
                                width: parent.width
                                height: 20
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: root.mprisUsable
                                isPlaying: root.mprisPlayer?.playbackState === MprisPlaybackState.Playing
                                value: root.mprisUsable ? 0 : 0   // 由下方轮询 Timer 驱动
                                actualValue: root.mprisUsable ? 0 : 0
                                fillColor: Theme.primary
                                playheadColor: Theme.primary
                                trackColor: Theme.withAlpha(Theme.surfaceVariant, 0.40)  // 未播放部分（浅色可见）
                                actualProgressColor: Theme.onSurface_38

                                // 点击进度条 seek（MPRIS 支持时）
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: root.mprisPlayer?.canSeek ?? false
                                    onClicked: mouse => {
                                        if (root.mprisPlayer && root.mprisPlayer.length > 0) {
                                            var ratio = Math.max(0, Math.min(1, mouse.x / width))
                                            root.mprisPlayer.position = ratio * root.mprisPlayer.length * 0.99
                                        }
                                    }
                                }
                            }

                            // 轮询 MPRIS 位置，驱动波形进度条
                            Timer {
                                interval: 50
                                running: root.mprisUsable
                                repeat: true
                                onTriggered: {
                                    if (root.mprisPlayer) {
                                        try {
                                            var pos = root.mprisPlayer.position || 0
                                            var len = Math.max(1, root.mprisPlayer.length || 1)
                                            progressBar.value = Math.min(1, pos / len)
                                            progressBar.actualValue = progressBar.value
                                        } catch (e) {}
                                    }
                                }
                            }

                            // 兜底进度条（MPRIS 不可用时，基于 SPlayer WebSocket 数据）
                            Rectangle {
                                width: parent.width
                                height: 6
                                radius: 3
                                visible: !root.mprisUsable
                                color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.6)

                                Rectangle {
                                    width: root.currentDuration > 0
                                        ? Math.min(1, root.currentTime / root.currentDuration) * parent.width
                                        : 0
                                    height: parent.height
                                    radius: 3
                                    color: Theme.primary
                                }
                            }

                            // 时间行
                            Row {
                                width: parent.width

                                StyledText {
                                    id: timeStart
                                    text: root._fmtTime(root.currentTime)
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }

                                Item {
                                    width: parent.width - timeStart.implicitWidth - timeEnd.implicitWidth
                                    height: 1
                                }

                                StyledText {
                                    id: timeEnd
                                    text: root._fmtTime(root.currentDuration)
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        // 右侧列：专辑封面 + 播放控制按钮（封面下方，与进度条水平对齐）
                        // visible 用 mprisUsable 判断（避免失效引用导致整列不可见）
                        Column {
                            id: rightCol
                            width: 80
                            spacing: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.mprisUsable
                                && (root.mprisPlayer.trackArtUrl ?? "") !== ""

                            // 专辑封面（来自 MPRIS）
                            DankAlbumArt {
                                id: _coverArt
                                width: 80
                                height: 80
                                anchors.horizontalCenter: parent.horizontalCenter
                                activePlayer: root.mprisPlayer
                                showAnimation: true
                            }

                            // 控制按钮组：上一曲 / 播放·暂停 / 下一曲
                            // （封面下方，视觉上与左侧进度条行水平对齐）
                            Row {
                                width: parent.width
                                spacing: Theme.spacingXS
                                anchors.horizontalCenter: parent.horizontalCenter

                                // 上一曲（透明背景 + hover 反馈）
                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 11
                                    color: titlePrevBtn.containsMouse
                                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
                                        : "transparent"
                                    anchors.verticalCenter: parent.verticalCenter

                                    MouseArea {
                                        id: titlePrevBtn
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.prevTrack()
                                    }

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "skip_previous"
                                        size: Theme.iconSize - 8
                                        color: titlePrevBtn.containsMouse ? Theme.primary : Theme.surfaceText
                                    }
                                }

                                // 播放/暂停（主题色圆形背景 + 黑色图标）
                                Rectangle {
                                    width: 26
                                    height: 26
                                    radius: 13
                                    color: root.connected
                                        ? (titlePlayBtn.containsMouse ? Qt.lighter(Theme.primary, 1.15) : Theme.primary)
                                        : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter

                                    MouseArea {
                                        id: titlePlayBtn
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.togglePlayPause()
                                    }

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: root.isPlaying ? "pause" : "play_arrow"
                                        size: 15
                                        color: "#000000"
                                    }
                                }

                                // 下一曲（透明背景 + hover 反馈）
                                Rectangle {
                                    width: 22
                                    height: 22
                                    radius: 11
                                    color: titleNextBtn.containsMouse
                                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
                                        : "transparent"
                                    anchors.verticalCenter: parent.verticalCenter

                                    MouseArea {
                                        id: titleNextBtn
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.nextTrack()
                                    }

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "skip_next"
                                        size: Theme.iconSize - 8
                                        color: titleNextBtn.containsMouse ? Theme.primary : Theme.surfaceText
                                    }
                                }
                            }
                        }
                    }
                }

                // ── 歌词预览：当前行 + 上下文 ──
                // 标题行：歌词图标 + "歌词"（与上方 SPlayer 标题对齐）
                // 图标尺寸与作者/专辑行一致（14px），并用 y 微调垂直居中，
                // 避免图标因字形基线差异显得略高
                // 注意：不能用 anchors.verticalCenter（anchors 会覆盖 y 赋值，
                // 导致偏移不生效），改用显式 y 计算 = 居中 + 下移补偿
                Row {
                    width: parent.width
                    leftPadding: Theme.spacingS
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: "lyrics"
                        size: 14
                        color: Theme.surfaceVariantText
                        // 垂直居中（Row 高度内）再下移 1px 补偿字形偏移
                        y: (parent.height - height) / 2 + 1
                    }

                    StyledText {
                        text: "歌词"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Rectangle {
                    width: parent.width
                    // 高度恒定（不随歌词有无变化）：窗口 implicitHeight 恒定，
                    // 避免切到无歌词歌曲时窗口变小、切回有歌词歌曲时被截断。
                    // 注意：DankPopout 的 renderedAlignedHeight 是快照，
                    // 窗口高度在打开时固定、运行时无法动态 resize，
                    // 因此这里用固定值（内容多时内部滚动）。
                    height: 300 + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.3)

                    // 无歌词时显示占位文字
                    StyledText {
                        anchors.centerIn: parent
                        text: root.lyricsLines.length > 0 ? "" : "等待 SPlayer 推送…"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        visible: root.lyricsLines.length === 0
                    }

                    ListView {
                        id: lyricList
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        clip: true
                        interactive: true
                        model: root.lyricsLines
                        spacing: 6
                        currentIndex: root.currentLineIndex
                        preferredHighlightBegin: height / 2 - 14
                        preferredHighlightEnd: height / 2 + 14
                        highlightRangeMode: ListView.ApplyRange
                        visible: root.lyricsLines.length > 0

                        // 高亮条：当前行背景平滑滑动（行切换渐变效果）
                        // x/width 与 delegate 文字 padding 对齐（左右完全相等）
                        highlight: Rectangle {
                            readonly property real hPad: Theme.spacingM
                            x: Theme.spacingM
                            width: lyricList.width - Theme.spacingM - hPad
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.primary, 0.10)

                            Behavior on y {
                                NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                            }
                        }

                        delegate: Item {
                            required property var modelData
                            required property int index

                            width: ListView.view.width
                            height: lyricRow.implicitHeight

                            // 点击歌词行 → seek 到该行开始处（MPRIS）
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.seekToLine(index)
                            }

                            // 每行三行结构：原文（大）→ 中文翻译（较小）→ 罗马音（最小）
                            // 文字 padding 与高亮条缩进完全一致（spacingM），
                            // 左右完全相等，保证高亮条与文字对齐稳定
                            Column {
                                id: lyricRow
                                width: parent.width
                                leftPadding: Theme.spacingM
                                rightPadding: Theme.spacingM
                                topPadding: Theme.spacingS
                                bottomPadding: Theme.spacingS
                                spacing: 4

                                // 原文歌词（大）：当前行逐字高亮（yrc），否则整行高亮
                                // 宽度减一字宽：提前约一个字 elide/换行，
                                // 右端留出可见留白，避免紧贴高亮条边界
                                StyledText {
                                    width: parent.width - Theme.fontSizeMedium
                                    text: root._wordHighlightHtml(modelData, index === root.currentLineIndex)
                                        || modelData.text
                                    textFormat: Text.RichText
                                    font.pixelSize: index === root.currentLineIndex
                                        ? Theme.fontSizeMedium + 2
                                        : Theme.fontSizeMedium
                                    font.weight: index === root.currentLineIndex ? Font.DemiBold : Font.Normal
                                    color: index === root.currentLineIndex ? Theme.primary : Theme.surfaceText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1

                                    Behavior on font.pixelSize {
                                        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
                                    }
                                    Behavior on color {
                                        ColorAnimation { duration: 200 }
                                    }
                                }

                                // 中文翻译（较小）
                                StyledText {
                                    width: parent.width - Theme.fontSizeSmall
                                    text: modelData.translated
                                    visible: modelData.translated !== ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.withAlpha(Theme.surfaceText, 0.72)
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                // 罗马音（最小 + 斜体）
                                StyledText {
                                    width: parent.width - (Theme.fontSizeSmall - 1)
                                    text: modelData.roman
                                    visible: modelData.roman !== ""
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.italic: true
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                        }
                    }
                }
                }   // popoutCol
        }
    }

    popoutWidth: 380
    popoutHeight: 520

    Component.onCompleted: {
        console.info("[LiveLyrics] SPlayer 版插件加载完成，bridge: " + bridgeScript)
        if (_bridgeWanted)
            bridgeProcess.running = true
    }
}
