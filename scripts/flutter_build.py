#!/usr/bin/env python3

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBSPEC = ROOT / "flutter_app" / "pubspec.yaml"
VERSION_PATTERN = re.compile(r"^version:\s+(\d+\.\d+\.\d+)\+(\d+)\s*$", re.MULTILINE)


def read_version() -> tuple[str, str]:
    content = PUBSPEC.read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(content)
    if not match:
        raise SystemExit("Could not find Flutter version in flutter_app/pubspec.yaml")
    return match.group(1), match.group(2)


def git_commit_count() -> str:
    result = subprocess.run(
        ["git", "rev-list", "--count", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build Flutter artifacts with a dotted display version like 1.0.12.72.",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Flutter command after 'build', for example: apk --debug",
    )
    parser.add_argument(
        "--build-number",
        dest="build_number",
        default=None,
        help="Override the auto-generated build number.",
    )
    args = parser.parse_args()

    if not args.command:
        raise SystemExit("Usage: python3 scripts/flutter_build.py apk --debug [other flutter build args]")

    version_name, pubspec_build = read_version()
    build_number = args.build_number or git_commit_count() or pubspec_build

    command = [
        "flutter",
        "build",
        *args.command,
        "--build-name",
        version_name,
        "--build-number",
        build_number,
        f"--dart-define=APP_VERSION_NAME={version_name}",
        f"--dart-define=APP_BUILD_NUMBER={build_number}",
    ]

    print(f"Building version {version_name}.{build_number}")
    raise SystemExit(
        subprocess.run(command, cwd=ROOT / "flutter_app", check=False).returncode,
    )


if __name__ == "__main__":
    main()
