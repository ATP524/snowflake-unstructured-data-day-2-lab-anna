CREATE OR REPLACE PROCEDURE "ASK_COURSE"("QUESTION" VARCHAR, "TOP_K" NUMBER(38,0) DEFAULT 6, "ANSWER_MODEL" VARCHAR DEFAULT 'claude-sonnet-4-5', "PURPOSE" VARCHAR DEFAULT 'adhoc', "RUN_ID" VARCHAR DEFAULT null)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'ask_course'
EXECUTE AS CALLER
AS '
"""Ask cited questions and evaluate retrieval with the course_search service.

SNOWFLAKE.CORTEX.SEARCH_PREVIEW accepts only constant arguments. These
procedures therefore build one escaped literal per query, which lets a table
of evaluation questions drive Cortex Search. Production apps would use the
Cortex Search Python or REST API instead.
"""
import json
import re

SERVICE_NAME = "course_search"
RESULT_COLUMNS = ["source_id", "source_type", "lesson_slug", "citation", "search_text"]
SOURCE_TYPES = {"transcript", "slide", "faq"}
MODEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{1,80}$")
# A service name is spliced into SQL text, so it must be a plain (optionally qualified) identifier.
SERVICE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$")
METHOD_LABEL_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
PURPOSE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
NOT_FOUND = "I could not find that in the course materials."

PROMPT_TEMPLATE = """You answer questions from DataExpert.io boot camp students.
Use only the numbered sources below. Cite every claim with its source number, like [2].
If the sources do not answer the question, reply with exactly: {not_found}

Sources:
{context}

Question: {question}
Answer:"""

# Judge prompt for step 9e. Bump $judge_prompt_version in sql/runbook_config.sql when this changes.
JUDGE_PROMPTS = {
    "v1": """You grade one answer from a course question-answering assistant.
Use only the numbered sources shown. Score each item from 1 (worst) to 5 (best).
- groundedness: every claim in the answer is supported by the sources. If the answer is a
  refusal, score 5 when the sources really do not answer the question, otherwise 1.
- answer_relevance: the answer addresses the question that was asked.
- context_relevance: the sources are about the question.
- refused: true if the answer declines to answer (for example, says it could not find it).
- rationale: one short sentence.

Sources:
{context}

Question: {question}

Answer:
{answer}""",
}
JUDGE_SCHEMA = {
    "type": "json",
    "schema": {
        "type": "object",
        "properties": {
            "groundedness": {"type": "integer"},
            "answer_relevance": {"type": "integer"},
            "context_relevance": {"type": "integer"},
            "refused": {"type": "boolean"},
            "rationale": {"type": "string"},
        },
        "required": ["groundedness", "answer_relevance", "context_relevance", "refused", "rationale"],
    },
}


def sql_literal(value):
    """Quote text as a Snowflake single-quoted literal (backslashes are escapes)."""
    return "''" + value.replace("\\\\", "\\\\\\\\").replace("''", "''''") + "''"


def search(session, query, limit=5, source_type=None, service_name=SERVICE_NAME):
    query = (query or "").strip()
    if not query or len(query) > 2000:
        raise ValueError("query must contain 1 to 2000 characters")
    limit = int(limit)
    if not 1 <= limit <= 50:
        raise ValueError("limit must be between 1 and 50")
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    request = {"query": query, "columns": RESULT_COLUMNS, "limit": limit}
    if source_type:
        if source_type not in SOURCE_TYPES:
            raise ValueError(f"source_type must be one of {sorted(SOURCE_TYPES)}")
        request["filter"] = {"@eq": {"source_type": source_type}}
    statement = (f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW({sql_literal(service_name)}, "
                 f"{sql_literal(json.dumps(request))})")
    raw = session.sql(statement).collect()[0][0]
    return json.loads(raw).get("results", [])


def completion_text(raw):
    """AI_COMPLETE returns a string; tolerate a JSON response with choices too."""
    if raw is None:
        return None
    text = raw if isinstance(raw, str) else json.dumps(raw)
    try:
        parsed = json.loads(text)
    except ValueError:
        return text.strip()
    if isinstance(parsed, dict) and parsed.get("choices"):
        choice = parsed["choices"][0]
        return (choice.get("messages") or choice.get("message") or "").strip()
    return parsed.strip() if isinstance(parsed, str) else text.strip()


def usage_tokens(raw):
    """(prompt_tokens, completion_tokens) from an AI_COMPLETE show_details response, else (None, None)."""
    try:
        usage = json.loads(raw if isinstance(raw, str) else json.dumps(raw)).get("usage") or {}
        return usage.get("prompt_tokens"), usage.get("completion_tokens")
    except (ValueError, AttributeError):
        return None, None


def build_prompt(question, results):
    context = "\\n\\n".join(
        f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
    )
    return PROMPT_TEMPLATE.format(
        not_found=NOT_FOUND, context=context or "(no sources found)", question=question
    )


def complete(session, model, prompt, temperature=0, max_tokens=800, response_format=None):
    """One AI_COMPLETE call with show_details, so token usage comes back with the answer."""
    if not MODEL_PATTERN.match(model or ""):
        raise ValueError("model must be a Snowflake model name such as claude-sonnet-4-5")
    temperature = float(temperature)
    if not 0 <= temperature <= 1:
        raise ValueError("temperature must be between 0 and 1")
    fmt = ", response_format => PARSE_JSON(?)" if response_format else ""
    params = [prompt] + ([json.dumps(response_format)] if response_format else [])
    raw = session.sql(
        f"SELECT AI_COMPLETE(model => {sql_literal(model)}, prompt => ?, "
        f"model_parameters => {{''temperature'': {temperature}, ''max_tokens'': {int(max_tokens)}}}"
        f"{fmt}, show_details => TRUE)",
        params=params,
    ).collect()[0][0]
    return raw


def answer_question(session, question, top_k, answer_model, service_name=SERVICE_NAME):
    """Retrieve with Cortex Search and answer with AI_COMPLETE. Returns answer, sources, results, tokens."""
    top_k = int(top_k)
    if not 1 <= top_k <= 20:
        raise ValueError("top_k must be between 1 and 20")
    question = (question or "").strip()
    results = search(session, question, top_k, service_name=service_name)
    raw = complete(session, answer_model, build_prompt(question, results))
    sources = [
        {"n": n, "source_id": r.get("source_id"), "citation": r.get("citation")}
        for n, r in enumerate(results, 1)
    ]
    return completion_text(raw), sources, results, usage_tokens(raw)


def log_answer(session, question, answer_model, answer, sources, purpose, run_id, tokens):
    # One JSON row instead of separate binds: inside a procedure a bound Python None arrives as
    # the text ''None'', while JSON null reads back as SQL NULL.
    row = {"question": question, "answer_model": answer_model, "answer": answer, "sources": sources,
           "run_id": run_id, "purpose": purpose, "input_tokens": tokens[0], "output_tokens": tokens[1]}
    session.sql(
        """INSERT INTO ask_log (question, answer_model, answer, sources, run_id, purpose,
                                input_tokens, output_tokens)
           SELECT r:question::VARCHAR, r:answer_model::VARCHAR, r:answer::VARCHAR, r:sources,
                  r:run_id::VARCHAR, r:purpose::VARCHAR, r:input_tokens::NUMBER, r:output_tokens::NUMBER
           FROM (SELECT PARSE_JSON(?) AS r)""",
        params=[json.dumps(row)],
    ).collect()


def ask_course(session, question, top_k=6, answer_model="claude-sonnet-4-5", purpose="adhoc", run_id=None):
    """Retrieve with Cortex Search, answer with AI_COMPLETE, and log the result.

    purpose and run_id tag the ask_log row: ''adhoc'' for hand-run questions, ''eval'' for step 9e.
    """
    purpose = (purpose or "adhoc").strip().lower()
    if not PURPOSE_PATTERN.match(purpose):
        raise ValueError("purpose must be lower-case letters, digits or _, such as adhoc")
    answer, sources, _, tokens = answer_question(session, question, top_k, answer_model)
    log_answer(session, (question or "").strip(), answer_model, answer, sources, purpose, run_id, tokens)
    return {"question": (question or "").strip(), "answer": answer, "sources": sources}


def run_search_eval(session, top_k=10, service_name=SERVICE_NAME, method_label="CORTEX_SEARCH"):
    """Store the top-k Cortex Search results for every answerable eval question.

    service_name picks the service to search, so a baseline service (for example
    course_search_before_desc) can be scored without editing this module.
    method_label is the method value written to retrieval_results; only rows with
    that label are replaced, so other methods and other labels are kept.
    Each row keeps the service''s @scores (cosine_similarity, text_match, reranker_score).
    """
    top_k = int(top_k)
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    method_label = (method_label or "").strip().upper()
    if not METHOD_LABEL_PATTERN.match(method_label):
        raise ValueError("method_label must be upper-case letters, digits or _, such as CORTEX_SEARCH")
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions WHERE answerable ORDER BY question_id"
    ).collect()
    rows = []
    for question_id, question in questions:
        for rank, result in enumerate(search(session, question, top_k, service_name=service_name), 1):
            scores = result.get("@scores") or {}
            rows.append([method_label, question_id, rank, result.get("source_id"),
                         scores.get("cosine_similarity"), scores.get("text_match"),
                         scores.get("reranker_score")])
    session.sql("DELETE FROM retrieval_results WHERE method = ?", params=[method_label]).collect()
    if rows:
        session.create_dataframe(
            rows, schema=["METHOD", "QUESTION_ID", "RESULT_RANK", "SOURCE_ID",
                          "SCORE_COSINE", "SCORE_TEXT", "SCORE_RERANK"]
        ).write.mode("append").save_as_table("retrieval_results", column_order="name")
    return {"method": method_label, "service": service_name,
            "questions": len(questions), "rows": len(rows)}


