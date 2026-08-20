import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "confined-.ember"

  // ---- Configuration (shell.json entry settings) ----
  readonly property string mugMac: String(setting("mac", "") || "").trim().toUpperCase()
  readonly property int pollIntervalSec: Math.max(10, parseInt(setting("pollIntervalSec", 10), 10) || 10)
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
  property bool commandPending: false
  property string pendingCommand: ""
  property bool bridgeReady: false
  property int failStreak: 0
  property var pendingSetTemp: ""
  readonly property bool settingTarget: root.commandPending || root.pendingSetTemp !== ""
  // ---- Discovery (picker + scan fallback; no auto-off) ----
  property var discoveredDevices: []
  property bool discovering: false
  property string discoverError: ""
  property bool hasTriedScan: false
  property bool pairing: false
  property string pairingMac: ""
  property string pairingError: ""

  readonly property bool configured: mugMac !== ""
  function normalizeUnit(v) {
    v = String(v || "").trim().toUpperCase()
    return (v === "C" || v === "F") ? v : ""
  }
  property string unitPreference: normalizeUnit(setting("unit", ""))
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
    if (!root.connected) {
      var e = String(root.lastError || "offline")
      if (e.indexOf("Bluetooth is off") !== -1) return e
      if (e.indexOf("Mug not in range") !== -1) return e
      return "Mug offline"
    }
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
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.unit = unit
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setDiscoveredMac(mac) {
    mac = String(mac || "").trim().toUpperCase()
    if (!mac) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.mac = mac
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    else if (root.bar && root.bar.shell && typeof root.bar.shell.mutateShellConfig === "function") {
      // Fallback for older shell — mirror setUnitPref's old path.
      root.bar.shell.mutateShellConfig(function(config) {
        var layout = config.bar && config.bar.layout
        if (!layout) return
        ;["left", "center", "right"].forEach(function(region) {
          var entries = layout[region]
          if (!Array.isArray(entries)) return
          for (var i = 0; i < entries.length; i++) if (entries[i] && entries[i].id === root.moduleName) entries[i].mac = mac
        })
      })
    }
    root.discoverError = ""
  }

  function runDiscover(useScan) {
    if (root.discovering) return
    root.discovering = true
    root.discoverError = ""
    var cmd = ["python3", root.scriptPath(), "discover"]
    if (useScan) { cmd.push("--scan"); cmd.push("--timeout"); cmd.push("6") }
    discoverProc.command = cmd
    discoverProc.running = true
  }

  function onDiscoverFinished(text) {
    var raw = String(text || "").trim()
    root.discovering = false
    if (!raw) {
      root.discoveredDevices = []
      root.discoverError = "no response from discover"
      return
    }
    var data
    try { data = JSON.parse(raw) } catch (e) { root.discoverError = "bad response from discover"; root.discoveredDevices = []; return }
    if (data && typeof data === "object" && !Array.isArray(data) && data.error) {
      root.discoverError = String(data.error)
      root.discoveredDevices = []
      return
    }
    if (!Array.isArray(data)) data = []
    root.discoveredDevices = data
    root.discoverError = ""
    if (data.length === 0) {
      if (!root.hasTriedScan && !root.configured) {
        root.hasTriedScan = true
        // Fallback: actively scan for nearby unpaired advertisers.
        root.runDiscover(true)
      }
      return
    }
  }

  function useDiscoveredDevice(mac, paired) {
    mac = String(mac || "").trim().toUpperCase()
    if (!mac) return
    if (paired) {
      root.setDiscoveredMac(mac)
      return
    }
    if (root.pairing) return
    root.pairing = true
    root.pairingMac = mac
    root.pairingError = ""
    root.discoverError = ""
    pairProc.command = ["python3", root.scriptPath(), "pair", "--mac", mac]
    pairProc.running = true
  }

  function onPairFinished(text) {
    var raw = String(text || "").trim()
    root.pairing = false
    var mac = root.pairingMac
    root.pairingMac = ""
    if (!raw) {
      root.pairingError = "no response from pair"
      root.discoverError = root.pairingError
      return
    }
    var data
    try { data = JSON.parse(raw) } catch (e) { root.pairingError = "bad response from pair"; root.discoverError = root.pairingError; return }
    if (data && data.ok === true) {
      root.pairingError = ""
      root.setDiscoveredMac(data.mac || mac)
    } else {
      var err = data && data.error ? String(data.error) : "pair failed"
      root.pairingError = err
      root.discoverError = err
    }
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Bridge invocation (persistent repl process) ----
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

  function startBridge() {
    if (bridgeProc.running || !root.configured) return
    bridgeProc.command = ["python3", root.scriptPath(), "repl", "--mac", root.mugMac]
    bridgeProc.running = true
  }

  // Send one command, or queue it until the bridge is up. Only one command is
  // in flight at a time so BlueZ never sees concurrent connects from us.
  function request(line) {
    if (!root.configured) return
    if (bridgeProc.running && root.bridgeReady) {
      root.commandPending = true
      responseWatchdog.restart()
      bridgeProc.write(line + "\n")
    } else {
      root.pendingCommand = line
      if (!bridgeProc.running) root.startBridge()
    }
  }

  function refresh() {
    if (!root.configured) {
      root.connected = false
      return
    }
    if (root.commandPending) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    root.request("status")
  }

  function num(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  function applyState(data) {
    root.connected = true
    root.failStreak = 0
    // Deadband tiny GATT read jitter so the slider doesn't drift a few pixels
    // on every poll when the set-point is otherwise stable.
    var newCurrent = root.num(data.currentTemp, 0)
    if (Math.abs(newCurrent - root.currentTemp) > 0.05) root.currentTemp = newCurrent
    else if (root.currentTemp === 0 && newCurrent !== 0) root.currentTemp = newCurrent
    var newTarget = root.num(data.targetTemp, 0)
    var newHeater = data.heaterOn === true
    if (Math.abs(newTarget - root.targetTemp) > 0.05 || newHeater !== root.heaterOn) root.targetTemp = newTarget
    else if (root.targetTemp === 0 && newTarget !== 0) root.targetTemp = newTarget
    root.battery = root.num(data.battery, 0)
    root.charging = data.charging === true
    root.liquidState = String(data.liquidState || "")
    // liquidCode 0 (Standby) is a valid state; only a missing value is -1.
    root.liquidCode = root.num(data.liquidCode, -1)
    // The bridge always reports heaterOn; missing/undefined means off.
    root.heaterOn = newHeater
    root.mugUnit = data.unit === "F" ? "F" : "C"
    root.lastError = ""
  }

  // Route one response line from the bridge. Status and set-temp both return
  // the full mug state on success, so they share the same happy path.
  function onReplLine(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      return
    }
    root.commandPending = false
    responseWatchdog.stop()
    if (data.ok !== undefined) {
      if (data.ok === true) root.applyState(data)
      else root.lastError = String(data.error || "set failed")
    } else if (data.connected === true) {
      root.applyState(data)
    } else {
      // A single transient miss shouldn't flash the mug offline; only flip
      // state on consecutive failures.
      root.failStreak++
      root.lastError = String(data.error || "not reachable")
      if (root.failStreak >= 2) root.connected = false
    }
    root.deferNext()
  }

  // A poll/set deferred while a command was in flight runs now that the
  // bridge is idle again.
  function deferNext() {
    if (root.pendingSetTemp !== "") {
      var value = root.pendingSetTemp
      root.pendingSetTemp = ""
      root.setTargetTemp(value)
    } else if (root.refreshPending) {
      root.refreshPending = false
      Qt.callLater(root.refresh)
    }
  }

  function setTargetTemp(displayValue) {
    if (!root.configured) return
    displayValue = Number(displayValue)
    if (!isFinite(displayValue)) return
    if (displayValue !== 0 && (displayValue < root.minTemp - 0.01 || displayValue > root.maxTemp + 0.01)) return
    if (root.commandPending) {
      root.pendingSetTemp = displayValue
      return
    }
    root.pendingSetTemp = ""
    root.request("set-temp " + root.toCelsius(displayValue).toFixed(2))
  }

  // ---- Discovery process (one-shot) ----
  Process {
    id: discoverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDiscoverFinished(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.discovering) {
        // Keep whatever onStreamFinished parsed; only note a hard failure.
        if (root.discoveredDevices.length === 0 && root.discoverError === "") root.discoverError = "discover exited " + exitCode
        root.discovering = false
      }
    }
  }

  // ---- Pairing process (one-shot) ----
  Process {
    id: pairProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPairFinished(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.pairing) {
        if (root.pairingError === "" && root.discoverError === "") root.discoverError = "pair exited " + exitCode
        root.pairing = false
        root.pairingMac = ""
      }
    }
  }

  // ---- Persistent bridge process ----
  Process {
    id: bridgeProc
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: (data) => root.onReplLine(data)
    }
    onStarted: {
      root.bridgeReady = true
      if (root.pendingCommand !== "") {
        var line = root.pendingCommand
        root.pendingCommand = ""
        root.commandPending = true
        responseWatchdog.restart()
        bridgeProc.write(line + "\n")
      }
    }
    onRunningChanged: {
      if (!bridgeProc.running) root.bridgeReady = false
    }
    onExited: function(exitCode) {
      root.commandPending = false
      root.pendingCommand = ""
      if (exitCode !== 0 && root.lastError === "") root.lastError = "bridge exited " + exitCode
      if (root.configured) restartTimer.restart()
    }
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

  // A command left unanswered (stuck BlueZ call, dead link) means the bridge
  // needs a hard restart.
  Timer {
    id: responseWatchdog
    interval: 20000
    onTriggered: {
      root.commandPending = false
      root.failStreak++
      root.lastError = "bridge unresponsive"
      if (root.failStreak >= 2) root.connected = false
      if (bridgeProc.running) bridgeProc.running = false
      if (root.configured) restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: {
      if (root.configured && !bridgeProc.running) {
        if (root.pendingCommand === "") root.pendingCommand = "status"
        root.startBridge()
      }
    }
  }

  // When Bluetooth was off, re-probe quickly after it comes back so the
  // "Bluetooth is off" banner doesn't linger when the mug is still offline.
  Timer {
    id: bluetoothRetryTimer
    interval: 2000
    repeat: true
    running: (String(root.lastError || "").indexOf("Bluetooth is off") !== -1) || (String(root.discoverError || "").indexOf("Bluetooth is off") !== -1)
    onTriggered: {
      if (root.configured) {
        if (!root.connected) root.refresh()
      } else {
        if (!root.discovering) root.runDiscover(false)
      }
    }
  }

  // Pairing can block on BlueZ authorization (no agent, user prompt, etc.).
  // Don't leave the UI stuck in "Pairing…" forever.
  Timer {
    id: pairingWatchdog
    interval: 30000
    repeat: false
    running: root.pairing
    onTriggered: {
      if (!root.pairing) return
      if (pairProc.running) pairProc.running = false
      // Best-effort cancel the BlueZ pairing session
      if (root.pairingMac) {
        cancelPairProc.command = ["python3", root.scriptPath(), "cancel-pair", "--mac", root.pairingMac]
        cancelPairProc.running = true
      }
      root.pairing = false
      root.pairingMac = ""
      root.pairingError = "pairing timed out — try again"
      root.discoverError = root.pairingError
    }
  }
  Process {
    id: cancelPairProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Component.onCompleted: {
    if (root.configured) {
      root.pendingCommand = "status"
      root.startBridge()
    } else {
      // Fresh install — try to auto-pick a paired Ember mug, otherwise show the picker.
      root.hasTriedScan = false
      root.runDiscover(false)
    }
  }

  // ---- UI ----
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    root.unitPreference = root.normalizeUnit(root.setting("unit", ""))
    injectPanel()
  }

  onMugMacChanged: {
    // MAC edited in shell.json — drop the old GATT link and reconnect to the new device.
    if (bridgeProc.running) bridgeProc.running = false
    root.pendingCommand = ""
    root.commandPending = false
    root.bridgeReady = false
    root.connected = false
    root.lastError = ""
    if (root.configured) {
      root.pendingCommand = "status"
      root.startBridge()
    } else {
      restartTimer.stop()
      responseWatchdog.stop()
      root.hasTriedScan = false
      root.discoveredDevices = []
      root.discoverError = ""
      root.runDiscover(false)
    }
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