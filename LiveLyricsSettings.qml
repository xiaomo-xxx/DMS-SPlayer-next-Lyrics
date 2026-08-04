import Quickshell
import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

// ─────────────────────────────────────────────────────────────────────────────
//  LiveLyrics (SPlayer edition) — 设置页
//  配置项会写入 pluginData，LiveLyrics.qml 通过 pluginData.xxx 读取。
// ─────────────────────────────────────────────────────────────────────────────

PluginSettings {
    id: root
    pluginId: "liveLyrics"

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

    // ── SPlayer 连接 ──
    StyledRect {
        width: parent.width
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

    // ── 显示选项 ──
    StyledRect {
        width: parent.width
        height: displayColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: displayColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "显示"
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
                settingKey: "autoHideWhenClosed"
                label: "SPlayer 未启动时自动隐藏"
                description: "SPlayer 进程未启动时隐藏 Bar 组件（每 5 秒检测，启动后自动恢复）"
                defaultValue: true
            }

            SelectionSetting {
                settingKey: "barLyricMode"
                label: "状态栏歌词语言"
                description: "Bar 上显示的歌词：原文 / 中文翻译 / 原文+翻译"
                options: [
                    { label: "原文", value: "original" },
                    { label: "中文翻译", value: "translation" },
                    { label: "原文 + 翻译", value: "both" }
                ]
                defaultValue: "original"
            }
        }
    }

    // ── 提示 ──
    StyledRect {
        width: parent.width
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
