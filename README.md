# Ember-Tray

> AI-assisted and reviewed — small D-Bus bridge to a mug you’ve paired yourself.

Monitor and control an [Ember smart mug](https://ember.com/) from the Omarchy tray: current temperature, battery, liquid state, and target temperature.

## Features

- **Bar icon** — mug glyph; tooltip shows battery/liquid. Panel shows the temperature.
- **Panel** — tap the temperature to toggle °F/°C (persists), slider sets target (far-left = **Off**, then 120–145 °F / 48.9–62.8 °C). Off is 6% of the track, so 120 is a short nudge from Off.
- **Auto-discovery** — paired mug found automatically when you open the panel (single mug auto-configures, multiple → picker with **Use**). **Scan nearby** finds unpaired advertisers.
- **First-run safety** — freshly paired mugs are kept **off** until you pick a temperature (firmware defaults to ~135 °F after reset).
- No extra packages — uses `dbus-python` + BlueZ already on Omarchy.

## Dependencies

- Python 3 + `dbus-python`
- BlueZ (`bluetoothd`)

## Install

```sh
omarchy plugin add https://github.com/Confined-/Ember-Tray.git --enable
```

## Remove

```sh
omarchy plugin remove confined-.ember
```

Removes the bar entry and plugin folder.

## Pair

```sh
bluetoothctl
scan on
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
```

Once paired, just open the panel — no need to edit `shell.json`:

- Single paired mug → configured automatically.
- Multiple paired mugs → picker, tap **Use**.
- Unpaired nearby mug → **Scan nearby** (or `ember_ble.py discover --scan`), then `pair`/`trust` and tap **Use** / reopen panel.

If the phone app is connected, disconnect it first — it fights the computer for the link.

**Reset** if the mug won’t appear ([official](https://support.ember.com/en-US/ember-mug-how-to-reset-1757480)): pick the mug up, hold the bottom button ~15 s until LED blinks blue → yellow → red, let go, wait for white pulse, then “forget” *Ember Ceramic Mug* in Bluetooth settings and pair again.

## Configure

Rarely needed — auto-discovery handles `mac`. If you do edit `~/.config/omarchy/shell.json` (`bar.layout.*` → `confined-.ember`):

| Setting | Default | Meaning |
|---------|---------|---------|
| `mac` | `""` | Auto-filled; e.g. `AA:BB:CC:DD:EE:FF` |
| `pollIntervalSec` | `10` | Poll seconds (min 10) |
| `unit` | `""` | `C`/`F` or mug’s setting |
| `refreshOnOpen` | `true` | Re-read on panel open |

Until `mac` is set the bar shows “not configured” and the panel shows the discovery picker.

## Usage

- Click bar icon to open panel, middle-click to refresh. Polls every `pollIntervalSec` and on open.
- Drag slider, release to set. Tap the large temperature to toggle °F/°C.

## How it works

`ember_ble.py` talks BlueZ GATT directly via D-Bus:

| Characteristic | UUID | R/W |
|---|---|---|
| Current temp | `fc540002-236c-4c94-8fa9-944a3e5353fa` | R |
| Target temp | `fc540003-236c-4c94-8fa9-944a3e5353fa` | R/W |
| Unit | `fc540004-236c-4c94-8fa9-944a3e5353fa` | R |
| Battery | `fc540007-236c-4c94-8fa9-944a3e5353fa` | R |
| Liquid state | `fc540008-236c-4c94-8fa9-944a3e5353fa` | R |

Temps are `uint16LE` hundredths °C. The bar keeps one long-lived `ember_ble.py repl --mac …` process (Ember firmware hates connect/disconnect churn) and sends `status` / `set-temp` lines. `discover [--scan]` lists nearby Ember mugs.

## Caveats

- First write may need the official Ember app to unlock the GATT characteristic; after “remove from app” a factory reset + re-pair is sometimes required.
- Not affiliated with Ember; “Ember” is a trademark of Ember Technologies, Inc. Protocol reverse-engineered ([orlopau/ember-mug](https://github.com/orlopau/ember-mug)), may vary by firmware.

## License

MIT — see [LICENSE](LICENSE).
