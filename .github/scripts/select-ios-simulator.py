#!/usr/bin/env python3
import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: select-ios-simulator.py <device-name-prefix>", file=sys.stderr)
        return 2

    prefix = sys.argv[1]
    payload = json.load(sys.stdin)
    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        match = re.search(r"SimRuntime\.iOS-([0-9-]+)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        for device in devices:
            name = device.get("name", "")
            udid = device.get("udid", "")
            if name.startswith(prefix) and udid:
                candidates.append((version, name, udid))

    if not candidates:
        print(f"no available iOS Simulator starts with {prefix!r}", file=sys.stderr)
        return 1

    version, name, udid = max(candidates)
    print(udid)
    print(
        f"selected {name} on iOS {'.'.join(map(str, version))} ({udid})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
