/*
 * Placement: which panel edge the pill lives on and where along it. Plasma's
 * own way (Edit Mode, drag) always works too; this asks the daemon to run
 * linux/bin/cc-pill-place, which re-creates the widget on the chosen panel
 * with these settings carried over.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property int cfg_port
    property string status: ""
    property bool busy: false

    function move() {
        page.busy = true
        page.status = "Asking the daemon…"
        const xhr = new XMLHttpRequest()
        xhr.open("POST", "http://127.0.0.1:" + page.cfg_port + "/place")
        xhr.setRequestHeader("X-CC-Pill", "1")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.timeout = 5000
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            page.busy = false
            let ok = false
            try { ok = xhr.status === 200 && JSON.parse(xhr.responseText).ok === true } catch (e) { ok = false }
            page.status = ok ? "Moving. The widget is re-created on the " + edgeCombo.currentText.toLowerCase()
                               + " panel; if its order changes, the desktop restarts for a moment."
                             : (xhr.status === 0 ? "The cc-pill daemon isn't running (systemctl --user status cc-pill)."
                                                 : "The daemon refused: " + xhr.responseText)
        }
        xhr.send(JSON.stringify({ edge: edgeCombo.currentValue, align: alignCombo.currentValue }))
    }

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: edgeCombo
            Kirigami.FormData.label: "Panel:"
            textRole: "text"
            valueRole: "value"
            model: [
                { text: "Top", value: "top" },
                { text: "Bottom", value: "bottom" },
                { text: "Left", value: "left" },
                { text: "Right", value: "right" }
            ]
        }

        QQC2.ComboBox {
            id: alignCombo
            Kirigami.FormData.label: "Position:"
            textRole: "text"
            valueRole: "value"
            enabled: edgeCombo.currentValue === "top" || edgeCombo.currentValue === "bottom"
            model: [
                { text: "Left", value: "start" },
                { text: "Centre (between two spacers)", value: "center" },
                { text: "Right, before the system tray", value: "end" }
            ]
            currentIndex: 2
        }

        QQC2.Button {
            Kirigami.FormData.label: " "
            text: "Move the widget there"
            icon.name: "transform-move"
            enabled: !page.busy
            onClicked: page.move()
        }

        QQC2.Label {
            visible: page.status.length > 0
            text: page.status
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.Label {
            text: "A panel is created at that edge if there is none. The pill's other settings come along; apply them first, "
                  + "since moving closes this dialog. A vertical panel shows the dots only.\n\n"
                  + "By hand: right-click a panel → Enter Edit Mode, then drag the widget anywhere, "
                  + "or add two Panel Spacers around it to centre it."
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 26
        }
    }
}
