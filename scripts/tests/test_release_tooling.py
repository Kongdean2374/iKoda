import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


versions = module("build_version", SCRIPTS / "build-version.py")
ipa_tool = module("verify_ipa", SCRIPTS / "verify-ipa.py")


class VersionTests(unittest.TestCase):
    def test_feature_upgrade_never_downgrades(self):
        for old, new in (("0.3", "0.4.0"), ("0.4.0", "0.5.0"), ("0.9.7", "0.10.0"), ("1.2.9", "1.3.0")):
            self.assertEqual(versions.next_feature_version(old), new)
            self.assertGreater(versions.semantic_version(new), versions.semantic_version(old))

    def test_run_and_rerun_slots_are_distinct_and_ordered(self):
        first = versions.identity("0.4.0", 10000, 25, 1)
        rerun = versions.identity("0.4.0", 10000, 25, 2)
        last = versions.identity("0.4.0", 10000, 25, 99)
        following = versions.identity("0.4.0", 10000, 26, 1)
        self.assertEqual(first["build_number"], "12501")
        self.assertEqual(first["ipa_name"], "Koda-0.4.0-build12501.ipa")
        self.assertLess(int(first["build_number"]), int(rerun["build_number"]))
        self.assertLess(int(last["build_number"]), int(following["build_number"]))
        self.assertNotEqual(first["artifact_name"], rerun["artifact_name"])

    def test_invalid_run_identifiers_fail_instead_of_colliding(self):
        for run, attempt in ((0, 1), (-1, 1), (1, 0), (1, -1), (1, 100)):
            with self.subTest(run=run, attempt=attempt), self.assertRaises(ValueError):
                versions.identity("0.4.0", 10000, run, attempt)
        with self.assertRaises(ValueError):
            versions.identity("0.4.0", 2_147_483_647, 1, 1)
        with self.assertRaises(ValueError):
            versions.identity("../0.4.0", 10000, 1, 1)

    def test_project_requires_matching_app_widget_and_configurations(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.pbxproj"
            line = "MARKETING_VERSION = 0.4.0; CURRENT_PROJECT_VERSION = 10000;\n"
            project.write_text(line * 4)
            self.assertEqual(versions.project_versions(project), ("0.4.0", 10000))
            project.write_text(line * 3 + line.replace("10000", "10001"))
            with self.assertRaisesRegex(ValueError, "disagree"):
                versions.project_versions(project)
            project.write_text(line * 3)
            with self.assertRaisesRegex(ValueError, "both app/widget"):
                versions.project_versions(project)


class IPATests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)

    def fixture(self, *, widget_build="10501", omit=None, bad_binary=False, extra=None,
                app_info=None, widget_info=None):
        files = {}
        for root, name, identifier, build in (
            ("Payload/Koda.app", "Koda", "ivors.Koda", "10501"),
            ("Payload/Koda.app/PlugIns/KodaWidgets.appex", "KodaWidgets", "ivors.Koda.Widgets", widget_build),
        ):
            info = {"CFBundleShortVersionString": "0.4.0", "CFBundleVersion": build,
                    "CFBundleExecutable": name, "CFBundleIdentifier": identifier,
                    "CFBundleSupportedPlatforms": ["iPhoneOS"]}
            info.update((app_info if name == "Koda" else widget_info) or {})
            files[f"{root}/Info.plist"] = (plistlib.dumps(info, fmt=plistlib.FMT_BINARY), 0o644)
            files[f"{root}/{name}"] = ((b"NOPE" if bad_binary else b"\xcf\xfa\xed\xfe") + bytes(60), 0o755)
            localized = {"Immersive Listening": "沉浸式聽歌", "Unlock Touch Controls": "解除觸控鎖定"}
            files[f"{root}/zh-Hant.lproj/Localizable.strings"] = (plistlib.dumps(localized), 0o644)
            files[f"{root}/en.lproj/Localizable.strings"] = (b"compiled English", 0o644)
        files["Payload/Koda.app/Metadata.appintents/extract.actionsdata"] = (b"general metadata", 0o644)
        files["Payload/Koda.app/zh-Hant.lproj/InfoPlist.strings"] = (b"compiled purposes", 0o644)
        files["Payload/Koda.app/KodaCore_KodaCore.bundle/zh-Hant.lproj/Localizable.strings"] = (b"compiled core table", 0o644)
        files["Payload/Koda.app/KodaCore_KodaCore.bundle/en.lproj/Localizable.strings"] = (b"compiled English", 0o644)
        if omit:
            files.pop(omit)
        path = self.root / "Koda-0.4.0-build10501.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            for name, (data, mode) in files.items():
                item = zipfile.ZipInfo(name)
                item.create_system = 3
                item.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(item, data)
            if extra:
                archive.writestr(extra, "malicious path")
        return path

    def verify(self, path, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            return ipa_tool.verify(path, self.root / "extracted", "0.4.0", "10501", **options)

    def test_checks_actual_plists_executables_and_resources(self):
        app = self.verify(self.fixture())
        self.assertTrue((app / "Koda").is_file())
        self.assertTrue((app / "PlugIns/KodaWidgets.appex/KodaWidgets").stat().st_mode & stat.S_IXUSR)

    def test_checks_retired_carplay_is_not_compiled(self):
        self.verify(self.fixture(), immersive_release=True)

    def test_rejects_retired_carplay_scene_in_compiled_app(self):
        app_info = {"UIApplicationSceneManifest": {"UISceneConfigurations": {
            "CPTemplateApplicationSceneSessionRoleApplication": [{"UISceneClassName": "CPTemplateApplicationScene"}],
        }}}
        with self.assertRaisesRegex(ValueError, "Retired CarPlay scene"):
            self.verify(self.fixture(app_info=app_info), immersive_release=True)

    def test_rejects_widget_version_mismatch(self):
        with self.assertRaisesRegex(ValueError, "Wrong build"):
            self.verify(self.fixture(widget_build="3"))

    def test_rejects_missing_zh_hant_resource(self):
        with self.assertRaisesRegex(ValueError, "Missing compiled Traditional Chinese"):
            self.verify(self.fixture(omit="Payload/Koda.app/KodaCore_KodaCore.bundle/zh-Hant.lproj/Localizable.strings"))

    def test_rejects_non_executable_binary(self):
        with self.assertRaisesRegex(ValueError, "Not a Mach-O"):
            self.verify(self.fixture(bad_binary=True))

    def test_rejects_missing_executable(self):
        with self.assertRaisesRegex(ValueError, "Missing executable"):
            self.verify(self.fixture(omit="Payload/Koda.app/Koda"))

    def test_rejects_path_traversal_before_extracting(self):
        with self.assertRaisesRegex(ValueError, "Unsafe IPA member"):
            self.verify(self.fixture(extra="../outside.txt"))
        self.assertFalse((self.root / "extracted").exists())
        self.assertFalse((self.root / "outside.txt").exists())

    def test_will_not_overwrite_an_existing_directory(self):
        output = self.root / "extracted"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.verify(self.fixture())
        self.assertEqual(sentinel.read_text(), "keep")

    def test_rejects_corrupt_archive(self):
        path = self.fixture()
        raw = bytearray(path.read_bytes())
        index = raw.index(b"compiled core table")
        raw[index] ^= 0x01
        path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "CRC"):
            self.verify(path)


if __name__ == "__main__":
    unittest.main()
