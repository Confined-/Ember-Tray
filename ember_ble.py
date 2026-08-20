#!/usr/bin/env python3
"""Ember mug BLE bridge for the Omarchy Ember-Tray plugin.

Talks to a paired Ember mug over BlueZ GATT directly through D-Bus using
dbus-python (already installed on Omarchy). No pip packages are needed.

The mug must be paired first, e.g.:

    bluetoothctl
    scan on
    # ... find "EMBER" and note its MAC ...
    pair AA:BB:CC:DD:EE:FF
    trust AA:BB:CC:DD:EE:FF

Commands:

    ember_ble.py status   --mac AA:BB:CC:DD:EE:FF
    ember_ble.py set-temp --mac AA:BB:CC:DD:EE:FF --value 55.5   (0 turns the heater off)

Both print a single JSON line on stdout.

The widget keeps a single long-lived `repl` process connected to the mug so
BlueZ never sees a fresh connect/disconnect every poll (Ember firmware is
sensitive to that churn):

    ember_ble.py repl --mac AA:BB:CC:DD:EE:FF

`repl` reads one command per line from stdin (`status`, `set-temp <celsius>`,
`quit`) and prints one JSON line per response. The one-shot `status`/`set-temp`
commands are kept for scripting and quick checks.
"""

import argparse
import json
import signal
import struct
import sys
import time

import dbus

CHAR_UUIDS = {
    "current_temp": "fc540002236c4c948fa9944a3e5353fa",
    "target_temp": "fc540003236c4c948fa9944a3e5353fa",
    "unit": "fc540004236c4c948fa9944a3e5353fa",
    "battery": "fc540007236c4c948fa9944a3e5353fa",
    "liquid_state": "fc540008236c4c948fa9944a3e5353fa",
}

LIQUID_LABELS = {
    0: "Standby",
    1: "Empty",
    2: "Filling",
    3: "Cold",
    4: "Cooling",
    5: "Heating",
    6: "Perfect",
    7: "Warm",
}

WATCHDOG_SECONDS = 12


def emit(payload):
    print(json.dumps(payload))
    sys.stdout.flush()


def error(message):
    return " ".join(str(message).split())


def install_watchdog(seconds):
    def _handler(_signum, _frame):
        emit({"connected": False, "error": "operation timed out"})
        sys.exit(1)

    signal.signal(signal.SIGALRM, _handler)
    signal.alarm(seconds)


def clear_watchdog():
    signal.alarm(0)


def normalize_uuid(value):
    return str(value).replace("-", "").lower()


def parse_u16le(data):
    return int.from_bytes(bytes(data[:2]), "little")


def parse_temp(data):
    return parse_u16le(data) / 100.0


def parse_battery(data):
    raw = bytes(data)
    percent = raw[0] if len(raw) >= 1 else 0
    charging = len(raw) >= 2 and raw[1] == 1
    return percent, charging


def find_device(bus, mac):
    mac = str(mac).upper()
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager"
    )
    try:
        objects = manager.GetManagedObjects()
    except Exception as exc:
        raise RuntimeError(f"bluez unreachable: {error(exc)}") from exc
    for path, ifaces in objects.items():
        device = ifaces.get("org.bluez.Device1")
        if device and str(device.get("Address", "")).upper() == mac:
            return path
    return None


def find_characteristics(bus, device_path):
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager"
    )
    objects = manager.GetManagedObjects()
    characteristics = {}
    for path, ifaces in objects.items():
        if not path.startswith(device_path + "/"):
            continue
        characteristic = ifaces.get("org.bluez.GattCharacteristic1")
        if not characteristic:
            continue
        uuid = normalize_uuid(characteristic.get("UUID", ""))
        for name, expected in CHAR_UUIDS.items():
            if uuid == expected:
                characteristics[name] = path
    return characteristics


