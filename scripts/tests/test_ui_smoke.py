import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("ui_smoke", Path(__file__).resolve().parents[1] / "run-ui-smoke.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class SimulatorSelectionTests(unittest.TestCase):
    def test_unsupported_or_unavailable_runtime_is_not_reported_as_testable(self):
        inventory = {
            "runtimes": [
                {"identifier": "test.iOS-25", "version": "25.0", "isAvailable": True},
                {"identifier": "test.iOS-27", "version": "27.0", "isAvailable": False},
            ],
            "devices": {"test.iOS-25": [{"name": "iPhone 17", "udid": "old", "isAvailable": True}]},
        }
        self.assertEqual(UI.select_devices(inventory), [])

    def test_chooses_two_distinct_sizes_on_the_newest_available_ios(self):
        inventory = {
            "runtimes": [
                {"identifier": "test.iOS-26", "version": "26.1", "isAvailable": True},
                {"identifier": "test.iOS-27", "version": "27.0", "isAvailable": True},
            ],
            "devices": {"test.iOS-27": [
                {"name": "iPhone 17 Pro", "udid": "normal", "isAvailable": True},
                {"name": "iPhone 16e", "udid": "compact", "isAvailable": True},
                {"name": "iPhone 17 Pro Max", "udid": "large", "isAvailable": True},
                {"name": "iPad Pro", "udid": "ipad", "isAvailable": True},
            ]},
        }
        selected = UI.select_devices(inventory)
        self.assertEqual([d["udid"] for d in selected], ["compact", "large"])
        self.assertTrue(all(d["runtime"] == "test.iOS-27" for d in selected))

    def test_one_available_phone_runs_once_instead_of_inventing_a_second_device(self):
        inventory = {
            "runtimes": [{"identifier": "test.iOS-26", "version": "26.0", "isAvailable": True}],
            "devices": {"test.iOS-26": [
                {"name": "iPhone 17", "udid": "phone", "isAvailable": True},
                {"name": "iPhone 17 Pro Max", "udid": "broken", "isAvailable": False},
            ]},
        }
        self.assertEqual([d["udid"] for d in UI.select_devices(inventory)], ["phone"])
