#!/usr/bin/env python3
"""Normalize the assembled MTPADMIN CLI before installation.

Historical fragments intentionally crossed heredoc/function boundaries. Newer runtime
functions superseded three legacy implementations. Keep source compatibility, but strip
the superseded definitions from the final executable so there is exactly one effective
security/resources/doctor implementation.
"""
from pathlib import Path
import sys


def cut_between(src: str, start_marker: str, end_marker: str, label: str) -> str:
    starts = [i for i in range(len(src)) if src.startswith(start_marker, i)]
    if len(starts) != 1:
        raise SystemExit(f"normalize_cli: expected one legacy {label} start, got {len(starts)}")
    start = starts[0]
    end = src.find(end_marker, start + len(start_marker))
    if end < 0:
        raise SystemExit(f"normalize_cli: legacy {label} end marker missing")
    return src[:start] + src[end:]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: normalize_cli.py PATH")
    path = Path(sys.argv[1])
    src = path.read_text(encoding="utf-8")

    expected = {
        "security_cmd(){": 2,
        "resources_cmd(){": 2,
        "doctor_cmd(){": 2,
    }
    for marker, count in expected.items():
        got = src.count(marker)
        if got != count:
            raise SystemExit(f"normalize_cli: expected {count} occurrences of {marker}, got {got}")

    # The first security/resources implementations are contiguous in 20-admin.sh.
    src = cut_between(src, "security_cmd(){\n", "logs_cmd(){", "security/resources block")
    # The first doctor implementation ends immediately before update_cmd().
    src = cut_between(src, "doctor_cmd(){\n", "update_cmd(){", "doctor block")

    for marker in expected:
        got = src.count(marker)
        if got != 1:
            raise SystemExit(f"normalize_cli: expected exactly one final {marker}, got {got}")

    # Guard against accidentally stripping the canonical runtime implementations.
    required = (
        "Scanner Guard / manual firewall controls",
        "Runtime-safe doctor helpers",
        "Memory PSI healthy",
        "Web active slot",
        "Scanner Guard service",
    )
    for marker in required:
        if marker not in src:
            raise SystemExit(f"normalize_cli: required runtime marker missing: {marker}")

    path.write_text(src, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