def read_char(bus, chrc_path):
    obj = bus.get_object("org.bluez", chrc_path)
    iface = dbus.Interface(obj, "org.bluez.GattCharacteristic1")
    value = iface.ReadValue({"offset": dbus.UInt16(0)}, timeout=WATCHDOG_SECONDS * 1000)
    return bytes(value)


def write_char(bus, chrc_path, data):
    obj = bus.get_object("org.bluez", chrc_path)
    iface = dbus.Interface(obj, "org.bluez.GattCharacteristic1")
    options = {"offset": dbus.UInt16(0)}
    try:
        # The Ember mug only accepts write-without-response even though BlueZ
        # advertises the plain "write" flag; send that first.
        iface.WriteValue(
            dbus.ByteArray(data),
            {"type": "command", **options},
            timeout=WATCHDOG_SECONDS * 1000,
        )
    except dbus.exceptions.DBusException as exc:
        # Only fall back if the write type itself is unsupported; a
        # "NotConnected" or ATT error here should surface immediately.
        msg = str(exc)
        if "NotSupported" not in msg and "not supported" not in msg.lower():
            raise
        iface.WriteValue(
            dbus.ByteArray(data),
            {"type": "request", **options},
            timeout=WATCHDOG_SECONDS * 1000,
        )


def connect_device(bus, device_path):
    obj = bus.get_object("org.bluez", device_path)
    return dbus.Interface(obj, "org.bluez.Device1")


def connect_with_retry(device, attempts=4, delay=1.0):
    """Connect, retrying transient 'In Progress' errors.

    BlueZ returns from Connect() while a connection attempt is already being
    made (by this script or a concurrent one) with
    org.bluez.Error.InProgress; retrying lets us wait for the winner.
    """
    last_error = None
    for attempt in range(attempts):
        try:
            device.Connect()
            return
        except Exception as exc:
            last_error = exc
            if "InProgress" not in str(exc):
                raise
            if attempt < attempts - 1:
                time.sleep(delay)
    raise last_error


def wait_services_resolved(bus, device_path, timeout=8):
    """Wait until GATT services are available after a connect.

    BlueZ often returns from Connect() before org.bluez.Device1.ServicesResolved
    is true, so walking the object tree right away can miss the characteristics
    and falsely report "mug service not found". Poll the property instead.
    """
    obj = bus.get_object("org.bluez", device_path)
    props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if props.Get("org.bluez.Device1", "ServicesResolved"):
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def open_mug(bus, device, device_path):
    """Connect (if needed) and return the resolved characteristics, or None."""
    connect_with_retry(device)
    if not wait_services_resolved(bus, device_path):
        return None
    chrc = find_characteristics(bus, device_path)
    if "current_temp" not in chrc or "target_temp" not in chrc:
        return None
    return chrc


def confirm_write(bus, chrc_path, raw, attempts=6, delay=0.5):
    """Read back a written value, retrying while the mug applies it.

    The mug writes with write-without-response, which carries no
    acknowledgment; an immediate read can race the mug still applying the
    value (and even briefly refuse target reads with an ATT error) and would
    falsely report failure.
    """
    expected = raw / 100.0
    for _ in range(attempts):
        time.sleep(delay)
        try:
            confirmed = parse_temp(read_char(bus, chrc_path))
        except Exception:
            continue
        if abs(confirmed - expected) <= 0.11:
            return confirmed
    return None


def find_adapter(bus):
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager"
    )
    try:
        objects = manager.GetManagedObjects()
    except Exception:
        return None
    for path, ifaces in objects.items():
        if "org.bluez.Adapter1" in ifaces:
            return path
    return None


def bluetooth_off_reason(bus):
    adapter_path = find_adapter(bus)
    if not adapter_path:
        return "Bluetooth is off — turn it on in Bluetooth settings"
    try:
        obj = bus.get_object("org.bluez", adapter_path)
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        if not props.Get("org.bluez.Adapter1", "Powered"):
            return "Bluetooth is off — turn it on in Bluetooth settings"
    except Exception:
        return "Bluetooth is off — turn it on in Bluetooth settings"
    return None


