/*
 * Appearance: look (Plasma or porcelain), font, colours, capsule and border.
 * Everything defaults to "follow the panel"; each section can be taken over.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as QtDialogs
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQuickControls

KCM.SimpleKCM {
    id: page

    property string cfg_style
    property string cfg_colors

    property alias cfg_customFont: customFontRadio.checked
    property string cfg_fontFamily
    property int cfg_fontSize
    property int cfg_fontWeight
    property bool cfg_fontItalic

    property color cfg_textColor
    property color cfg_accentColor
    property color cfg_attentionColor
    property color cfg_doneColor
    property color cfg_backgroundColor
    property color cfg_borderColor

    property alias cfg_capsule: capsuleCheck.checked
    property alias cfg_borderWidth: borderSpin.value
    property alias cfg_cornerRadius: radiusSpin.value

    readonly property bool customColors: cfg_colors === "custom"

    function fontLabel() {
        const fam = cfg_fontFamily || Kirigami.Theme.defaultFont.family
        const size = cfg_fontSize > 0 ? cfg_fontSize : Kirigami.Theme.defaultFont.pointSize
        let s = fam + " " + size + "pt"
        if (cfg_fontWeight >= 600) s += " bold"
        else if (cfg_fontWeight > 0 && cfg_fontWeight < 400) s += " light"
        if (cfg_fontItalic) s += " italic"
        return s
    }

    QtDialogs.FontDialog {
        id: fontDialog
        title: "Pill font"
        onAccepted: {
            page.cfg_fontFamily = selectedFont.family
            page.cfg_fontSize = selectedFont.pointSize
            page.cfg_fontWeight = selectedFont.weight
            page.cfg_fontItalic = selectedFont.italic
            customFontRadio.checked = true
        }
    }

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: styleCombo
            Kirigami.FormData.label: "Look:"
            textRole: "text"
            valueRole: "value"
            model: [
                { text: "Plasma · follows your colour scheme and panel font", value: "plasma" },
                { text: "Porcelain · the macOS cc-pill pill", value: "porcelain" }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_style))
            onActivated: page.cfg_style = currentValue
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Font" }

        QQC2.RadioButton {
            id: panelFontRadio
            Kirigami.FormData.label: "Font:"
            text: "The panel's font"
            checked: !customFontRadio.checked
        }
        RowLayout {
            QQC2.RadioButton {
                id: customFontRadio
                text: "Custom:"
            }
            QQC2.Button {
                text: page.fontLabel() + "…"
                icon.name: "font"
                onClicked: {
                    fontDialog.selectedFont = Qt.font({
                        family: page.cfg_fontFamily || Kirigami.Theme.defaultFont.family,
                        pointSize: page.cfg_fontSize > 0 ? page.cfg_fontSize : Kirigami.Theme.defaultFont.pointSize,
                        weight: page.cfg_fontWeight || 400,
                        italic: page.cfg_fontItalic
                    })
                    fontDialog.open()
                }
            }
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Colours" }

        QQC2.ComboBox {
            id: colorsCombo
            Kirigami.FormData.label: "Colours:"
            textRole: "text"
            valueRole: "value"
            model: [
                { text: "Follow the colour scheme (or the porcelain palette)", value: "scheme" },
                { text: "Custom", value: "custom" }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_colors))
            onActivated: page.cfg_colors = currentValue
        }

        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Text:"
            enabled: page.customColors
            color: page.cfg_textColor
            showAlphaChannel: true
            onColorChanged: page.cfg_textColor = color
        }
        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Accent (working, voice):"
            enabled: page.customColors
            color: page.cfg_accentColor
            showAlphaChannel: true
            onColorChanged: page.cfg_accentColor = color
        }
        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Needs you:"
            enabled: page.customColors
            color: page.cfg_attentionColor
            showAlphaChannel: true
            onColorChanged: page.cfg_attentionColor = color
        }
        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Done:"
            enabled: page.customColors
            color: page.cfg_doneColor
            showAlphaChannel: true
            onColorChanged: page.cfg_doneColor = color
        }
        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Capsule fill:"
            enabled: page.customColors
            color: page.cfg_backgroundColor
            showAlphaChannel: true
            onColorChanged: page.cfg_backgroundColor = color
        }
        KQuickControls.ColorButton {
            Kirigami.FormData.label: "Border:"
            enabled: page.customColors
            color: page.cfg_borderColor
            showAlphaChannel: true
            onColorChanged: page.cfg_borderColor = color
        }

        QQC2.CheckBox {
            id: capsuleCheck
            Kirigami.FormData.label: "Capsule:"
            visible: !page.customColors
            text: "tint a capsule behind the pill, in the scheme's text colour"
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Border" }

        QQC2.SpinBox {
            id: borderSpin
            Kirigami.FormData.label: "Border width:"
            from: 0
            to: 6
            textFromValue: function(value) { return value === 0 ? "none" : value + " px" }
            valueFromText: function(text) { return parseInt(text, 10) || 0 }
        }

        QQC2.SpinBox {
            id: radiusSpin
            Kirigami.FormData.label: "Corner radius:"
            from: 0
            to: 99
            textFromValue: function(value) { return value >= 99 ? "round" : value + " px" }
            valueFromText: function(text) { return parseInt(text, 10) || 0 }
        }

        QQC2.Label {
            text: "The capsule, its border and corners show with a fill or border colour that isn't transparent."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }
}
