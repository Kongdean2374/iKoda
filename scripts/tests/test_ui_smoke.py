import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


SPEC = importlib.util.spec_from_file_location("ui_smoke", Path(__file__).resolve().parents[1] / "run-ui-smoke.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class SimulatorSelectionTests(unittest.TestCase):
    def test_original_release_scheme_remains_shared_when_ui_scheme_is_added(self):
        # Xcode stops exposing the implicit Koda scheme once explicit shared schemes
        # exist. Preserve the entry point used by both existing release jobs.
        schemes = Path(__file__).resolve().parents[2] / "Koda.xcodeproj/xcshareddata/xcschemes"
        release = ET.parse(schemes / "Koda.xcscheme").getroot()
        entries = release.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].get("buildForArchiving"), "YES")
        self.assertEqual(entries[0].find("BuildableReference").get("BlueprintName"), "Koda")
        smoke = ET.parse(schemes / "Koda-UI-Smoke.xcscheme").getroot()
        testables = smoke.findall("./TestAction/Testables/TestableReference/BuildableReference")
        self.assertEqual([item.get("BlueprintName") for item in testables], ["KodaUITests"])

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

    def test_same_version_general_runtime_beats_device_variant_but_variant_remains_a_fallback(self):
        variant = "test.iOS-27-2-iPhone19-4"
        general = "test.iOS-27-2"
        inventory = {
            "runtimes": [
                {"identifier": variant, "version": "27.2", "isAvailable": True},
                {"identifier": general, "version": "27.2.0", "isAvailable": True},
            ],
            "devices": {
                variant: [{"name": "iPhone Duo", "udid": "duo", "isAvailable": True}],
                general: [
                    {"name": "iPhone 17e", "udid": "compact", "isAvailable": True},
                    {"name": "iPhone 17 Pro Max", "udid": "large", "isAvailable": True},
                ],
            },
        }
        selected = UI.select_devices(inventory)
        self.assertEqual([device["udid"] for device in selected], ["compact", "large"])
        self.assertTrue(all(device["runtime"] == general for device in selected))
        inventory["runtimes"][1]["isAvailable"] = False
        self.assertEqual(UI.select_devices(inventory), [
            {"name": "iPhone Duo", "udid": "duo", "runtime": variant},
        ])
