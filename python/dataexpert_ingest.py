"""Ingest DataExpert.io lessons, transcripts, slide PDFs, and videos into Snowflake.

These handlers run inside Python stored procedures created by
sql/02_ingest_procedures.sql and sql/12_video_procedure.sql (both generated
from this file by build_sql.py).
The API key comes from the Snowflake secret bound to the alias
'dataexpert_api_key'. It is sent only as a Bearer header to www.dataexpert.io.
It is never written to a table, a log, or a URL, and never sent to the slide
storage host.

ATP NOTE: this is similar to how we just change the URL using the api_key and program_id, transcript, video, slides in the URL
this is talking to the DataExpert APi
"""
from snowflake.snowpark.context import get_active_session

session = get_active_session()
session.use_database("bootcamp")
session.use_schema("atp524")  # Replace with your schema.

import hashlib
import io
import json
import os
import re
import tempfile
import time
import uuid
from urllib.parse import unquote, urlparse

import requests

API_BASE = "https://www.dataexpert.io/api/v1"
API_HOST = "www.dataexpert.io"
# Slide requests redirect to presigned URLs on this bucket. The instructor's
# network rule must allow the same host.
SLIDE_HOSTS = frozenset({"techcreator.s3.us-west-2.amazonaws.com"})
# Video requests are assumed to redirect to the same bucket as slides. If they
# redirect somewhere else, the download fails and names the host: add it here
# and to the instructor's network rule.
VIDEO_HOSTS = SLIDE_HOSTS
SECRET_ALIAS = "dataexpert_api_key"
SLIDE_STAGE = "@lesson_slides"
VIDEO_STAGE = "@lesson_videos"
USER_AGENT = "snowflake-unstructured-data-day-2-lab"

## limits 100MB; Video max: 5Gb
MAX_PDF_BYTES = 100 * 1024 * 1024  # AI_PARSE_DOCUMENT input limit
# AI_MULTI_EMBED accepts videos up to 6 GB and 4 hours. The cap stays below
# that and also bounds the procedure's temporary disk use.

# GB, MEGA, KILO, KILO
MAX_VIDEO_BYTES = 5 * 1024 * 1024 * 1024
VIDEO_TYPES = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "video/x-matroska": ".mkv",
}
MAX_LESSONS = 100
REQUEST_PAUSE_SECONDS = 0.25
RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})
REDIRECT_STATUS = frozenset({301, 302, 303, 307, 308})
CATALOG_ENDPOINTS = ("lesson", "academy", "program")
SLUG_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$")
PDF_DATE_PATTERN = re.compile(
    r"^D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?([Zz+-])?(\d{2})?'?(\d{2})?"
)


class ApiAuthError(RuntimeError):
    """The API rejected the key; stop instead of logging one error per lesson."""

## pulls in secret API key you provided
def get_api_key():
    """Read the student's key from the secret bound to the procedure."""
    import _snowflake  # Available only inside Snowflake.

    return _snowflake.get_generic_secret_string(SECRET_ALIAS)

## client talkes to DataExpert API
class ApiClient:
    """Small HTTP client with retries, an allowlisted redirect, and size caps."""