def run_answer_eval(session, top_k=6, answer_model="claude-sonnet-4-5", judge_model="llama3.3-70b",
                    judge_prompt_version="v1", judge_temperature=0, service_name=SERVICE_NAME, run_id="manual"):
    """Step 9e: answer every eval question (answerable and not), then grade each answer with a judge.

    Answers are logged to ask_log with purpose ''eval'' and this run_id. Judgments go to
    answer_judgments (this run''s rows are replaced). The judge sees the same sources the
    answer model saw. Token usage of both calls is stored for cost.
    """
    if judge_prompt_version not in JUDGE_PROMPTS:
        raise ValueError(f"judge_prompt_version must be one of {sorted(JUDGE_PROMPTS)}")
    if not MODEL_PATTERN.match(judge_model or ""):
        raise ValueError("judge_model must be a Snowflake model name such as llama3.3-70b")
    run_id = (run_id or "manual").strip()
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions ORDER BY question_id"
    ).collect()
    session.sql("DELETE FROM answer_judgments WHERE run_id = ?", params=[run_id]).collect()
    done, failed = 0, 0
    for question_id, question in questions:
        answer, sources, results, tokens = answer_question(session, question, top_k, answer_model, service_name)
        log_answer(session, question, answer_model, answer, sources, "eval", run_id, tokens)
        context = "\\n\\n".join(
            f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
        ) or "(no sources found)"
        prompt = JUDGE_PROMPTS[judge_prompt_version].format(context=context, question=question, answer=answer)
        grade, judge_raw, judge_error = {}, None, None
        try:
            judge_raw = complete(session, judge_model, prompt, judge_temperature, 400, JUDGE_SCHEMA)
            parsed = json.loads(judge_raw if isinstance(judge_raw, str) else json.dumps(judge_raw))
            grade = (parsed.get("structured_output") or [{}])[0].get("raw_message") or {}
        except Exception as exc:   # keep the answer; record why the grade is missing
            judge_error = str(exc)[:500]
        judge_tokens = usage_tokens(judge_raw) if judge_raw else (None, None)
        clamp = lambda v: max(1, min(5, int(v))) if isinstance(v, (int, float)) else None
        row = {"run_id": run_id, "question_id": question_id, "question": question,
               "answer_model": answer_model, "gen_top_k": int(top_k), "answer": answer, "sources": sources,
               "judge_model": judge_model, "judge_prompt_version": judge_prompt_version,
               "groundedness": clamp(grade.get("groundedness")),
               "answer_relevance": clamp(grade.get("answer_relevance")),
               "context_relevance": clamp(grade.get("context_relevance")),
               "refused": grade.get("refused") if isinstance(grade.get("refused"), bool) else None,
               "rationale": grade.get("rationale"), "judge_error": judge_error,
               "answer_input_tokens": tokens[0], "answer_output_tokens": tokens[1],
               "judge_input_tokens": judge_tokens[0], "judge_output_tokens": judge_tokens[1]}
        session.sql(
            """INSERT INTO answer_judgments (run_id, question_id, question, answer_model, gen_top_k, answer,
                 sources, judge_model, judge_prompt_version, groundedness, answer_relevance,
                 context_relevance, refused, rationale, judge_error, answer_input_tokens,
                 answer_output_tokens, judge_input_tokens, judge_output_tokens, judged_at)
               SELECT r:run_id::VARCHAR, r:question_id::VARCHAR, r:question::VARCHAR, r:answer_model::VARCHAR,
                      r:gen_top_k::NUMBER, r:answer::VARCHAR, r:sources, r:judge_model::VARCHAR,
                      r:judge_prompt_version::VARCHAR, r:groundedness::NUMBER, r:answer_relevance::NUMBER,
                      r:context_relevance::NUMBER, r:refused::BOOLEAN, r:rationale::VARCHAR,
                      r:judge_error::VARCHAR, r:answer_input_tokens::NUMBER, r:answer_output_tokens::NUMBER,
                      r:judge_input_tokens::NUMBER, r:judge_output_tokens::NUMBER, CURRENT_TIMESTAMP()
               FROM (SELECT PARSE_JSON(?) AS r)""",
            params=[json.dumps(row)],
        ).collect()
        failed += judge_error is not None
        done += 1
    return {"run_id": run_id, "questions": len(questions), "judged": done - failed, "judge_errors": failed}
';

