import QtQuick
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "confined-.ember"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var mug: root.hostWidget || null
  readonly property bool configured: mug ? mug.configured : false
  readonly property bool connected: mug ? mug.connected : false
  readonly property string displayUnit: mug ? mug.displayUnit : "C"
  readonly property bool useFahrenheit: displayUnit === "F"
  readonly property real currentTempDisplay: mug ? mug.toDisplay(mug.currentTemp) : 0
  readonly property bool heaterOn: mug ? mug.heaterOn : false
  readonly property string liquidState: mug ? mug.liquidState : ""
  readonly property int battery: mug ? mug.battery : 0
  readonly property bool charging: mug ? mug.charging : false
  readonly property string lastError: mug ? mug.lastError : ""

  // Control range: the slider's far-left segment is "off"; the rest of the
  // track maps the usable temperature band (120–145 °F / 48.9–62.8 °C). The
  // raw track scale is fixed in Fahrenheit degrees so switching the display
  // unit never rescales the slider; the Celsius band is the exact Fahrenheit
  // equivalent, so a given temperature sits at the same knob position in both.
  readonly property real fMinTemp: 120
  readonly property real fMaxTemp: 145
  readonly property real minTemp: useFahrenheit ? root.fMinTemp : (root.fMinTemp - 32) * 5 / 9
  readonly property real maxTemp: useFahrenheit ? root.fMaxTemp : (root.fMaxTemp - 32) * 5 / 9
  readonly property real tempStep: useFahrenheit ? 1 : 0.5
  readonly property real offZone: 0.06
  readonly property real sliderMax: root.fMaxTemp
  readonly property real offValue: root.sliderMax * root.offZone

  // Convert between raw slider position (0..sliderMax) and the temperature it
  // means (0 = off, then minTemp..maxTemp).
  function rawToTemp(v) {
    if (v <= root.offValue) return 0
    return root.minTemp + (v - root.offValue) / (root.sliderMax - root.offValue) * (root.maxTemp - root.minTemp)
  }

  function tempToRaw(t) {
    if (t <= 0) return 0
    return root.offValue + (t - root.minTemp) / (root.maxTemp - root.minTemp) * (root.sliderMax - root.offValue)
  }

  readonly property real sliderTarget: {
    if (root.mug && root.mug.heaterOn && root.mug.targetTemp > 0) {
      var v = root.mug.toDisplay(root.mug.targetTemp)
      return Math.max(root.minTemp, Math.min(root.maxTemp, v))
    }
    return 0
  }

  // While the slider is being dragged, show the live position as the target;
  // the mug is only written on release. Keep showing it while the write is in
  // flight so the value doesn't snap back before the mug confirms it.
  readonly property bool sliderDragging: tempSlider ? tempSlider.dragging : false
  readonly property bool settingTarget: mug ? (mug.settingTarget === true) : false
  property real sliderPreviewRaw: root.tempToRaw(root.sliderTarget)
  // Debounce tiny GATT jitter so the knob doesn't drift a few pixels on every poll.
  property real _stableRaw: root.tempToRaw(root.sliderTarget)
  function _updateStableRaw() {
    var raw = root.tempToRaw(root.sliderTarget)
    if (Math.abs(raw - root._stableRaw) > 0.4) root._stableRaw = raw
    else if (root._stableRaw === 0 && raw !== 0) root._stableRaw = raw
  }
  onSliderTargetChanged: _updateStableRaw()
  // PanelSlider's `value` drives the knob after a drag, so it must NOT change
  // when `dragging` flips: its onValueChanged resets liveValue, which would
  // clobber the release position and snap the slider back to the old target.
  readonly property real sliderValue: root.settingTarget
    ? root.sliderPreviewRaw
    : root._stableRaw
  readonly property real displayRaw: (root.sliderDragging || root.settingTarget)
    ? root.sliderPreviewRaw
    : root._stableRaw
  readonly property real displayedTarget: root.roundTemp(root.rawToTemp(root.displayRaw))

  function open() {
    root.controller.show()
    if (!root.configured && root.mug && !root.mug.discovering) {
      // Fresh install or unpaired: paired mug is found automatically, but a
      // newly-paired mug after the initial load needs an explicit scan.
      root.mug.runDiscover(false)
    } else if (root.mug && root.mug.refreshOnOpen) root.refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (root.mug && root.mug.refresh) root.mug.refresh()
  }

  function setTarget(displayValue) {
    if (root.mug && root.mug.setTargetTemp) root.mug.setTargetTemp(root.roundTemp(displayValue))
  }

  function roundTemp(value) {
    return Math.round(value / root.tempStep) * root.tempStep
  }

  function formatValue(value) {
    return String(Number(Number(value).toFixed(1)))
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        // ---- Hero: current temperature + liquid state / battery.
        Item {
          width: parent.width
          height: Math.max(heroLeft.height, heroRight.height)

          Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              id: tempBig
              text: root.connected ? root.formatValue(root.currentTempDisplay) : "—"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true

              MouseArea {
                anchors.fill: parent
                enabled: root.connected
                cursorShape: Qt.PointingHandCursor
                onClicked: root.mug.setUnitPref(root.useFahrenheit ? "C" : "F")
              }
            }
            Text {
              text: root.connected ? "°" + root.displayUnit : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.top: tempBig.top
              anchors.topMargin: Style.space(4)
            }
          }

          Column {
            id: heroRight
            width: heroRightColumn.implicitWidth
            anchors.right: parent.right
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)

            Text {
              text: root.connected ? root.liquidState.toUpperCase() : ""
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }

            Row {
              id: heroRightColumn
              visible: root.connected
              spacing: Style.space(6)

              Text {
                text: root.battery + "%"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              Text {
                visible: root.charging
                text: "⚡"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // ---- Divider.
        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- Target temperature control.
        Column {
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "TARGET"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.displayedTarget > 0
                ? root.formatValue(root.displayedTarget) + "°" + root.displayUnit
                : "OFF"
              color: root.displayedTarget > 0 ? root.bar.foreground : Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: tempSlider
            width: parent.width
            bar: root.bar
            enabled: root.connected
            minimum: 0
            maximum: root.sliderMax
            step: root.tempStep
            value: root.sliderValue
            tickCount: 0
            onMoved: function(value) {
              root.sliderPreviewRaw = value
            }
            onReleased: function(value) {
              if (root.connected) root.setTarget(root.rawToTemp(value))
            }
          }
        }

        // ---- Discovery (when not configured: auto-pick paired mug, else picker + scan fallback).
        Column {
          visible: !root.configured
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "No mug configured"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.mug && root.mug.discovering
            width: parent.width
            text: "Scanning for Ember mugs…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.mug && !root.mug.discovering && root.mug.discoverError !== ""
            width: parent.width
            text: root.mug ? root.mug.discoverError : ""
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.mug && !root.mug.discovering && root.mug.discoverError === "" && root.mug.discoveredDevices.length === 0
            width: parent.width
            text: "No Ember mugs found. Tap Scan nearby to discover it — then tap Pair."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.mug && !root.mug.discovering && root.mug.discoveredDevices.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.mug && root.mug.discoveredDevices.length === 1
                ? "Found 1 mug — tap Use to configure:"
                : "Found " + (root.mug ? root.mug.discoveredDevices.length : 0) + " mugs — pick one:"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.mug ? root.mug.discoveredDevices : []
              delegate: Rectangle {
                width: parent.width
                height: 44
                radius: 8
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.07)
                border.width: 1
                border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)

                Row {
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - useBtn.width - parent.spacing
                    spacing: 2

                    Text {
                      width: parent.width
                      text: (modelData.name || "Ember Mug") + (modelData.paired ? " • paired" : " • not paired")
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      text: modelData.mac || ""
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall - 1
                      elide: Text.ElideRight
                    }
                  }

                  Rectangle {
                    id: useBtn
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56
                    height: 28
                    radius: 6
                    color: Color.accent
                    opacity: root.mug && root.mug.pairing && root.mug.pairingMac === modelData.mac ? 0.6 : 1.0
                    Text {
                      anchors.centerIn: parent
                      text: root.mug && root.mug.pairing && root.mug.pairingMac === modelData.mac ? "…" : (modelData.paired ? "Use" : "Pair")
                      color: "white"
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    MouseArea {
                      anchors.fill: parent
                      enabled: !(root.mug && root.mug.pairing)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (!root.mug) return
                        if (root.mug.useDiscoveredDevice) root.mug.useDiscoveredDevice(modelData.mac, modelData.paired)
                        else if (root.mug.setDiscoveredMac) root.mug.setDiscoveredMac(modelData.mac)
                      }
                    }
                  }
                }
              }
            }
          }

          Rectangle {
            visible: root.mug && !root.mug.discovering
            width: 128
            height: 28
            radius: 6
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15)
            Text {
              anchors.centerIn: parent
              text: "Scan nearby"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mug && root.mug.runDiscover) root.mug.runDiscover(true)
            }
          }
        }

        // ---- Status footer (only when a MAC is configured but offline).
        Text {
          visible: root.configured && !root.connected
          width: parent.width
          text: {
            var e = String(root.lastError || "")
            if (e.indexOf("Bluetooth is off") !== -1) return e
            if (e.indexOf("Mug not in range") !== -1) return e
            return "Mug offline"
          }
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}