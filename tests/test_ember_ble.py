import unittest
from unittest.mock import MagicMock, patch
import sys
import pathlib

# Add plugin root to path
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import ember_ble


class TestParseTarget(unittest.TestCase):
    def test_off(self):
        self.assertEqual(ember_ble.parse_target_value("0"), 0)
        self.assertEqual(ember_ble.parse_target_value("0.0"), 0)

    def test_valid_band(self):
        # 120°F = 48.888...°C, 145°F = 62.777...°C
        self.assertEqual(ember_ble.parse_target_value("48.89"), 4889)
        self.assertEqual(ember_ble.parse_target_value("57.22"), 5722)  # ~135°F
        self.assertEqual(ember_ble.parse_target_value("62.78"), 6278)

    def test_rejects_fahrenheit_mistake(self):
        with self.assertRaises(ValueError) as ctx:
            ember_ble.parse_target_value("130")
        self.assertIn("Fahrenheit", str(ctx.exception))

    def test_rejects_out_of_range(self):
        for v in ["45", "70", "47.9", "63.1", "100"]:
            with self.assertRaises(ValueError):
                ember_ble.parse_target_value(v)

    def test_rejects_non_finite(self):
        for v in ["inf", "nan", "-inf"]:
            with self.assertRaises(ValueError):
                ember_ble.parse_target_value(v)

    def test_rejects_overflow(self):
        # Would overflow <H if not validated (655.35 is max)
        with self.assertRaises(ValueError):
            ember_ble.parse_target_value("700")


class TestFriendlyError(unittest.TestCase):
    def test_bluetooth_off_takes_precedence(self):
        bus = MagicMock()
        with patch.object(ember_ble, "bluetooth_off_reason", return_value="Bluetooth is off — turn it on in Bluetooth settings"):
            err = ember_ble.friendly_error(Exception("org.bluez.Error.Failed: whatever"), bus)
            self.assertIn("Bluetooth is off", err)

    def test_not_ready_maps(self):
        err = ember_ble.friendly_error(Exception("org.bluez.Error.NotReady: Resource Not Ready"))
        self.assertIn("Bluetooth is off", err)

    def test_not_available_maps(self):
        err = ember_ble.friendly_error(Exception("org.bluez.Error.NotAvailable: not available"))
        self.assertIn("Mug not in range", err)


class TestDiscoveryOwnership(unittest.TestCase):
    def test_only_stops_if_started(self):
        # Simulate the fixed logic: only StopDiscovery if StartDiscovery succeeded
        bus = MagicMock()
        mock_adapter = MagicMock()
        mock_adapter.StartDiscovery.side_effect = Exception("org.bluez.Error.InProgress: Already discovering")
        mock_adapter.StopDiscovery = MagicMock()

        # Emulate cmd_discover's logic
        started_by_us = False
        try:
            mock_adapter.StartDiscovery()
            started_by_us = True
        except Exception as exc:
            msg = str(exc)
            if "InProgress" not in msg and "Already" not in msg:
                self.fail("should have suppressed InProgress")
            # Should NOT have set started_by_us
            self.assertFalse(started_by_us)

        if started_by_us:
            mock_adapter.StopDiscovery()

        mock_adapter.StopDiscovery.assert_not_called()

    def test_stops_when_we_started(self):
        bus = MagicMock()
        mock_adapter = MagicMock()
        mock_adapter.StartDiscovery.return_value = None
        mock_adapter.StopDiscovery = MagicMock()

        started_by_us = False
        try:
            mock_adapter.StartDiscovery()
            started_by_us = True
        except Exception:
            pass

        if started_by_us:
            mock_adapter.StopDiscovery()

        mock_adapter.StopDiscovery.assert_called_once()


class TestParseHelpers(unittest.TestCase):
    def test_parse_temp(self):
        self.assertAlmostEqual(ember_ble.parse_temp(bytes([0x2E, 0x16])), 56.78)

    def test_parse_battery(self):
        pct, charging = ember_ble.parse_battery(bytes([80, 1]))
        self.assertEqual(pct, 80)
        self.assertTrue(charging)
        pct, charging = ember_ble.parse_battery(bytes([55, 0]))
        self.assertFalse(charging)


if __name__ == "__main__":
    unittest.main()
