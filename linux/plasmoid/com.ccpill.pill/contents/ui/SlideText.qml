/*
 * One line of pill text inside a fixed-width slot. When the text is wider
 * than the slot it glides left to show its tail, rests, and glides back,
 * so the panel never has to make room for it.
 */
import QtQuick

Text {
    id: t

    property real slotWidth: 100
    // 0..1 while a briefing is spoken: the text crawls left in step with the
    // voice so the words being said stay in view. -1 = idle glide behaviour.
    property real crawl: -1
    readonly property real overflow: Math.max(0, implicitWidth - slotWidth)

    Binding {
        target: t
        property: "x"
        value: -t.overflow * Math.min(1, Math.max(0, t.crawl))
        when: t.crawl >= 0
        restoreMode: Binding.RestoreBindingOrValue
    }

    maximumLineCount: 1
    elide: Text.ElideNone

    SequentialAnimation {
        id: glide
        running: t.visible && t.opacity > 0 && t.overflow > 0 && t.crawl < 0
        loops: Animation.Infinite
        PauseAnimation { duration: 1400 }
        NumberAnimation { target: t; property: "x"; to: -t.overflow; duration: Math.max(400, t.overflow / 36 * 1000); easing.type: Easing.InOutSine }
        PauseAnimation { duration: 1800 }
        NumberAnimation { target: t; property: "x"; to: 0; duration: Math.max(400, t.overflow / 36 * 1000); easing.type: Easing.InOutSine }
        PauseAnimation { duration: 2600 }
        onRunningChanged: if (!running) t.x = 0
    }

    onTextChanged: {
        x = 0
        if (glide.running) glide.restart()
    }
}
