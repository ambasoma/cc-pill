/*
 * The bloom: the briefing hanging off the panel while it is spoken, words
 * lighting up with the voice. Content of the tooltip-type window in main.qml.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: bloom

    property var ctl

    Kirigami.Theme.inherit: false
    Kirigami.Theme.colorSet: Kirigami.Theme.Window

    readonly property var b: ctl ? ctl.briefing : null
    readonly property bool customColors: ctl ? ctl.customColors : false
    readonly property color ink: customColors && ctl.theme ? ctl.theme.ink : Kirigami.Theme.textColor
    readonly property color accent: ctl && ctl.theme ? ctl.theme.gold : Kirigami.Theme.highlightColor
    readonly property font bodyFont: ctl && ctl.customFont ? ctl.customFontValue
                                   : Qt.font({ family: Kirigami.Theme.defaultFont.family,
                                               pointSize: Kirigami.Theme.defaultFont.pointSize + 1 })
    readonly property real maxTextW: Kirigami.Units.gridUnit * 24

    // wrap only when the line would be longer than the widest we allow
    TextMetrics { id: plain; font: bloom.bodyFont; text: bloom.b ? bloom.b.text : "" }

    implicitWidth: column.implicitWidth + Kirigami.Units.largeSpacing * 2
    implicitHeight: column.implicitHeight + Kirigami.Units.largeSpacing * 2
    width: implicitWidth
    height: implicitHeight

    ColumnLayout {
        id: column
        x: Kirigami.Units.largeSpacing
        y: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Rectangle {
                width: 7; height: 7; radius: 3.5
                color: bloom.accent
                Layout.alignment: Qt.AlignVCenter
                SequentialAnimation on opacity {
                    running: bloom.b !== null && !bloom.b.silent
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                }
            }
            Text {
                text: {
                    if (!bloom.b) return ""
                    const who = bloom.ctl && bloom.ctl.pillData ? bloom.ctl.pillData.voice.name : ""
                    const where = bloom.b.repo || ""
                    return [where, who].filter(s => s.length > 0).join(" · ").toUpperCase()
                }
                color: bloom.ink
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                font.weight: Font.DemiBold
                font.letterSpacing: 1.1
            }
        }

        Text {
            id: body
            Layout.preferredWidth: Math.min(bloom.maxTextW, plain.width + 4)
            width: Layout.preferredWidth
            wrapMode: Text.WordWrap
            textFormat: Text.StyledText
            font: bloom.bodyFont
            color: bloom.ink
            lineHeight: 1.15
            text: bloom.ctl ? bloom.ctl.bloomHtml(Qt.rgba(bloom.ink.r, bloom.ink.g, bloom.ink.b, 0.35).toString()) : ""
        }
    }
}
