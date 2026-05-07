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
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""
    return result.stdout.strip()


def stamp_web_entrypoint(version_name: str, build_number: str) -> None:
    build_dir = ROOT / "flutter_app" / "build" / "web"
    main_js = build_dir / "main.dart.js"
    bootstrap = build_dir / "flutter_bootstrap.js"

    if not main_js.exists() or not bootstrap.exists():
        return

    versioned_main_name = f"main.{version_name}.{build_number}.dart.js"
    versioned_main = build_dir / versioned_main_name
    for stale_entrypoint in build_dir.glob("main.*.dart.js"):
        if stale_entrypoint != versioned_main:
            stale_entrypoint.unlink()
    for stale_source_map in build_dir.glob("main.*.dart.js.map"):
        stale_source_map.unlink()
    if versioned_main.exists():
        versioned_main.unlink()
    main_js.rename(versioned_main)

    source_map = build_dir / "main.dart.js.map"
    if source_map.exists():
        versioned_source_map_name = f"{versioned_main_name}.map"
        versioned_source_map = build_dir / versioned_source_map_name
        if versioned_source_map.exists():
            versioned_source_map.unlink()
        source_map.rename(versioned_source_map)
        content = versioned_main.read_text(encoding="utf-8")
        content = content.replace(
            "//# sourceMappingURL=main.dart.js.map",
            f"//# sourceMappingURL={versioned_source_map_name}",
        )
        versioned_main.write_text(content, encoding="utf-8")

    bootstrap_content = bootstrap.read_text(encoding="utf-8")
    bootstrap_content = bootstrap_content.replace(
        '"mainJsPath":"main.dart.js"',
        f'"mainJsPath":"{versioned_main_name}"',
    )
    bootstrap.write_text(bootstrap_content, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build Flutter artifacts with a three-part display version like 1.1.0.",
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

    print(f"Building version {version_name} (build {build_number})")
    result = subprocess.run(command, cwd=ROOT / "flutter_app", check=False)
    if result.returncode != 0:
        raise SystemExit(result.returncode)

    if args.command and args.command[0] == "web":
        stamp_web_entrypoint(version_name, build_number)

    raise SystemExit(0)


if __name__ == "__main__":
    main()