CREATE OR REPLACE PROCEDURE "INGEST_CATALOG"()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python','requests','pypdf')
HANDLER = 'ingest_catalog'
EXTERNAL_ACCESS_INTEGRATIONS = (DATAEXPERT_API_ACCESS)
SECRETS = ('dataexpert_api_key'=DATAEXPERT_API_KEY)
EXECUTE AS CALLER
AS '
"""Ingest DataExpert.io lessons, transcripts, slide PDFs, and videos into Snowflake.

These handlers run inside Python stored procedures created by
sql/02_ingest_procedures.sql and sql/12_video_procedure.sql (both generated
from this file by build_sql.py).
The API key comes from the Snowflake secret bound to the alias
''dataexpert_api_key''. It is sent only as a Bearer header to www.dataexpert.io.
It is never written to a table, a log, or a URL, and never sent to the slide
storage host.
"""
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
# Slide requests redirect to presigned URLs on this bucket. The instructor''s
# network rule must allow the same host.
SLIDE_HOSTS = frozenset({"techcreator.s3.us-west-2.amazonaws.com"})
# Video requests are assumed to redirect to the same bucket as slides. If they
# redirect somewhere else, the download fails and names the host: add it here
# and to the instructor''s network rule.
VIDEO_HOSTS = SLIDE_HOSTS
SECRET_ALIAS = "dataexpert_api_key"
SLIDE_STAGE = "@lesson_slides"
VIDEO_STAGE = "@lesson_videos"
USER_AGENT = "snowflake-unstructured-data-day-2-lab"

MAX_PDF_BYTES = 100 * 1024 * 1024  # AI_PARSE_DOCUMENT input limit
# AI_MULTI_EMBED accepts videos up to 6 GB and 4 hours. The cap stays below
# that and also bounds the procedure''s temporary disk use.
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
    r"^D:(\\d{4})(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?([Zz+-])?(\\d{2})?''?(\\d{2})?"
)


class ApiAuthError(RuntimeError):
    """The API rejected the key; stop instead of logging one error per lesson."""


def get_api_key():
    """Read the student''s key from the secret bound to the procedure."""
    import _snowflake  # Available only inside Snowflake.

    return _snowflake.get_generic_secret_string(SECRET_ALIAS)


class ApiClient:
    """Small HTTP client with retries, an allowlisted redirect, and size caps."""

    def __init__(self, api_key, http=None, pause_seconds=REQUEST_PAUSE_SECONDS):
        if not api_key or not api_key.strip():
            raise ValueError("The dataexpert_api_key secret is empty")
        self.http = http or requests.Session()
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
        """Download a lesson''s slide PDF, or return None when it has none."""
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
        """Return (response, source_url, url_path) for a lesson''s video, or None."""
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
                    "VIDEO_HOSTS and to the instructor''s network rule."
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
        """Describe a lesson''s video without downloading it, or return None."""
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
        """Stream a lesson''s video into directory, or return None when it has none.

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
    """MP4 and MOV have an ''ftyp'' box at byte 4; WebM and MKV start with EBML."""
    return head[4:8] == b"ftyp" or head[:4] == b"\\x1aE\\xdf\\xa3"


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
    """Convert a PDF date such as D:20261117042906+00''00'' to ISO 8601."""
    match = PDF_DATE_PATTERN.match(value or "")
    if not match:
        return None
    year, month, day, hour, minute, second, sign, tz_h, tz_m = match.groups()
    text = (f"{year}-{month or ''01''}-{day or ''01''}T{hour or ''00''}:"
            f"{minute or ''00''}:{second or ''00''}")
    if sign in ("Z", "z"):
        return text + "+00:00"
    if sign in ("+", "-"):
        return f"{text}{sign}{tz_h or ''00''}:{tz_m or ''00''}"
    return text


def pdf_metadata(data):
    """Read page count and the PDF''s own document information dictionary."""
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
    stage_path = f"{slug}/{deck_id}/{slides[''filename'']}"
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
    """Download transcripts and slide PDFs for one program''s lessons."""
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
                video["source_url"], video["filename"], f"{stage_dir}/{video[''filename'']}",
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
';

CREATE OR REPLACE PROCEDURE "INGEST_LESSONS"("PROGRAM_ID" NUMBER(38,0), "MAX_LESSONS" NUMBER(38,0) DEFAULT 40)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python','requests','pypdf')
HANDLER = 'ingest_lessons'
EXTERNAL_ACCESS_INTEGRATIONS = (DATAEXPERT_API_ACCESS)
SECRETS = ('dataexpert_api_key'=DATAEXPERT_API_KEY)
EXECUTE AS CALLER
AS '
"""Ingest DataExpert.io lessons, transcripts, slide PDFs, and videos into Snowflake.

These handlers run inside Python stored procedures created by
sql/02_ingest_procedures.sql and sql/12_video_procedure.sql (both generated
from this file by build_sql.py).
The API key comes from the Snowflake secret bound to the alias
''dataexpert_api_key''. It is sent only as a Bearer header to www.dataexpert.io.
It is never written to a table, a log, or a URL, and never sent to the slide
storage host.
"""
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
# Slide requests redirect to presigned URLs on this bucket. The instructor''s
# network rule must allow the same host.
SLIDE_HOSTS = frozenset({"techcreator.s3.us-west-2.amazonaws.com"})
# Video requests are assumed to redirect to the same bucket as slides. If they
# redirect somewhere else, the download fails and names the host: add it here
# and to the instructor''s network rule.
VIDEO_HOSTS = SLIDE_HOSTS
SECRET_ALIAS = "dataexpert_api_key"
SLIDE_STAGE = "@lesson_slides"
VIDEO_STAGE = "@lesson_videos"
USER_AGENT = "snowflake-unstructured-data-day-2-lab"

MAX_PDF_BYTES = 100 * 1024 * 1024  # AI_PARSE_DOCUMENT input limit
# AI_MULTI_EMBED accepts videos up to 6 GB and 4 hours. The cap stays below
# that and also bounds the procedure''s temporary disk use.
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
    r"^D:(\\d{4})(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?([Zz+-])?(\\d{2})?''?(\\d{2})?"
)


class ApiAuthError(RuntimeError):
    """The API rejected the key; stop instead of logging one error per lesson."""


def get_api_key():
    """Read the student''s key from the secret bound to the procedure."""
    import _snowflake  # Available only inside Snowflake.

    return _snowflake.get_generic_secret_string(SECRET_ALIAS)


class ApiClient:
    """Small HTTP client with retries, an allowlisted redirect, and size caps."""

    def __init__(self, api_key, http=None, pause_seconds=REQUEST_PAUSE_SECONDS):
        if not api_key or not api_key.strip():
            raise ValueError("The dataexpert_api_key secret is empty")
        self.http = http or requests.Session()
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
        """Download a lesson''s slide PDF, or return None when it has none."""
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
        """Return (response, source_url, url_path) for a lesson''s video, or None."""
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
                    "VIDEO_HOSTS and to the instructor''s network rule."
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
        """Describe a lesson''s video without downloading it, or return None."""
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
        """Stream a lesson''s video into directory, or return None when it has none.

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
    """MP4 and MOV have an ''ftyp'' box at byte 4; WebM and MKV start with EBML."""
    return head[4:8] == b"ftyp" or head[:4] == b"\\x1aE\\xdf\\xa3"


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
    """Convert a PDF date such as D:20261117042906+00''00'' to ISO 8601."""
    match = PDF_DATE_PATTERN.match(value or "")
    if not match:
        return None
    year, month, day, hour, minute, second, sign, tz_h, tz_m = match.groups()
    text = (f"{year}-{month or ''01''}-{day or ''01''}T{hour or ''00''}:"
            f"{minute or ''00''}:{second or ''00''}")
    if sign in ("Z", "z"):
        return text + "+00:00"
    if sign in ("+", "-"):
        return f"{text}{sign}{tz_h or ''00''}:{tz_m or ''00''}"
    return text


