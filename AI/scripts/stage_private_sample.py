#!/usr/bin/env python3
"""Stage the selected private QAP.ia sample under anonymized identifiers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--private-map",
        type=Path,
        default=Path("AI/data/recorded-audio-private-map.json"),
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=Path("AI/data/qapia-private-meetings-v0"),
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def secure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def copy_on_write_or_copy(source: Path, destination: Path) -> None:
    if destination.exists():
        if destination.is_file() and sha256_file(source) == sha256_file(destination):
            os.chmod(destination, 0o600)
            return
        raise FileExistsError(f"Refusing to overwrite a different file: {destination}")

    try:
        subprocess.run(
            ["cp", "-c", str(source), str(destination)],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        shutil.copy2(source, destination)
    os.chmod(destination, 0o600)


def staged_file_record(path: Path, root: Path, kind: str) -> dict[str, Any]:
    return {
        "kind": kind,
        "file": str(path.relative_to(root)),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def main() -> int:
    args = parse_args()
    private_map_path = args.private_map.resolve()
    destination = args.destination.resolve()
    if not private_map_path.is_file():
        raise SystemExit(f"Private map not found: {private_map_path}")

    mapping = json.loads(private_map_path.read_text(encoding="utf-8"))
    secure_directory(destination)
    meetings_root = destination / "meetings"
    secure_directory(meetings_root)

    manifest_meetings: list[dict[str, Any]] = []
    total_audio_bytes = 0
    for meeting in mapping["meetings"]:
        identifier = meeting["sample_id"]
        meeting_destination = meetings_root / identifier
        secure_directory(meeting_destination)

        files: list[dict[str, Any]] = []
        for index, audio_path_value in enumerate(meeting["audio_paths"], start=1):
            source = Path(audio_path_value)
            if not source.is_file():
                raise FileNotFoundError(source)
            audio_destination = meeting_destination / f"audio-{index:03d}{source.suffix.lower()}"
            copy_on_write_or_copy(source, audio_destination)
            record = staged_file_record(audio_destination, destination, "audio")
            files.append(record)
            total_audio_bytes += record["bytes"]

        for source_key, destination_name, kind in (
            ("transcript_path", "transcript.source.txt", "source_transcript"),
            ("summary_path", "summary.source.md", "source_summary"),
        ):
            source = Path(meeting[source_key])
            if not source.is_file():
                raise FileNotFoundError(source)
            file_destination = meeting_destination / destination_name
            copy_on_write_or_copy(source, file_destination)
            files.append(staged_file_record(file_destination, destination, kind))

        manifest_meetings.append(
            {
                "sample_id": identifier,
                "duration_bucket": meeting["duration_bucket"],
                "consent_status": "pending_documentation",
                "annotation_status": "pending_teacher_transcription",
                "split": "pending_participant_and_organization_grouping",
                "files": files,
            }
        )

    manifest = {
        "schema_version": 1,
        "dataset_id": "qapia-private-meetings-v0",
        "classification": "private-sensitive-restricted",
        "redistribution": "prohibited",
        "training_status": "blocked_until_consent_and_human_review",
        "meeting_count": len(manifest_meetings),
        "meetings": manifest_meetings,
    }
    manifest_path = destination / "manifest.json"
    if manifest_path.exists():
        current = json.loads(manifest_path.read_text(encoding="utf-8"))
        if current != manifest:
            raise FileExistsError("Refusing to replace a different private manifest")
    else:
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    os.chmod(manifest_path, 0o600)

    result = {
        "dataset_id": manifest["dataset_id"],
        "meeting_count": len(manifest_meetings),
        "audio_gib": round(total_audio_bytes / (1024**3), 3),
        "training_status": manifest["training_status"],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
