import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_ROOT = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_ROOT))
MODULE_PATH = SCRIPTS_ROOT / "prepare_annotation_queue.py"
SPEC = importlib.util.spec_from_file_location("prepare_annotation_queue", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def teacher_result(text: str, probabilities: list[float]) -> dict:
    return {
        "draft_transcript": text,
        "sources": [
            {
                "metadata": {"duration_seconds": 300.0},
                "segments": [
                    {
                        "words": [
                            {"probability": probability}
                            for probability in probabilities
                        ]
                    }
                ],
            }
        ],
    }


class PrepareAnnotationQueueTests(unittest.TestCase):
    def test_priority_marks_extreme_divergence_as_urgent(self) -> None:
        metrics = MODULE.priority_metrics(
            " ".join(["conteudo"] * 100),
            teacher_result("texto curto", [0.9, 0.9]),
        )
        self.assertEqual(metrics["priorityBand"], "urgent")
        self.assertIn("extreme_length_divergence", metrics["flags"])

    def test_matching_transcript_has_lower_priority(self) -> None:
        matching = MODULE.priority_metrics(
            "decisão aprovada hoje",
            teacher_result("decisão aprovada hoje", [0.99, 0.98, 0.97]),
        )
        divergent = MODULE.priority_metrics(
            "decisão aprovada hoje",
            teacher_result("outro assunto diferente", [0.4, 0.3, 0.2]),
        )
        self.assertLess(matching["priorityScore"], divergent["priorityScore"])

    def test_private_writer_is_atomic_and_restricted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "private" / "queue.json"
            MODULE.write_private_json(path, {"entries": []})
            self.assertEqual(json.loads(path.read_text()), {"entries": []})
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(os.stat(path.parent).st_mode & 0o777, 0o700)
            self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