def pdf_metadata(data):
    """Read page count and the PDF''s own document information dictionary."""
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
    stage_path = f"{slug}/{deck_id}/{slides[''filename'']}"
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
    """Download transcripts and slide PDFs for one program''s lessons."""
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
                video["source_url"], video["filename"], f"{stage_dir}/{video[''filename'']}",
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
';

CREATE OR REPLACE PROCEDURE "INGEST_VIDEOS"("PROGRAM_ID" NUMBER(38,0), "MAX_LESSONS" NUMBER(38,0) DEFAULT 40)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python','requests')
HANDLER = 'ingest_videos'
EXTERNAL_ACCESS_INTEGRATIONS = (DATAEXPERT_API_ACCESS)
SECRETS = ('dataexpert_api_key'=DATAEXPERT_API_KEY)
EXECUTE AS CALLER
AS '
"""Ingest DataExpert.io lessons, transcripts, slide PDFs, and videos into Snowflake.

These handlers run inside Python stored procedures created by
sql/02_ingest_procedures.sql and sql/12_video_procedure.sql (both generated
from this file by build_sql.py).
The API key comes from the Snowflake secret bound to the alias
''dataexpert_api_key''. It is sent only as a Bearer header to www.dataexpert.io.
It is never written to a table, a log, or a URL, and never sent to the slide
storage host.
"""
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
# Slide requests redirect to presigned URLs on this bucket. The instructor''s
# network rule must allow the same host.
SLIDE_HOSTS = frozenset({"techcreator.s3.us-west-2.amazonaws.com"})
# Video requests are assumed to redirect to the same bucket as slides. If they
# redirect somewhere else, the download fails and names the host: add it here
# and to the instructor''s network rule.
VIDEO_HOSTS = SLIDE_HOSTS
SECRET_ALIAS = "dataexpert_api_key"
SLIDE_STAGE = "@lesson_slides"
VIDEO_STAGE = "@lesson_videos"
USER_AGENT = "snowflake-unstructured-data-day-2-lab"

MAX_PDF_BYTES = 100 * 1024 * 1024  # AI_PARSE_DOCUMENT input limit
# AI_MULTI_EMBED accepts videos up to 6 GB and 4 hours. The cap stays below
# that and also bounds the procedure''s temporary disk use.
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
    r"^D:(\\d{4})(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?(\\d{2})?([Zz+-])?(\\d{2})?''?(\\d{2})?"
)


class ApiAuthError(RuntimeError):
    """The API rejected the key; stop instead of logging one error per lesson."""


def get_api_key():
    """Read the student''s key from the secret bound to the procedure."""
    import _snowflake  # Available only inside Snowflake.

    return _snowflake.get_generic_secret_string(SECRET_ALIAS)


class ApiClient:
    """Small HTTP client with retries, an allowlisted redirect, and size caps."""

    def __init__(self, api_key, http=None, pause_seconds=REQUEST_PAUSE_SECONDS):
        if not api_key or not api_key.strip():
            raise ValueError("The dataexpert_api_key secret is empty")
        self.http = http or requests.Session()
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
        """Download a lesson''s slide PDF, or return None when it has none."""
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
        """Return (response, source_url, url_path) for a lesson''s video, or None."""
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
                    "VIDEO_HOSTS and to the instructor''s network rule."
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
        """Describe a lesson''s video without downloading it, or return None."""
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
        """Stream a lesson''s video into directory, or return None when it has none.

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
    """MP4 and MOV have an ''ftyp'' box at byte 4; WebM and MKV start with EBML."""
    return head[4:8] == b"ftyp" or head[:4] == b"\\x1aE\\xdf\\xa3"


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
    """Convert a PDF date such as D:20261117042906+00''00'' to ISO 8601."""
    match = PDF_DATE_PATTERN.match(value or "")
    if not match:
        return None
    year, month, day, hour, minute, second, sign, tz_h, tz_m = match.groups()
    text = (f"{year}-{month or ''01''}-{day or ''01''}T{hour or ''00''}:"
            f"{minute or ''00''}:{second or ''00''}")
    if sign in ("Z", "z"):
        return text + "+00:00"
    if sign in ("+", "-"):
        return f"{text}{sign}{tz_h or ''00''}:{tz_m or ''00''}"
    return text


def pdf_metadata(data):
    """Read page count and the PDF''s own document information dictionary."""
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
    stage_path = f"{slug}/{deck_id}/{slides[''filename'']}"
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
    """Download transcripts and slide PDFs for one program''s lessons."""
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
                video["source_url"], video["filename"], f"{stage_dir}/{video[''filename'']}",
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
';

CREATE OR REPLACE PROCEDURE "RENDER_SLIDE_IMAGES"("MAX_WIDTH" NUMBER(38,0) DEFAULT 1600, "REBUILD" BOOLEAN DEFAULT FALSE)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python','pypdfium2','pillow')
HANDLER = 'render_slide_images'
EXECUTE AS CALLER
AS '
"""Render each staged slide PDF page to an image for multimodal embeddings.

AI_PARSE_DOCUMENT returns each page''s text. Extracting embedded images is
different from rendering the whole page, so this procedure draws every page,
including its layout, charts, and photos, into a PNG. It runs in Snowflake
(sql/10_slide_image_procedure.sql) using pypdfium2 from the Snowflake Anaconda
channel.
"""
import io

SOURCE_STAGE = "@lesson_slides"
IMAGE_STAGE = "@slide_images"
MAX_IMAGE_BYTES = int(4.5 * 1024 * 1024)  # Well under AI_EMBED''s 10 MB image limit.
MIN_WIDTH, MAX_WIDTH = 512, 2400


def render_page(page, max_width):
    """Return (bytes, extension, width, height) for one pdfium page."""
    width, _ = page.get_size()
    image = page.render(scale=min(max_width / width, 4.0)).to_pil().convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    extension = "png"
    if buffer.tell() > MAX_IMAGE_BYTES:
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=85)
        extension = "jpg"
    return buffer.getvalue(), extension, image.width, image.height


def render_slide_images(session, max_width=1600, rebuild=False):
    import pypdfium2 as pdfium

    max_width = int(max_width)
    if not MIN_WIDTH <= max_width <= MAX_WIDTH:
        raise ValueError(f"max_width must be between {MIN_WIDTH} and {MAX_WIDTH}")
    decks = session.sql(
        "SELECT deck_id, stage_path FROM slide_decks ORDER BY lesson_slug"
    ).collect()
    summary = {"decks": len(decks), "decks_rendered": 0, "decks_skipped": 0, "pages": 0}
    for deck_id, stage_path in decks:
        done = session.sql(
            "SELECT COUNT(*) FROM slide_images WHERE deck_id = ?", params=[deck_id]
        ).collect()[0][0]
        if done and not rebuild:
            summary["decks_skipped"] += 1
            continue
        session.sql("DELETE FROM slide_images WHERE deck_id = ?", params=[deck_id]).collect()
        session.sql(f"REMOVE {IMAGE_STAGE}/{deck_id}/").collect()
        pdf_bytes = session.file.get_stream(f"{SOURCE_STAGE}/{stage_path}").read()
        document = pdfium.PdfDocument(pdf_bytes)
        try:
            for page_index in range(len(document)):
                data, extension, width, height = render_page(document[page_index], max_width)
                image_path = f"{deck_id}/page_{page_index + 1:03d}.{extension}"
                session.file.put_stream(
                    io.BytesIO(data), f"{IMAGE_STAGE}/{image_path}",
                    auto_compress=False, overwrite=True,
                )
                session.sql(
                    """INSERT INTO slide_images
                         (slide_id, deck_id, page_index, page_number, image_path,
                          width_px, height_px, image_bytes)
                       SELECT ?, ?, ?, ?, ?, ?, ?, ?""",
                    params=[f"{deck_id}:p{page_index + 1:03d}", deck_id, page_index,
                            page_index + 1, image_path, width, height, len(data)],
                ).collect()
                summary["pages"] += 1
        finally:
            document.close()
        summary["decks_rendered"] += 1
    if summary["decks_rendered"]:
        session.sql("ALTER STAGE slide_images REFRESH").collect()
    return summary
';

CREATE OR REPLACE PROCEDURE "RUN_ANSWER_EVAL"("TOP_K" NUMBER(38,0) DEFAULT 6, "ANSWER_MODEL" VARCHAR DEFAULT 'claude-sonnet-4-5', "JUDGE_MODEL" VARCHAR DEFAULT 'llama3.3-70b', "JUDGE_PROMPT_VERSION" VARCHAR DEFAULT 'v1', "JUDGE_TEMPERATURE" FLOAT DEFAULT 0, "SERVICE_NAME" VARCHAR DEFAULT 'course_search', "RUN_ID" VARCHAR DEFAULT 'manual')
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_answer_eval'
EXECUTE AS CALLER
AS '
"""Ask cited questions and evaluate retrieval with the course_search service.

