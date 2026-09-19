import importlib.util
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


class FakeModel:
    def __init__(self) -> None:
        self.options = None

    def transcribe(self, audio_path: str, **options):
        self.options = options
        word = SimpleNamespace(start=0.0, end=0.5, word=" teste", probability=0.99)
        segment = SimpleNamespace(
            start=0.0,
            end=0.5,
            text=" teste",
            avg_logprob=-0.1,
            no_speech_prob=0.01,
            words=[word],
        )
        info = SimpleNamespace(
            language="pt",
            language_probability=1.0,
            duration=1.0,
            duration_after_vad=0.5,
        )
        return iter([segment]), info


class TeacherTranscribeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            import faster_whisper  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("faster-whisper is not installed locally")
        module_path = (
            Path(__file__).resolve().parents[1] / "scripts" / "teacher_transcribe.py"
        )
        spec = importlib.util.spec_from_file_location("teacher_transcribe", module_path)
        cls.module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(cls.module)

    def test_silence_robust_options_are_forwarded(self) -> None:
        model = FakeModel()
        segments, metadata = self.module.transcribe_file(
            model,
            Path("fixture.m4a"),
            "pt",
            True,
            False,
            2.0,
        )
        self.assertEqual(len(segments), 1)
        self.assertEqual(metadata["detected_language"], "pt")
        self.assertTrue(model.options["vad_filter"])
        self.assertFalse(model.options["condition_on_previous_text"])
        self.assertEqual(model.options["hallucination_silence_threshold"], 2.0)
        self.assertEqual(model.options["temperature"][0], 0.0)
        self.assertGreater(len(model.options["temperature"]), 1)
