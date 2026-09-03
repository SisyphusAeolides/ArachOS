import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Image {
            id: background
            source: "welcome.png"
            width: presentation.width
            height: presentation.height
            fillMode: Image.PreserveAspectFit
        }
        Text {
            text: "Welcome to ArachOS!"
            color: "white"
            font.pixelSize: 32
            anchors.centerIn: parent
        }
    }
}
