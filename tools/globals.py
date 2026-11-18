#!/usr/bin/env python3
"""
Fail when a build reads a global its #ifdef/#ifndef branches took away.

A name a branch defines and shared code reads works in the build that keeps the
branch and is nil in the other, which the tests never see: they load the source
with every branch in. So each build's Lua is compared with its source, as LuaJIT
compiles both (tools/globals.lua):

- a global a built file reads that its source never reads as a global was a local
  the build lost, such as a `local function` inside `--#ifndef DRIVERCENTRAL`;
- a global a build reads that the source sets but the build never does was
  defined only in a branch the build left out. Definitions are compared within
  each driver and its literal require dependencies.

A built file that does not compile fails too. Run after `tools/preprocess.py`, as
`make check` does:
    tools/globals.py build/oss build/drivercentral
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TREES = ("src", "drivers", "vendor")
LUA_TOKEN = re.compile(
    r"(?P<long>(?:--)?\[(?P<equals>=*)\[.*?\](?P=equals)\])"
    r"|--[^\n]*|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\w+|\S",
    re.DOTALL,
)
MODULE_NAME = re.compile(r"""(['"])([\w./-]+)\1""")


def lua_files(base: Path) -> list[Path]:
    return sorted(p for tree in TREES for p in (base / tree).rglob("*.lua"))


def source_of(built: Path, build_dir: Path, root: Path) -> Path | None:
    """
    The source file a built one came from. A variant's folder, drivers/<driver>_<suffix>,
    came from drivers/<driver>, which holds the variants.json.
    """
    rel = built.relative_to(build_dir)
    source = root / rel
    if source.is_file():
        return source
    if rel.parts[0] != "drivers":
        return None
    variant = rel.parts[1]
    for driver in sorted((root / "drivers").iterdir(), key=lambda d: -len(d.name)):
        if (driver / "variants.json").is_file() and (
            variant == driver.name or variant.startswith(driver.name + "_")
        ):
            candidate = driver.joinpath(*rel.parts[2:])
            return candidate if candidate.is_file() else None
    return None


def globals_of(files: list[Path]) -> tuple[dict, dict]:
    """
    Each file's global reads and sets ({path: {"GGET": set, "GSET": set}}), and the
    compile error of each file LuaJIT could not load.
    """
    found: dict = defaultdict(lambda: {"GGET": set(), "GSET": set()})
    errors: dict = {}
    if not files:
        return found, errors
    run = subprocess.run(
        ["luajit", str(Path(__file__).parent / "globals.lua"), *map(str, files)],
        capture_output=True,
        text=True,
    )
    if run.returncode != 0:
        raise SystemExit(f"Error: tools/globals.lua failed: {run.stderr.strip()}")
    for line in run.stdout.splitlines():
        path, op, name = line.split("\t", 2)
        if op == "ERROR":
            errors[Path(path)] = name
        else:
            found[Path(path)][op].add(name)
    return found, errors


@lru_cache(maxsize=None)
def required_modules(file: Path) -> tuple[str, ...]:
    """Find literal module names in require calls, including pcall(require, ...)."""
    tokens = [
        match[0]
        for match in LUA_TOKEN.finditer(file.read_text(encoding="utf-8"))
        if not match[0].startswith("--")
    ]
    modules = []
    for i, token in enumerate(tokens):
        if token != "require" or (i and tokens[i - 1] in (".", ":")):
            continue
        argument = i + 1
        if argument < len(tokens) and tokens[argument] in ("(", ","):
            argument += 1
        if argument < len(tokens) and (
            literal := MODULE_NAME.fullmatch(tokens[argument])
        ):
            modules.append(literal[2])
    return tuple(modules)


def package_files(entry: Path, base: Path) -> set[Path]:
    """Resolve literal dependencies in the same directory order as gen-squishy.lua."""
    paths = (base / "src", base / "vendor", entry.parent)
    included: set[Path] = set()
    pending = [entry]
    while pending:
        file = pending.pop()
        if file in included:
            continue
        included.add(file)
        for name in required_modules(file):
            module = name.replace(".", "/")
            resolved = next(
                (
                    directory / relative
                    for directory in paths
                    for relative in (f"{module}.lua", f"{module}/init.lua")
                    if (directory / relative).is_file()
                ),
                None,
            )
            if resolved is not None:
                pending.append(resolved)
    return included


def check(build_dirs: list[Path], root: Path = ROOT) -> list[str]:
    """Each global a build reads that its branches took away, as an error message."""
    problems = []
    required_modules.cache_clear()
    for build_dir in build_dirs:
        built = lua_files(build_dir)
        pairs = {b: source_of(b, build_dir, root) for b in built}
        packages = [
            (entry, package_files(pairs[entry], root), package_files(entry, build_dir))
            for entry in sorted((build_dir / "drivers").glob("*/driver.lua"))
            if pairs.get(entry) is not None
        ]
        sources = {s for s in pairs.values() if s is not None}
        for _, source_package, _ in packages:
            sources.update(source_package)
        found, errors = globals_of(built + sorted(sources))
        for b, s in pairs.items():
            if b in errors:
                where = (
                    s.relative_to(root) if s is not None else b.relative_to(build_dir)
                )
                problems.append(
                    f'File "{where}": the {build_dir.name} build does not compile:'
                    f" {errors[b]}"
                )
                continue
            if s is None:
                continue
            where = s.relative_to(root)
            reads = found[b]["GGET"]
            if s in errors:
                lost = set()
            else:
                lost = reads - found[s]["GGET"]
            for name in sorted(lost):
                problems.append(
                    f'File "{where}": the {build_dir.name} build reads `{name}` as a'
                    " global, but the source declares it local. An #ifdef/#ifndef"
                    " branch this build leaves out holds the declaration."
                )
        for entry, source_package, built_package in packages:
            source_sets = set().union(*(found[file]["GSET"] for file in source_package))
            build_sets = set().union(*(found[file]["GSET"] for file in built_package))
            only_in_branches = source_sets - build_sets
            for file in sorted(built_package):
                original = pairs.get(file)
                if original is None or file in errors:
                    continue
                reads = found[file]["GGET"]
                if original not in errors:
                    reads = reads & found[original]["GGET"]
                for name in sorted(reads & only_in_branches):
                    problems.append(
                        f'File "{original.relative_to(root)}": the {build_dir.name}'
                        f" build reads the global `{name}`, which only an"
                        f" #ifdef/#ifndef branch this build leaves out sets"
                        f" (driver {entry.parent.name})."
                    )
    return problems


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 1
    problems = check([Path(a).resolve() for a in argv])
    for problem in problems:
        print(f"Error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
