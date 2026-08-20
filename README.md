# Ember-Tray

Control your Ember smart mug from the Omarchy tray — see temperature and battery, set the target.

## Install

```sh
omarchy plugin add https://github.com/Confined-/Ember-Tray.git --enable
```

## Pair

Pair via the Bluetooth tray icon, or via this panel: tap **Scan nearby** to discover the mug, then tap **Use** — it pairs automatically.

Open the tray panel after pairing:

- One paired mug → connects automatically.
- Several mugs → tap **Use** on the one you want.

If the phone app is connected, disconnect it first.

**Reset** if the mug won’t appear: pick it up, hold the bottom button ~15 s until it blinks blue → yellow → red, let go, wait for white pulse, then forget *Ember Ceramic Mug* in Bluetooth settings and pair again — [official instructions](https://support.ember.com/en-US/ember-mug-how-to-reset-1757480).

## Use

- Click the tray icon to open the panel.
- Tap the large temperature to switch °F/°C.
- Drag the slider to set the target — far left is **Off**.

No config files to edit. A fresh mug is kept off until you pick a temperature (it would otherwise default to ~135 °F).

## Remove

```sh
omarchy plugin remove confined-.ember
```

## License

MIT — see [LICENSE](LICENSE).
