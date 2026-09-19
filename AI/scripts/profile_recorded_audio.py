#!/usr/bin/env python3
"""Build a privacy-preserving inventory of QAP.ia recordings.

The script reads local application data but never writes transcript, summary,
title or participant content to its report. A private ID-to-path mapping is
written under AI/data, which is excluded from Git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


UUID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
DURATION_PATTERN = re.compile(r"estimated duration:\s*([0-9.]+) sec")
TRACK_PATTERN = re.compile(r"^Track ID:", re.MULTILINE)


def parse_args() -> argparse.Namespace:
    home = Path.home()
    default_root = home / "Library/Application Support/Qapia"
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--meetings-root",
        type=Path,
        default=default_root / "Meetings",
    )
    parser.add_argument(
        "--store",
        type=Path,
        default=default_root / "Persistence/QAPia.store",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("AI/runs/recorded-audio-inventory"),
    )
    parser.add_argument(
        "--private-map",
        type=Path,
        default=Path("AI/data/recorded-audio-private-map.json"),
    )
    parser.add_argument("--hash-audio", action="store_true")
    parser.add_argument("--sample-size", type=int, default=18)
    return parser.parse_args()


def uuid_from_blob(value: bytes) -> str:
    raw = value.hex().upper()
    if len(raw) != 32:
        raise ValueError("Unexpected UUID blob length")
    return f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"


def sample_id(meeting_uuid: str) -> str:
    return hashlib.sha256(meeting_uuid.encode("utf-8")).hexdigest()[:12]


def normalize_text(value: str | None) -> str:
    if not value:
        return ""
    return "\n".join(line.rstrip() for line in value.replace("\r\n", "\n").splitlines()).strip()


def word_count(value: str) -> int:
    return len(re.findall(r"\b\w+\b", value, flags=re.UNICODE))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_audio(path: Path, hash_audio: bool) -> dict[str, Any]:
    result: dict[str, Any] = {
        "exists": path.is_file(),
        "extension": path.suffix.lower(),
        "bytes": path.stat().st_size if path.is_file() else 0,
        "decodable": False,
        "duration_seconds": 0.0,
        "tracks": 0,
        "sha256": None,
    }
    if not path.is_file():
        return result

    try:
        completed = subprocess.run(
            ["afinfo", str(path)],
            capture_output=True,
            check=False,
            text=True,
            timeout=90,
        )
    except (OSError, subprocess.TimeoutExpired):
        return result

    durations = [float(value) for value in DURATION_PATTERN.findall(completed.stdout)]
    result["decodable"] = completed.returncode == 0 and bool(durations)
    result["duration_seconds"] = max(durations, default=0.0)
    result["tracks"] = len(TRACK_PATTERN.findall(completed.stdout))
    if hash_audio and result["decodable"]:
        result["sha256"] = sha256_file(path)
    return result


def load_database(store: Path) -> tuple[list[sqlite3.Row], dict[int, list[sqlite3.Row]]]:
    uri = f"file:{store}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    meetings = connection.execute(
        """
        SELECT
            Z_PK AS meeting_pk,
            ZID AS meeting_id,
            ZSTATERAWVALUE AS state,
            ZRECORDEDDURATION AS recorded_duration,
            ZTRANSCRIPT AS transcript,
            ZSUMMARY AS summary
        FROM ZSTOREDMEETING
        ORDER BY Z_PK
        """
    ).fetchall()
    segments = connection.execute(
        """
        SELECT
            Z1RECORDINGSEGMENTS AS meeting_pk,
            ZSEQUENCE AS sequence,
            ZFILEPATH AS file_path,
            ZRECORDEDDURATION AS recorded_duration
        FROM ZSTOREDRECORDINGSEGMENT
        ORDER BY Z1RECORDINGSEGMENTS, ZSEQUENCE
        """
    ).fetchall()
    connection.close()

    segments_by_meeting: dict[int, list[sqlite3.Row]] = defaultdict(list)
    for segment in segments:
        segments_by_meeting[int(segment["meeting_pk"])].append(segment)
    return meetings, segments_by_meeting


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def duration_bucket(seconds: float) -> str:
    if seconds < 20 * 60:
        return "short_5_to_20_min"
    if seconds < 45 * 60:
        return "medium_20_to_45_min"
    return "long_45_plus_min"


def select_balanced_sample(
    candidates: list[dict[str, Any]], sample_size: int
) -> list[dict[str, Any]]:
    quotas = {
        "short_5_to_20_min": 5,
        "medium_20_to_45_min": 8,
        "long_45_plus_min": 5,
    }
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for candidate in sorted(candidates, key=lambda item: item["sample_id"]):
        groups[candidate["duration_bucket"]].append(candidate)

    selected: list[dict[str, Any]] = []
    selected_ids: set[str] = set()
    for bucket, quota in quotas.items():
        for candidate in groups[bucket][:quota]:
            selected.append(candidate)
            selected_ids.add(candidate["sample_id"])

    if len(selected) < sample_size:
        remainder = [
            candidate
            for candidate in sorted(candidates, key=lambda item: item["sample_id"])
            if candidate["sample_id"] not in selected_ids
        ]
        selected.extend(remainder[: sample_size - len(selected)])
    return selected[:sample_size]


def main() -> int:
    args = parse_args()
    meetings_root = args.meetings_root.expanduser().resolve()
    store = args.store.expanduser().resolve()
    output_root = args.output_root.resolve()
    private_map_path = args.private_map.resolve()

    if not meetings_root.is_dir():
        raise SystemExit(f"Meetings root not found: {meetings_root}")
    if not store.is_file():
        raise SystemExit(f"SwiftData store not found: {store}")

    meetings, segments_by_meeting = load_database(store)
    db_uuids = {uuid_from_blob(row["meeting_id"]) for row in meetings}
    filesystem_dirs = {
        path.name.upper(): path
        for path in meetings_root.iterdir()
        if path.is_dir() and UUID_PATTERN.match(path.name)
    }

    orphan_dirs = [path for key, path in filesystem_dirs.items() if key not in db_uuids]
    orphan_summary = {
        "directories": len(orphan_dirs),
        "with_audio": sum(1 for path in orphan_dirs if any((path / "audio").glob("*"))),
        "with_transcript": sum(1 for path in orphan_dirs if (path / "transcript.txt").is_file()),
        "with_summary": sum(1 for path in orphan_dirs if (path / "summary.md").is_file()),
    }

    profiles: list[dict[str, Any]] = []
    private_records: dict[str, dict[str, Any]] = {}
    audio_hash_owners: dict[str, set[str]] = defaultdict(set)

    for meeting in meetings:
        meeting_uuid = uuid_from_blob(meeting["meeting_id"])
        identifier = sample_id(meeting_uuid)
        meeting_dir = meetings_root / meeting_uuid
        transcript_path = meeting_dir / "transcript.txt"
        summary_path = meeting_dir / "summary.md"

        file_transcript = (
            transcript_path.read_text(encoding="utf-8", errors="replace")
            if transcript_path.is_file()
            else ""
        )
        file_summary = (
            summary_path.read_text(encoding="utf-8", errors="replace")
            if summary_path.is_file()
            else ""
        )
        normalized_file_transcript = normalize_text(file_transcript)
        normalized_file_summary = normalize_text(file_summary)
        normalized_db_transcript = normalize_text(meeting["transcript"])
        normalized_db_summary = normalize_text(meeting["summary"])

        audio_records: list[dict[str, Any]] = []
        private_audio_paths: list[str] = []
        unsafe_paths = 0
        for segment in segments_by_meeting.get(int(meeting["meeting_pk"]), []):
            raw_path = segment["file_path"]
            if not raw_path:
                continue
            audio_path = Path(raw_path).expanduser()
            if not is_within(audio_path, meetings_root):
                unsafe_paths += 1
                continue
            audio_profile = inspect_audio(audio_path, args.hash_audio)
            audio_profile["sequence"] = int(segment["sequence"] or 0)
            audio_profile["recorded_duration"] = float(segment["recorded_duration"] or 0)
            audio_records.append(audio_profile)
            private_audio_paths.append(str(audio_path))
            if audio_profile["sha256"]:
                audio_hash_owners[audio_profile["sha256"]].add(identifier)

        actual_duration = sum(record["duration_seconds"] for record in audio_records)
        recorded_duration = float(meeting["recorded_duration"] or 0)
        duration_difference = abs(actual_duration - recorded_duration)
        duration_tolerance = max(10.0, recorded_duration * 0.05)
        transcript_words = word_count(normalized_file_transcript)
        summary_words = word_count(normalized_file_summary)
        words_per_minute = (
            transcript_words / (actual_duration / 60.0) if actual_duration > 0 else 0.0
        )

        eligibility_failures: list[str] = []
        if meeting["state"] != "completed":
            eligibility_failures.append("meeting_not_completed")
        if not audio_records:
            eligibility_failures.append("no_referenced_audio")
        if audio_records and not all(record["exists"] for record in audio_records):
            eligibility_failures.append("missing_referenced_audio")
        if audio_records and not all(record["decodable"] for record in audio_records):
            eligibility_failures.append("undecodable_audio")
        if audio_records and not all(record["extension"] == ".m4a" for record in audio_records):
            eligibility_failures.append("non_final_audio_format")
        if actual_duration < 5 * 60:
            eligibility_failures.append("audio_shorter_than_5_minutes")
        if duration_difference > duration_tolerance:
            eligibility_failures.append("duration_mismatch")
        if transcript_words < 250:
            eligibility_failures.append("transcript_too_short")
        if summary_words < 50:
            eligibility_failures.append("summary_too_short")
        if normalized_file_transcript != normalized_db_transcript:
            eligibility_failures.append("transcript_file_database_mismatch")
        if normalized_file_summary != normalized_db_summary:
            eligibility_failures.append("summary_file_database_mismatch")
        if not 20 <= words_per_minute <= 250:
            eligibility_failures.append("implausible_transcript_density")
        if unsafe_paths:
            eligibility_failures.append("audio_path_outside_meetings_root")

        profile = {
            "sample_id": identifier,
            "state": meeting["state"],
            "recorded_duration_seconds": round(recorded_duration, 3),
            "audio_duration_seconds": round(actual_duration, 3),
            "duration_difference_seconds": round(duration_difference, 3),
            "duration_bucket": duration_bucket(actual_duration),
            "referenced_audio_files": len(audio_records),
            "decodable_audio_files": sum(
                1 for record in audio_records if record["decodable"]
            ),
            "audio_bytes": sum(record["bytes"] for record in audio_records),
            "audio_track_counts": [record["tracks"] for record in audio_records],
            "transcript_words": transcript_words,
            "summary_words": summary_words,
            "transcript_words_per_minute": round(words_per_minute, 2),
            "transcript_matches_database": normalized_file_transcript
            == normalized_db_transcript,
            "summary_matches_database": normalized_file_summary == normalized_db_summary,
            "eligible_for_annotation": not eligibility_failures,
            "eligibility_failures": eligibility_failures,
        }
        profiles.append(profile)
        private_records[identifier] = {
            "meeting_uuid": meeting_uuid,
            "audio_paths": private_audio_paths,
            "transcript_path": str(transcript_path),
            "summary_path": str(summary_path),
        }

    duplicate_sample_ids: set[str] = set()
    duplicate_groups = 0
    for owners in audio_hash_owners.values():
        if len(owners) > 1:
            duplicate_groups += 1
            duplicate_sample_ids.update(owners)

    for profile in profiles:
        if profile["sample_id"] in duplicate_sample_ids:
            profile["eligible_for_annotation"] = False
            profile["eligibility_failures"].append("duplicate_audio_content")

    eligible = [profile for profile in profiles if profile["eligible_for_annotation"]]
    selected = select_balanced_sample(eligible, args.sample_size)
    selected_ids = {profile["sample_id"] for profile in selected}

    failure_counts = Counter(
        failure
        for profile in profiles
        for failure in profile["eligibility_failures"]
    )
    state_counts = Counter(profile["state"] for profile in profiles)
    selected_bucket_counts = Counter(profile["duration_bucket"] for profile in selected)
    selected_audio_seconds = sum(profile["audio_duration_seconds"] for profile in selected)

    summary = {
        "schema_version": 1,
        "grain": "one active SwiftData meeting",
        "privacy": {
            "titles_read": False,
            "participants_read": False,
            "text_content_written_to_reports": False,
            "raw_audio_copied": False,
        },
        "inventory": {
            "database_meetings": len(meetings),
            "database_states": dict(sorted(state_counts.items())),
            "filesystem_meeting_directories": len(filesystem_dirs),
            "database_meetings_missing_directory": sum(
                1 for meeting_uuid in db_uuids if meeting_uuid not in filesystem_dirs
            ),
            "orphan_filesystem": orphan_summary,
            "referenced_audio_files": sum(
                profile["referenced_audio_files"] for profile in profiles
            ),
            "decodable_referenced_audio_files": sum(
                profile["decodable_audio_files"] for profile in profiles
            ),
            "referenced_audio_hours": round(
                sum(profile["audio_duration_seconds"] for profile in profiles) / 3600.0,
                2,
            ),
            "duplicate_audio_groups": duplicate_groups,
        },
        "quality": {
            "eligible_for_annotation": len(eligible),
            "ineligible": len(profiles) - len(eligible),
            "failure_counts": dict(failure_counts.most_common()),
        },
        "sample": {
            "requested_meetings": args.sample_size,
            "selected_meetings": len(selected),
            "selected_audio_hours": round(selected_audio_seconds / 3600.0, 2),
            "duration_buckets": dict(sorted(selected_bucket_counts.items())),
            "status": "annotation_pool_not_training_ready",
            "split": "pending_participant_and_organization_grouping",
        },
    }

    public_profiles = [
        {**profile, "selected_for_annotation": profile["sample_id"] in selected_ids}
        for profile in profiles
    ]
    private_selection = {
        "schema_version": 1,
        "classification": "private-sensitive-training-source-map",
        "meetings": [
            {
                "sample_id": profile["sample_id"],
                "duration_bucket": profile["duration_bucket"],
                "suggested_split": "pending_participant_and_organization_grouping",
                **private_records[profile["sample_id"]],
            }
            for profile in selected
        ],
    }

    output_root.mkdir(parents=True, exist_ok=True)
    private_map_path.parent.mkdir(parents=True, exist_ok=True)
    (output_root / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output_root / "meeting-profiles.json").write_text(
        json.dumps(public_profiles, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    private_map_path.write_text(
        json.dumps(private_selection, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(private_map_path, 0o600)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
