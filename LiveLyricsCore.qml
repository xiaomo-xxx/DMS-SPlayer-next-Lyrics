import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Common
import qs.Services

// ─────────────────────────────────────────────────────────────────────────────
//  LiveLyricsCore — 桌面组件的纯逻辑核心（Item 根）
//
//  为什么不用 PluginComponent（LiveLyrics.qml）？
//    PluginComponent 硬编码实例化 Bar 上下文对象（PluginPopout layer surface、
//    BasePill×2、visibilityProcess、PluginService 绑定链）。即使 headless
//    模式置空 pill/popout，这些对象仍存在——实测在 Niri 上持续消耗 ~60-100%
//    CPU（gdb 定位到绑定风暴 + harfbuzz shaping）。桌面组件常驻 = 永不停止。
//
//  本组件是干净 Item：仅 bridge 生命周期 + 事件解析 + 歌词查找 + 控制函数。
//  数据源全部为 WebSocket（SPlayer 推送），不持有 MPRIS 常驻绑定
//  （控制/seek 时临时访问 MprisController.activePlayer，零绑定链）。
//
//  配置（由 LiveLyricsDesktop.qml 注入）：
//    pluginData —— 合并后的设置（splayerHost/splayerPort/waveAnimation/accentOverride）
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // ── 配置（桌面组件注入）──
    property var pluginData: ({})
    property string splayerHost: pluginData.splayerHost ?? "127.0.0.1"
    property string splayerPort: pluginData.splayerPort ?? "25885"
    property bool waveAnimation: pluginData.waveAnimation ?? true
    property color accentOverride: "transparent"

    // ── 状态 ──
    property bool connected: false
    property string lastError: ""
    property string currentTitle: ""
    property string currentSongName: ""
    property string currentArtist: ""
    property string currentAlbum: ""
    property string currentCoverUrl: ""
    property int currentDuration: 0
    property int currentTime: 0
    property bool isPlaying: false
    property var lyricsLines: []
    property int currentLineIndex: -1
    property int currentWordIndex: -1

    property var _lastReportedTime: 0
    property var _lastProgressAt: 0
    property int _restartDelay: 0

    // ── bridge 脚本路径（与 LiveLyrics.qml 相同约定）──
    function _bridgeScriptPath() {
        var override = Quickshell.env("DMS_LIVELYRICS_BRIDGE")
        if (override && override !== "")
            return override
        var configHome = Quickshell.env("XDG_CONFIG_HOME")
        if (!configHome || configHome === "")
            configHome = (Quickshell.env("HOME") || "") + "/.config"
        return configHome + "/DankMaterialShell/plugins/livelyrics/bridge/splayer_bridge.py"
    }

    function _pythonBin() {
        var override = Quickshell.env("DMS_LIVELYRICS_PYTHON")
        return (override && override !== "") ? override : "python3"
    }

    property string bridgeScript: _bridgeScriptPath()

    // ── bridge 进程 ──
    Process {
        id: bridgeProcess
        command: [root._pythonBin(), root.bridgeScript, root.splayerHost, root.splayerPort]
        running: false
        stdinEnabled: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root._onBridgeLine(data)
        }
        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                var line = (data || "").trim()
                if (line !== "")
                    console.warn("[LiveLyricsDesktop][bridge] " + line)
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.connected = false
            root._scheduleRestart()
        }
    }

    readonly property bool _bridgeWanted: root.splayerPort !== ""

    on_BridgeWantedChanged: {
        if (root._bridgeWanted)
            bridgeProcess.running = true
        else
            bridgeProcess.running = false
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

    function _restartBridge() {
        root._restartDelay = 0
        bridgeRestartTimer.stop()
        bridgeProcess.running = false
        bridgeProcess.running = true
    }

    onSplayerHostChanged: _restartBridge()
    onSplayerPortChanged: _restartBridge()

    // 通过 bridge 向 SPlayer 发送命令（stdin 通道）
    function _wsCommand(command) {
        if (!bridgeProcess.running) {
            console.warn("[LiveLyricsDesktop] bridge 未运行，无法发送: " + command)
            return
        }
        bridgeProcess.write(JSON.stringify({ type: "control", data: { command: command } }) + "\n")
    }

    // ── 事件分发 ──
    function _onBridgeLine(rawLine) {
        var line = (rawLine || "").trim()
        if (line === "")
            return
        var msg
        try {
            msg = JSON.parse(line)
        } catch (e) {
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
            break
        case "__error":
            root.lastError = msg.data && msg.data.message ? msg.data.message : ""
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

    function _onSongInfo(d) {
        if (!d)
            return
        var title = d.playName || d.name || d.title || ""
        var artist = d.artistName || d.artist || ""
        var album = d.albumName || d.album || ""

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
        root.currentCoverUrl = d.cover || ""
        if (d.duration > 0)
            root.currentDuration = d.duration

        if (!sameTrack) {
            root.lyricsLines = []
            root.currentLineIndex = -1
            root.currentWordIndex = -1
        }

        var hasLyricData = (Array.isArray(d.lrcData) && d.lrcData.length > 0)
            || (Array.isArray(d.yrcData) && d.yrcData.length > 0)
        if (hasLyricData && !sameTrack) {
            root._onLyricChange({ lrcData: d.lrcData, yrcData: d.yrcData })
        }

        if (typeof d.currentTime === "number" && d.currentTime >= 0) {
            root.currentTime = d.currentTime
            root._lastReportedTime = d.currentTime
            root._lastProgressAt = d.playStatus === true ? Date.now() : 0
            root._updateCurrentLine()
        }

        if (d.playStatus !== undefined)
            root._onStatusChange({ status: d.playStatus === true })
    }

    function _onSongChange(d) {
        var title = d.title || d.name || ""
        var artist = d.artist || ""
        var songName = d.name || ""

        var curTitle = root.currentTitle
        var curArtist = root.currentArtist
        var curName = root.currentSongName

        var sameTrack = false
        if (curTitle === title && curArtist === artist) {
            sameTrack = true
        } else if (songName && songName !== "" && curTitle.indexOf(songName) >= 0) {
            sameTrack = true
        } else if (curName && curName !== "" && title.indexOf(curName) >= 0) {
            sameTrack = true
        }

        root.currentTitle = title
        root.currentSongName = songName
        root.currentArtist = artist
        root.currentAlbum = d.album || ""
        root.currentCoverUrl = d.cover || ""
        root.currentDuration = d.duration > 0 ? d.duration : 0

        if (sameTrack) {
            root._updateCurrentLine()
        } else {
            root.currentTime = 0
            root._lastProgressAt = 0
            root.lyricsLines = []
            root.currentLineIndex = -1
            root.currentWordIndex = -1
        }
    }

    function _onLyricChange(d) {
        var source = (Array.isArray(d.yrcData) && d.yrcData.length > 0) ? d.yrcData : d.lrcData
        root.lyricsLines = root._parseLyricData(source)
        root.currentLineIndex = -1
        root.currentWordIndex = -1
        root._updateCurrentLine()
    }

    function _onProgressChange(d) {
        if (d.duration > 0)
            root.currentDuration = d.duration
        var serverTime = typeof d.currentTime === "number" ? d.currentTime : -1
        if (serverTime >= 0) {
            if (root.isPlaying && root._lastProgressAt > 0) {
                // 播放中：本地 positionTicker 平滑推进，服务器轮询值可能略落后。
                // 偏差在 1s 内保持本地推进值，避免时间小幅"回退"导致歌词行抖动；
                // 偏差 > 1s 视为 seek/拖动，才校正。
                var drift = serverTime - root.currentTime
                if (drift >= -1000 && drift <= 1000) {
                    root._lastReportedTime = root.currentTime
                    root._lastProgressAt = Date.now()
                    root._updateCurrentLine()
                    return
                }
            }
            root.currentTime = serverTime
        }
        if (root.isPlaying) {
            root._lastReportedTime = root.currentTime
            root._lastProgressAt = Date.now()
        }
        root._updateCurrentLine()
    }

    function _onStatusChange(d) {
        var playing = d.status === true
        root.isPlaying = playing
        if (playing) {
            root._lastReportedTime = root.currentTime
            root._lastProgressAt = Date.now()
        } else {
            root._lastProgressAt = 0
        }
    }

    // ── 歌词解析（与 LiveLyrics.qml 相同）──
    function _coerceText(v) {
        if (v === undefined || v === null)
            return ""
        if (typeof v === "string")
            return v
        if (Array.isArray(v))
            return v.map(x => (x && typeof x === "object") ? (x.text || x.word || "") : String(x)).join(" ")
        return String(v)
    }

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
                if (text !== "" && word !== "" && !word.startsWith(" ") && !text.endsWith(" "))
                    text += " "
                text += word
                if (startTime < 0 && typeof w.startTime === "number")
                    startTime = w.startTime
                if (typeof w.endTime === "number" && w.endTime > endTime)
                    endTime = w.endTime
                words.push({
                    startTime: typeof w.startTime === "number" ? w.startTime : -1,
                    endTime: typeof w.endTime === "number" ? w.endTime : -1,
                    word: word
                })
            }
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

    // ── 行查找 ──
    function _updateCurrentLine() {
        var lines = root.lyricsLines
        if (lines.length === 0) {
            root.currentLineIndex = -1
            return
        }
        var t = root.currentTime
        var idx = -1
        for (var i = 0; i < lines.length; i++) {
            if (t >= lines[i].startTime)
                idx = i
            else
                break
        }
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

    // 逐字高亮富文本（与 LiveLyrics.qml 相同）
    function _wordHighlightHtml(line, isCurrent) {
        if (!line || !line.words || line.words.length === 0)
            return null
        if (!isCurrent || root.currentWordIndex < 0)
            return null
        var spanColor = root.accentOverride.toString() !== "#00000000"
            ? root.accentOverride
            : Theme.primary
        var html = ""
        var emitted = false
        for (var i = 0; i < line.words.length; i++) {
            var w = line.words[i]
            if (!w || w.word === undefined || w.word === null)
                continue
            var word = w.word.trim()
            if (word === "")
                continue
            if (emitted)
                html += " "
            var color = (i <= root.currentWordIndex) ? spanColor : Theme.surfaceText
            html += "<span style='color:" + color + ";'>" + word + "</span>"
            emitted = true
        }
        return html
    }

    // 播放中平滑推进
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

    // ── 显示辅助 ──
    readonly property string displayTitle: root.currentSongName !== ""
        ? root.currentSongName
        : root.currentTitle

    readonly property var currentLine: currentLineIndex >= 0 && currentLineIndex < lyricsLines.length
        ? lyricsLines[currentLineIndex]
        : null

    function _fmtTime(ms) {
        if (ms <= 0)
            return "0:00"
        var total = Math.floor(ms / 1000)
        var m = Math.floor(total / 60)
        var s = total % 60
        return m + ":" + ("0" + s).slice(-2)
    }

    // ── 控制（MPRIS 临时访问，无常驻绑定）──
    function togglePlayPause() {
        var player = MprisController.activePlayer
        if (player && player.canTogglePlaying) {
            player.togglePlaying()
            return
        }
        root._wsCommand("toggle")
    }

    function prevTrack() {
        var player = MprisController.activePlayer
        if (player && player.canGoPrevious) {
            player.previous()
            return
        }
        root._wsCommand("prev")
    }

    function nextTrack() {
        var player = MprisController.activePlayer
        if (player && player.canGoNext) {
            player.next()
            return
        }
        root._wsCommand("next")
    }

    function seekToLine(index) {
        if (index < 0 || index >= root.lyricsLines.length)
            return
        var player = MprisController.activePlayer
        if (player && player.canSeek) {
            var startMs = root.lyricsLines[index].startTime
            if (startMs < 0)
                return
            player.position = startMs / 1000
            return
        }
        console.warn("[LiveLyricsDesktop] MPRIS 不可用，无法 seek")
    }

    function seekToRatio(ratio) {
        var player = MprisController.activePlayer
        if (player && player.canSeek && player.length > 0) {
            player.position = Math.max(0, Math.min(1, ratio)) * player.length * 0.99
        }
    }

    Component.onCompleted: {
        if (root._bridgeWanted)
            bridgeProcess.running = true
    }
}