## request library to make HTTP request, which is how you request data from website via GET REQUEST
    def __init__(self, api_key, http=None, pause_seconds=REQUEST_PAUSE_SECONDS):
        if not api_key or not api_key.strip():
            raise ValueError("The dataexpert_api_key secret is empty")
        self.http = http or requests.Session() ## GET REQUEST
        self.pause_seconds = pause_seconds
        self.api_headers = {
            "Authorization": f"Bearer {api_key.strip()}",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }

    def _get(self, url, headers, stream=False):
        for attempt in range(3):
            try:
                response = self.http.get(
                    url, headers=headers, timeout=(10, 90),
                    allow_redirects=False, stream=stream,
                )
            except requests.RequestException:
                if attempt == 2:
                    raise
            else:
                if response.status_code not in RETRYABLE_STATUS or attempt == 2:
                    return response
                response.close()
            time.sleep(self.pause_seconds + 2 * (attempt + 1))
        raise RuntimeError("unreachable")

    def _check_auth(self, response):
        if response.status_code in (401, 403):
            try:
                body = response.json()
                reason = body.get("error") or body.get("message") or ""
            except ValueError:
                reason = ""
            reason = f": {str(reason)[:200]}" if reason else ""
            raise ApiAuthError(
                f"DataExpert API rejected the key (HTTP {response.status_code}{reason}). "
                "Recreate the dataexpert_api_key secret with an active key from "
                "https://www.dataexpert.io/onboarding."
            )

    def get_json(self, path):
        """Return (http_status, parsed JSON or None)."""
        response = self._get(f"{API_BASE}{path}", self.api_headers)
        time.sleep(self.pause_seconds)
        self._check_auth(response)
        if response.status_code != 200:
            return response.status_code, None
        return 200, response.json()

    def get_slides(self, slug):
        """Download a lesson's slide PDF, or return None when it has none."""
        api_url = f"{API_BASE}/lesson/{slug}/slides"
        response = self._get(api_url, {**self.api_headers, "Accept": "application/pdf"})
        time.sleep(self.pause_seconds)
        self._check_auth(response)
        if response.status_code == 404:
            return None
        source_url = api_url
        filename_path = urlparse(api_url).path
        if response.status_code in REDIRECT_STATUS:
            location = response.headers.get("Location", "")
            target = urlparse(location)
            if target.scheme != "https" or target.hostname not in SLIDE_HOSTS:
                raise ValueError(f"Unexpected slide redirect host: {target.hostname!r}")
            # The presigned URL carries its own signature. Send no API key.
            response = self._get(
                location, {"Accept": "application/pdf", "User-Agent": USER_AGENT},
                stream=True,
            )
            source_url = f"https://{target.hostname}{target.path}"  # Drop the signature.
            filename_path = target.path
        if response.status_code != 200:
            raise RuntimeError(f"Slide download failed with HTTP {response.status_code}")
        data = read_capped(response, MAX_PDF_BYTES)
        if not data.startswith(b"%PDF-"):
            raise ValueError("Slide response is not a PDF")
        return {
            "bytes": data,
            "source_url": source_url,
            "filename": safe_filename(filename_path),
        }

    def _open_video(self, slug):
        """Return (response, source_url, url_path) for a lesson's video, or None."""
        api_url = f"{API_BASE}/lesson/{slug}/video"
        response = self._get(api_url, {**self.api_headers, "Accept": "video/*"}, stream=True)
        time.sleep(self.pause_seconds)
        self._check_auth(response)
        if response.status_code == 404:
            response.close()
            return None
        source_url, url_path = api_url, urlparse(api_url).path
        if response.status_code in REDIRECT_STATUS:
            location = response.headers.get("Location", "")
            response.close()
            target = urlparse(location)
            if target.scheme != "https" or target.hostname not in VIDEO_HOSTS:
                raise ValueError(
                    f"Unexpected video redirect host: {target.hostname!r}. Add it to "
                    "VIDEO_HOSTS and to the instructor's network rule."
                )
            # The presigned URL carries its own signature. Send no API key.
            response = self._get(
                location, {"Accept": "video/*", "User-Agent": USER_AGENT}, stream=True,
            )
            source_url = f"https://{target.hostname}{target.path}"  # Drop the signature.
            url_path = target.path
        if response.status_code != 200:
            response.close()
            raise RuntimeError(f"Video download failed with HTTP {response.status_code}")
        return response, source_url, url_path

    def probe_video(self, slug):
        """Describe a lesson's video without downloading it, or return None."""
        opened = self._open_video(slug)
        if opened is None:
            return None
        response, source_url, url_path = opened
        response.close()
        size = response.headers.get("Content-Length")
        return {
            "source_url": source_url,
            "filename": safe_video_filename(url_path, response.headers.get("Content-Type")),
            "content_type": response.headers.get("Content-Type"),
            "bytes": int(size) if size and size.isdigit() else None,
        }

    def download_video(self, slug, directory):
        """Stream a lesson's video into directory, or return None when it has none.

        Videos can be gigabytes, so they go to a temporary file, never into memory.
        """
        opened = self._open_video(slug)
        if opened is None:
            return None
        response, source_url, url_path = opened
        content_type = (response.headers.get("Content-Type") or "").split(";")[0].strip()
        filename = safe_video_filename(url_path, content_type)
        path = os.path.join(directory, filename)
        digest, size, head = hashlib.sha256(), 0, b""
        try:
            with open(path, "wb") as out:
                for part in response.iter_content(chunk_size=1024 * 1024):
                    if not part:
                        continue
                    size += len(part)
                    if size > MAX_VIDEO_BYTES:
                        raise ValueError(
                            f"Video exceeds the {MAX_VIDEO_BYTES // 1024 ** 3} GB limit"
                        )
                    if len(head) < 16:
                        head += part[:16 - len(head)]
                    digest.update(part)
                    out.write(part)
        finally:
            response.close()
        if not looks_like_video(head):
            raise ValueError("Video response is not an MP4, MOV, WebM, or MKV file")
        return {
            "path": path,
            "filename": filename,
            "bytes": size,
            "sha256": digest.hexdigest(),
            "source_url": source_url,
            "content_type": content_type or None,
        }


