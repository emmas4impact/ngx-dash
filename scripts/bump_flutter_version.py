import re
import sys
from pathlib import Path


PUBSPEC = Path(__file__).resolve().parents[1] / "flutter_app" / "pubspec.yaml"
APP_VERSION = Path(__file__).resolve().parents[1] / "flutter_app" / "lib" / "app_version.dart"
VERSION_PATTERN = re.compile(r"^version:\s+(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$", re.MULTILINE)


def bump(version: str, part: str) -> str:
    match = VERSION_PATTERN.search(version)
    if not match:
        raise SystemExit("Could not find version like 'version: 1.0.0+1' in flutter_app/pubspec.yaml")

    major, minor, patch, build = [int(value) for value in match.groups()]
    if part == "major":
        major += 1
        minor = 0
        patch = 0
    elif part == "minor":
        minor += 1
        patch = 0
    elif part == "patch":
        patch += 1
    elif part == "build":
        pass
    else:
        raise SystemExit("Usage: python scripts/bump_flutter_version.py [major|minor|patch|build]")

    build += 1
    return VERSION_PATTERN.sub(f"version: {major}.{minor}.{patch}+{build}", version, count=1)


def main() -> None:
    part = sys.argv[1] if len(sys.argv) > 1 else "patch"
    current = PUBSPEC.read_text(encoding="utf-8")
    updated = bump(current, part)
    PUBSPEC.write_text(updated, encoding="utf-8")
    match = VERSION_PATTERN.search(updated)
    if not match:
        raise SystemExit("Could not read updated Flutter version")
    major, minor, patch, build = match.groups()
    APP_VERSION.write_text(
        "\n".join(
            [
                "const appVersionName = String.fromEnvironment(",
                "  'APP_VERSION_NAME',",
                f"  defaultValue: '{major}.{minor}.{patch}',",
                ");",
                "const appBuildNumber = String.fromEnvironment(",
                "  'APP_BUILD_NUMBER',",
                f"  defaultValue: '{build}',",
                ");",
                "const appDisplayVersion = '$appVersionName.$appBuildNumber';",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(match.group(0))


if __name__ == "__main__":
    main()