def not_found_reason(bus):
    off = bluetooth_off_reason(bus)
    if off:
        return off
    return "Mug not in range — is it nearby and turned on?"


def friendly_error(exc, bus=None):
    if bus is not None:
        off = bluetooth_off_reason(bus)
        if off:
            return off
    msg = str(exc)
    if "NotReady" in msg or "Resource Not Ready" in msg:
        return "Bluetooth is off — turn it on in Bluetooth settings"
    if "NotAvailable" in msg or "not available" in msg.lower():
        return "Mug not in range — is it nearby and turned on?"
    if "NotConnected" in msg:
        return "Mug not in range — is it nearby and turned on?"
    if "DoesNotExist" in msg:
        return "Mug not in range — is it nearby and turned on?"
    return error(exc)


def collect_ember_candidates(bus):
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager"
    )
    try:
        objects = manager.GetManagedObjects()
    except Exception as exc:
        off = bluetooth_off_reason(bus)
        if off:
            raise RuntimeError(off) from exc
        raise RuntimeError(f"bluez unreachable: {error(exc)}") from exc
    candidates = []
    for _path, ifaces in objects.items():
        dev = ifaces.get("org.bluez.Device1")
        if not dev:
            continue
        name = str(dev.get("Name", "") or "")
        alias = str(dev.get("Alias", "") or "")
        combined = (name + " " + alias).lower()
        if "ember" not in combined:
            continue
        addr = str(dev.get("Address", "")).upper()
        if not addr:
            continue
        rssi = dev.get("RSSI")
        try:
            rssi_val = int(rssi) if rssi is not None else None
        except Exception:
            rssi_val = None
        candidates.append(
            {
                "mac": addr,
                "name": name or alias,
                "alias": alias,
                "paired": bool(dev.get("Paired", False)),
                "trusted": bool(dev.get("Trusted", False)),
                "connected": bool(dev.get("Connected", False)),
                "rssi": rssi_val,
            }
        )
    # Paired first, then strongest RSSI, then MAC for stability.
    candidates.sort(key=lambda d: (not d["paired"], -(d["rssi"] if d["rssi"] is not None else -999), d["mac"]))
    return candidates


def cmd_discover(args):
    bus = dbus.SystemBus()
    off = bluetooth_off_reason(bus)
    if off:
        print(json.dumps({"error": off}))
        sys.stdout.flush()
        return 1
    if args.scan:
        adapter_path = find_adapter(bus)
        adapter = dbus.Interface(bus.get_object("org.bluez", adapter_path), "org.bluez.Adapter1")
        try:
            adapter.StartDiscovery()
        except Exception as exc:
            msg = str(exc)
            if "InProgress" not in msg and "Already" not in msg and "Failed" not in msg:
                print(json.dumps({"error": friendly_error(exc, bus)}))
                sys.stdout.flush()
                return 1
            # Already discovering is fine — just collect what we have.
        time.sleep(args.timeout)
        try:
            adapter.StopDiscovery()
        except Exception:
            pass
    try:
        candidates = collect_ember_candidates(bus)
    except Exception as exc:
        print(json.dumps({"error": friendly_error(exc, bus)}))
        sys.stdout.flush()
        return 1
    print(json.dumps(candidates))
    sys.stdout.flush()
    return 0