SNOWFLAKE.CORTEX.SEARCH_PREVIEW accepts only constant arguments. These
procedures therefore build one escaped literal per query, which lets a table
of evaluation questions drive Cortex Search. Production apps would use the
Cortex Search Python or REST API instead.
"""
import json
import re

SERVICE_NAME = "course_search"
RESULT_COLUMNS = ["source_id", "source_type", "lesson_slug", "citation", "search_text"]
SOURCE_TYPES = {"transcript", "slide", "faq"}
MODEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{1,80}$")
# A service name is spliced into SQL text, so it must be a plain (optionally qualified) identifier.
SERVICE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$")
METHOD_LABEL_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
PURPOSE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
NOT_FOUND = "I could not find that in the course materials."

PROMPT_TEMPLATE = """You answer questions from DataExpert.io boot camp students.
Use only the numbered sources below. Cite every claim with its source number, like [2].
If the sources do not answer the question, reply with exactly: {not_found}

Sources:
{context}

Question: {question}
Answer:"""

# Judge prompt for step 9e. Bump $judge_prompt_version in sql/runbook_config.sql when this changes.
JUDGE_PROMPTS = {
    "v1": """You grade one answer from a course question-answering assistant.
Use only the numbered sources shown. Score each item from 1 (worst) to 5 (best).
- groundedness: every claim in the answer is supported by the sources. If the answer is a
  refusal, score 5 when the sources really do not answer the question, otherwise 1.
- answer_relevance: the answer addresses the question that was asked.
- context_relevance: the sources are about the question.
- refused: true if the answer declines to answer (for example, says it could not find it).
- rationale: one short sentence.

Sources:
{context}

Question: {question}

