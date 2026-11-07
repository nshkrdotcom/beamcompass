"""Actual bytes/negative fault tests of deterministic non-Git release builder."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("p06_release", ROOT / "p06_release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseReproducibilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "source"
        (self.root / "monorepo" / "core" / "lib").mkdir(parents=True)
        (self.root / "monorepo" / "core" / "lib" / "a.ex").write_text("defmodule Safe, do: :ok")
        (self.root / "README.md").write_text("stable")

    def test_same_bytes_reproduce_across_timestamps_and_directories(self):
        a = Path(self.tmp.name) / "one.zip"
        b = Path(self.tmp.name) / "two.zip"
        first = module.build(self.root, a)
        (self.root / "README.md").touch()
        second = module.build(self.root, b)
        self.assertEqual(first["sha256"], second["sha256"])
        self.assertEqual(a.read_bytes(), b.read_bytes())
        self.assertTrue(module.verify(a)["verified"])
        self.assertEqual(module.check_reproducibility(self.root)["rounds"], 2)

    def test_changed_source_bytes_change_digest_without_identity_confusion(self):
        a = Path(self.tmp.name) / "one.zip"
        b = Path(self.tmp.name) / "two.zip"
        original = module.build(self.root, a)["sha256"]
        (self.root / "monorepo/core/lib/a.ex").write_text("defmodule Changed, do: :ok")
        self.assertNotEqual(original, module.build(self.root, b)["sha256"])
        self.assertTrue(module.verify(b)["verified"])

    def test_modified_release_payload_cannot_verify(self):
        archive = Path(self.tmp.name) / "corrupt.zip"
        module.build(self.root, archive)
        with zipfile.ZipFile(archive, mode="a") as z:
            z.writestr("beamcompass/UNLISTED.txt", "unexpected")
        with self.assertRaisesRegex(ValueError, "noncanonical|integrity"):
            module.verify(archive)

    def test_target_symlink_and_oversize_input_are_refused(self):
        target = Path(self.tmp.name) / "outside"
        target.write_text("do not read")
        (self.root / "monorepo" / "core" / "lib" / "bad.ex").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            module.build(self.root, Path(self.tmp.name) / "bad.zip")
        (self.root / "monorepo" / "core" / "lib" / "bad.ex").unlink()
        with self.assertRaisesRegex(ValueError, "oversize"):
            with mock.patch.object(module, "MAX_FILE_SIZE", 3):
                module.build(self.root, Path(self.tmp.name) / "bad.zip")


if __name__ == "__main__":
    unittest.main()
