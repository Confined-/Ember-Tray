# Ember Mug

> This plugin's code was written with the help of an AI assistant and has been
> reviewed; the D-Bus/BlueZ bridge is small and only talks to a device you have
> paired yourself.

Monitor and control an [Ember smart mug](https://ember.com/) from the Omarchy
bar: current temperature, battery level, liquid state, and target temperature
control.

## Features

- **Bar widget** with a mug icon (current temperature, battery, and liquid
  state are in the tooltip and panel).
- **Control panel** (click the bar widget) with a target-temperature slider;
  the far-left of the slider is **Off**.
- No extra packages — the plugin talks to the mug over BlueZ GATT directly
  through D-Bus using the already-installed `dbus-python`.

## Dependencies

- **Python 3** with the `dbus-python` bindings (installed by default on
  Omarchy).
- **BlueZ** (`bluetoothd`) running, with the mug **paired** to your machine
  (see below).

## Install

```sh
omarchy plugin add https://github.com/Confined-/ember-plugin.git --enable
```

## Remove

```sh
omarchy plugin remove confined-.ember
```

This removes the plugin and its bar-widget entry. Any `mac`, `unit`, or
`pollIntervalSec` values you set stay behind in the widget's entry in
`~/.config/omarchy/shell.json` — delete that entry by hand if you want them
gone too.

## Pair the mug

The mug must be paired to your machine before the plugin can reach it.

```sh
bluetoothctl
scan on
# ...find the mug (it advertises as "EMBER") and note its MAC...
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
```

If the mug is currently connected to the Ember phone app, the two will fight
over the connection — disconnect it from the app (or turn off Bluetooth there)
so the computer can connect.

If the mug won't pair or doesn't show up in `scan on`, it may need a reset
([official instructions](https://support.ember.com/en-US/ember-mug-how-to-reset-1757480)):

1. Pick the mug up.
2. Press and hold the power button for **about 15 seconds**.
3. The LED will blink **blue, then yellow, then red** — let go once you see
   these colors.
4. Wait for the LED to pulse back to **white**, which confirms the reset.
5. If the mug was paired before, "forget" the *Ember Ceramic Mug* in your
   device's Bluetooth settings, then pair again as above.

## Configure

Settings live inline in the widget's entry in `~/.config/omarchy/shell.json`
(under `bar.layout.*` for the `confined-.ember` entry). Edit the file and the
widget picks the changes up on the next reload:

Until `mac` is set, the bar widget just shows the mug icon and its tooltip
says the mug is not configured.

| Setting               | Default | Meaning                                             |
|-----------------------|---------|-----------------------------------------------------|
| `mac`                 | (empty) | The mug's MAC address, e.g. `AA:BB:CC:DD:EE:FF`     |
| `pollIntervalSec`     | `10`    | How often to read the mug, in seconds (min 10)      |
| `unit`                | (empty) | `C` or `F`; empty uses the mug's own stored setting |
| `refreshOnOpen`       | `true`  | Re-read the mug whenever the panel opens            |

## Usage

- Click the bar widget to open the control panel.
- Drag the slider (the target label previews the temperature live while you
  drag, and the mug is updated on release). The slider's far-left segment is
  **Off** (writes a target of `0` and turns the heater off); the rest of the
  track sets the temperature from 120–145 °F (48.9–62.8 °C).
- The **°F / °C** next to the displayed temperature toggles the display unit:
  click the unit letter to switch between Fahrenheit and Celsius. The choice
  applies instantly and persists to the `unit` setting in shell.json.
- The widget re-reads the mug every `pollIntervalSec`, when the panel opens,
  and on middle-click of the bar icon.

## How it works

`ember_ble.py` is a small Python bridge that calls the BlueZ D-Bus API to read
and write the mug's GATT characteristics:

| Characteristic | UUID                                   | Read / Write |
|----------------|----------------------------------------|--------------|
| Current temp   | `fc540002-236c-4c94-8fa9-944a3e5353fa` | Read         |
| Target temp    | `fc540003-236c-4c94-8fa9-944a3e5353fa` | Read/Write   |
| Temperature unit | `fc540004-236c-4c94-8fa9-944a3e5353fa` | Read         |
| Battery        | `fc540007-236c-4c94-8fa9-944a3e5353fa` | Read         |
| Liquid state   | `fc540008-236c-4c94-8fa9-944a3e5353fa` | Read         |

Temperatures are sent as a uint16 little-endian value in hundredths of a
degree Celsius. The widget keeps a single long-lived `ember_ble.py repl --mac …`
process connected to the mug so the link isn't torn down after every poll
(Ember firmware is sensitive to that), and feeds it one `status` / `set-temp`
command per line.

## Caveats

- If writes are rejected (an ATT/insufficient-permissions error), the mug may
  need a one-time setup in the official Ember app; the app unlocks writing on
  the device. Some firmware versions also require a factory reset + re-pair
  when a device has been removed from the app.
- This project is not affiliated with Ember. "Ember" is a trademark of Ember
  Technologies, Inc.
- The protocol was reverse-engineered by the community
  ([orlopau/ember-mug](https://github.com/orlopau/ember-mug)); it is unofficial
  and may differ between firmware versions.

## License

MIT. See [LICENSE](LICENSE).