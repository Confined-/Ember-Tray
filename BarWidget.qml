import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "brittle.ember"

  // ---- Configuration (shell.json entry settings) ----
  readonly property string mugMac: String(setting("mac", "") || "").trim().toUpperCase()
  readonly property int pollIntervalSec: Math.max(10, parseInt(setting("pollIntervalSec", 30), 10) || 30)
  readonly property bool refreshOnOpen: setting("refreshOnOpen", true) === true

  // ---- Live mug state (from the status bridge) ----
  property bool connected: false
  property real currentTemp: 0
  property real targetTemp: 0
  property int battery: 0
  property bool charging: false
  property string liquidState: ""
  property int liquidCode: -1
  property string mugUnit: "C"
  property bool heaterOn: false
  property string lastError: ""
  property bool refreshPending: false
  property int failStreak: 0
  property var pendingSetTemp: ""
  readonly property bool settingTarget: setTempProc.running || root.pendingSetTemp !== ""

  readonly property bool configured: mugMac !== ""
  property string unitPreference: String(setting("unit", "") || "").toUpperCase()
  readonly property string displayUnit: unitPreference !== "" ? unitPreference : mugUnit
  readonly property bool useFahrenheit: displayUnit === "F"

  // ---- Unit helpers ----
  function toDisplay(celsius) {
    return useFahrenheit ? celsius * 9 / 5 + 32 : celsius
  }

  function toCelsius(displayValue) {
    return useFahrenheit ? (displayValue - 32) * 5 / 9 : displayValue
  }

  // ---- Bar presentation ----
  readonly property string barText: ""

  readonly property string barTooltip: {
    if (!root.configured) return "Ember mug not configured"
    if (!root.connected) return "Ember mug: " + (root.lastError || "offline")
    return "Mug " + root.battery + "%" + (root.charging ? " ⚡" : "") + " • " + root.liquidState
  }

  // ---- Panel plumbing (shape contract used by Bar.findPanelWidget) ----
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // ---- Unit preference toggle (runtime + persisted to shell.json) ----
  function setUnitPref(unit) {
    unit = String(unit || "").toUpperCase()
    if (unit !== "C" && unit !== "F") return
    root.unitPreference = unit
    var bar = root.bar
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return
    bar.shell.mutateShellConfig(function(config) {
      var layout = config.bar && config.bar.layout
      if (!layout) return
      ["left", "center", "right"].forEach(function(region) {
        var entries = layout[region]
        if (!Array.isArray(entries)) return
        for (var i = 0; i < entries.length; i++) {
          if (entries[i] && entries[i].id === root.moduleName) entries[i].unit = unit
        }
      })
    })
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Bridge invocation ----
  function scriptPath() {
    var url = String(Qt.resolvedUrl("ember_ble.py"))
    if (url.indexOf("file://localhost/") === 0) url = url.substring("file://localhost/".length)
    else if (url.indexOf("file://") === 0) url = url.substring("file://".length)
    try {
      return decodeURIComponent(url)
    } catch (e) {
      return url
    }
  }

  function refresh() {
    if (!root.configured) {
      root.connected = false
      return
    }
    // Never run a status poll while a set-temp is in flight: BlueZ rejects a
    // second simultaneous connect with Error.InProgress.
    if (setTempProc.running) {
      root.refreshPending = true
      return
    }
    if (statusProc.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    statusProc.command = ["python3", root.scriptPath(), "status", "--mac", root.mugMac]
    statusProc.running = true
  }

  function applyState(data) {
    root.connected = true
    root.failStreak = 0
    root.currentTemp = parseFloat(data.currentTemp) || 0
    root.targetTemp = parseFloat(data.targetTemp) || 0
    root.battery = parseInt(data.battery, 10) || 0
    root.charging = data.charging === true
    root.liquidState = String(data.liquidState || "")
    root.liquidCode = parseInt(data.liquidCode, 10) || -1
    root.heaterOn = data.heaterOn !== false
    root.mugUnit = data.unit === "F" ? "F" : "C"
    root.lastError = ""
  }

  function applyStatus(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (data.connected === true) {
      root.applyState(data)
    } else {
      // A single transient poll failure (e.g. reconnect right after a write)
      // shouldn't flash the mug offline; only flip state on consecutive misses.
      root.failStreak++
      root.lastError = String(data.error || "not reachable")
      if (root.failStreak >= 2) root.connected = false
    }
  }

  function setTargetTemp(displayValue) {
    if (!root.configured || setTempProc.running) return
    // Wait for an in-flight status poll instead of racing it; the preview
    // stays shown (via pendingSetTemp) until the set can actually run.
    if (statusProc.running) {
      root.pendingSetTemp = displayValue
      return
    }
    root.pendingSetTemp = ""
    var celsius = root.toCelsius(displayValue)
    setTempProc.command = ["python3", root.scriptPath(), "set-temp", "--mac", root.mugMac, "--value", celsius.toFixed(2)]
    setTempProc.running = true
  }

  function applySetTemp(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    if (data.ok === true) {
      root.applyState(data)
    } else {
      root.lastError = String(data.error || "set failed")
    }
  }

  // ---- Status poll ----
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onRunningChanged: {
      if (statusProc.running) statusWatchdog.restart()
      else statusWatchdog.stop()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "status exited " + exitCode
      if (root.pendingSetTemp !== "") {
        var v = root.pendingSetTemp
        root.pendingSetTemp = ""
        root.setTargetTemp(v)
      } else if (root.refreshPending) {
        Qt.callLater(root.refresh)
      }
    }
  }

  // ---- Target temperature write ----
  Process {
    id: setTempProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySetTemp(text)
    }
    onExited: function(exitCode) {
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
      }
    }
    // The set-temp bridge verifies the write and returns the full mug state,
    // so no immediate follow-up poll is needed (a quick second connect can
    // read a stale cache or fail transiently and revert the UI).
  }

  // ---- Polling ----
  Timer {
    id: pollTimer
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A stuck BlueZ call can leave the Process wedged; reset it and retry.
  Timer {
    id: statusWatchdog
    interval: 20000
    onTriggered: {
      if (statusProc.running) statusProc.running = false
      root.refresh()
    }
  }

  // ---- UI ----
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    root.unitPreference = String(root.setting("unit", "") || "").toUpperCase()
    injectPanel()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
    }
  }
}