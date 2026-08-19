# Ember Mug

> **Disclaimer:** This plugin's code was written entirely by an AI assistant.
> No human hands have touched it.

Monitor and control an [Ember smart mug](https://ember.com/) from the Omarchy
bar: current temperature, battery level, liquid state, and target temperature
control.

## Features

- **Bar widget** with a mug icon (current temperature, battery, and liquid
  state are in the tooltip and panel).
- **Control panel** (click the bar widget) with a target-temperature slider;
  the far-left of the slider is **Off**.
- Zero new packages — the plugin talks to the mug over BlueZ GATT directly
  through D-Bus using the already-installed `dbus-python`.

## Install

```sh
omarchy plugin add https://github.com/Confined-/ember-plugin.git --enable
```

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

## Configure

Settings live inline in the widget's entry in `~/.config/omarchy/shell.json`
(under `bar.layout.*` for the `confined-.ember` entry). Edit the file and the
widget picks the changes up on the next reload:

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
degree Celsius. The bar widget runs `ember_ble.py status --mac …` on a timer
and parses the JSON it prints.

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