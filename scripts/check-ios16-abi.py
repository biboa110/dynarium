#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify that Dynarium.app and embedded frameworks preserve iOS 16.0 ABI."""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

FORBIDDEN_LIBCXX_PREFIXES = (
    "__ZNSt3__13pmr",
    "__ZNKSt3__13pmr",
    "__ZNSt3__110__print",
    "__ZNSt3__16chrono4tzdb",
    "__ZNKSt3__16chrono4tzdb",
    "__ZNSt3__115__hash_memory",
    "__ZNSt3__112__to_chars",
    "__ZNSt3__114__from_chars",
)


def parse_version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.strip().split(".") if part)


def collect_macho_binaries(app_bundle: pathlib.Path) -> list[pathlib.Path]:
    exec_name = subprocess.check_output(
        ["plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", str(app_bundle / "Info.plist")],
        text=True,
    ).strip()
    binaries = [app_bundle / exec_name]
    frameworks_dir = app_bundle / "Frameworks"
    if frameworks_dir.is_dir():
        for fw in sorted(frameworks_dir.glob("*.framework")):
            candidate = fw / fw.stem
            if candidate.is_file():
                binaries.append(candidate)
    return binaries


def check_minos(binary: pathlib.Path, max_minos: tuple[int, ...]) -> str | None:
    out = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    in_bv = False
    for line in out.splitlines():
        stripped = line.strip()
        if stripped.startswith("cmd "):
            in_bv = stripped == "cmd LC_BUILD_VERSION"
        elif in_bv and stripped.startswith("minos "):
            ver = stripped.split()[1]
            if parse_version(ver) > max_minos:
                return f"{binary.name}: minos {ver} exceeds {'.'.join(map(str, max_minos))}"
            return None
    return f"{binary.name}: missing LC_BUILD_VERSION minos"


def check_libcxx_symbols(binary: pathlib.Path) -> list[str]:
    out = subprocess.check_output(["nm", "-u", str(binary)], text=True)
    libcxx_syms = sorted(
        {
            line.strip()
            for line in out.splitlines()
            if line.strip().startswith(("__ZNSt3__1", "__ZNKSt3__1"))
        }
    )
    print(f"[check-ios16-abi] {binary.name}: {len(libcxx_syms)} undefined libc++ symbols")
    for sym in libcxx_syms:
        print(f"  {sym}")

    bad = [
        sym
        for sym in libcxx_syms
        if any(sym.startswith(prefix) for prefix in FORBIDDEN_LIBCXX_PREFIXES)
    ]
    return bad


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_bundle", type=pathlib.Path)
    parser.add_argument("--expected-max-minos", default="16.0")
    args = parser.parse_args()

    max_minos = parse_version(args.expected_max_minos)
    binaries = collect_macho_binaries(args.app_bundle)
    if not binaries:
        print("No Mach-O binaries found in bundle", file=sys.stderr)
        return 1

    failures: list[str] = []
    for binary in binaries:
        if not binary.is_file():
            failures.append(f"Missing binary: {binary}")
            continue
        minos_err = check_minos(binary, max_minos)
        if minos_err:
            failures.append(minos_err)
        bad_syms = check_libcxx_symbols(binary)
        for sym in bad_syms:
            failures.append(f"{binary.name}: forbidden post-iOS-16 libc++ symbol {sym}")

    if failures:
        for err in failures:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    print(f"[check-ios16-abi] Verified {len(binaries)} Mach-O binaries for iOS {args.expected_max_minos} compatibility.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
