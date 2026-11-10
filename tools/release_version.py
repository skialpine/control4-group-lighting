"""Project release versions: YYYYMMDDRR, with a new revision for each release."""

import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

VERSION_FILE = Path(__file__).resolve().parents[1] / "VERSION"


def validate(value: str) -> str:
    if not re.fullmatch(r"[0-9]{10}", value):
        raise ValueError("version must be YYYYMMDDRR")
    datetime.strptime(value[:8], "%Y%m%d")
    if int(value) > 2147483647:
        raise ValueError("version exceeds the controller integer range")
    return value


def tag_version(tag: str, expected: str, previous_tags=()) -> str:
    match = re.fullmatch(r"v([0-9]{10})(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?", tag)
    if not match or validate(match[1]) != validate(expected):
        raise ValueError(
            "release tag must match VERSION (vYYYYMMDDRR or vYYYYMMDDRR-suffix)"
        )
    for previous in previous_tags:
        prior = re.fullmatch(
            r"v([0-9]{8}|[0-9]{10})(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?", previous
        )
        if previous != tag and prior and int(prior[1]) >= int(match[1]):
            raise ValueError(
                "release VERSION must increase beyond existing release tags"
            )
    return match[1]


def main() -> int:
    try:
        current = validate(VERSION_FILE.read_text().strip())
        if sys.argv[1:] == ["current"]:
            print(current)
        elif len(sys.argv) in (3, 4) and sys.argv[1] == "tag-version":
            previous = ()
            if len(sys.argv) == 4:
                if sys.argv[3] != "--check-history":
                    raise ValueError("unknown tag-version option")
                previous = subprocess.check_output(
                    ["git", "tag", "--list", "v*"], text=True, cwd=VERSION_FILE.parent
                ).splitlines()
            print("DRIVER_VERSION=" + tag_version(sys.argv[2], current, previous))
        else:
            raise ValueError("usage: release_version.py current|tag-version <tag>")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
