import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "profile_recorded_audio.py"
)
SPEC = importlib.util.spec_from_file_location("profile_recorded_audio", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ProfileRecordedAudioTests(unittest.TestCase):
    def test_uuid_blob_is_rendered_as_swift_uuid(self) -> None:
        raw = bytes.fromhex("00112233445566778899AABBCCDDEEFF")
        self.assertEqual(
            MODULE.uuid_from_blob(raw),
            "00112233-4455-6677-8899-AABBCCDDEEFF",
        )

    def test_normalize_text_preserves_words_and_normalizes_line_endings(self) -> None:
        self.assertEqual(MODULE.normalize_text("Ata  \r\nfinal\r\n"), "Ata\nfinal")

    def test_duration_buckets_match_sample_policy(self) -> None:
        self.assertEqual(MODULE.duration_bucket(300), "short_5_to_20_min")
        self.assertEqual(MODULE.duration_bucket(1200), "medium_20_to_45_min")
        self.assertEqual(MODULE.duration_bucket(2700), "long_45_plus_min")

    def test_hash_is_stable_without_exposing_identifier(self) -> None:
        identifier = "00112233-4455-6677-8899-AABBCCDDEEFF"
        self.assertEqual(MODULE.sample_id(identifier), MODULE.sample_id(identifier))
        self.assertNotIn(identifier, MODULE.sample_id(identifier))
        self.assertEqual(len(MODULE.sample_id(identifier)), 12)

    def test_sha256_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "audio.bin"
            path.write_bytes(b"qapia")
            self.assertEqual(
                MODULE.sha256_file(path),
                "9dd928fba4db9076f61ece0fd97785a0db92c55abd7d1a5f0073715744889300",
            )


if __name__ == "__main__":
    unittest.main()
