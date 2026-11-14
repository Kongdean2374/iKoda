#!/usr/bin/env python3
"""Derive an immutable release identity without changing tracked project files."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ATTEMPT_SLOTS = 100


def semantic_version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError(f"Invalid release version: {value!r}")
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0])[:3])


def next_feature_version(current: str) -> str:
    """The 0.3 line upgrades to 0.4.0; newer lines always advance a minor version."""
    major, minor, _ = semantic_version(current)
    if (major, minor) < (0, 4):
        return "0.4.0"
    return f"{major}.{minor + 1}.0"


def project_versions(project: Path) -> tuple[str, int]:
    text = project.read_text()
    versions = re.findall(r"\bMARKETING_VERSION\s*=\s*([\d.]+)\s*;", text)
    builds = re.findall(r"\bCURRENT_PROJECT_VERSION\s*=\s*(\d+)\s*;", text)
    # Two configurations for each of Koda and KodaWidgets. Fail on disagreement,
    # rather than shipping an extension with a different release identity.
    if len(versions) != 4 or len(builds) != 4:
        raise ValueError("Expected version settings for both app/widget Debug and Release")
    if len(set(versions)) != 1 or len(set(builds)) != 1:
        raise ValueError("App and widget project versions disagree")
    version = versions[0]
    semantic_version(version)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Release MARKETING_VERSION must use major.minor.patch")
    return version, int(builds[0])


def identity(version: str, baseline: int, run_number: int, attempt: int) -> dict[str, str]:
    semantic_version(version)
    if baseline < 1 or run_number < 1:
        raise ValueError("Build baseline and workflow run number must be positive")
    if not 1 <= attempt < ATTEMPT_SLOTS:
        raise ValueError("Workflow attempts must be 1...99; start a new workflow run after that")
    build = baseline + run_number * ATTEMPT_SLOTS + attempt
    # One decimal component is accepted by the sideloading workflow and Xcode.
    # Keep it well inside a signed 32-bit integer for downstream signing tools.
    if build > 2_147_483_647:
        raise ValueError("Build number exceeds the supported integer range")
    name = f"Koda-{version}-build{build}"
    return {"version": version, "build_number": str(build), "ipa_name": f"{name}.ipa",
            "artifact_name": name, "dmg_name": f"{name}-mac.dmg"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT / "Koda.xcodeproj/project.pbxproj")
    parser.add_argument("--run-number", type=int, default=os.environ.get("GITHUB_RUN_NUMBER"))
    parser.add_argument("--attempt", type=int, default=os.environ.get("GITHUB_RUN_ATTEMPT"))
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--next-feature-version", help="Print the next safe feature release; no files are changed")
    args = parser.parse_args()
    if args.next_feature_version:
        print(next_feature_version(args.next_feature_version))
        return
    if args.run_number is None or args.attempt is None:
        parser.error("run-number and attempt are required outside GitHub Actions")
    version, baseline = project_versions(args.project)
    values = identity(version, baseline, args.run_number, args.attempt)
    if args.github_output:
        with args.github_output.open("a") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(values, indent=2))


if __name__ == "__main__":
    main()
