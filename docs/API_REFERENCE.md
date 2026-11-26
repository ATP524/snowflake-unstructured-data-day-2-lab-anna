# DataExpert content API: observed behavior

Date: 2026-11-18  
POC: Course instructor  
TL;DR: Five GET endpoints under `https://www.dataexpert.io/api/v1`, plus `/lesson/<slug>/video` (new, not yet observed). Authenticate with a Bearer header. Slides redirect to a presigned S3 URL; many lessons return 404 for transcripts or slides.

This was observed with an instructor key on 2026-11-18. A student key returns only the programs and lessons that student can access.

## Authentication

Accepted ways to send the key:

- `Authorization: Bearer <key>` (the lab uses this)
- `x-api-key: <key>`
- `?api_key=<key>` query parameter (works, but puts the key in URLs and logs)

A missing key returns `401 {"message":"Unauthorized"}`. A deactivated key returns `401 {"error":"API key is inactive"}`. Students get keys from [dataexpert.io/onboarding](https://www.dataexpert.io/onboarding).

## Endpoints

### `GET /api/v1/lesson`

`200 {"lessons": [...]}`, about 480 KB for 629 lessons with an instructor key. Fields per lesson:

`lesson_id`, `title`, `slug`, `description`, `duration_seconds` (often null), `is_free`, `date_recorded`, `image_url`, `academy_id`, `program_id`, `module_id`, `sort_order`, `module_name` (may have leading spaces), `has_slides`.

`has_slides` was a reliable predictor. All 299 lessons with `false` returned 404 for slides, and 325 of 330 with `true` redirected to a PDF.

### `GET /api/v1/academy`

`200 {"academy": {...}}` with `academy_id`, `academy_name`, `academy_description`, `support_email`, `academy_policies_link`, `important_links` (an object of path to label), `social_metadata`, and `faqs`: an array of `{faq_id, program_id, question, answer, sort_order}`. Nine FAQs were returned; answers contain newlines and URLs.

### `GET /api/v1/program`

`200 {"programs": [...]}` with `program_id`, `name`, `slug`, `description`, `start_date`, `end_date`, `is_active`, pricing and Stripe IDs, `instructor_ids`, `discord_role`, and other display fields. The lab models only the identifying fields.

### `GET /api/v1/lesson/<slug>/transcript`

`200 {"transcript": {"lesson_id", "slug", "title", "text", "cues": [{"start", "end", "text"}]}}`.

- `text` is the punctuated full transcript with no line breaks.
- `cues` are timed segments of about 40 characters and 2 to 4 seconds each, unpunctuated. Times are seconds as floats.
- A 43-minute lecture has 45,181 characters and 1,057 cues (about 150 KB of JSON).
- Without a transcript: `404 {"error":"Transcript not found for this lesson"}`.

### `GET /api/v1/lesson/<slug>/slides`

`302` with `Location: https://techcreator.s3.us-west-2.amazonaws.com/academy/2/course/<lesson_id>/<file>.pdf?<signature>`. The signed URL needs no other credentials. Don't forward the API key to it. Without slides: `404 {"error":"Slides not found for this lesson"}`.

The PDFs are Canva exports with document information (`/Title`, `/Author`, `/CreationDate`). The two program 908 decks are 19 pages (7.6 MB) and 33 pages (3.0 MB) at 1440 × 810 points.

### `GET /api/v1/lesson/<slug>/video`

Added 2026-11-19 and not yet observed with a key. Without a key on 2026-11-19, production returned the site's HTML 404 page here, not the API's `401` JSON, so the route wasn't live yet. `ingest_videos` assumes it works like `/slides`:

- A `302` to a presigned URL on a host in `VIDEO_HOSTS`, currently the slide bucket, or a `200` with the video itself.
- `404` when the lesson has no video.
- An MP4, MOV, WebM, or MKV body.

Run `python3 python/check_api.py --program 908 --videos` with a key to see the real status, host, content type, and size without downloading. If the redirect host differs, add it to `VIDEO_HOSTS` and the network rule, then update this section.

## Availability across the catalog

Survey of all 629 lessons with an instructor key:

| Transcript | Slides | Lessons |
| --- | --- | ---: |
| 200 | PDF | 309 |
| 200 | 404 | 216 |
| 404 | 404 | 80 |
| 404 | PDF | 16 |
| timeout | timeout | 7 |
| 500 | 404 | 1 |

Seven lessons did not respond within 30 seconds, and one transcript returned HTTP 500. The ingestion client retries 429 and 5xx responses up to three times and logs anything that still fails.

Program 908 (Senior AI Analytics Engineering Boot Camp) has 40 lessons. Three have transcripts (onboarding, Day 1 lecture, Day 1 lab) and two have slides (kickoff, Day 1 lecture).