def cmd_pair(args):
    bus = dbus.SystemBus()
    device_path = find_device(bus, args.mac)
    if not device_path:
        print(json.dumps({"ok": False, "error": not_found_reason(bus)}))
        sys.stdout.flush()
        return 1
    obj = bus.get_object("org.bluez", device_path)
    dev_iface = dbus.Interface(obj, "org.bluez.Device1")
    # Pair if not already paired
    try:
        # Check current paired state first to avoid unnecessary Pair call
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        paired = props.Get("org.bluez.Device1", "Paired")
        if not paired:
            dev_iface.Pair()
    except dbus.exceptions.DBusException as exc:
        msg = str(exc)
        # AlreadyExists / Already Paired can be treated as success
        if "AlreadyExists" not in msg and "Already paired" not in msg and "Paired" not in msg:
            print(json.dumps({"ok": False, "error": friendly_error(exc, bus)}))
            sys.stdout.flush()
            return 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error": friendly_error(exc, bus)}))
        sys.stdout.flush()
        return 1
    # Trust so it auto-connects next time
    try:
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        props.Set("org.bluez.Device1", "Trusted", dbus.Boolean(True))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": friendly_error(exc, bus)}))
        sys.stdout.flush()
        return 1
    print(json.dumps({"ok": True, "mac": str(args.mac).upper()}))
    sys.stdout.flush()
    return 0


def read_state(bus, chrc, target_override=None, heater_on_override=None):
    current = parse_temp(read_char(bus, chrc["current_temp"]))
    target = (
        target_override
        if target_override is not None
        else parse_temp(read_char(bus, chrc["target_temp"]))
    )
    percent, charging = parse_battery(read_char(bus, chrc["battery"]))
    liquid_raw = bytes(read_char(bus, chrc["liquid_state"]))
    liquid_code = liquid_raw[0] if liquid_raw else -1
    unit_raw = bytes(read_char(bus, chrc["unit"]))
    unit = "F" if (unit_raw and unit_raw[0] == 1) else "C"
    heater_on = (
        heater_on_override if heater_on_override is not None else target > 0
    )
    return {
        "connected": True,
        "currentTemp": current,
        "targetTemp": target,
        "heaterOn": heater_on,
        "battery": percent,
        "charging": charging,
        "liquidState": LIQUID_LABELS.get(liquid_code, "Unknown"),
        "liquidCode": liquid_code,
        "unit": unit,
    }


def cmd_status(args):
    bus = dbus.SystemBus()
    device_path = find_device(bus, args.mac)
    if not device_path:
        emit({"connected": False, "error": not_found_reason(bus)})
        return 0

    device = connect_device(bus, device_path)
    install_watchdog(WATCHDOG_SECONDS)
    try:
        chrc = open_mug(bus, device, device_path)
    except Exception as exc:
        clear_watchdog()
        emit({"connected": False, "error": friendly_error(exc, bus)})
        return 0

    if chrc is None:
        clear_watchdog()
        off = bluetooth_off_reason(bus)
        if off:
            emit({"connected": False, "error": off})
        else:
            emit({"connected": False, "error": "Mug not in range — is it nearby and turned on?"})
        return 0

    try:
        emit(read_state(bus, chrc))
        return 0
    except Exception as exc:
        clear_watchdog()
        emit({"connected": False, "error": friendly_error(exc, bus)})
        return 0
    finally:
        clear_watchdog()
        try:
            device.Disconnect()
        except Exception:
            pass


def cmd_set_temp(args):
    bus = dbus.SystemBus()
    device_path = find_device(bus, args.mac)
    if not device_path:
        emit({"ok": False, "error": not_found_reason(bus)})
        return 1

    device = connect_device(bus, device_path)
    install_watchdog(WATCHDOG_SECONDS)
    try:
        chrc = open_mug(bus, device, device_path)
    except Exception as exc:
        clear_watchdog()
        emit({"ok": False, "error": friendly_error(exc, bus)})
        return 1

    if chrc is None:
        clear_watchdog()
        off = bluetooth_off_reason(bus)
        if off:
            emit({"ok": False, "error": off})
        else:
            emit({"ok": False, "error": "Mug not in range — is it nearby and turned on?"})
        return 1

    try:
        raw = max(0, int(round(float(args.value) * 100)))
        write_char(bus, chrc["target_temp"], struct.pack("<H", raw))
        # Write-without-response carries no acknowledgment, so confirm the mug
        # actually stored the value before reporting success.
        confirmed = confirm_write(bus, chrc["target_temp"], raw)
        if confirmed is None:
            emit({"ok": False, "error": "write not confirmed (mug unresponsive)"})
            return 1
        emit({"ok": True, **read_state(bus, chrc, target_override=confirmed, heater_on_override=raw > 0)})
        return 0
    except Exception as exc:
        clear_watchdog()
        emit({"ok": False, "error": friendly_error(exc, bus)})
        return 1
    finally:
        clear_watchdog()
        try:
            device.Disconnect()
        except Exception:
            pass


