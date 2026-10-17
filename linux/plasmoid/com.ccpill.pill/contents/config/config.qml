import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: "General"
        icon: "configure"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: "Appearance"
        icon: "preferences-desktop-theme-global"
        source: "configAppearance.qml"
    }
    ConfigCategory {
        name: "Placement"
        icon: "transform-move"
        source: "configPlacement.qml"
    }
}
