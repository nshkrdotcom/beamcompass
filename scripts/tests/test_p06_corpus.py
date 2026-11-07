"""Corpus inventory never executes target code and rejects missing/bad inputs."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent
spec = importlib.util.spec_from_file_location("p06_corpus", ROOT / "p06_corpus.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RealCorpusTests(unittest.TestCase):
    def test_local_real_project_source_bytes_and_distinct_contexts(self):
        catalog = __import__("json").loads((SOURCE / "corpora/P06-real-projects.json").read_text())
        samples = module.inventory(SOURCE, catalog)
        self.assertEqual({row["id"] for row in samples}, {"beamcompass-core", "beamcompass-web", "ledger-sample"})
        self.assertTrue(all(row["source_files"] >= 3 and row["source_bytes"] > 100 for row in samples))
        self.assertTrue(all(len(i["sha256"]) == 64 for row in samples for i in row["file_content_integrity"]))
        self.assertTrue(catalog["requires_independent_external_corpus_for_broad_release"])

    def test_missing_real_source_and_symlink_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            catalog = {"format": "beamcompass.p06-corpora", "schema_version": 1,
                       "minimum_local_distinct_projects": 1,
                       "corpora": [{"id": "x", "root": "missing", "kind": "synthetic", "provenance": "test"}]}
            with self.assertRaisesRegex(ValueError, "missing"):
                module.inventory(root, catalog)
            (root / "good/lib").mkdir(parents=True)
            (root / "good/mix.exs").write_text("raise 'untrusted Mix'")
            (root / "good/lib/a.ex").write_text("defmodule A do\nend")
            (root / "linked").symlink_to(root / "good")
            catalog["corpora"][0]["root"] = "linked"
            with self.assertRaisesRegex(ValueError, "symlink"):
                module.inventory(root, catalog)

    def test_intentional_inventory_only_cannot_claim_exporter_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = module.run(SOURCE, SOURCE, Path(tmp), inventory_only=True)
            self.assertFalse(result["acceptance_passed"])
            self.assertEqual(result["status"], "inventory_only_not_exporter_acceptance")


if __name__ == "__main__":
    unittest.main()
