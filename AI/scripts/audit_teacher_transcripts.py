#!/usr/bin/env python3
"""Audit private teacher transcripts without emitting meeting content."""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Iterable


WORD_PATTERN = re.compile(r"\b\w+\b", flags=re.UNICODE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teacher-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def tokens(value: str) -> list[str]:
    return WORD_PATTERN.findall(value.casefold())


def rounded_summary(values: Iterable[float]) -> dict[str, float | None]:
    materialized = list(values)
    if not materialized:
        return {"min": None, "mean": None, "median": None, "max": None}
    return {
        "min": round(min(materialized), 6),
        "mean": round(statistics.fmean(materialized), 6),
        "median": round(statistics.median(materialized), 6),
        "max": round(max(materialized), 6),
    }


def audit(dataset_root: Path, teacher_root: Path) -> dict[str, Any]:
    dataset_root = dataset_root.resolve()
    teacher_root = teacher_root.resolve()
    manifest = json.loads((dataset_root / "manifest.json").read_text(encoding="utf-8"))

    expected = {meeting["sample_id"]: meeting for meeting in manifest["meetings"]}
    output_paths = sorted(teacher_root.glob("*.json"))
    temporary_files = list(teacher_root.glob("*.tmp"))

    structural_errors: Counter[str] = Counter()
    review_statuses: Counter[str] = Counter()
    classifications: Counter[str] = Counter()
    teacher_models: Counter[str] = Counter()
    detected_languages: Counter[str] = Counter()
    output_modes: Counter[str] = Counter()
    duration_buckets: Counter[str] = Counter()

    language_probabilities: list[float] = []
    word_probabilities: list[float] = []
    segment_logprobabilities: list[float] = []
    transcript_word_ratios: list[float] = []
    transcript_sequence_similarities: list[float] = []

    seen_ids: set[str] = set()
    source_audio_count = 0
    teacher_audio_count = 0
    total_audio_seconds = 0.0
    segment_count = 0
    word_count = 0
    low_confidence_word_count = 0
    empty_draft_count = 0
    timestamp_violation_count = 0

    for output_path in output_paths:
        output_modes[oct(output_path.stat().st_mode & 0o777)] += 1
        result = json.loads(output_path.read_text(encoding="utf-8"))
        sample_id = result.get("sample_id")
        if sample_id not in expected:
            structural_errors["unexpected_sample"] += 1
            continue
        if sample_id in seen_ids:
            structural_errors["duplicate_sample"] += 1
            continue
        seen_ids.add(sample_id)

        meeting = expected[sample_id]
        duration_buckets[meeting["duration_bucket"]] += 1
        review_statuses[str(result.get("review_status"))] += 1
        classifications[str(result.get("classification"))] += 1
        teacher = result.get("teacher", {})
        teacher_models[str(teacher.get("model"))] += 1

        audio_records = {
            record["file"]: record
            for record in meeting["files"]
            if record["kind"] == "audio"
        }
        source_audio_count += len(audio_records)
        sources = result.get("sources", [])
        teacher_audio_count += len(sources)
        if {source.get("file") for source in sources} != set(audio_records):
            structural_errors["audio_source_set_mismatch"] += 1

        for source in sources:
            source_file = source.get("file")
            record = audio_records.get(source_file)
            if record is None or source.get("sha256") != record.get("sha256"):
                structural_errors["audio_sha256_mismatch"] += 1

            metadata = source.get("metadata", {})
            language = str(metadata.get("detected_language"))
            detected_languages[language] += 1
            language_probability = metadata.get("language_probability")
            if isinstance(language_probability, (int, float)):
                language_probabilities.append(float(language_probability))
            duration = metadata.get("duration_seconds")
            if isinstance(duration, (int, float)):
                total_audio_seconds += float(duration)

            previous_segment_end = -1
            for segment in source.get("segments", []):
                segment_count += 1
                start = segment.get("start_ms")
                end = segment.get("end_ms")
                if (
                    not isinstance(start, int)
                    or not isinstance(end, int)
                    or start < 0
                    or end < start
                    or start < previous_segment_end
                ):
                    timestamp_violation_count += 1
                if isinstance(end, int):
                    previous_segment_end = end
                logprob = segment.get("avg_logprob")
                if isinstance(logprob, (int, float)):
                    segment_logprobabilities.append(float(logprob))

                previous_word_end = -1
                for word in segment.get("words", []):
                    word_count += 1
                    probability = word.get("probability")
                    if isinstance(probability, (int, float)):
                        numeric_probability = float(probability)
                        word_probabilities.append(numeric_probability)
                        if numeric_probability < 0.5:
                            low_confidence_word_count += 1
                    word_start = word.get("start_ms")
                    word_end = word.get("end_ms")
                    if word_start is None or word_end is None:
                        continue
                    if (
                        not isinstance(word_start, int)
                        or not isinstance(word_end, int)
                        or word_start < 0
                        or word_end < word_start
                        or word_start < previous_word_end
                    ):
                        timestamp_violation_count += 1
                    if isinstance(word_end, int):
                        previous_word_end = word_end

        draft = result.get("draft_transcript", "")
        teacher_tokens = tokens(draft) if isinstance(draft, str) else []
        if not teacher_tokens:
            empty_draft_count += 1

        transcript_records = [
            record for record in meeting["files"] if record["kind"] == "source_transcript"
        ]
        if len(transcript_records) != 1:
            structural_errors["source_transcript_count"] += 1
            continue
        source_text = (dataset_root / transcript_records[0]["file"]).read_text(
            encoding="utf-8"
        )
        source_tokens = tokens(source_text)
        if source_tokens:
            transcript_word_ratios.append(len(teacher_tokens) / len(source_tokens))
            transcript_sequence_similarities.append(
                SequenceMatcher(None, source_tokens, teacher_tokens, autojunk=False).ratio()
            )
        else:
            structural_errors["empty_source_transcript"] += 1

    missing_outputs = set(expected) - seen_ids
    extra_outputs = len(output_paths) - len(seen_ids)
    if missing_outputs:
        structural_errors["missing_output"] += len(missing_outputs)
    if extra_outputs:
        structural_errors["unusable_output"] += extra_outputs
    if temporary_files:
        structural_errors["temporary_file"] += len(temporary_files)
    if timestamp_violation_count:
        structural_errors["timestamp_violation"] += timestamp_violation_count

    low_confidence_fraction = (
        low_confidence_word_count / len(word_probabilities) if word_probabilities else None
    )
    report = {
        "schema_version": 1,
        "classification": "aggregate-non-content-audit",
        "training_readiness": "pending_human_correction",
        "integrity": {
            "valid": not structural_errors,
            "expected_meetings": len(expected),
            "teacher_outputs": len(output_paths),
            "missing_outputs": len(missing_outputs),
            "temporary_files": len(temporary_files),
            "source_audio_files": source_audio_count,
            "teacher_audio_sources": teacher_audio_count,
            "output_modes": dict(sorted(output_modes.items())),
            "structural_errors": dict(sorted(structural_errors.items())),
        },
        "coverage": {
            "duration_buckets": dict(sorted(duration_buckets.items())),
            "audio_hours": round(total_audio_seconds / 3600, 6),
            "segments": segment_count,
            "timestamped_words": word_count,
            "empty_drafts": empty_draft_count,
        },
        "configuration": {
            "teacher_models": dict(sorted(teacher_models.items())),
            "review_statuses": dict(sorted(review_statuses.items())),
            "classifications": dict(sorted(classifications.items())),
            "detected_languages": dict(sorted(detected_languages.items())),
        },
        "signals_for_human_review": {
            "language_probability": rounded_summary(language_probabilities),
            "word_probability": rounded_summary(word_probabilities),
            "segment_avg_logprob": rounded_summary(segment_logprobabilities),
            "low_confidence_word_threshold": 0.5,
            "low_confidence_word_count": low_confidence_word_count,
            "low_confidence_word_fraction": (
                round(low_confidence_fraction, 6)
                if low_confidence_fraction is not None
                else None
            ),
            "teacher_to_current_word_ratio": rounded_summary(transcript_word_ratios),
            "teacher_current_sequence_similarity": rounded_summary(
                transcript_sequence_similarities
            ),
            "comparison_warning": (
                "Current app transcripts are noisy references, not ground truth; "
                "differences only prioritize human review."
            ),
        },
    }
    return report


def main() -> int:
    args = parse_args()
    report = audit(args.dataset_root, args.teacher_root)
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized, encoding="utf-8")
        os.chmod(args.output, 0o600)
    print(serialized, end="")
    return 0 if report["integrity"]["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
