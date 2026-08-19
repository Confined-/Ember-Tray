#!/usr/bin/env python3
"""Ember mug BLE bridge for the Omarchy ember plugin.

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
"""

import argparse
import json
import signal
import struct
import sys
import time

import dbus

SERVICE_UUID = "fc543622236c4c948fa9944a3e5353fa"

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
    except dbus.exceptions.DBusException:
        # Fall back to a normal write request for firmware that wants it.
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

    The widget runs status and set-temp as separate short-lived processes;
    when one is already connecting, BlueZ rejects the other with
    org.bluez.Error.InProgress. Retrying lets the loser wait for the winner.
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
        emit({"connected": False, "error": "mug not found (pair it first)"})
        return 0

    device = connect_device(bus, device_path)
    install_watchdog(WATCHDOG_SECONDS)
    try:
        connect_with_retry(device)
    except Exception as exc:
        clear_watchdog()
        emit({"connected": False, "error": f"connect failed: {error(exc)}"})
        return 0

    try:
        chrc = find_characteristics(bus, device_path)
        if "current_temp" not in chrc:
            clear_watchdog()
            emit({"connected": False, "error": "mug service not found on device"})
            return 0

        emit(read_state(bus, chrc))
        return 0
    except Exception as exc:
        clear_watchdog()
        emit({"connected": False, "error": error(exc)})
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
        emit({"ok": False, "error": "mug not found (pair it first)"})
        return 1

    device = connect_device(bus, device_path)
    install_watchdog(WATCHDOG_SECONDS)
    try:
        connect_with_retry(device)
    except Exception as exc:
        clear_watchdog()
        emit({"ok": False, "error": f"connect failed: {error(exc)}"})
        return 1

    try:
        chrc = find_characteristics(bus, device_path)
        target = chrc.get("target_temp")
        if not target:
            clear_watchdog()
            emit({"ok": False, "error": "target temperature characteristic not found"})
            return 1
        raw = max(0, int(round(float(args.value) * 100)))
        write_char(bus, target, struct.pack("<H", raw))
        # Write-without-response carries no acknowledgment, so confirm the mug
        # actually stored the value before reporting success.
        confirmed = parse_temp(read_char(bus, target))
        if abs(confirmed - raw / 100.0) > 0.11:
            emit({"ok": False, "error": f"write not confirmed (mug reports {confirmed:.2f})"})
            return 1
        emit({"ok": True, **read_state(bus, chrc, target_override=confirmed, heater_on_override=raw > 0)})
        return 0
    except Exception as exc:
        clear_watchdog()
        emit({"ok": False, "error": error(exc)})
        return 1
    finally:
        clear_watchdog()
        try:
            device.Disconnect()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser(prog="ember_ble")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status")
    status.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")

    set_temp = sub.add_parser("set-temp")
    set_temp.add_argument("--mac", required=True, help="mug MAC address (AA:BB:CC:DD:EE:FF)")
    set_temp.add_argument("--value", required=True, help="target temperature in Celsius; 0 turns the heater off")

    args = parser.parse_args()

    if args.command == "status":
        return cmd_status(args)
    return cmd_set_temp(args)


if __name__ == "__main__":
    sys.exit(main())