#!/usr/bin/env python3
"""Decode Avro entries mirrored from the Ceph `atom-entries` bucket.

Each object in the bucket is a standalone Avro Object Container File (the
Aiven S3 sink connector's `format.output.type: avro`), keyed by
`{{topic}}/{{partition}}-{{start_offset}}`. The same FreshRSS entry
(`vi_entry_id`) can appear in multiple files as freshrss-streams re-emits
updates, so records must be deduped by `vi_entry_id`, keeping the one with
the latest `updated` timestamp, before filtering down to the entries a
caller cares about.

CLI usage (called from scripts/freshrss.nu):
    decode_atom_entries.py <dir-of-mirrored-objects> < allowed-links.txt

Reads newline-delimited allowed entry links (matched against the `id`
field) from stdin, and prints a JSON array of matching, deduped, projected
records to stdout.
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


def filter_by_ids(deduped_by_entry_id, allowed_ids):
    """Return the deduped records whose `id` (entry link) is in `allowed_ids`."""
    return [record for record in deduped_by_entry_id.values() if record["id"] in allowed_ids]


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
        print("usage: decode_atom_entries.py <dir-of-mirrored-objects> < allowed-links.txt", file=sys.stderr)
        return 2

    bucket_dir = Path(sys.argv[1])
    allowed_ids = {line.strip() for line in sys.stdin if line.strip()}

    paths = [p for p in bucket_dir.rglob("*") if p.is_file()]
    records = iter_records(paths)
    deduped = dedupe_latest(records)
    matched = filter_by_ids(deduped, allowed_ids)

    json.dump([to_projection(r) for r in matched], sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
