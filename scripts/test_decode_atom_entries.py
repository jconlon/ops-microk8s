"""Unit tests for decode_atom_entries.py's pure logic.

Uses synthetic Avro fixtures (not live bucket data) so these run offline,
with no cluster/network dependency.
"""
import datetime
import json
import subprocess
import sys
from pathlib import Path

import fastavro

import decode_atom_entries as dae

VALUE_SCHEMA = {
    "type": "record",
    "name": "value_r",
    "fields": [
        {"name": "id", "type": "string"},
        {"name": "title", "type": "string"},
        {"name": "updated", "type": {"type": "long", "logicalType": "timestamp-millis"}},
        {"name": "published", "type": ["null", {"type": "long", "logicalType": "timestamp-millis"}]},
        {"name": "author_name", "type": ["null", "string"]},
        {"name": "summary", "type": ["null", "string"]},
        {"name": "categories", "type": ["null", {"type": "array", "items": "string"}]},
        {"name": "source_feed_name", "type": ["null", "string"]},
        {"name": "vi_entry_id", "type": "long"},
        {"name": "vi_summary_bullets", "type": {"type": "array", "items": "string"}},
        {"name": "vi_summary_status", "type": "string"},
    ],
}
FILE_SCHEMA = {
    "type": "record",
    "name": "connector_records",
    "fields": [{"name": "value", "type": VALUE_SCHEMA}],
}


def make_value(**overrides):
    base = {
        "id": "https://example.com/a",
        "title": "Title",
        "updated": datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc),
        "published": datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc),
        "author_name": None,
        "summary": "a summary",
        "categories": ["#News"],
        "source_feed_name": "Feed",
        "vi_entry_id": 1,
        "vi_summary_bullets": ["point one"],
        "vi_summary_status": "processed",
    }
    base.update(overrides)
    return base


def write_avro_file(path: Path, values: list[dict]):
    with open(path, "wb") as f:
        fastavro.writer(f, FILE_SCHEMA, [{"value": v} for v in values])


def test_iter_records_reads_value_payload(tmp_path):
    f = tmp_path / "0-1"
    write_avro_file(f, [make_value(id="https://x/1", vi_entry_id=1)])

    records = list(dae.iter_records([f]))

    assert len(records) == 1
    assert records[0]["id"] == "https://x/1"


def test_dedupe_latest_keeps_most_recently_updated_record_per_entry_id():
    older = make_value(
        id="https://x/1", vi_entry_id=42,
        updated=datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc),
        summary="stale",
    )
    newer = make_value(
        id="https://x/1", vi_entry_id=42,
        updated=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc),
        summary="fresh",
    )

    deduped = dae.dedupe_latest([older, newer])

    assert deduped[42]["summary"] == "fresh"


def test_dedupe_latest_is_order_independent():
    older = make_value(vi_entry_id=1, updated=datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc))
    newer = make_value(vi_entry_id=1, updated=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc))

    assert dae.dedupe_latest([newer, older])[1]["updated"] == newer["updated"]
    assert dae.dedupe_latest([older, newer])[1]["updated"] == newer["updated"]


def test_sort_by_recency_orders_newest_first_by_published():
    old = make_value(vi_entry_id=1, published=datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc))
    new = make_value(vi_entry_id=2, published=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc))

    ordered = dae.sort_by_recency([old, new])

    assert [r["vi_entry_id"] for r in ordered] == [2, 1]


def test_sort_by_recency_falls_back_to_updated_when_published_is_null():
    no_published = make_value(
        vi_entry_id=1, published=None,
        updated=datetime.datetime(2026, 7, 1, tzinfo=datetime.timezone.utc),
    )
    older_published = make_value(
        vi_entry_id=2, published=datetime.datetime(2026, 3, 1, tzinfo=datetime.timezone.utc),
    )

    ordered = dae.sort_by_recency([older_published, no_published])

    assert [r["vi_entry_id"] for r in ordered] == [1, 2]


def test_to_projection_serializes_timestamps_and_drops_internal_fields():
    value = make_value(id="https://x/1")

    projected = dae.to_projection(value)

    assert projected["id"] == "https://x/1"
    assert projected["updated"] == "2026-01-01T00:00:00+00:00"
    assert "vi_entry_id" not in projected


def test_cli_prints_every_record_deduped_and_sorted_newest_first(tmp_path):
    f1 = tmp_path / "0-1"
    f2 = tmp_path / "0-2"
    write_avro_file(f1, [make_value(
        id="https://x/1", vi_entry_id=1,
        published=datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc),
    )])
    write_avro_file(f2, [make_value(
        id="https://x/2", vi_entry_id=2,
        published=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc),
    )])

    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "decode_atom_entries.py"), str(tmp_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    parsed = json.loads(result.stdout)
    assert [r["id"] for r in parsed] == ["https://x/2", "https://x/1"]


def test_cli_dedupes_across_files_by_entry_id(tmp_path):
    f1 = tmp_path / "0-1"
    f2 = tmp_path / "0-2"
    write_avro_file(f1, [make_value(
        id="https://x/1", vi_entry_id=1, summary="stale",
        updated=datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc),
    )])
    write_avro_file(f2, [make_value(
        id="https://x/1", vi_entry_id=1, summary="fresh",
        updated=datetime.datetime(2026, 6, 1, tzinfo=datetime.timezone.utc),
    )])

    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "decode_atom_entries.py"), str(tmp_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    parsed = json.loads(result.stdout)
    assert len(parsed) == 1
    assert parsed[0]["summary"] == "fresh"


def test_cli_prints_empty_array_for_empty_directory(tmp_path):
    result = subprocess.run(
        [sys.executable, str(Path(__file__).parent / "decode_atom_entries.py"), str(tmp_path)],
        capture_output=True,
        text=True,
        check=True,
    )

    assert json.loads(result.stdout) == []
