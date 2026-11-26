"""Check a DataExpert API key and see what it can access, without Snowflake.

Uses the same client as the Snowflake ingestion procedures. The key is read
from an environment variable so it never lands in shell history or files:

    read -s DATAEXPERT_API_KEY && export DATAEXPERT_API_KEY
    python3 python/check_api.py                    # catalog summary
    python3 python/check_api.py --program 908      # plus transcripts/slides
    python3 python/check_api.py --program 908 --videos   # plus video headers
"""
import argparse
import os
import sys
from collections import Counter

from dataexpert_ingest import ApiClient


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--program", type=int, help="program_id to check lesson by lesson")
    parser.add_argument("--max-lessons", type=int, default=40)
    parser.add_argument("--videos", action="store_true",
                        help="also probe /lesson/<slug>/video (headers only, no download)")
    args = parser.parse_args()

    key = os.environ.get("DATAEXPERT_API_KEY", "")
    if not key:
        sys.exit("Set DATAEXPERT_API_KEY first (get it from https://www.dataexpert.io/onboarding).")
    client = ApiClient(key, pause_seconds=0.1)

    payloads = {}
    for endpoint in ("lesson", "academy", "program"):
        status, payloads[endpoint] = client.get_json(f"/{endpoint}")
        print(f"GET /api/v1/{endpoint}: HTTP {status}")
        if status != 200:
            sys.exit(1)

    lessons = payloads["lesson"]["lessons"]
    programs = {p["program_id"]: p["name"] for p in payloads["program"]["programs"]}
    faqs = payloads["academy"]["academy"].get("faqs", [])
    print(f"\n{len(lessons)} lessons, {len(programs)} programs, {len(faqs)} FAQs\n")
    per_program = Counter(l["program_id"] for l in lessons)
    for program_id, count in per_program.most_common():
        print(f"  program {program_id:>5}  {count:>4} lessons  {programs.get(program_id, '?')}")

    if args.program is None:
        return
    selected = sorted((l for l in lessons if l["program_id"] == args.program),
                      key=lambda l: (l["sort_order"] or 0, l["lesson_id"]))[:args.max_lessons]
    print(f"\nProgram {args.program}: checking {len(selected)} lessons")
    totals = Counter()
    for lesson in selected:
        status, payload = client.get_json(f"/lesson/{lesson['slug']}/transcript")
        transcript = "-"
        if status == 200:
            cues = payload["transcript"].get("cues") or []
            transcript = f"{len(cues)} cues, {cues[-1]['end'] / 60:.0f} min" if cues else "text only"
            totals["transcripts"] += 1
        slides = "-"
        if lesson.get("has_slides") is not False:
            deck = client.get_slides(lesson["slug"])
            if deck:
                slides = f"{deck['filename']} ({len(deck['bytes']) / 1e6:.1f} MB)"
                totals["decks"] += 1
        video = "-"
        if args.videos:
            try:
                found = client.probe_video(lesson["slug"])
            except (ValueError, RuntimeError) as exc:
                found, video = None, f"ERROR {exc}"
            if found:
                size = f"{found['bytes'] / 1e6:.0f} MB" if found["bytes"] else "size unknown"
                host = found["source_url"].split("/")[2]
                video = f"{found['filename']} ({size}, {found['content_type']}, from {host})"
                totals["videos"] += 1
        print(f"  {lesson['slug'][:55]:<55} transcript: {transcript:<18} slides: {slides:<24}"
              + (f" video: {video}" if args.videos else ""))
    print(f"\n{totals['transcripts']} transcripts and {totals['decks']} slide decks available"
          + (f", {totals['videos']} videos" if args.videos else ""))


if __name__ == "__main__":
    main()
