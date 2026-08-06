import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// ─────────────────────────────────────────────────────────────────────────────
//  LiveLyrics (SPlayer edition) — 桌面组件
//
//  与 Bar 插件（LiveLyrics.qml）共用同一套逻辑与配置：
//    - 逻辑核心：Loader 加载 LiveLyrics.qml（headless 模式，仅纯逻辑：
//      bridge 生命周期 / 事件分发 / 歌词解析 / MPRIS 自愈 / 控制函数）
//    - 配置：注入同一份 pluginData（与 Bar 共享 splayerHost/Port 等设置）
//    - 多客户端：SPlayer WebSocket 支持多个连接（已实测）
//
//  桌面组件自定义配置（pluginData，与 Bar 共享设置页）：
//    - desktopMode       显示模式: all（全部）/ player（仅播放器）/ lyrics（仅歌词）
//    - desktopAccentMode 强调色: primary（主色）/ secondary（辅色）/ custom（自定义）
//    - desktopCustomColor 自定义强调色（hex）
//    - desktopBgOpacity  背景透明度（0-100，百分比）
//    - displayPreferences 显示器选择（实例级，DMS 内置）
//
//  性能：桌面组件常驻，MPRIS 位置轮询用 250ms 低频（避免高频 D-Bus 往返）。
//  波浪进度条动画与 Bar 详情页一致（播放中波动），由 MPRIS 播放状态驱动。
// ─────────────────────────────────────────────────────────────────────────────