Answer:
{answer}""",
}
JUDGE_SCHEMA = {
    "type": "json",
    "schema": {
        "type": "object",
        "properties": {
            "groundedness": {"type": "integer"},
            "answer_relevance": {"type": "integer"},
            "context_relevance": {"type": "integer"},
            "refused": {"type": "boolean"},
            "rationale": {"type": "string"},
        },
        "required": ["groundedness", "answer_relevance", "context_relevance", "refused", "rationale"],
    },
}


def sql_literal(value):
    """Quote text as a Snowflake single-quoted literal (backslashes are escapes)."""
    return "''" + value.replace("\\\\", "\\\\\\\\").replace("''", "''''") + "''"


def search(session, query, limit=5, source_type=None, service_name=SERVICE_NAME):
    query = (query or "").strip()
    if not query or len(query) > 2000:
        raise ValueError("query must contain 1 to 2000 characters")
    limit = int(limit)
    if not 1 <= limit <= 50:
        raise ValueError("limit must be between 1 and 50")
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    request = {"query": query, "columns": RESULT_COLUMNS, "limit": limit}
    if source_type:
        if source_type not in SOURCE_TYPES:
            raise ValueError(f"source_type must be one of {sorted(SOURCE_TYPES)}")
        request["filter"] = {"@eq": {"source_type": source_type}}
    statement = (f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW({sql_literal(service_name)}, "
                 f"{sql_literal(json.dumps(request))})")
    raw = session.sql(statement).collect()[0][0]
    return json.loads(raw).get("results", [])


def completion_text(raw):
    """AI_COMPLETE returns a string; tolerate a JSON response with choices too."""
    if raw is None:
        return None
    text = raw if isinstance(raw, str) else json.dumps(raw)
    try:
        parsed = json.loads(text)
    except ValueError:
        return text.strip()
    if isinstance(parsed, dict) and parsed.get("choices"):
        choice = parsed["choices"][0]
        return (choice.get("messages") or choice.get("message") or "").strip()
    return parsed.strip() if isinstance(parsed, str) else text.strip()


def usage_tokens(raw):
    """(prompt_tokens, completion_tokens) from an AI_COMPLETE show_details response, else (None, None)."""
    try:
        usage = json.loads(raw if isinstance(raw, str) else json.dumps(raw)).get("usage") or {}
        return usage.get("prompt_tokens"), usage.get("completion_tokens")
    except (ValueError, AttributeError):
        return None, None


def build_prompt(question, results):
    context = "\\n\\n".join(
        f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
    )
    return PROMPT_TEMPLATE.format(
        not_found=NOT_FOUND, context=context or "(no sources found)", question=question
    )


def complete(session, model, prompt, temperature=0, max_tokens=800, response_format=None):
    """One AI_COMPLETE call with show_details, so token usage comes back with the answer."""
    if not MODEL_PATTERN.match(model or ""):
        raise ValueError("model must be a Snowflake model name such as claude-sonnet-4-5")
    temperature = float(temperature)
    if not 0 <= temperature <= 1:
        raise ValueError("temperature must be between 0 and 1")
    fmt = ", response_format => PARSE_JSON(?)" if response_format else ""
    params = [prompt] + ([json.dumps(response_format)] if response_format else [])
    raw = session.sql(
        f"SELECT AI_COMPLETE(model => {sql_literal(model)}, prompt => ?, "
        f"model_parameters => {{''temperature'': {temperature}, ''max_tokens'': {int(max_tokens)}}}"
        f"{fmt}, show_details => TRUE)",
        params=params,
    ).collect()[0][0]
    return raw


def answer_question(session, question, top_k, answer_model, service_name=SERVICE_NAME):
    """Retrieve with Cortex Search and answer with AI_COMPLETE. Returns answer, sources, results, tokens."""
    top_k = int(top_k)
    if not 1 <= top_k <= 20:
        raise ValueError("top_k must be between 1 and 20")
    question = (question or "").strip()
    results = search(session, question, top_k, service_name=service_name)
    raw = complete(session, answer_model, build_prompt(question, results))
    sources = [
        {"n": n, "source_id": r.get("source_id"), "citation": r.get("citation")}
        for n, r in enumerate(results, 1)
    ]
    return completion_text(raw), sources, results, usage_tokens(raw)


def log_answer(session, question, answer_model, answer, sources, purpose, run_id, tokens):
    # One JSON row instead of separate binds: inside a procedure a bound Python None arrives as
    # the text ''None'', while JSON null reads back as SQL NULL.
    row = {"question": question, "answer_model": answer_model, "answer": answer, "sources": sources,
           "run_id": run_id, "purpose": purpose, "input_tokens": tokens[0], "output_tokens": tokens[1]}
    session.sql(
        """INSERT INTO ask_log (question, answer_model, answer, sources, run_id, purpose,
                                input_tokens, output_tokens)
           SELECT r:question::VARCHAR, r:answer_model::VARCHAR, r:answer::VARCHAR, r:sources,
                  r:run_id::VARCHAR, r:purpose::VARCHAR, r:input_tokens::NUMBER, r:output_tokens::NUMBER
           FROM (SELECT PARSE_JSON(?) AS r)""",
        params=[json.dumps(row)],
    ).collect()


def ask_course(session, question, top_k=6, answer_model="claude-sonnet-4-5", purpose="adhoc", run_id=None):
    """Retrieve with Cortex Search, answer with AI_COMPLETE, and log the result.

    purpose and run_id tag the ask_log row: ''adhoc'' for hand-run questions, ''eval'' for step 9e.
    """
    purpose = (purpose or "adhoc").strip().lower()
    if not PURPOSE_PATTERN.match(purpose):
        raise ValueError("purpose must be lower-case letters, digits or _, such as adhoc")
    answer, sources, _, tokens = answer_question(session, question, top_k, answer_model)
    log_answer(session, (question or "").strip(), answer_model, answer, sources, purpose, run_id, tokens)
    return {"question": (question or "").strip(), "answer": answer, "sources": sources}


def run_search_eval(session, top_k=10, service_name=SERVICE_NAME, method_label="CORTEX_SEARCH"):
    """Store the top-k Cortex Search results for every answerable eval question.

    service_name picks the service to search, so a baseline service (for example
    course_search_before_desc) can be scored without editing this module.
    method_label is the method value written to retrieval_results; only rows with
    that label are replaced, so other methods and other labels are kept.
    Each row keeps the service''s @scores (cosine_similarity, text_match, reranker_score).
    """
    top_k = int(top_k)
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    method_label = (method_label or "").strip().upper()
    if not METHOD_LABEL_PATTERN.match(method_label):
        raise ValueError("method_label must be upper-case letters, digits or _, such as CORTEX_SEARCH")
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions WHERE answerable ORDER BY question_id"
    ).collect()
    rows = []
    for question_id, question in questions:
        for rank, result in enumerate(search(session, question, top_k, service_name=service_name), 1):
            scores = result.get("@scores") or {}
            rows.append([method_label, question_id, rank, result.get("source_id"),
                         scores.get("cosine_similarity"), scores.get("text_match"),
                         scores.get("reranker_score")])
    session.sql("DELETE FROM retrieval_results WHERE method = ?", params=[method_label]).collect()
    if rows:
        session.create_dataframe(
            rows, schema=["METHOD", "QUESTION_ID", "RESULT_RANK", "SOURCE_ID",
                          "SCORE_COSINE", "SCORE_TEXT", "SCORE_RERANK"]
        ).write.mode("append").save_as_table("retrieval_results", column_order="name")
    return {"method": method_label, "service": service_name,
            "questions": len(questions), "rows": len(rows)}


def run_answer_eval(session, top_k=6, answer_model="claude-sonnet-4-5", judge_model="llama3.3-70b",
                    judge_prompt_version="v1", judge_temperature=0, service_name=SERVICE_NAME, run_id="manual"):
    """Step 9e: answer every eval question (answerable and not), then grade each answer with a judge.

    Answers are logged to ask_log with purpose ''eval'' and this run_id. Judgments go to
    answer_judgments (this run''s rows are replaced). The judge sees the same sources the
    answer model saw. Token usage of both calls is stored for cost.
    """
    if judge_prompt_version not in JUDGE_PROMPTS:
        raise ValueError(f"judge_prompt_version must be one of {sorted(JUDGE_PROMPTS)}")
    if not MODEL_PATTERN.match(judge_model or ""):
        raise ValueError("judge_model must be a Snowflake model name such as llama3.3-70b")
    run_id = (run_id or "manual").strip()
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions ORDER BY question_id"
    ).collect()
    session.sql("DELETE FROM answer_judgments WHERE run_id = ?", params=[run_id]).collect()
    done, failed = 0, 0
    for question_id, question in questions:
        answer, sources, results, tokens = answer_question(session, question, top_k, answer_model, service_name)
        log_answer(session, question, answer_model, answer, sources, "eval", run_id, tokens)
        context = "\\n\\n".join(
            f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
        ) or "(no sources found)"
        prompt = JUDGE_PROMPTS[judge_prompt_version].format(context=context, question=question, answer=answer)
        grade, judge_raw, judge_error = {}, None, None
        try:
            judge_raw = complete(session, judge_model, prompt, judge_temperature, 400, JUDGE_SCHEMA)
            parsed = json.loads(judge_raw if isinstance(judge_raw, str) else json.dumps(judge_raw))
            grade = (parsed.get("structured_output") or [{}])[0].get("raw_message") or {}
        except Exception as exc:   # keep the answer; record why the grade is missing
            judge_error = str(exc)[:500]
        judge_tokens = usage_tokens(judge_raw) if judge_raw else (None, None)
        clamp = lambda v: max(1, min(5, int(v))) if isinstance(v, (int, float)) else None
        row = {"run_id": run_id, "question_id": question_id, "question": question,
               "answer_model": answer_model, "gen_top_k": int(top_k), "answer": answer, "sources": sources,
               "judge_model": judge_model, "judge_prompt_version": judge_prompt_version,
               "groundedness": clamp(grade.get("groundedness")),
               "answer_relevance": clamp(grade.get("answer_relevance")),
               "context_relevance": clamp(grade.get("context_relevance")),
               "refused": grade.get("refused") if isinstance(grade.get("refused"), bool) else None,
               "rationale": grade.get("rationale"), "judge_error": judge_error,
               "answer_input_tokens": tokens[0], "answer_output_tokens": tokens[1],
               "judge_input_tokens": judge_tokens[0], "judge_output_tokens": judge_tokens[1]}
        session.sql(
            """INSERT INTO answer_judgments (run_id, question_id, question, answer_model, gen_top_k, answer,
                 sources, judge_model, judge_prompt_version, groundedness, answer_relevance,
                 context_relevance, refused, rationale, judge_error, answer_input_tokens,
                 answer_output_tokens, judge_input_tokens, judge_output_tokens, judged_at)
               SELECT r:run_id::VARCHAR, r:question_id::VARCHAR, r:question::VARCHAR, r:answer_model::VARCHAR,
                      r:gen_top_k::NUMBER, r:answer::VARCHAR, r:sources, r:judge_model::VARCHAR,
                      r:judge_prompt_version::VARCHAR, r:groundedness::NUMBER, r:answer_relevance::NUMBER,
                      r:context_relevance::NUMBER, r:refused::BOOLEAN, r:rationale::VARCHAR,
                      r:judge_error::VARCHAR, r:answer_input_tokens::NUMBER, r:answer_output_tokens::NUMBER,
                      r:judge_input_tokens::NUMBER, r:judge_output_tokens::NUMBER, CURRENT_TIMESTAMP()
               FROM (SELECT PARSE_JSON(?) AS r)""",
            params=[json.dumps(row)],
        ).collect()
        failed += judge_error is not None
        done += 1
    return {"run_id": run_id, "questions": len(questions), "judged": done - failed, "judge_errors": failed}
';

CREATE OR REPLACE PROCEDURE "RUN_SEARCH_EVAL"("TOP_K" NUMBER(38,0) DEFAULT 10, "SERVICE_NAME" VARCHAR DEFAULT 'course_search', "METHOD_LABEL" VARCHAR DEFAULT 'CORTEX_SEARCH')
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_search_eval'
EXECUTE AS CALLER
AS '
"""Ask cited questions and evaluate retrieval with the course_search service.

