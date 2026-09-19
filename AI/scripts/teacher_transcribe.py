#!/usr/bin/env python3
"""Create timestamped teacher transcripts for the private annotation pool."""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any

from faster_whisper import WhisperModel


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--model", default="large-v3")
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--compute-type", default="float16")
    parser.add_argument("--language", default="pt")
    return parser.parse_args()


def transcribe_file(
    model: WhisperModel,
    audio_path: Path,
    language: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    segments, info = model.transcribe(
        str(audio_path),
        language=language,
        beam_size=5,
        best_of=5,
        temperature=0.0,
        condition_on_previous_text=True,
        vad_filter=False,
        word_timestamps=True,
    )
    output_segments: list[dict[str, Any]] = []
    for segment in segments:
        output_segments.append(
            {
                "start_ms": round(segment.start * 1000),
                "end_ms": round(segment.end * 1000),
                "text": segment.text.strip(),
                "avg_logprob": round(segment.avg_logprob, 6),
                "no_speech_prob": round(segment.no_speech_prob, 6),
                "words": [
                    {
                        "start_ms": round(word.start * 1000) if word.start is not None else None,
                        "end_ms": round(word.end * 1000) if word.end is not None else None,
                        "text": word.word,
                        "probability": round(word.probability, 6),
                    }
                    for word in (segment.words or [])
                ],
            }
        )
    metadata = {
        "detected_language": info.language,
        "language_probability": round(info.language_probability, 6),
        "duration_seconds": round(info.duration, 3),
        "duration_after_vad_seconds": round(info.duration_after_vad, 3),
    }
    return output_segments, metadata


def main() -> int:
    args = parse_args()
    dataset_root = args.dataset_root.resolve()
    output_root = args.output_root.resolve()
    manifest_path = dataset_root / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"Manifest not found: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    output_root.mkdir(parents=True, exist_ok=True)
    os.chmod(output_root, 0o700)

    model = WhisperModel(
        args.model,
        device=args.device,
        compute_type=args.compute_type,
    )
    completed = 0
    skipped = 0
    started_at = time.monotonic()

    for meeting in manifest["meetings"]:
        identifier = meeting["sample_id"]
        output_path = output_root / f"{identifier}.json"
        if output_path.is_file():
            skipped += 1
            continue

        audio_files = [
            file_record
            for file_record in meeting["files"]
            if file_record["kind"] == "audio"
        ]
        sources: list[dict[str, Any]] = []
        draft_parts: list[str] = []
        for file_record in audio_files:
            audio_path = dataset_root / file_record["file"]
            segments, audio_metadata = transcribe_file(model, audio_path, args.language)
            sources.append(
                {
                    "file": file_record["file"],
                    "sha256": file_record["sha256"],
                    "metadata": audio_metadata,
                    "segments": segments,
                }
            )
            draft_parts.append(" ".join(segment["text"] for segment in segments))

        result = {
            "schema_version": 1,
            "sample_id": identifier,
            "classification": "private-sensitive-restricted",
            "teacher": {
                "model": args.model,
                "device": args.device,
                "compute_type": args.compute_type,
                "language": args.language,
                "beam_size": 5,
                "best_of": 5,
                "temperature": 0.0,
                "vad_filter": False,
                "word_timestamps": True,
            },
            "review_status": "pending_human_correction",
            "sources": sources,
            "draft_transcript": "\n\n".join(draft_parts),
        }
        temporary_path = output_path.with_suffix(".json.tmp")
        temporary_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary_path, 0o600)
        temporary_path.replace(output_path)
        completed += 1
        print(f"completed {identifier}", flush=True)

    elapsed_seconds = time.monotonic() - started_at
    print(
        json.dumps(
            {
                "completed": completed,
                "skipped": skipped,
                "elapsed_seconds": round(elapsed_seconds, 2),
                "review_status": "pending_human_correction",
            }
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