def looks_like_video(head):
    """MP4 and MOV have an 'ftyp' box at byte 4; WebM and MKV start with EBML."""
    return head[4:8] == b"ftyp" or head[:4] == b"\x1aE\xdf\xa3"


def safe_video_filename(url_path, content_type=None):
    name = unquote(url_path.rsplit("/", 1)[-1])
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._")
    extension = VIDEO_TYPES.get((content_type or "").split(";")[0].strip(), ".mp4")
    if not name.lower().endswith(tuple(VIDEO_TYPES.values())):
        name = f"video{extension}"
    return name[-120:]


def read_capped(response, limit):
    parts, size = [], 0
    for part in response.iter_content(chunk_size=256 * 1024):
        if not part:
            continue
        size += len(part)
        if size > limit:
            raise ValueError(f"PDF exceeds the {limit // (1024 * 1024)} MB limit")
        parts.append(part)
    return b"".join(parts)


def safe_filename(url_path):
    name = unquote(url_path.rsplit("/", 1)[-1])
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("._")
    if not name.lower().endswith(".pdf") or name.lower() == ".pdf":
        name = "slides.pdf"
    return name[-120:]


def validate_slug(slug):
    if not isinstance(slug, str) or not SLUG_PATTERN.match(slug):
        raise ValueError(f"Invalid lesson slug: {slug!r}")
    return slug


def pdf_date(value):
    """Convert a PDF date such as D:20261117042906+00'00' to ISO 8601."""
    match = PDF_DATE_PATTERN.match(value or "")
    if not match:
        return None
    year, month, day, hour, minute, second, sign, tz_h, tz_m = match.groups()
    text = (f"{year}-{month or '01'}-{day or '01'}T{hour or '00'}:"
            f"{minute or '00'}:{second or '00'}")
    if sign in ("Z", "z"):
        return text + "+00:00"
    if sign in ("+", "-"):
        return f"{text}{sign}{tz_h or '00'}:{tz_m or '00'}"
    return text


def pdf_metadata(data):
    """Read page count and the PDF's own document information dictionary."""
    try:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(data))
        info = reader.metadata or {}

        def text(key):
            value = info.get(key)
            return str(value).strip() or None if value is not None else None

        return {
            "page_count": len(reader.pages),
            "title": text("/Title"),
            "author": text("/Author"),
            "subject": text("/Subject"),
            "keywords": text("/Keywords"),
            "creator": text("/Creator"),
            "producer": text("/Producer"),
            "created_at": pdf_date(text("/CreationDate")),
            "modified_at": pdf_date(text("/ModDate")),
        }
    except Exception as exc:  # Metadata is helpful, not required.
        return {"metadata_error": str(exc)[:500]}


def save_transcript(session, run_id, lesson, payload):
    transcript = (payload or {}).get("transcript") or {}
    cues = transcript.get("cues") or []
    text = transcript.get("text") or ""
    if not cues and not text:
        raise ValueError("Transcript response has no text or cues")
    duration = max((float(c.get("end") or 0) for c in cues), default=None)
    session.sql("DELETE FROM lesson_transcripts WHERE lesson_slug = ?",
                params=[lesson["slug"]]).collect()
    session.sql(
        """INSERT INTO lesson_transcripts
             (run_id, lesson_id, lesson_slug, lesson_title, transcript_text,
              cue_count, duration_seconds, transcript)
           SELECT ?, ?, ?, ?, ?, ?, ?, PARSE_JSON(?)""",
        params=[run_id, lesson["lesson_id"], lesson["slug"], lesson["title"], text,
                len(cues), duration, json.dumps(transcript)],
    ).collect()
    return len(cues)

