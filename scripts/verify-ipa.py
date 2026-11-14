#!/usr/bin/env python3
"""Verify the actual IPA and extract it for Foundation localization checks."""
from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import zipfile

MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def localized_file(root: Path, filename: str) -> Path:
    # SwiftPM may lowercase the directory name; both spellings are valid for Apple.
    candidates = [folder / filename for folder in root.iterdir()
                  if folder.is_dir() and folder.name.lower() == "zh-hant.lproj"]
    require(len(candidates) == 1 and candidates[0].is_file(),
            f"Missing compiled Traditional Chinese {filename}: {root}")
    return candidates[0]


def inspect_bundle(root: Path, version: str, build: str, apple_tools: bool = False) -> dict:
    info_path = root / "Info.plist"
    require(info_path.is_file(), f"Missing Info.plist: {root}")
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    require(info.get("CFBundleShortVersionString") == version, f"Wrong release version in {root}")
    require(info.get("CFBundleVersion") == build, f"Wrong build number in {root}")
    executable = info.get("CFBundleExecutable", "")
    require(isinstance(executable, str) and executable not in ("", ".", "..")
            and Path(executable).name == executable and "\\" not in executable,
            f"Unsafe or missing executable name in {root}")
    binary = root / executable
    require(binary.is_file(), f"Missing executable: {binary}")
    require(bool(binary.stat().st_mode & stat.S_IXUSR), f"Executable permission missing: {binary}")
    with binary.open("rb") as file:
        require(file.read(4) in MACHO_MAGICS and binary.stat().st_size >= 32, f"Not a Mach-O executable: {binary}")
    localized_file(root, "Localizable.strings")
    if apple_tools:
        subprocess.run(["/usr/bin/plutil", "-lint", str(info_path)], check=True)
        for key, expected in (("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
            actual = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(info_path)], text=True).strip()
            require(actual == expected, f"PlistBuddy version mismatch: {root} {key}")
        description = subprocess.check_output(["/usr/bin/file", str(binary)], text=True).strip()
        require("Mach-O" in description, f"file did not recognize executable: {description}")
        subprocess.run(["/usr/bin/lipo", "-verify_arch", "arm64", str(binary)], check=True)
        print(description)
    return info


def verify(ipa: Path, output: Path, version: str, build: str, apple_tools: bool = False) -> Path:
    require(not output.exists(), f"Verification output already exists: {output}")
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "IPA ZIP CRC validation failed")
        names = set()
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in item.filename,
                    f"Unsafe IPA member: {item.filename}")
            require(item.filename not in names, f"Duplicate IPA member: {item.filename}")
            require(not stat.S_ISLNK(item.external_attr >> 16), f"Unexpected IPA symlink: {item.filename}")
            names.add(item.filename)
        require("Payload/Koda.app/Info.plist" in names, "IPA does not contain Payload/Koda.app")
        output.mkdir(parents=True)
        archive.extractall(output)
        # Python's ZIP extraction does not preserve Unix executable permissions.
        for item in archive.infolist():
            mode = item.external_attr >> 16
            if stat.S_ISREG(mode):
                (output / item.filename).chmod(mode & 0o777)
    app = output / "Payload/Koda.app"
    main = inspect_bundle(app, version, build, apple_tools)
    require(main.get("CFBundleIdentifier") == "ivors.Koda", "App bundle identifier changed")
    require("iPhoneOS" in main.get("CFBundleSupportedPlatforms", []), "IPA is not an iOS device build")
    widget = inspect_bundle(app / "PlugIns/KodaWidgets.appex", version, build, apple_tools)
    require(widget.get("CFBundleIdentifier") == "ivors.Koda.Widgets", "Widget bundle identifier changed")
    localized_file(app, "InfoPlist.strings")
    core = list(app.rglob("KodaCore_KodaCore.bundle"))
    require(len(core) == 1, "Expected one packaged KodaCore resource bundle")
    localized_file(core[0], "Localizable.strings")
    print(f"PASS: {ipa.name}; app/widget version {version} build {build}; valid executables and compiled zh-Hant resources.")
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--apple-tools", action="store_true")
    args = parser.parse_args()
    verify(args.ipa, args.output, args.version, args.build, args.apple_tools)


if __name__ == "__main__":
    main()
