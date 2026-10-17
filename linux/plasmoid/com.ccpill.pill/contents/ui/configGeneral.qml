import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_port: portSpin.value
    property alias cfg_showCats: catsCheck.checked
    property alias cfg_slotChars: slotSpin.value
    property string cfg_style

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

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: portSpin
            Kirigami.FormData.label: "Daemon port:"
            from: 1024
            to: 65535
            editable: true
            textFromValue: function(value) { return String(value) }
            valueFromText: function(text) { return parseInt(text, 10) || 17357 }
        }

        QQC2.Label {
            text: "Must match daemon_port in ~/.cc-pill/config.json (default 17357)."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        QQC2.SpinBox {
            id: slotSpin
            Kirigami.FormData.label: "Text width:"
            from: 8
            to: 60
            textFromValue: function(value) { return value + " characters" }
            valueFromText: function(text) { return parseInt(text, 10) || 22 }
        }

        QQC2.Label {
            text: "The widget keeps this width while sessions run; longer text glides inside it."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: catsCheck
            Kirigami.FormData.label: "Cats:"
            text: "Charlie and Lily run laps while Claude works"
        }
    }
}
