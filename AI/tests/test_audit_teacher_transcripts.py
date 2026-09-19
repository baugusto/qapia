import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "audit_teacher_transcripts.py"
)
SPEC = importlib.util.spec_from_file_location("audit_teacher_transcripts", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class AuditTeacherTranscriptsTests(unittest.TestCase):
    def test_tokens_are_casefolded_and_unicode_aware(self) -> None:
        self.assertEqual(MODULE.tokens("AÇÃO, decisão!"), ["ação", "decisão"])

    def test_audit_accepts_complete_private_teacher_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            dataset_root = root / "source"
            teacher_root = root / "teacher"
            meeting_root = dataset_root / "meetings" / "sample-1"
            meeting_root.mkdir(parents=True)
            teacher_root.mkdir()
            transcript_path = meeting_root / "transcript.source.txt"
            transcript_path.write_text("Ação definida hoje", encoding="utf-8")
            manifest = {
                "meetings": [
                    {
                        "sample_id": "sample-1",
                        "duration_bucket": "short_5_to_20_min",
                        "files": [
                            {
                                "kind": "audio",
                                "file": "meetings/sample-1/audio.m4a",
                                "sha256": "audio-sha",
                            },
                            {
                                "kind": "source_transcript",
                                "file": "meetings/sample-1/transcript.source.txt",
                                "sha256": "transcript-sha",
                            },
                        ],
                    }
                ]
            }
            (dataset_root / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            output = {
                "sample_id": "sample-1",
                "classification": "private-sensitive-restricted",
                "review_status": "pending_human_correction",
                "teacher": {"model": "large-v3"},
                "draft_transcript": "Ação definida hoje",
                "sources": [
                    {
                        "file": "meetings/sample-1/audio.m4a",
                        "sha256": "audio-sha",
                        "metadata": {
                            "detected_language": "pt",
                            "language_probability": 1.0,
                            "duration_seconds": 600.0,
                        },
                        "segments": [
                            {
                                "start_ms": 0,
                                "end_ms": 1500,
                                "avg_logprob": -0.1,
                                "words": [
                                    {
                                        "start_ms": 0,
                                        "end_ms": 500,
                                        "probability": 0.9,
                                    }
                                ],
                            }
                        ],
                    }
                ],
            }
            output_path = teacher_root / "sample-1.json"
            output_path.write_text(json.dumps(output), encoding="utf-8")
            os.chmod(output_path, 0o600)

            report = MODULE.audit(dataset_root, teacher_root)

            self.assertTrue(report["integrity"]["valid"])
            self.assertEqual(report["integrity"]["teacher_outputs"], 1)
            self.assertEqual(report["coverage"]["audio_hours"], round(600 / 3600, 6))
            self.assertEqual(
                report["signals_for_human_review"]["low_confidence_word_count"], 0
            )
            self.assertEqual(
                report["signals_for_human_review"][
                    "teacher_current_sequence_similarity"
                ]["mean"],
                1.0,
            )

    def test_audit_rejects_missing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            dataset_root = root / "source"
            teacher_root = root / "teacher"
            dataset_root.mkdir()
            teacher_root.mkdir()
            (dataset_root / "manifest.json").write_text(
                json.dumps(
                    {
                        "meetings": [
                            {
                                "sample_id": "missing",
                                "duration_bucket": "long_45_plus_min",
                                "files": [],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            report = MODULE.audit(dataset_root, teacher_root)

            self.assertFalse(report["integrity"]["valid"])
            self.assertEqual(report["integrity"]["missing_outputs"], 1)


if __name__ == "__main__":
    unittest.main()
