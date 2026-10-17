import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_port: portSpin.value
    property alias cfg_slotChars: slotSpin.value
    property alias cfg_openOnHover: hoverCheck.checked
    property alias cfg_hoverDelay: delaySpin.value
    property alias cfg_hitPadding: hitSpin.value
    property alias cfg_idleDot: idleCheck.checked
    property alias cfg_showCats: catsCheck.checked

    Kirigami.FormLayout {
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

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Activation" }

        QQC2.CheckBox {
            id: hoverCheck
            Kirigami.FormData.label: "Open the card:"
            text: "peek when the pointer rests on the widget (a click always opens it)"
        }

        QQC2.Label {
            text: "The peek takes no keyboard focus, so it never interrupts typing. Click for the full card with prompt fields."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
        }

        QQC2.SpinBox {
            id: delaySpin
            Kirigami.FormData.label: "Hover delay:"
            enabled: hoverCheck.checked
            from: 0
            to: 3000
            stepSize: 50
            textFromValue: function(value) { return value + " ms" }
            valueFromText: function(text) { return parseInt(text, 10) || 0 }
        }

        QQC2.SpinBox {
            id: hitSpin
            Kirigami.FormData.label: "Hit area:"
            from: 0
            to: 48
            textFromValue: function(value) { return value + " px each side" }
            valueFromText: function(text) { return parseInt(text, 10) || 0 }
        }

        QQC2.Label {
            text: "Extra space around the pill that reacts to the pointer, without changing how the pill looks."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        QQC2.CheckBox {
            id: idleCheck
            Kirigami.FormData.label: "No sessions:"
            text: "keep a faint dot so the widget stays findable and clickable"
        }

        Item { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Daemon" }

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

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: catsCheck
            Kirigami.FormData.label: "Cats:"
            text: "Charlie and Lily run laps while Claude works"
        }
    }
}
