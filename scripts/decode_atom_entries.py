#!/usr/bin/env python3
"""Decode Avro entries mirrored from the Ceph `atom-entries` bucket.

Each object in the bucket is a standalone Avro Object Container File (the
Aiven S3 sink connector's `format.output.type: avro`), keyed by
`{{topic}}/{{partition}}-{{start_offset}}`. freshrss-streams only ever
emits an entry into this pipeline once it's been tagged `review` in
FreshRSS — so every record in the bucket is, by construction, a reviewed
article; there's nothing left to filter by. The same entry (`vi_entry_id`)
can appear in multiple files as freshrss-streams re-emits updates, so
records are deduped by `vi_entry_id`, keeping the one with the latest
`updated` timestamp.

CLI usage (called from scripts/freshrss.nu):
    decode_atom_entries.py <dir-of-mirrored-objects>

Prints a JSON array of deduped, projected records to stdout, newest first.
"""
import datetime
import json
import sys
from pathlib import Path

import fastavro

# Fields needed to render a markdown entry — everything else (vi_entry_id,
# raw feed content, word counts, transcript status, ...) is pipeline
# bookkeeping not needed by the caller.
_PROJECTION_FIELDS = (
    "id",
    "title",
    "updated",
    "published",
    "author_name",
    "summary",
    "categories",
    "source_feed_name",
    "vi_summary_bullets",
    "vi_summary_status",
)


def iter_records(paths):
    """Yield the decoded `value` payload of every record in the given Avro files."""
    for path in paths:
        with open(path, "rb") as f:
            for outer in fastavro.reader(f):
                yield outer["value"]


def dedupe_latest(records):
    """Collapse records to one per `vi_entry_id`, keeping the latest `updated`."""
    latest = {}
    for record in records:
        entry_id = record["vi_entry_id"]
        current = latest.get(entry_id)
        if current is None or record["updated"] > current["updated"]:
            latest[entry_id] = record
    return latest


def sort_by_recency(records):
    """Sort records newest first, by `published`, falling back to `updated` when null."""
    return sorted(records, key=lambda r: r["published"] or r["updated"], reverse=True)


def to_projection(record):
    """Project a record down to markdown-relevant fields, JSON-serializable."""
    projected = {}
    for field in _PROJECTION_FIELDS:
        value = record.get(field)
        if isinstance(value, datetime.datetime):
            value = value.isoformat()
        projected[field] = value
    return projected


def main():
    if len(sys.argv) != 2:
        print("usage: decode_atom_entries.py <dir-of-mirrored-objects>", file=sys.stderr)
        return 2

    bucket_dir = Path(sys.argv[1])
    paths = [p for p in bucket_dir.rglob("*") if p.is_file()]
    records = iter_records(paths)
    ordered = sort_by_recency(dedupe_latest(records).values())

    json.dump([to_projection(r) for r in ordered], sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