SNOWFLAKE.CORTEX.SEARCH_PREVIEW accepts only constant arguments. These
procedures therefore build one escaped literal per query, which lets a table
of evaluation questions drive Cortex Search. Production apps would use the
Cortex Search Python or REST API instead.
"""
import json
import re

SERVICE_NAME = "course_search"
RESULT_COLUMNS = ["source_id", "source_type", "lesson_slug", "citation", "search_text"]
SOURCE_TYPES = {"transcript", "slide", "faq"}
MODEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{1,80}$")
# A service name is spliced into SQL text, so it must be a plain (optionally qualified) identifier.
SERVICE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$")
METHOD_LABEL_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
PURPOSE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
NOT_FOUND = "I could not find that in the course materials."

PROMPT_TEMPLATE = """You answer questions from DataExpert.io boot camp students.
Use only the numbered sources below. Cite every claim with its source number, like [2].
If the sources do not answer the question, reply with exactly: {not_found}

Sources:
{context}

Question: {question}
Answer:"""

# Judge prompt for step 9e. Bump $judge_prompt_version in sql/runbook_config.sql when this changes.
JUDGE_PROMPTS = {
    "v1": """You grade one answer from a course question-answering assistant.
Use only the numbered sources shown. Score each item from 1 (worst) to 5 (best).
- groundedness: every claim in the answer is supported by the sources. If the answer is a
  refusal, score 5 when the sources really do not answer the question, otherwise 1.
- answer_relevance: the answer addresses the question that was asked.
- context_relevance: the sources are about the question.
- refused: true if the answer declines to answer (for example, says it could not find it).
- rationale: one short sentence.

Sources:
{context}

Question: {question}