## passing data to Snowkpark, into stage path
def save_slides(session, run_id, lesson, slides):
    """Upload a new deck version; skip the upload when the bytes are unchanged."""
    slug = lesson["slug"]
    data = slides["bytes"]
    sha256 = hashlib.sha256(data).hexdigest()
    deck_id = sha256[:16]
    existing = session.sql(
        "SELECT COUNT(*) FROM slide_decks WHERE lesson_slug = ? AND sha256 = ?",
        params=[slug, sha256],
    ).collect()[0][0]
    if existing:
        return deck_id, False
    stage_path = f"{slug}/{deck_id}/{slides['filename']}"
    session.sql(f"REMOVE {SLIDE_STAGE}/{slug}/").collect()  # Older deck versions.
    session.file.put_stream(
        io.BytesIO(data), f"{SLIDE_STAGE}/{stage_path}",
        auto_compress=False, overwrite=True,
    )
    meta = pdf_metadata(data)
    session.sql("DELETE FROM slide_decks WHERE lesson_slug = ?", params=[slug]).collect() 
    session.sql(
        """INSERT INTO slide_decks
             (run_id, deck_id, lesson_id, lesson_slug, lesson_title, source_url,
              source_filename, stage_path, file_bytes, sha256, pdf_title, pdf_author,
              pdf_page_count, pdf_created_at, pdf_metadata)
           SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, TRY_TO_TIMESTAMP_TZ(?), PARSE_JSON(?)""",
        params=[run_id, deck_id, lesson["lesson_id"], slug, lesson["title"],
                slides["source_url"], slides["filename"], stage_path, len(data), sha256,
                meta.get("title"), meta.get("author"), meta.get("page_count"),
                meta.get("created_at"), json.dumps(meta)],
    ).collect()
    return deck_id, True


def ingest_catalog(session):
    """Land the lesson, academy, and program responses as raw VARIANT rows."""
    client = ApiClient(get_api_key())
    run_id = uuid.uuid4().hex
    summary = {"run_id": run_id}
    for endpoint in CATALOG_ENDPOINTS:
        path = f"/{endpoint}"
        status, payload = client.get_json(path)
        if status != 200:
            raise RuntimeError(f"GET /api/v1{path} returned HTTP {status}")
        session.sql(
            "INSERT INTO api_responses (run_id, endpoint, payload) SELECT ?, ?, PARSE_JSON(?)",
            params=[run_id, f"/api/v1{path}", json.dumps(payload)],
        ).collect()
        summary[endpoint] = "loaded"
    counts = session.sql(
        """SELECT (SELECT COUNT(*) FROM lessons), (SELECT COUNT(*) FROM programs),
                  (SELECT COUNT(*) FROM academy_faqs)"""
    ).collect()[0]
    summary.update({"lessons": counts[0], "programs": counts[1], "faqs": counts[2]})
    return summary


def select_lessons(session, program_id, max_lessons):
    if program_id is None:
        raise ValueError("Pass a program_id. Find yours with: SELECT * FROM programs;")
    max_lessons = int(max_lessons)
    if not 1 <= max_lessons <= MAX_LESSONS:
        raise ValueError(f"max_lessons must be between 1 and {MAX_LESSONS}")
    rows = session.sql(
        """SELECT lesson_id, slug, title, has_slides FROM lessons
           WHERE program_id = ? ORDER BY sort_order, lesson_id LIMIT ?""",
        params=[int(program_id), max_lessons],
    ).collect()
    if not rows:
        raise ValueError(
            f"No lessons for program {program_id}. Run CALL ingest_catalog(); "
            "and check SELECT * FROM programs;"
        )
    return [
        {"lesson_id": r[0], "slug": validate_slug(r[1]), "title": r[2], "has_slides": r[3]}
        for r in rows
    ]


