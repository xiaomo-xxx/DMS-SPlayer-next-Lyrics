import Quickshell
import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets
import qs.Modules.Settings.Widgets

// ─────────────────────────────────────────────────────────────────────────────
//  LiveLyrics (SPlayer edition) — 设置页
//  配置项会写入 pluginData，LiveLyrics.qml 通过 pluginData.xxx 读取。
// ─────────────────────────────────────────────────────────────────────────────

PluginSettings {
    id: root
    pluginId: "liveLyrics"

    // 实例上下文（桌面组件实例设置页注入；全局设置页不注入 → 保持空）
    property string instanceId: ""
    property var instanceData: null

    readonly property bool isInstance: root.instanceId !== "" || root.instanceData !== null
    readonly property var cfg: root.isInstance
        ? (root.instanceData?.config ?? {})
        : (SettingsData.getPluginSettingsForPlugin(root.pluginId) ?? {})

    // 供 SettingsColorPicker / SettingsSliderRow / SettingsDisplayPicker 使用
    function updateConfig(key, value) {
        root.saveValue(key, value)
    }

    // 颜色值 → hex 字符串
    function colorToHex(v) {
        if (v === undefined || v === null)
            return "#6750A4"
        if (typeof v === "string") {
            var s = v.trim()
            return s.charAt(0) === "#" ? s : "#" + s
        }
        var str = v.toString()
        return "#" + str.slice(-6)
    }

    StyledText {
        width: parent.width
        text: "DMS SPlayer Lyrics"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "通过 WebSocket 连接 SPlayer，在 DankBar 显示实时歌词。"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // ── SPlayer 连接（仅全局设置显示；实例设置不显示）──
    StyledRect {
        width: parent.width
        visible: !root.isInstance
        height: connectionColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: connectionColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "SPlayer 连接"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StringSetting {
                settingKey: "splayerHost"
                label: "主机地址"
                description: "SPlayer WebSocket 服务地址"
                placeholder: "127.0.0.1"
                defaultValue: "127.0.0.1"
            }

            StringSetting {
                settingKey: "splayerPort"
                label: "端口"
                description: "SPlayer 默认 WebSocket 端口为 25885"
                placeholder: "25885"
                defaultValue: "25885"
            }
        }
    }

    // ── 通用（Bar + 桌面组件共用；仅全局设置显示，单一来源）──
    // 未启动自动隐藏 / 波形动画由这一个开关统一控制，详情页与桌面组件同步生效。
    // 实例设置中不显示（避免写入实例 config 造成两处开关分裂）
    StyledRect {
        width: parent.width
        visible: !root.isInstance
        height: generalColumn.implicitHeight + Theme.spacingL * 2
        implicitHeight: height
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: generalColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "通用"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            ToggleSetting {
                settingKey: "autoHideWhenClosed"
                label: "SPlayer 未启动时自动隐藏"
                description: "SPlayer 进程未启动时隐藏 Bar 组件与桌面组件（每 5 秒检测，启动后自动恢复）"
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "waveAnimation"
                label: "波形进度条动画"
                description: "详情页/桌面组件波形进度条播放时波动动画。桌面组件常驻时关闭可降低 CPU 占用"
                defaultValue: true
            }
        }
    }

    // ── Bar 显示（仅 Bar 专属设置；仅全局设置显示）──
    StyledRect {
        width: parent.width
        visible: !root.isInstance
        height: barDisplayColumn.implicitHeight + Theme.spacingL * 2
        implicitHeight: height
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: barDisplayColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Bar 显示"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            ToggleSetting {
                settingKey: "showTitleFallback"
                label: "无歌词时显示歌曲标题"
                description: "当前歌曲没有歌词时，在 Bar 上显示歌曲标题"
                defaultValue: true
            }

            ToggleSetting {
                settingKey: "showConnectionStatus"
                label: "详情页连接状态"
                description: "详情页顶部显示连接状态条（已连接/未连接）"
                defaultValue: true
            }

            SelectionSetting {
                settingKey: "barLyricMode"
                label: "状态栏歌词样式"
                description: "Bar 上歌词显示：原文 / 中文翻译 / 原文+翻译 / 隐藏（仅保留音乐图标）"
                options: [
                    { label: "原文", value: "original" },
                    { label: "中文翻译", value: "translation" },
                    { label: "原文 + 翻译", value: "both" },
                    { label: "隐藏", value: "hidden" }
                ]
                defaultValue: "original"
            }

            StringSetting {
                settingKey: "vScrollSpeed"
                label: "歌词滚动速度"
                description: "水平/垂直 Bar 歌词滚动速度（px/帧，每 25ms 一帧；支持一位小数，如 2.5）"
                placeholder: "2.5"
                defaultValue: "2.5"
            }
        }
    }

    // ── 桌面组件（仅实例设置显示；全局隐藏）──
    // 桌面组件配置的唯一来源是实例 config（写入实例即生效，无全局覆盖混淆）。
    // 全局设置中不显示此区，避免全局改桌面配置与实例覆盖产生不一致。
    StyledRect {
        width: parent.width
        visible: root.isInstance
        height: desktopColumn.implicitHeight + Theme.spacingL * 2
        implicitHeight: height
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: desktopColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "桌面组件"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            SelectionSetting {
                settingKey: "desktopMode"
                label: "显示模式"
                description: "桌面组件显示内容：全部 / 仅播放器 / 仅歌词"
                options: [
                    { label: "全部显示", value: "all" },
                    { label: "仅播放器", value: "player" },
                    { label: "仅歌词", value: "lyrics" }
                ]
                defaultValue: "all"
            }

            StyledText {
                width: parent.width
                text: "强调色"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            // 强调色选择（主色/辅色/自定义色块，经 DMS 弹窗选色）
            // 注意：弹窗的 hex 输入框需按回车生效后再点 Save
            SettingsColorPicker {
                id: accentPicker
                width: parent.width
                colorMode: root.cfg.desktopAccentMode ?? "primary"
                customColor: root.cfg.desktopCustomColor ?? "#6750A4"
                pickerTitle: "选择强调色"
                onColorModeSelected: mode => root.updateConfig("desktopAccentMode", mode)
                onCustomColorSelected: color => root.updateConfig("desktopCustomColor", root.colorToHex(color))
            }

            // 自定义色 hex 直接输入（输入后按回车生效，立即写入配置）
            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    text: "自定义色 (#RRGGBB)"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                DankTextField {
                    id: customHexField
                    width: 130
                    height: 32
                    text: root.colorToHex(root.cfg.desktopCustomColor)
                    placeholderText: "#6750A4"
                    font.pixelSize: Theme.fontSizeSmall
                    backgroundColor: Theme.surfaceHover
                    borderWidth: 1
                    topPadding: Theme.spacingS
                    bottomPadding: Theme.spacingS
                    onAccepted: () => {
                        const hexPattern = /^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/
                        if (!hexPattern.test(text))
                            return
                        var hex = text.charAt(0) === "#" ? text : "#" + text
                        root.updateConfig("desktopCustomColor", hex)
                        root.updateConfig("desktopAccentMode", "custom")
                    }
                }
            }

            SettingsSliderRow {
                id: bgOpacitySlider
                text: "背景透明度"
                description: "桌面组件背景不透明度（0 = 全透明，100 = 不透明）"
                value: root.cfg.desktopBgOpacity ?? 60
                minimum: 0
                maximum: 100
                // 关键：用 sliderDragFinished（用户拖动结束才触发）写入！
                // onValueChanged 只在绑定重算时触发，用户拖动不触发 → 设置不生效
                onSliderDragFinished: finalValue => root.updateConfig("desktopBgOpacity", finalValue)
            }

            // 显示器选择（仅实例设置显示；全局配置为 ["all"]）
            SettingsDisplayPicker {
                visible: root.isInstance
                displayPreferences: root.cfg.displayPreferences ?? ["all"]
                onPreferencesChanged: prefs => root.updateConfig("displayPreferences", prefs)
            }
        }
    }

    // ── 提示（仅全局设置显示；实例设置不显示）──
    StyledRect {
        width: parent.width
        visible: !root.isInstance
        height: hintColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: hintColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "调试"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: "插件通过 bridge/splayer_bridge.py 连接 SPlayer。可用环境变量覆盖：\n"
                    + "DMS_LIVELYRICS_BRIDGE —— bridge 脚本路径\n"
                    + "DMS_LIVELYRICS_PYTHON —— python 可执行文件\n"
                    + "bridge 日志输出到 DMS 日志（搜索 [LiveLyrics][bridge]）。"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }

}
