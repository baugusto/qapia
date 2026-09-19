#!/usr/bin/env python3
"""Create a private, content-free human-review queue for teacher transcripts."""

from __future__ import annotations

import argparse
import json
import math
import os
from collections import Counter
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from audit_teacher_transcripts import transcript_degeneracy_signals, tokens


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teacher-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def priority_metrics(
    current_transcript: str,
    teacher_result: dict[str, Any],
) -> dict[str, Any]:
    current_tokens = tokens(current_transcript)
    teacher_tokens = tokens(str(teacher_result.get("draft_transcript", "")))
    similarity = (
        SequenceMatcher(None, current_tokens, teacher_tokens, autojunk=False).ratio()
        if current_tokens or teacher_tokens
        else 1.0
    )
    word_ratio = len(teacher_tokens) / len(current_tokens) if current_tokens else None

    probabilities = [
        float(word["probability"])
        for source in teacher_result.get("sources", [])
        for segment in source.get("segments", [])
        for word in segment.get("words", [])
        if isinstance(word.get("probability"), (int, float))
    ]
    low_confidence_count = sum(value < 0.5 for value in probabilities)
    low_confidence_fraction = (
        low_confidence_count / len(probabilities) if probabilities else 1.0
    )
    duration_seconds = sum(
        float(source.get("metadata", {}).get("duration_seconds", 0.0))
        for source in teacher_result.get("sources", [])
    )
    segment_texts = [
        str(segment.get("text", ""))
        for source in teacher_result.get("sources", [])
        for segment in source.get("segments", [])
    ]
    degeneracy = transcript_degeneracy_signals(
        str(teacher_result.get("draft_transcript", "")),
        segment_texts,
    )

    if word_ratio is None or word_ratio <= 0:
        ratio_penalty = 1.0
    else:
        ratio_penalty = min(abs(math.log2(word_ratio)) / 2.0, 1.0)
    confidence_penalty = min(low_confidence_fraction / 0.15, 1.0)
    priority_score = (
        0.55 * (1.0 - similarity)
        + 0.25 * ratio_penalty
        + 0.20 * confidence_penalty
    )

    flags: list[str] = []
    if not teacher_tokens:
        flags.append("empty_teacher_transcript")
    if degeneracy["pathological"]:
        flags.append("teacher_repetition_pathology")
    if word_ratio is None or word_ratio < 0.5 or word_ratio > 1.5:
        flags.append("extreme_length_divergence")
    if similarity < 0.2:
        flags.append("very_low_sequence_similarity")
    elif similarity < 0.4:
        flags.append("low_sequence_similarity")
    if low_confidence_fraction >= 0.10:
        flags.append("high_low_confidence_share")
    elif low_confidence_fraction >= 0.06:
        flags.append("elevated_low_confidence_share")

    if (
        "empty_teacher_transcript" in flags
        or "teacher_repetition_pathology" in flags
        or word_ratio is None
        or word_ratio < 0.35
        or similarity < 0.10
    ):
        priority_band = "urgent"
    elif priority_score >= 0.60 or word_ratio < 0.60 or similarity < 0.25:
        priority_band = "high"
    elif priority_score >= 0.40 or low_confidence_fraction >= 0.06:
        priority_band = "medium"
    else:
        priority_band = "normal"

    return {
        "priorityScore": round(priority_score, 6),
        "priorityBand": priority_band,
        "flags": flags,
        "audioSeconds": round(duration_seconds, 3),
        "currentWordCount": len(current_tokens),
        "teacherWordCount": len(teacher_tokens),
        "teacherToCurrentWordRatio": (
            round(word_ratio, 6) if word_ratio is not None else None
        ),
        "sequenceSimilarity": round(similarity, 6),
        "timestampedWordCount": len(probabilities),
        "lowConfidenceWordCount": low_confidence_count,
        "lowConfidenceWordFraction": round(low_confidence_fraction, 6),
        "teacherDegeneracy": degeneracy,
    }


def build_queue(dataset_root: Path, teacher_root: Path) -> dict[str, Any]:
    dataset_root = dataset_root.resolve()
    teacher_root = teacher_root.resolve()
    manifest = json.loads((dataset_root / "manifest.json").read_text(encoding="utf-8"))
    entries: list[dict[str, Any]] = []

    for meeting in manifest["meetings"]:
        sample_id = meeting["sample_id"]
        teacher_path = teacher_root / f"{sample_id}.json"
        if not teacher_path.is_file():
            raise ValueError(f"Missing teacher output for {sample_id}")
        teacher_result = json.loads(teacher_path.read_text(encoding="utf-8"))
        transcript_records = [
            record
            for record in meeting["files"]
            if record["kind"] == "source_transcript"
        ]
        if len(transcript_records) != 1:
            raise ValueError(f"Expected one current transcript for {sample_id}")
        transcript_record = transcript_records[0]
        current_transcript = (dataset_root / transcript_record["file"]).read_text(
            encoding="utf-8"
        )
        metrics = priority_metrics(current_transcript, teacher_result)
        audio_files = [
            record["file"] for record in meeting["files"] if record["kind"] == "audio"
        ]
        entries.append(
            {
                "sampleId": sample_id,
                "durationBucket": meeting["duration_bucket"],
                "consentStatus": meeting["consent_status"],
                "asrReviewStatus": "pending_human_correction",
                "split": meeting["split"],
                "teacherTranscriptFile": str(
                    Path("teacher") / teacher_path.relative_to(teacher_root.parent)
                ),
                "currentTranscriptFile": transcript_record["file"],
                "audioFiles": audio_files,
                "annotationFile": f"annotations/{sample_id}/annotation.json",
                "signals": metrics,
            }
        )

    entries.sort(
        key=lambda entry: (
            -float(entry["signals"]["priorityScore"]),
            entry["sampleId"],
        )
    )
    for rank, entry in enumerate(entries, start=1):
        entry["rank"] = rank

    return {
        "schemaVersion": 1,
        "classification": "private-sensitive-restricted",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "purpose": "human_asr_correction",
        "trainingReadiness": "blocked_pending_human_correction_and_consent",
        "scoring": {
            "sequenceDivergenceWeight": 0.55,
            "lengthDivergenceWeight": 0.25,
            "lowConfidenceWeight": 0.20,
            "lowConfidenceThreshold": 0.5,
            "warning": (
                "Priority estimates review risk only; neither automatic transcript "
                "is human ground truth."
            ),
        },
        "entries": entries,
    }


def aggregate_receipt(queue: dict[str, Any]) -> dict[str, Any]:
    bands = Counter(entry["signals"]["priorityBand"] for entry in queue["entries"])
    flags = Counter(
        flag for entry in queue["entries"] for flag in entry["signals"]["flags"]
    )
    return {
        "meetings": len(queue["entries"]),
        "priorityBands": dict(sorted(bands.items())),
        "reviewFlags": dict(sorted(flags.items())),
        "trainingReadiness": queue["trainingReadiness"],
    }


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(temporary_path, 0o600)
    temporary_path.replace(path)


def main() -> int:
    args = parse_args()
    queue = build_queue(args.dataset_root, args.teacher_root)
    write_private_json(args.output.resolve(), queue)
    print(json.dumps(aggregate_receipt(queue), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