def ingest_lessons(session, program_id, max_lessons=40):
    """Download transcripts and slide PDFs for one program's lessons."""
    lessons = select_lessons(session, program_id, max_lessons)
    client = ApiClient(get_api_key())
    run_id = uuid.uuid4().hex
    summary = {"run_id": run_id, "program_id": int(program_id), "lessons_checked": len(lessons),
               "transcripts": 0, "slide_decks_uploaded": 0, "slide_decks_unchanged": 0,
               "missing": 0, "errors": 0, "error_details": []}

    def error(slug, endpoint, detail):
        summary["errors"] += 1
        summary["error_details"].append(f"{slug} {endpoint}: {str(detail)[:200]}")

    uploaded = False
    for lesson in lessons:
        slug = lesson["slug"]
        path = f"/lesson/{slug}/transcript"
        try:
            status, payload = client.get_json(path)
            if status == 200:
                save_transcript(session, run_id, lesson, payload)
                summary["transcripts"] += 1
            elif status == 404:
                summary["missing"] += 1
            else:
                error(slug, "transcript", f"HTTP {status}")
        except ApiAuthError:
            raise
        except Exception as exc:
            error(slug, "transcript", exc)

        if lesson["has_slides"] is False:
            continue
        try:
            slides = client.get_slides(slug)
            if slides is None:
                summary["missing"] += 1
                continue
            _, is_new = save_slides(session, run_id, lesson, slides)
            if is_new:
                uploaded = True
                summary["slide_decks_uploaded"] += 1
            else:
                summary["slide_decks_unchanged"] += 1
        except ApiAuthError:
            raise
        except Exception as exc:
            error(slug, "slides", exc)
    if uploaded:
        session.sql("ALTER STAGE lesson_slides REFRESH").collect()
    return summary


def save_video(session, run_id, lesson, video):
    """Stage a new video version; skip the upload when the bytes are unchanged."""
    slug = lesson["slug"]
    video_id = video["sha256"][:16]
    existing = session.sql(
        "SELECT COUNT(*) FROM lesson_videos WHERE lesson_slug = ? AND sha256 = ?",
        params=[slug, video["sha256"]],
    ).collect()[0][0]
    if existing:
        return video_id, False
    stage_dir = f"{slug}/{video_id}"
    session.sql(f"REMOVE {VIDEO_STAGE}/{slug}/").collect()  # Older video versions.
    session.file.put(video["path"], f"{VIDEO_STAGE}/{stage_dir}",
                     auto_compress=False, overwrite=True)
    session.sql("DELETE FROM lesson_videos WHERE lesson_slug = ?", params=[slug]).collect()
    session.sql(
        """INSERT INTO lesson_videos
             (run_id, video_id, lesson_id, lesson_slug, lesson_title, source_url,
              source_filename, stage_path, content_type, file_bytes, sha256)
           SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?""",
        params=[run_id, video_id, lesson["lesson_id"], slug, lesson["title"],
                video["source_url"], video["filename"], f"{stage_dir}/{video['filename']}",
                video["content_type"], video["bytes"], video["sha256"]],
    ).collect()
    return video_id, True


def ingest_videos(session, program_id, max_lessons=40):
    """Download lesson videos for one program into @lesson_videos.

    Each video is streamed to a temporary file, hashed, staged, and deleted
    before the next one, so only one video is on local disk at a time. An
    unchanged video is downloaded again to hash it, but not re-uploaded.
    """
    lessons = select_lessons(session, program_id, max_lessons)
    client = ApiClient(get_api_key())
    run_id = uuid.uuid4().hex
    summary = {"run_id": run_id, "program_id": int(program_id), "lessons_checked": len(lessons),
               "videos_uploaded": 0, "videos_unchanged": 0, "missing": 0,
               "errors": 0, "error_details": []}
    uploaded = False
    for lesson in lessons:
        slug = lesson["slug"]
        try:
            with tempfile.TemporaryDirectory() as directory:
                video = client.download_video(slug, directory)
                if video is None:
                    summary["missing"] += 1
                    continue
                _, is_new = save_video(session, run_id, lesson, video)
            if is_new:
                uploaded = True
                summary["videos_uploaded"] += 1
            else:
                summary["videos_unchanged"] += 1
        except ApiAuthError:
            raise
        except Exception as exc:
            summary["errors"] += 1
            summary["error_details"].append(f"{slug} video: {str(exc)[:200]}")
    if uploaded:
        session.sql("ALTER STAGE lesson_videos REFRESH").collect()
    return summary
