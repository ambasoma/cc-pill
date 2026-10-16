import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_port: portSpin.value
    property alias cfg_showCats: catsCheck.checked

    Kirigami.FormLayout {
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
            text: "Run laps across the pill while Claude works"
        }
    }
}