def cmd_repl(args):
    """Persistent bridge: stays connected and serves one command per stdin line.

    Keeps a single GATT connection across polls so BlueZ doesn't tear the link
    down after every status read. A failed command drops the connection (chrc
    is reset) and reconnects before the next command.
    """
    bus = dbus.SystemBus()
    device_path = find_device(bus, args.mac)
    if not device_path:
        emit({"connected": False, "error": not_found_reason(bus)})
        return 1

    device = connect_device(bus, device_path)
    try:
        chrc = open_mug(bus, device, device_path)
    except Exception as exc:
        emit({"connected": False, "error": friendly_error(exc, bus)})
        return 1

    if chrc is None:
        off = bluetooth_off_reason(bus)
        if off:
            emit({"connected": False, "error": off})
        else:
            emit({"connected": False, "error": "Mug not in range — is it nearby and turned on?"})
        return 1

    try:
        for line in sys.stdin:
            command = line.strip()
            if not command:
                continue
            if command in ("quit", "exit"):
                break
            try:
                if chrc is None:
                    chrc = open_mug(bus, device, device_path)
                    if chrc is None:
                        off = bluetooth_off_reason(bus)
                        if off:
                            emit({"connected": False, "error": off})
                        else:
                            emit({"connected": False, "error": "Mug not in range — is it nearby and turned on?"})
                        continue
                if command == "status":
                    emit(read_state(bus, chrc))
                elif command.startswith("set-temp "):
                    value = command[len("set-temp "):].strip()
                    try:
                        raw = max(0, int(round(float(value) * 100)))
                    except ValueError:
                        emit({"ok": False, "error": "invalid temperature"})
                        continue
                    write_char(bus, chrc["target_temp"], struct.pack("<H", raw))
                    confirmed = confirm_write(bus, chrc["target_temp"], raw)
                    if confirmed is None:
                        emit({"ok": False, "error": "write not confirmed (mug unresponsive)"})
                    else:
                        emit({"ok": True, **read_state(bus, chrc, target_override=confirmed, heater_on_override=raw > 0)})
                else:
                    emit({"ok": False, "error": "unknown command"})
            except Exception as exc:
                chrc = None
                if command == "status":
                    emit({"connected": False, "error": friendly_error(exc, bus)})
                else:
                    emit({"ok": False, "error": friendly_error(exc, bus)})
    finally:
        try:
            device.Disconnect()
        except Exception:
            pass
    return 0


def main():
    parser = argparse.ArgumentParser(prog="ember_ble")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status")
    status.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")

    set_temp = sub.add_parser("set-temp")
    set_temp.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")
    set_temp.add_argument("--value", required=True, help="target temperature in Celsius; 0 turns the heater off")

    repl = sub.add_parser("repl")
    repl.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")

    discover = sub.add_parser("discover")
    discover.add_argument("--scan", action="store_true", help="actively scan for nearby unpaired mugs")
    discover.add_argument("--timeout", type=int, default=6, help="scan duration in seconds (with --scan)")

    pair = sub.add_parser("pair")
    pair.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")

    args = parser.parse_args()

    if args.command == "status":
        return cmd_status(args)
    if args.command == "repl":
        return cmd_repl(args)
    if args.command == "discover":
        return cmd_discover(args)
    if args.command == "pair":
        return cmd_pair(args)
    return cmd_set_temp(args)


if __name__ == "__main__":
    sys.exit(main())