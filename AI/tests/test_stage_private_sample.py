import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "stage_private_sample.py"
SPEC = importlib.util.spec_from_file_location("stage_private_sample", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class StagePrivateSampleTests(unittest.TestCase):
    def test_copy_is_private_and_idempotent_for_same_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.m4a"
            destination = root / "destination.m4a"
            source.write_bytes(b"private audio fixture")

            MODULE.copy_on_write_or_copy(source, destination)
            MODULE.copy_on_write_or_copy(source, destination)

            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(os.stat(destination).st_mode & 0o777, 0o600)

    def test_copy_refuses_to_replace_different_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.txt"
            destination = root / "destination.txt"
            source.write_text("source", encoding="utf-8")
            destination.write_text("different", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                MODULE.copy_on_write_or_copy(source, destination)


if __name__ == "__main__":
    unittest.main()
