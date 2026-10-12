"""Summarize guest swap intervals. These are not display-present measurements."""
import argparse
import csv
from datetime import datetime, timezone
import io
import json
from pathlib import Path


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def utc_microseconds(value):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("UTC boundaries require a timezone, for example 2026-10-12T01:40:00Z")
    return round(parsed.timestamp() * 1_000_000)


def utc_string(value):
    return datetime.fromtimestamp(value / 1_000_000, timezone.utc).isoformat() if value is not None else None


def analyze(path, start_seconds=0, end_seconds=None, start_utc=None, end_utc=None):
    frames = []
    elapsed = 0.0
    start_us, end_us = utc_microseconds(start_utc), utc_microseconds(end_utc)
    snapshot = path.read_text(encoding="utf-8-sig")
    incomplete_tail = bool(snapshot and not snapshot.endswith("\n"))
    if incomplete_tail:
        snapshot = snapshot[:snapshot.rfind("\n") + 1]
    with io.StringIO(snapshot) as source:
        reader = csv.DictReader(source)
        if not reader.fieldnames or "frame_time_us" not in reader.fieldnames:
            raise ValueError("Not a ReXGlue frame counter CSV")
        if (start_us is not None or end_us is not None) and "timestamp_utc_us" not in reader.fieldnames:
            raise ValueError("This capture has no UTC anchors; use a newer capture or an independently verified relative range")
        for index, row in enumerate(reader):
            duration_us = int(row["frame_time_us"])
            if duration_us <= 0:
                continue
            interval_start = elapsed
            elapsed += duration_us / 1_000_000
            # Include only intervals wholly inside the requested time window.
            if interval_start < start_seconds or (end_seconds is not None and elapsed > end_seconds):
                continue
            timestamp_us = int(row["timestamp_utc_us"]) if "timestamp_utc_us" in row else None
            if start_us is not None and timestamp_us - duration_us < start_us:
                continue
            if end_us is not None and timestamp_us > end_us:
                continue
            frames.append({"row": index + 1, "end_seconds": elapsed,
                           "timestamp_utc_us": timestamp_us,
                           "milliseconds": duration_us / 1000,
                           "pipeline_cache_misses": int(row.get("pipeline_cache_misses", 0)),
                           "command_buffer_stalls": int(row.get("command_buffer_stalls", 0)),
                           "draw_calls": int(row.get("draw_calls", 0))})
    if not frames:
        raise ValueError("No positive complete frame intervals in the selected window")
    times = [frame["milliseconds"] for frame in frames]
    total_ms = sum(times)
    return {
        "source": str(path.resolve()),
        "measurement": "Guest XE_SWAP intervals; not display presentation or pure GPU time",
        "time_origin": "Seconds since the first recorded guest XE_SWAP, not process launch or load-sampler start. A separately observed anchor is required for wall-clock alignment.",
        "selection_seconds": {"start": start_seconds, "end": end_seconds},
        "selection_utc": {"start": start_utc, "end": end_utc},
        "observed_utc": {"first_interval_end": utc_string(frames[0]["timestamp_utc_us"]),
                         "last_interval_end": utc_string(frames[-1]["timestamp_utc_us"])},
        "frames": len(frames), "included_seconds": total_ms / 1000,
        "incomplete_tail_discarded": incomplete_tail,
        "effective_swap_fps": len(frames) * 1000 / total_ms,
        "frame_ms": {"median": percentile(times, .5), "p95": percentile(times, .95),
                     "p99": percentile(times, .99), "maximum": max(times)},
        "frames_over_50_ms": sum(t > 50 for t in times),
        "frames_over_100_ms": sum(t > 100 for t in times),
        "pipeline_cache_misses": sum(f["pipeline_cache_misses"] for f in frames),
        "command_buffer_stalls": sum(f["command_buffer_stalls"] for f in frames),
        "longest_intervals": sorted(frames, key=lambda f: f["milliseconds"], reverse=True)[:10],
        "limits": "Exclude menus, loading, replay, and unfocused periods before comparing skating. Counter coincidence alone does not prove causation.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--start-seconds", type=float, default=0,
                        help="Seconds since the first recorded guest swap, not process launch")
    parser.add_argument("--end-seconds", type=float,
                        help="Seconds since the first recorded guest swap; use an observed anchor for wall-clock alignment")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--start-utc", help="ISO timestamp with timezone; requires timestamp_utc_us column")
    parser.add_argument("--end-utc", help="ISO timestamp with timezone; requires timestamp_utc_us column")
    args = parser.parse_args()
    if args.start_seconds < 0 or (args.end_seconds is not None and args.end_seconds <= args.start_seconds):
        parser.error("Choose a nonnegative start and an end greater than start")
    if args.start_utc and args.end_utc and utc_microseconds(args.end_utc) <= utc_microseconds(args.start_utc):
        parser.error("UTC end must be after UTC start")
    result = analyze(args.csv_path, args.start_seconds, args.end_seconds, args.start_utc, args.end_utc)
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