DesktopPluginComponent {
    id: root

    // 初始尺寸（wrapper 会以此为默认保存，并随后绑定为动态尺寸）
    widgetWidth: 380
    widgetHeight: 420
    minWidth: 300
    minHeight: 380

    // ─────────────────────────────────────────────────────────────────────
    // 逻辑核心：加载 LiveLyricsCore.qml（纯 Item 逻辑）
    // 不用 LiveLyrics.qml（PluginComponent）：其基类硬编码 Bar 上下文对象
    // （PluginPopout layer surface / BasePill / PluginService 绑定链），
    // headless 也不销毁——实测 Niri 上持续 ~60-100% CPU。
    // LiveLyricsCore 是干净 Item，仅 bridge + 解析 + 控制。
    // ─────────────────────────────────────────────────────────────────────
    property alias core: coreLoader.item

    Loader {
        id: coreLoader
        sourceComponent: Component {
            LiveLyricsCore {}
        }
    }

    // 将合并配置（全局 + 实例）注入逻辑核心
    // 将合并配置（全局 + 实例）注入逻辑核心
    // 通用键（waveAnimation/autoHideWhenClosed/host/port）只取全局：
    // 实例 config 不再包含这些键（设置页已隐藏通用区），即使有残留也不覆盖全局
    function _mergedConfig() {
        var merged = {}
        try {
            var global = SettingsData.getPluginSettingsForPlugin(root.pluginId)
            for (var k in global)
                merged[k] = global[k]
        } catch (e) {}
        for (var k2 in root.pluginData) {
            if (k2 === "waveAnimation" || k2 === "autoHideWhenClosed"
                    || k2 === "splayerHost" || k2 === "splayerPort")
                continue   // 通用键不被实例覆盖
            merged[k2] = root.pluginData[k2]
        }
        return merged
    }

    function _syncCoreConfig() {
        var item = coreLoader.item
        if (item && root.pluginId !== "") {
            item.pluginData = root._mergedConfig()
            item.splayerHost = item.pluginData.splayerHost ?? "127.0.0.1"
            item.splayerPort = item.pluginData.splayerPort ?? "25885"
            item.waveAnimation = item.pluginData.waveAnimation ?? true
            item.accentOverride = root.accentColor
        }
    }

    Connections {
        target: root
        function onPluginIdChanged() {
            Qt.callLater(() => root._syncCoreConfig())
        }
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId) {
                Qt.callLater(() => root._syncCoreConfig())
                // 关键：实例模式下 pluginData = instanceConfig，全局设置变化
                // 不会触发 onPluginDataChanged → effectiveCfg 不刷新 →
                // autoHideWhenClosed 等通用键保持旧值（隐藏不生效的根因）
                Qt.callLater(() => root._refreshEffectiveCfg())
            }
        }
    }

    // 实例配置更新（设置页写入实例 config）→ 重新同步 core（accentOverride）
    // 注：UI 属性（desktopMode/accentColor/bgOpacity）绑定 pluginData 会自动更新，
    // 但 core.accentOverride 是手动赋值，需在此跟随刷新
    Connections {
        target: root
        function onInstanceDataChanged() {
            Qt.callLater(() => root._syncCoreConfig())
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 桌面组件配置（实例 config 覆盖全局，合并后生效）
    // 注意：不能用绑定调用 _mergedConfig()（QML 无法追踪函数内依赖，
    // 只在创建时求值一次）→ 用 var 属性 + 手动刷新
    // ─────────────────────────────────────────────────────────────────────
    property var effectiveCfg: ({
        desktopMode: "all",
        desktopAccentMode: "primary",
        desktopCustomColor: "#6750A4",
        desktopBgOpacity: 60
    })

    function _refreshEffectiveCfg() {
        root.effectiveCfg = root._mergedConfig()
    }

    // pluginData 变化（全局设置/实例配置更新）→ 刷新合并配置
    onPluginDataChanged: root._refreshEffectiveCfg()

    // 显示模式: all / player / lyrics
    property string desktopMode: effectiveCfg.desktopMode ?? "all"
    // 强调色模式: primary / secondary / custom
    property string accentMode: effectiveCfg.desktopAccentMode ?? "primary"
    property color customAccentColor: effectiveCfg.desktopCustomColor ?? "#6750A4"
    // 背景透明度（0-100 → 0.0-1.0）
    property real bgOpacity: {
        var raw = parseFloat(effectiveCfg.desktopBgOpacity)
        return raw >= 0 && raw <= 100 ? raw / 100 : 0.6
    }

    readonly property color accentColor: {
        if (root.accentMode === "secondary")
            return Theme.secondary
        if (root.accentMode === "custom")
            return root.customAccentColor
        return Theme.primary
    }

    readonly property bool showPlayer: root.desktopMode !== "lyrics"
    readonly property bool showLyrics: root.desktopMode !== "player"

    // ─────────────────────────────────────────────────────────────────────
    // 跟随 SPlayer 进程隐藏（与 Bar 的 visibilityCommand 相同机制）
    // 复用全局通用设置 autoHideWhenClosed（经 effectiveCfg 合并，不被实例覆盖）：
    // 开启时 SPlayer 未运行 → 组件淡出；关闭 → 始终显示
    // ─────────────────────────────────────────────────────────────────────
    property bool splayerAlive: true
    readonly property bool hideWhenClosed: root.effectiveCfg.autoHideWhenClosed ?? true
    readonly property real _targetOpacity: (hideWhenClosed && !splayerAlive) ? 0 : 1

    opacity: root._targetOpacity
    enabled: opacity > 0.01

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }
    }

    // 每 5 秒检测 SPlayer 进程（与 Bar 插件 visibilityCommand 相同命令）
    Timer {
        id: splayerCheckTimer
        interval: 5000
        repeat: true
        running: true
        onTriggered: splayerCheckProcess.running = true
    }

    Process {
        id: splayerCheckProcess
        command: ["sh", "-c", "pgrep -x SPlayer"]
        running: false
        onExited: (exitCode, exitStatus) => {
            root.splayerAlive = (exitCode === 0)
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => root._syncCoreConfig())
        // 初始立即检测一次（避免 SPlayer 已关闭时组件短暂闪现）
        splayerCheckProcess.running = true
    }

    // ─────────────────────────────────────────────────────────────────────
    // UI（详情页样式 + 自定义配置）
    // ─────────────────────────────────────────────────────────────────────

    // 背景（桌面组件自带圆角面板，透明度可配置）
    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surface, root.bgOpacity)
    }

    Item {
        id: uiRoot
        anchors.fill: parent
        anchors.margins: Theme.spacingM

        // ── 歌曲卡片（anchors 链式布局，Column 不可用：implicitHeight=0）──
        // 连接状态条已移除（桌面组件不显示连接状态，设置页同步说明）
        Rectangle {
            id: songCard
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            visible: root.showPlayer
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.4)

            // 高度 = 信息行 + 进度条 + 时间行 + 控制按钮行 + 间距/边距
            height: topRow.implicitHeight + progressBar.height + timeRow.implicitHeight
                + controlsRow.implicitHeight + Theme.spacingS * 2 + Theme.spacingM * 2

            // ── 信息行：歌名/作者/专辑 + 封面（右侧）──
            Row {
                id: topRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                // 信息列（宽度扣除封面列）
                Column {
                    id: infoCol
                    width: parent.width - 80 - parent.spacing
                    spacing: Theme.spacingS

                    // 歌名（最多两行）
                    StyledText {
                        width: parent.width
                        text: core.displayTitle !== "" ? core.displayTitle : "没有正在播放的歌曲"
                        font.pixelSize: Theme.fontSizeLarge + 2
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        wrapMode: Text.WordWrap
                    }

                    // 作者
                    Row {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: core.currentArtist !== ""

                        DankIcon {
                            name: "person"
                            size: 14
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            width: parent.width - 14 - parent.spacing
                            text: core.currentArtist
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                    }

                    // 专辑
                    Row {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: core.currentAlbum !== ""

                        DankIcon {
                            name: "album"
                            size: 14
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            width: parent.width - 14 - parent.spacing
                            text: core.currentAlbum
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                    }
                }

                // 封面（右侧，垂直居中；DankAlbumArt，MPRIS 封面 + 频谱动画）
                // 卡顿根因已修复（布局循环），恢复完整封面样式
                DankAlbumArt {
                    id: coverArt
                    width: 80
                    height: 80
                    anchors.verticalCenter: parent.verticalCenter
                    activePlayer: MprisController.activePlayer
                    showAnimation: true
                    visible: (MprisController.activePlayer?.trackArtUrl ?? "") !== ""
                }
            }

            // ── 波形进度条（卡片全宽，不受封面影响，居中）──
            // 数据源：WebSocket（core.currentTime 由 progress-change + positionTicker
            // 200ms 平滑推进）。始终显示波形样式（播放时动画，暂停静态填充）
            M3WaveProgress {
                id: progressBar
                anchors.top: topRow.bottom
                anchors.topMargin: Theme.spacingS
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                height: 20
                visible: core.connected
                // 动画开关（通用设置）：关闭时静态填充
                isPlaying: core.waveAnimation && core.isPlaying
                // WebSocket 时间直接绑定（播放中 200ms 平滑推进，暂停静止）
                value: core.currentDuration > 0
                    ? Math.min(1, core.currentTime / core.currentDuration)
                    : 0
                actualValue: progressBar.value
                fillColor: root.accentColor
                playheadColor: root.accentColor
                trackColor: Theme.withAlpha(Theme.surfaceVariant, 0.40)
                actualProgressColor: Theme.onSurface_38

                // 点击进度条 seek（MPRIS 支持时；函数内临时访问，无常驻绑定）
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        var p = MprisController.activePlayer
                        if (p && p.canSeek && p.length > 0) {
                            var ratio = Math.max(0, Math.min(1, mouse.x / width))
                            p.position = ratio * p.length * 0.99
                        }
                    }
                }
            }

            // ── 时间行（全宽，与进度条对齐）──
            // 关键：不能用 Row + Item(width: parent.width - a.implicitWidth - b.implicitWidth)
            // 弹性占位——StyledText 整形后 implicitWidth 变化 → 触发占位 width 重算 →
            // Row 重布局 → 再次整形 → 无限循环（gdb 实证 fontconfig shaping 风暴）。
            // 改用 anchors 左右布局：零 implicitWidth 互引，无循环。
            Item {
                id: timeRow
                anchors.top: progressBar.bottom
                anchors.topMargin: 2
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                height: 14

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: core._fmtTime(core.currentTime)
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: core._fmtTime(core.currentDuration)
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }

            // ── 播放控制按钮行（卡片底部整行居中）──
            Row {
                id: controlsRow
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Theme.spacingM
                spacing: Theme.spacingL
                // 三个按钮统一高度（40px），顶对齐即中心对齐 → 同一横线

                // 上一曲
                Rectangle {
                    width: 40
                    height: 40
                    radius: 20
                    color: prevBtn.containsMouse
                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
                        : "transparent"

                    MouseArea {
                        id: prevBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: core.prevTrack()
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        name: "skip_previous"
                        size: 22
                        color: prevBtn.containsMouse ? root.accentColor : Theme.surfaceText
                    }
                }

                // 播放/暂停（强调色圆形背景 + 黑色图标）
                Rectangle {
                    width: 40
                    height: 40
                    radius: 20
                    color: core.connected
                        ? (playBtn.containsMouse ? Qt.lighter(root.accentColor, 1.15) : root.accentColor)
                        : Theme.surfaceVariantText

                    MouseArea {
                        id: playBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: core.togglePlayPause()
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        name: core.isPlaying ? "pause" : "play_arrow"
                        size: 22
                        color: "#000000"
                    }
                }

                // 下一曲
                Rectangle {
                    width: 40
                    height: 40
                    radius: 20
                    color: nextBtn.containsMouse
                        ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)
                        : "transparent"

                    MouseArea {
                        id: nextBtn
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: core.nextTrack()
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        name: "skip_next"
                        size: 22
                        color: nextBtn.containsMouse ? root.accentColor : Theme.surfaceText
                    }
                }
            }
        }

        // ── 歌词预览（弹性高度，显示模式控制）──
        Rectangle {
            id: lyricArea
            anchors.top: root.showPlayer ? songCard.bottom : parent.top
            anchors.topMargin: root.showPlayer ? Theme.spacingM : 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.showLyrics
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.3)

            // 无歌词时显示占位文字
            StyledText {
                anchors.centerIn: parent
                text: core.lyricsLines.length > 0 ? "" : "等待 SPlayer 推送…"
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                visible: core.lyricsLines.length === 0
            }

            ListView {
                id: lyricList
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                clip: true
                interactive: true
                model: core.lyricsLines
                spacing: 6
                currentIndex: core.currentLineIndex
                preferredHighlightBegin: height / 2 - 14
                preferredHighlightEnd: height / 2 + 14
                highlightRangeMode: ListView.ApplyRange
                visible: core.lyricsLines.length > 0

                // 高亮条：当前行背景平滑滑动（行切换渐变效果）
                highlight: Rectangle {
                    readonly property real hPad: Theme.spacingM
                    x: Theme.spacingM
                    width: lyricList.width - Theme.spacingM - hPad
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(root.accentColor, 0.10)

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
                        onClicked: core.seekToLine(index)
                    }

                    // 每行三行结构：原文（大）→ 中文翻译（较小）→ 罗马音（最小）
                    Column {
                        id: lyricRow
                        width: parent.width
                        leftPadding: Theme.spacingM
                        rightPadding: Theme.spacingM
                        topPadding: Theme.spacingS
                        bottomPadding: Theme.spacingS
                        spacing: 4

                        // 原文歌词（大）：当前行逐字高亮（yrc），否则整行高亮
                        // 卡顿根因（布局循环）已修复，恢复逐字高亮
                        StyledText {
                            width: parent.width - Theme.fontSizeMedium
                            text: core._wordHighlightHtml(modelData, index === core.currentLineIndex)
                                || modelData.text
                            textFormat: Text.RichText
                            font.pixelSize: index === core.currentLineIndex
                                ? Theme.fontSizeMedium + 2
                                : Theme.fontSizeMedium
                            font.weight: index === core.currentLineIndex ? Font.DemiBold : Font.Normal
                            color: index === core.currentLineIndex ? root.accentColor : Theme.surfaceText
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
    }
}
