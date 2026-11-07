#!/usr/bin/env python3
"""Deterministic source-only release ZIP and integrity verifier, stdlib only.

Does not execute any target source, does not use Git/archive provenance. It
produces stable payload bytes for the same files. Hashes establish *integrity*
but NOT author authenticity. Compiled artifacts are not packed or signed.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import zipfile

SOURCE_DIRS = ("monorepo", "fixtures", "scripts", "assets", "corpora", ".github")
SOURCE_FILES = ("README.md", ".tool-versions", ".editorconfig", "LICENSE", ".gitignore")
EXCLUDE_PARTS = {".git", "_build", "deps", ".elixir_ls", "node_modules", "__pycache__", ".pytest_cache", "_archive", "tmp"}
EXCLUDE_SUFFIXES = (".pyc", ".beam", ".ez", ".log", ".tmp")
TIMESTAMP = (1980, 1, 1, 0, 0, 0)
MAX_FILE_SIZE = 64 * 1024 * 1024


def canonical(obj: object) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def listed_files(root: Path) -> list[Path]:
    root = Path(root).absolute()
    if not root.is_dir() or root.is_symlink():
        raise ValueError("source root missing or symlinked")
    candidates = [root / name for name in SOURCE_FILES]
    for directory in SOURCE_DIRS:
        base = root / directory
        if base.is_symlink():
            raise ValueError("symlink source directory: " + directory)
        if base.is_dir():
            candidates.extend(base.rglob("*"))
    files = []
    for p in sorted(set(candidates)):
        rel = p.relative_to(root)
        if EXCLUDE_PARTS.intersection(rel.parts) or p.suffix in EXCLUDE_SUFFIXES:
            continue
        # Never follow attacker-controlled symlink source input even if the
        # destination resolves inside the tree.
        if p.is_symlink():
            raise ValueError("symlink in release input: " + rel.as_posix())
        if p.is_file():
            if p.stat().st_size > MAX_FILE_SIZE:
                raise ValueError("oversize release input: " + rel.as_posix())
            files.append(p)
        elif p.exists() and not p.is_dir():
            raise ValueError("unsafe release input: " + rel.as_posix())
    if not files:
        raise ValueError("empty release input")
    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def payload(root: Path) -> dict[str, bytes]:
    root = Path(root).absolute()
    entries: dict[str, bytes] = {}
    hashes = []
    for path in listed_files(root):
        rel = path.relative_to(root).as_posix()
        data = path.read_bytes()
        if len(data) > MAX_FILE_SIZE:
            raise ValueError("oversize release input: " + rel)
        entries["beamcompass/" + rel] = data
        hashes.append({"path": "beamcompass/" + rel, "sha256": sha256(data), "bytes": len(data)})
    manifest = {"format": "beamcompass.release-source-inventory", "schema_version": 1,
                "scope": "source-only", "authenticity": "not-established-by-hashes",
                "files": hashes}
    entries["beamcompass/release-inventory.json"] = canonical(manifest)
    return entries


def build(root: Path, output: Path) -> dict[str, object]:
    entries = payload(root)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_STORED, allowZip64=True) as z:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(filename=name, date_time=TIMESTAMP)
            info.create_system = 3
            info.external_attr = (0o100644 << 16)
            info.compress_type = zipfile.ZIP_STORED
            z.writestr(info, data)
    return {"output": str(output), "sha256": sha256(output.read_bytes()),
            "entries": len(entries), "total_uncompressed_bytes": sum(map(len, entries.values()))}


def verify(zip_path: Path) -> dict[str, object]:
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        if names != sorted(set(names)) or "beamcompass/release-inventory.json" not in names:
            raise ValueError("noncanonical or missing release manifest")
        for info in z.infolist():
            if info.date_time != TIMESTAMP or info.compress_type != zipfile.ZIP_STORED or info.file_size > MAX_FILE_SIZE:
                raise ValueError("noncanonical ZIP metadata or input limit")
            if not info.filename.startswith("beamcompass/") or ".." in Path(info.filename).parts:
                raise ValueError("unsafe release archive path")
        manifest = json.loads(z.read("beamcompass/release-inventory.json"))
        if set(manifest) != {"format", "schema_version", "scope", "authenticity", "files"} or \
           manifest["format"] != "beamcompass.release-source-inventory" or \
           manifest["schema_version"] != 1 or manifest["scope"] != "source-only" or \
           manifest["authenticity"] != "not-established-by-hashes":
            raise ValueError("unsupported release manifest")
        expected = []
        for name in names:
            if name == "beamcompass/release-inventory.json":
                continue
            data = z.read(name)
            expected.append({"path": name, "sha256": sha256(data), "bytes": len(data)})
        if manifest["files"] != expected or z.read("beamcompass/release-inventory.json") != canonical(manifest):
            raise ValueError("release content integrity failure")
    return {"verified": True, "entries": len(names), "sha256": sha256(Path(zip_path).read_bytes())}


def check_reproducibility(root: Path) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="p06-release-") as directory:
        first = Path(directory) / "first.zip"
        second = Path(directory) / "second.zip"
        a = build(root, first)
        b = build(root, second)
        if a["sha256"] != b["sha256"] or first.read_bytes() != second.read_bytes():
            raise ValueError("nonreproducible release bytes")
        verify(first)
        verify(second)
        return {"status": "passed", "sha256": a["sha256"], "entries": a["entries"],
                "total_uncompressed_bytes": a["total_uncompressed_bytes"],
                "rounds": 2, "integrity": "sha256-not-publisher-authenticity"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--check-reproducible", action="store_true")
    args = parser.parse_args()
    try:
        if args.check_reproducible:
            result = check_reproducibility(args.source_root)
        elif args.out:
            result = build(args.source_root, args.out)
            result.update(verify(args.out))
        else:
            parser.error("--out or --check-reproducible required")
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print("RELEASE REFUSED: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
