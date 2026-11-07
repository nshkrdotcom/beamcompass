#!/usr/bin/env python3
"""Evidence-producing real corpus runner: only trusted core invokes Mix.

Inspected targets are file bytes; never enter their cwd with Mix, compile their
modules or execute their Mix/config/macros. Inventory-only is an explicitly
*nonaccepting* input measurement. Full output requires real trusted Mix export
and independent v2 validation, repeated outputs and wall/RSS samples.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import os
import subprocess
import sys
import time
import resource


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory(root: Path, catalog: dict, external_root: Path | None = None,
              external_origin: str | None = None) -> list[dict]:
    if catalog.get("format") != "beamcompass.p06-corpora" or catalog.get("schema_version") != 1:
        raise ValueError("unsupported corpus catalog")
    inputs = []
    used = set()
    for corpus in catalog.get("corpora", []):
        identifier = corpus["id"]
        if identifier in used:
            raise ValueError("duplicate corpus " + identifier)
        used.add(identifier)
        if Path(corpus["root"]).is_absolute() or ".." in Path(corpus["root"]).parts:
            raise ValueError("unsafe corpus path")
        project = root / corpus["root"]
        if not project.is_dir() or project.is_symlink() or not (project / "mix.exs").is_file():
            raise ValueError("missing or symlinked corpus: " + identifier)
        files = sorted(list((project / "lib").rglob("*.ex")) + list((project / "lib").rglob("*.exs")))
        if not files:
            raise ValueError("no Elixir source files in " + identifier)
        items = []
        started = time.monotonic_ns()
        for file in files:
            if file.is_symlink() or not file.is_file() or file.stat().st_size > 2_097_152:
                raise ValueError("unsafe source in " + identifier)
            data = file.read_bytes()
            items.append({"path": file.relative_to(project).as_posix(), "bytes": len(data), "sha256": digest(data),
                          "lines": data.count(b"\n") + (bool(data) and not data.endswith(b"\n"))})
        inputs.append({"id": identifier, "root": corpus["root"], "kind": corpus["kind"],
                       "origin": corpus["provenance"], "source_files": len(items),
                       "source_bytes": sum(i["bytes"] for i in items),
                       "source_lines": sum(i["lines"] for i in items),
                       "inventory_wall_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
                       "file_content_integrity": items})
    if len(used) < catalog.get("minimum_local_distinct_projects", 3):
        raise ValueError("insufficient local corpus diversity")
    if external_root is not None:
        if not external_origin or len(external_origin.strip()) < 10:
            raise ValueError("externally acquired corpus requires a concrete provenance statement")
        if external_root.is_symlink() or not external_root.is_dir() or not (external_root / "mix.exs").is_file():
            raise ValueError("external corpus missing or symlinked")
        files = sorted(list((external_root / "lib").rglob("*.ex")) +
                       list((external_root / "lib").rglob("*.exs")))
        if not files:
            raise ValueError("external corpus has no source files")
        items = []
        started = time.monotonic_ns()
        for file in files:
            if file.is_symlink() or not file.is_file() or file.stat().st_size > 2_097_152:
                raise ValueError("unsafe external source input")
            data = file.read_bytes()
            items.append({"path": file.relative_to(external_root).as_posix(),
                          "bytes": len(data), "sha256": digest(data),
                          "lines": data.count(b"\n") + (bool(data) and not data.endswith(b"\n"))})
        inputs.append({"id": "reviewed-external-corpus", "root": str(external_root.absolute()),
                       "kind": "operator-supplied-independent-project",
                       "origin": external_origin, "source_files": len(items),
                       "source_bytes": sum(i["bytes"] for i in items),
                       "source_lines": sum(i["lines"] for i in items),
                       "inventory_wall_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
                       "file_content_integrity": items})
    return inputs


def peak_rss(pid: int) -> int | None:
    # Linux-specific sampled resident bytes, explicitly not an exact upper bound.
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        return None
    return None


def invoke(cmd: list[str], cwd: Path, timeout: float = 180.0) -> dict:
    start = time.monotonic_ns()
    rss = []
    try:
        process = subprocess.Popen(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
    except OSError as exc:
        return {"command": cmd, "cwd": str(cwd), "exit_code": 127,
                "stdout": "", "stderr": f"executable unavailable: {exc}",
                "elapsed_ms": round((time.monotonic_ns() - start) / 1_000_000, 3),
                "peak_rss_bytes_sampled": None, "rss_samples": 0}
    try:
        while process.poll() is None and (time.monotonic_ns() - start) / 1_000_000_000 < timeout:
            memory = peak_rss(process.pid)
            if memory is not None:
                rss.append(memory)
            time.sleep(0.01)
        if process.poll() is None:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            timed_out = True
        else:
            timed_out = False
        stdout, stderr = process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
    return {"command": cmd, "cwd": str(cwd), "exit_code": 124 if timed_out else process.returncode,
            "stdout": stdout, "stderr": stderr, "elapsed_ms": round((time.monotonic_ns() - start) / 1_000_000, 3),
            "peak_rss_bytes_sampled": max(rss, default=None), "rss_samples": len(rss),
            "rss_sampling_interval_ms": 10, "rss_is_exact_peak": False}


def run(source_root: Path, docset_root: Path, out: Path, inventory_only: bool,
        external_root: Path | None = None, external_origin: str | None = None) -> dict:
    root = source_root.absolute()
    catalog = json.loads((root / "corpora/P06-real-projects.json").read_text())
    observed = inventory(root, catalog, external_root, external_origin)
    report = {"format": "beamcompass.p06-corpus-profile", "source_mode": "source",
              "corpus_provenance": catalog["provenance"], "corpora": observed,
              "status": "inventory_only_not_exporter_acceptance", "acceptance_passed": False,
              "limitations": ["Two first-party projects plus one controlled fixture; no independent third-party provenance",
                              "Measured Python inventory wall-time is NOT BEAM exporter wall-time or release SLO",
                              "Sampled /proc VmRSS may miss transient process peaks and child processes"]}
    out.mkdir(parents=True, exist_ok=True)
    if not inventory_only:
        trusted_core = root / "monorepo/beamcompass_core"
        for corpus in observed:
            for round_index in (1, 2):
                snapshot_path = out / f"{corpus['id']}-{round_index}.json"
                target_path = Path(corpus["root"])
                if not target_path.is_absolute():
                    target_path = root / target_path
                cmd = ["mix", "beamcompass.export", str(target_path), "--schema", "2",
                       "--project-id", "p06:" + corpus["id"], "--out", str(snapshot_path)]
                execution = invoke(cmd, trusted_core)
                corpus.setdefault("export_runs", []).append(execution)
                if execution["exit_code"] != 0 or not snapshot_path.is_file():
                    report["failure"] = "trusted-core-mix-export-failed:" + corpus["id"]
                    report["status"] = "blocked"
                    break
                try:
                    check = invoke([sys.executable, str(docset_root / "tools/p06_consumer_v2.py"), str(snapshot_path)], docset_root)
                    corpus.setdefault("consumer_runs", []).append(check)
                    if check["exit_code"] != 0:
                        report["failure"] = "independent-consumer-refused:" + corpus["id"]
                        report["status"] = "blocked"
                        break
                    data = json.loads(snapshot_path.read_text())
                    if data["issues"]:
                        report["failure"] = "source-parse-issues:" + corpus["id"]
                        report["status"] = "blocked"
                        break
                except (ValueError, KeyError, OSError) as e:
                    report["failure"] = "invalid-export:" + str(e)
                    report["status"] = "blocked"
                    break
            if report["status"] == "blocked":
                break
            first = (out / f"{corpus['id']}-1.json").read_bytes()
            second = (out / f"{corpus['id']}-2.json").read_bytes()
            corpus["deterministic_export_digest"] = digest(first)
            if first != second:
                report["status"] = "blocked"
                report["failure"] = "nondeterministic-export:" + corpus["id"]
                break
        else:
            # Count two actual first-party projects + one externally acquired
            # independent Mix app; the controlled ledger fixture is not a
            # substitute for independent external provenance.
            if external_root is not None and len(observed) >= 4:
                report["status"] = "exporter_corpus_and_independent_consumers_passed"
                report["acceptance_passed"] = True
            else:
                report["status"] = "local_corpora_verified_external_provenance_required"
    (out / "corpus-profile.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--docset-root", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--inventory-only", action="store_true")
    parser.add_argument("--external-project-root", type=Path,
                        help="B-supplied independent real Mix app, scanned only as inert source bytes")
    parser.add_argument("--external-provenance",
                        help="B-documented exact acquisition provenance; never guessed")
    args = parser.parse_args()
    try:
        report = run(args.source_root, args.docset_root, args.out, args.inventory_only,
                     args.external_project_root, args.external_provenance)
        print(json.dumps({"status": report["status"], "acceptance_passed": report["acceptance_passed"],
                          "count": len(report["corpora"]), "failure": report.get("failure")}, sort_keys=True))
        if args.inventory_only:
            return 0  # successful inventory only, not P06 full corpus acceptance
        return 0 if report["acceptance_passed"] else 1
    except (ValueError, KeyError, OSError, TypeError) as e:
        print("CORPUS REFUSED: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