Answer:
{answer}""",
}
JUDGE_SCHEMA = {
    "type": "json",
    "schema": {
        "type": "object",
        "properties": {
            "groundedness": {"type": "integer"},
            "answer_relevance": {"type": "integer"},
            "context_relevance": {"type": "integer"},
            "refused": {"type": "boolean"},
            "rationale": {"type": "string"},
        },
        "required": ["groundedness", "answer_relevance", "context_relevance", "refused", "rationale"],
    },
}


def sql_literal(value):
    """Quote text as a Snowflake single-quoted literal (backslashes are escapes)."""
    return "''" + value.replace("\\\\", "\\\\\\\\").replace("''", "''''") + "''"


def search(session, query, limit=5, source_type=None, service_name=SERVICE_NAME):
    query = (query or "").strip()
    if not query or len(query) > 2000:
        raise ValueError("query must contain 1 to 2000 characters")
    limit = int(limit)
    if not 1 <= limit <= 50:
        raise ValueError("limit must be between 1 and 50")
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    request = {"query": query, "columns": RESULT_COLUMNS, "limit": limit}
    if source_type:
        if source_type not in SOURCE_TYPES:
            raise ValueError(f"source_type must be one of {sorted(SOURCE_TYPES)}")
        request["filter"] = {"@eq": {"source_type": source_type}}
    statement = (f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW({sql_literal(service_name)}, "
                 f"{sql_literal(json.dumps(request))})")
    raw = session.sql(statement).collect()[0][0]
    return json.loads(raw).get("results", [])


def completion_text(raw):
    """AI_COMPLETE returns a string; tolerate a JSON response with choices too."""
    if raw is None:
        return None
    text = raw if isinstance(raw, str) else json.dumps(raw)
    try:
        parsed = json.loads(text)
    except ValueError:
        return text.strip()
    if isinstance(parsed, dict) and parsed.get("choices"):
        choice = parsed["choices"][0]
        return (choice.get("messages") or choice.get("message") or "").strip()
    return parsed.strip() if isinstance(parsed, str) else text.strip()


def usage_tokens(raw):
    """(prompt_tokens, completion_tokens) from an AI_COMPLETE show_details response, else (None, None)."""
    try:
        usage = json.loads(raw if isinstance(raw, str) else json.dumps(raw)).get("usage") or {}
        return usage.get("prompt_tokens"), usage.get("completion_tokens")
    except (ValueError, AttributeError):
        return None, None


def build_prompt(question, results):
    context = "\\n\\n".join(
        f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
    )
    return PROMPT_TEMPLATE.format(
        not_found=NOT_FOUND, context=context or "(no sources found)", question=question
    )


def complete(session, model, prompt, temperature=0, max_tokens=800, response_format=None):
    """One AI_COMPLETE call with show_details, so token usage comes back with the answer."""
    if not MODEL_PATTERN.match(model or ""):
        raise ValueError("model must be a Snowflake model name such as claude-sonnet-4-5")
    temperature = float(temperature)
    if not 0 <= temperature <= 1:
        raise ValueError("temperature must be between 0 and 1")
    fmt = ", response_format => PARSE_JSON(?)" if response_format else ""
    params = [prompt] + ([json.dumps(response_format)] if response_format else [])
    raw = session.sql(
        f"SELECT AI_COMPLETE(model => {sql_literal(model)}, prompt => ?, "
        f"model_parameters => {{''temperature'': {temperature}, ''max_tokens'': {int(max_tokens)}}}"
        f"{fmt}, show_details => TRUE)",
        params=params,
    ).collect()[0][0]
    return raw


def answer_question(session, question, top_k, answer_model, service_name=SERVICE_NAME):
    """Retrieve with Cortex Search and answer with AI_COMPLETE. Returns answer, sources, results, tokens."""
    top_k = int(top_k)
    if not 1 <= top_k <= 20:
        raise ValueError("top_k must be between 1 and 20")
    question = (question or "").strip()
    results = search(session, question, top_k, service_name=service_name)
    raw = complete(session, answer_model, build_prompt(question, results))
    sources = [
        {"n": n, "source_id": r.get("source_id"), "citation": r.get("citation")}
        for n, r in enumerate(results, 1)
    ]
    return completion_text(raw), sources, results, usage_tokens(raw)


def log_answer(session, question, answer_model, answer, sources, purpose, run_id, tokens):
    # One JSON row instead of separate binds: inside a procedure a bound Python None arrives as
    # the text ''None'', while JSON null reads back as SQL NULL.
    row = {"question": question, "answer_model": answer_model, "answer": answer, "sources": sources,
           "run_id": run_id, "purpose": purpose, "input_tokens": tokens[0], "output_tokens": tokens[1]}
    session.sql(
        """INSERT INTO ask_log (question, answer_model, answer, sources, run_id, purpose,
                                input_tokens, output_tokens)
           SELECT r:question::VARCHAR, r:answer_model::VARCHAR, r:answer::VARCHAR, r:sources,
                  r:run_id::VARCHAR, r:purpose::VARCHAR, r:input_tokens::NUMBER, r:output_tokens::NUMBER
           FROM (SELECT PARSE_JSON(?) AS r)""",
        params=[json.dumps(row)],
    ).collect()


def ask_course(session, question, top_k=6, answer_model="claude-sonnet-4-5", purpose="adhoc", run_id=None):
    """Retrieve with Cortex Search, answer with AI_COMPLETE, and log the result.

    purpose and run_id tag the ask_log row: ''adhoc'' for hand-run questions, ''eval'' for step 9e.
    """
    purpose = (purpose or "adhoc").strip().lower()
    if not PURPOSE_PATTERN.match(purpose):
        raise ValueError("purpose must be lower-case letters, digits or _, such as adhoc")
    answer, sources, _, tokens = answer_question(session, question, top_k, answer_model)
    log_answer(session, (question or "").strip(), answer_model, answer, sources, purpose, run_id, tokens)
    return {"question": (question or "").strip(), "answer": answer, "sources": sources}


def run_search_eval(session, top_k=10, service_name=SERVICE_NAME, method_label="CORTEX_SEARCH"):
    """Store the top-k Cortex Search results for every answerable eval question.

    service_name picks the service to search, so a baseline service (for example
    course_search_before_desc) can be scored without editing this module.
    method_label is the method value written to retrieval_results; only rows with
    that label are replaced, so other methods and other labels are kept.
    Each row keeps the service''s @scores (cosine_similarity, text_match, reranker_score).
    """
    top_k = int(top_k)
    if not SERVICE_PATTERN.match(service_name or ""):
        raise ValueError("service_name must be a Cortex Search service name such as course_search")
    method_label = (method_label or "").strip().upper()
    if not METHOD_LABEL_PATTERN.match(method_label):
        raise ValueError("method_label must be upper-case letters, digits or _, such as CORTEX_SEARCH")
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions WHERE answerable ORDER BY question_id"
    ).collect()
    rows = []
    for question_id, question in questions:
        for rank, result in enumerate(search(session, question, top_k, service_name=service_name), 1):
            scores = result.get("@scores") or {}
            rows.append([method_label, question_id, rank, result.get("source_id"),
                         scores.get("cosine_similarity"), scores.get("text_match"),
                         scores.get("reranker_score")])
    session.sql("DELETE FROM retrieval_results WHERE method = ?", params=[method_label]).collect()
    if rows:
        session.create_dataframe(
            rows, schema=["METHOD", "QUESTION_ID", "RESULT_RANK", "SOURCE_ID",
                          "SCORE_COSINE", "SCORE_TEXT", "SCORE_RERANK"]
        ).write.mode("append").save_as_table("retrieval_results", column_order="name")
    return {"method": method_label, "service": service_name,
            "questions": len(questions), "rows": len(rows)}


def run_answer_eval(session, top_k=6, answer_model="claude-sonnet-4-5", judge_model="llama3.3-70b",
                    judge_prompt_version="v1", judge_temperature=0, service_name=SERVICE_NAME, run_id="manual"):
    """Step 9e: answer every eval question (answerable and not), then grade each answer with a judge.

    Answers are logged to ask_log with purpose ''eval'' and this run_id. Judgments go to
    answer_judgments (this run''s rows are replaced). The judge sees the same sources the
    answer model saw. Token usage of both calls is stored for cost.
    """
    if judge_prompt_version not in JUDGE_PROMPTS:
        raise ValueError(f"judge_prompt_version must be one of {sorted(JUDGE_PROMPTS)}")
    if not MODEL_PATTERN.match(judge_model or ""):
        raise ValueError("judge_model must be a Snowflake model name such as llama3.3-70b")
    run_id = (run_id or "manual").strip()
    questions = session.sql(
        "SELECT question_id, question FROM eval_questions ORDER BY question_id"
    ).collect()
    session.sql("DELETE FROM answer_judgments WHERE run_id = ?", params=[run_id]).collect()
    done, failed = 0, 0
    for question_id, question in questions:
        answer, sources, results, tokens = answer_question(session, question, top_k, answer_model, service_name)
        log_answer(session, question, answer_model, answer, sources, "eval", run_id, tokens)
        context = "\\n\\n".join(
            f"[{n}] {r.get(''citation'')}\\n{r.get(''search_text'')}" for n, r in enumerate(results, 1)
        ) or "(no sources found)"
        prompt = JUDGE_PROMPTS[judge_prompt_version].format(context=context, question=question, answer=answer)
        grade, judge_raw, judge_error = {}, None, None
        try:
            judge_raw = complete(session, judge_model, prompt, judge_temperature, 400, JUDGE_SCHEMA)
            parsed = json.loads(judge_raw if isinstance(judge_raw, str) else json.dumps(judge_raw))
            grade = (parsed.get("structured_output") or [{}])[0].get("raw_message") or {}
        except Exception as exc:   # keep the answer; record why the grade is missing
            judge_error = str(exc)[:500]
        judge_tokens = usage_tokens(judge_raw) if judge_raw else (None, None)
        clamp = lambda v: max(1, min(5, int(v))) if isinstance(v, (int, float)) else None
        row = {"run_id": run_id, "question_id": question_id, "question": question,
               "answer_model": answer_model, "gen_top_k": int(top_k), "answer": answer, "sources": sources,
               "judge_model": judge_model, "judge_prompt_version": judge_prompt_version,
               "groundedness": clamp(grade.get("groundedness")),
               "answer_relevance": clamp(grade.get("answer_relevance")),
               "context_relevance": clamp(grade.get("context_relevance")),
               "refused": grade.get("refused") if isinstance(grade.get("refused"), bool) else None,
               "rationale": grade.get("rationale"), "judge_error": judge_error,
               "answer_input_tokens": tokens[0], "answer_output_tokens": tokens[1],
               "judge_input_tokens": judge_tokens[0], "judge_output_tokens": judge_tokens[1]}
        session.sql(
            """INSERT INTO answer_judgments (run_id, question_id, question, answer_model, gen_top_k, answer,
                 sources, judge_model, judge_prompt_version, groundedness, answer_relevance,
                 context_relevance, refused, rationale, judge_error, answer_input_tokens,
                 answer_output_tokens, judge_input_tokens, judge_output_tokens, judged_at)
               SELECT r:run_id::VARCHAR, r:question_id::VARCHAR, r:question::VARCHAR, r:answer_model::VARCHAR,
                      r:gen_top_k::NUMBER, r:answer::VARCHAR, r:sources, r:judge_model::VARCHAR,
                      r:judge_prompt_version::VARCHAR, r:groundedness::NUMBER, r:answer_relevance::NUMBER,
                      r:context_relevance::NUMBER, r:refused::BOOLEAN, r:rationale::VARCHAR,
                      r:judge_error::VARCHAR, r:answer_input_tokens::NUMBER, r:answer_output_tokens::NUMBER,
                      r:judge_input_tokens::NUMBER, r:judge_output_tokens::NUMBER, CURRENT_TIMESTAMP()
               FROM (SELECT PARSE_JSON(?) AS r)""",
            params=[json.dumps(row)],
        ).collect()
        failed += judge_error is not None
        done += 1
    return {"run_id": run_id, "questions": len(questions), "judged": done - failed, "judge_errors": failed}
';
