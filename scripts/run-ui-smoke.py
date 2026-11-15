#!/usr/bin/env python3
"""Run offline production-component UI checks on available iOS 26+ Simulators.

This deliberately reports unavailable runtimes as skipped, not as a successful UI
test. It creates no Apple account, downloads no runtime, and preserves the existing
Release IPA workflow. XCTest screenshots/xcresults are retained for visual review.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ui-smoke-results"


def command(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=check)


def select_devices(inventory: dict, device_group: str = "all") -> list[dict]:
    if device_group not in {"all", "compact", "large"}:
        raise ValueError(f"Unknown KODA_UI_DEVICE selection: {device_group}")

    def size_hint(device):
        name = device["name"]
        if "SE" in name or "mini" in name:
            return 0
        if re.search(r"iPhone \d+e\b", name):
            return 1
        if "Max" in name or "Plus" in name:
            return 4
        if "Air" in name:
            return 3
        return 2

    eligible = []
    for runtime in inventory.get("runtimes", []):
        version = tuple(int(v) for v in runtime.get("version", "0").split(".") if v.isdigit())
        version += (0,) * max(0, 3 - len(version))
        identifier = runtime.get("identifier", "")
        if not (runtime.get("isAvailable") and ".iOS-" in identifier and version >= (26,)):
            continue
        phones = [d for d in inventory.get("devices", {}).get(identifier, [])
                  if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
        if not phones:
            continue
        # Some Xcode releases list a device-specific runtime before the general
        # runtime at the same OS version. Prefer real compact/large coverage, then
        # the general runtime, without excluding a sole available device variant.
        has_size_range = len({size_hint(d) for d in phones}) > 1
        general_runtime = bool(re.search(r"\.iOS-\d+(?:-\d+)*$", identifier))
        priority = (version, has_size_range, general_runtime)
        eligible.append((priority, identifier, phones))
    if not eligible:
        return []
    _, identifier, phones = max(eligible, key=lambda candidate: candidate[0])
    # Names are selection hints only; the manifest records exactly what was
    # actually available. Never invent a second device when only one exists.
    phones.sort(key=lambda d: (size_hint(d), d["name"]))
    selected = [phones[0]]
    if phones[-1]["udid"] != phones[0]["udid"]:
        selected.append(phones[-1])
    if device_group == "compact":
        selected = selected[:1]
    elif device_group == "large":
        selected = selected[1:2]
    return [{"name": d["name"], "udid": d["udid"], "runtime": identifier} for d in selected]


def record(value: dict) -> None:
    (OUTPUT / "summary.json").write_text(json.dumps(value, indent=2) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("\n### Simulator UI component validation\n\n")
            handle.write(f"Status: **{value['status']}**. {value.get('reason', '')}\n\n")
            for device in value.get("devices", []):
                handle.write(f"- {device['name']} ({device['runtime']}): {device.get('status', 'pending')}\n")
            handle.write("\nThese checks use real SwiftUI controls in a DEBUG-only offline fixture; "
                         "they do not validate real audio routes, playback, haptics or Apple translation models.\n")


def main() -> int:
    OUTPUT.mkdir(exist_ok=True)
    inventory = json.loads(command("xcrun", "simctl", "list", "--json").stdout)
    device_group = os.environ.get("KODA_UI_DEVICE", "all")
    devices = select_devices(inventory, device_group)
    if not devices:
        reason = "No available iOS 26+ iPhone Simulator runtime; no UI tests executed."
        if device_group == "large" and select_devices(inventory):
            reason = "No second available iPhone Simulator for large-device coverage; no UI tests executed."
        print(f"::warning::{reason}")
        record({"status": "skipped", "reason": reason, "device_group": device_group, "devices": []})
        return 0
    result = {"status": "running", "device_group": device_group, "devices": devices}
    record(result)
    for index, device in enumerate(devices, 1):
        uid = device["udid"]
        # Dedicated GitHub runner simulators only. A clean install makes every run
        # independent of persisted preferences or a queue from an earlier test.
        command("xcrun", "simctl", "boot", uid, check=False)
        command("xcrun", "simctl", "bootstatus", uid, "-b")
        command("xcrun", "simctl", "uninstall", uid, "ivors.Koda", check=False)
        bundle = OUTPUT / f"device-{index}.xcresult"
        log = OUTPUT / f"device-{index}.log"
        arguments = ["xcodebuild", "test", "-project", "Koda.xcodeproj", "-scheme", "Koda-UI-Smoke",
                     "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={uid}",
                     "-destination-timeout", "120", "-derivedDataPath", "build-ui-smoke",
                     "-resultBundlePath", str(bundle), "-parallel-testing-enabled", "NO",
                     "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]
        print(f"Testing on {device['name']} ({device['runtime']})", flush=True)
        with log.open("w") as handle:
            completed = subprocess.run(arguments, cwd=ROOT, text=True, stdout=handle, stderr=subprocess.STDOUT)
        tail = log.read_text(errors="replace").splitlines()[-80:]
        print("\n".join(tail), flush=True)
        if bundle.exists():
            attachments = OUTPUT / f"device-{index}-attachments"
            exported = command("xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                               "--output-path", str(attachments), check=False)
            (OUTPUT / f"device-{index}-export.log").write_text(exported.stdout)
        command("xcrun", "simctl", "shutdown", uid, check=False)
        device["status"] = "passed" if completed.returncode == 0 else "failed"
        if completed.returncode:
            result["status"] = "failed"
            record(result)
            return completed.returncode
    result["status"] = "passed"
    record(result)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        OUTPUT.mkdir(exist_ok=True)
        record({"status": "failed", "reason": str(error), "devices": []})
        raise
