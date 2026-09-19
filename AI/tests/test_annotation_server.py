import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS_ROOT = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_ROOT))
MODULE_PATH = SCRIPTS_ROOT / "annotation_server.py"
SPEC = importlib.util.spec_from_file_location("annotation_server", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class AnnotationServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.dataset = self.root / "source"
        self.teacher = self.root / "teacher"
        self.annotations = self.root / "annotations"
        sample_root = self.dataset / "meetings" / "abcdef123456"
        sample_root.mkdir(parents=True)
        self.teacher.mkdir()
        (sample_root / "current.txt").write_text("transcrição atual", encoding="utf-8")
        (sample_root / "audio.m4a").write_bytes(b"audio")
        (self.teacher / "abcdef123456.json").write_text(
            json.dumps({"draft_transcript": " ".join(["palavra"] * 40)}),
            encoding="utf-8",
        )
        queue = {
            "entries": [
                {
                    "sampleId": "abcdef123456",
                    "rank": 1,
                    "durationBucket": "short_5_to_20_min",
                    "consentStatus": "pending_documentation",
                    "asrReviewStatus": "pending_human_correction",
                    "split": "pending_participant_grouping",
                    "teacherTranscriptFile": "asr-large-v3/abcdef123456.json",
                    "currentTranscriptFile": "meetings/abcdef123456/current.txt",
                    "audioFiles": ["meetings/abcdef123456/audio.m4a"],
                    "signals": {
                        "priorityBand": "high",
                        "priorityScore": 0.8,
                        "audioSeconds": 300,
                    },
                }
            ]
        }
        self.queue_path = self.root / "queue.json"
        self.queue_path.write_text(json.dumps(queue), encoding="utf-8")
        self.store = MODULE.AnnotationStore(
            self.queue_path,
            self.dataset,
            self.teacher,
            self.annotations,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_safe_path_rejects_escape(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.safe_path(self.dataset, "../outside")

    def test_approval_requires_full_checklist(self) -> None:
        with self.assertRaisesRegex(ValueError, "All ASR review checks"):
            self.store.save_review(
                "abcdef123456",
                {
                    "decision": "approve",
                    "reviewer": "QA",
                    "correctedTranscript": " ".join(["palavra"] * 40),
                    "reviewChecklist": {},
                },
            )

    def test_approved_review_is_private_and_counted(self) -> None:
        payload = {
            "decision": "approve",
            "reviewer": "QA",
            "consentStatus": "approved_for_private_training",
            "correctedTranscript": " ".join(["palavra"] * 40),
            "reviewChecklist": {key: True for key in MODULE.CHECKLIST_KEYS},
            "reviewNotes": "Conferido com áudio",
        }
        annotation = self.store.save_review("abcdef123456", payload)

        self.assertEqual(annotation["asrReviewStatus"], "approved")
        self.assertEqual(self.store.queue_payload()["trainingReady"], 1)
        annotation_path = self.annotations / "abcdef123456" / "annotation.json"
        corrected_path = self.annotations / "abcdef123456" / "corrected.transcript.txt"
        self.assertEqual(os.stat(annotation_path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(corrected_path).st_mode & 0o777, 0o600)
        self.assertNotIn("correctedTranscript", annotation)


if __name__ == "__main__":
    unittest.main()
