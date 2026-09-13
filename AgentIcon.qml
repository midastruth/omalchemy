import QtQuick
import QtQuick.Shapes

// Theme-aware rendering of the agent mark. Drawing the SVG paths directly
// avoids baked-in SVG colors and keeps the icon visible on every bar theme.
Item {
    id: root

    property color color: "white"

    Shape {
        width: 180
        height: 219
        anchors.centerIn: parent
        scale: Math.min(root.width / width, root.height / height)
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.color
            strokeWidth: 0
            PathSvg { path: "M9.50909 61.7971L66.929 166.792L51.8627 215.512L0 120.833L9.50909 61.7971Z" }
        }

        ShapePath {
            fillColor: root.color
            strokeWidth: 0
            PathSvg { path: "M157.327 164.996L54.0894 218.395L70.0183 166.794L177.333 111.477L157.328 164.997" }
        }

        ShapePath {
            fillColor: root.color
            fillRule: ShapePath.WindingFill
            strokeWidth: 0
            PathSvg { path: "M179.057 107.274L68.7822 164.153L10.1221 56.9971L120.275 0L179.057 107.274ZM45.8662 59.6309C45.3051 59.6116 45.0788 60.3486 45.5566 60.6455L85.8799 85.8467C86.2019 86.0483 86.4584 86.3264 86.6299 86.6494L86.6289 86.6504C86.8021 86.9762 86.8902 87.3448 86.877 87.7236L85.2178 135.252C85.1984 135.813 85.9345 136.039 86.2314 135.562L130.388 64.8896C130.701 64.388 130.685 63.811 130.44 63.3535L130.441 63.3516H130.439C130.197 62.8952 129.729 62.5598 129.139 62.5391L45.8662 59.6309Z" }
        }
    }
}
