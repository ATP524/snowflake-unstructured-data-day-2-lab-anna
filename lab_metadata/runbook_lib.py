"""Runbook engine for the Day 2 lab pipeline. Used by pipeline_runbook.ipynb.

The .sql files in sql/ stay the source of truth. Each runnable piece of a file
sits between comment markers:

    -- @runbook:begin 06a.build role=BUILD cost=none reads=a,b writes=c config=x purpose=...
    ...statements and the author's comments...
    -- @runbook:end 06a.build

This module reads those markers, decides which steps need to run from content
fingerprints and recorded history, runs only the chosen sections, checks their
results, and records every step of every run in Snowflake tables.

Roles: BUILD (creates or updates pipeline objects), CHECK (validation queries,
with optional expectations), OUTPUT (key results), EXPLORE (educational and
ad-hoc queries, never run by the runbook), EXPERIMENT (hand-run before/after
versions; the runbook runs label-driven equivalents), DEFINE (procedures).
"""
import datetime
import hashlib
import json
import math
import re
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd

# ---------------------------------------------------------------------------
# Pipeline shape
# ---------------------------------------------------------------------------
# Run order follows dependencies, not file numbers: 11e must run before 06a,
# because 06a reads slide_descriptions.
PIPELINE_ORDER = [
    "01", "02", "08", "10", "12",            # setup objects and procedures
    "03a", "03d",                            # external ingest
    "04b", "05a", "05c",                     # chunk transcripts, parse slides
    "11a", "11b", "11e",                     # render, embed and describe slides
    "06a", "06b", "07a",                     # corpus, embeddings, search service
    "09b", "09c", "11d", "09d",              # eval set, retrieval, scores
    "09e",                                   # optional answer quality (AI_COMPLETE answer + judge)
    "13a", "13b", "13c", "13d", "13f",       # optional video path
]
VIDEO_STEPS = {"12", "13a", "13b", "13c", "13d", "13f"}
ANSWER_STEPS = {"09e"}
EXTERNAL_STEPS = {"03a", "03d", "13b"}
RECORD_TABLES = ("runbook_runs", "runbook_step_runs", "runbook_source_freshness",
                 "retrieval_question_scores_history", "retrieval_scores_history_legacy",
                 "slide_descriptions_history", "runbook_ai_usage", "hitl_reviews")
LABEL_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]{0,40}$")
METRIC_K = 10                 # every metric is computed at @10, whatever $eval_top_k is
MIN_SHARED_QUESTIONS = 15     # an overall verdict needs at least this many shared questions
MIN_SLICE_QUESTIONS = 20      # a slice below this shows counts only, no verdict
SIGN_TEST_ALPHA = 0.05

MARKER_BEGIN = re.compile(r"^\s*--\s*@runbook:begin\s+(\S+)\s*(.*)$")
MARKER_END = re.compile(r"^\s*--\s*@runbook:end\s+(\S+)\s*$")


# ---------------------------------------------------------------------------
# Parsing the .sql files
# ---------------------------------------------------------------------------
@dataclass
class Section:
    id: str
    file: str
    start_line: int
    end_line: int
    sql: str
    attrs: dict

    @property
    def step(self):
        return self.id.split(".", 1)[0]

    @property
    def role(self):
        return self.attrs.get("role", "").upper()

    @property
    def cost(self):
        return self.attrs.get("cost", "none")

    def items(self, key):
        value = self.attrs.get(key, "")
        return [v.strip() for v in value.split(",") if v.strip()]

    @property
    def purpose(self):
        return self.attrs.get("purpose", "")

    @property
    def location(self):
        return f"sql/{self.file}:{self.start_line}-{self.end_line}"


def parse_attrs(text):
    """key=value pairs; purpose= is last and takes the rest of the line."""
    attrs = {}
    if "purpose=" in text:
        text, purpose = text.split("purpose=", 1)
        attrs["purpose"] = purpose.strip()
    for token in text.split():
        if "=" in token:
            key, value = token.split("=", 1)
            attrs[key.lower()] = value
    return attrs


def parse_sections(sql_dir):
    sections = {}
    for path in sorted(Path(sql_dir).glob("*.sql")):
        lines = path.read_text(encoding="utf-8").splitlines()
        open_id, open_attrs, start, body = None, None, None, []
        for number, line in enumerate(lines, 1):
            begin, end = MARKER_BEGIN.match(line), MARKER_END.match(line)
            if begin:
                if open_id:
                    raise ValueError(f"{path.name}:{number}: {begin.group(1)} begins inside {open_id}")
                open_id, open_attrs, start, body = begin.group(1), parse_attrs(begin.group(2)), number, []
            elif end:
                if end.group(1) != open_id:
                    raise ValueError(f"{path.name}:{number}: end {end.group(1)} does not match {open_id}")
                if open_id in sections:
                    raise ValueError(f"{path.name}:{number}: duplicate section {open_id}")
                sections[open_id] = Section(open_id, path.name, start + 1, number - 1,
                                            "\n".join(body), open_attrs)
                open_id = None
            elif open_id:
                body.append(line)
        if open_id:
            raise ValueError(f"{path.name}: section {open_id} is never ended")
    return sections


def split_statements(sql):
    """Split SQL on top-level semicolons, respecting quotes, comments and $$ bodies."""
    statements, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c, nxt = sql[i], sql[i + 1] if i + 1 < n else ""
        if c == "'":                                   # string literal ('' and \ escapes)
            j = i + 1
            while j < n:
                if sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(sql[i:j + 1])
            i = j + 1
        elif c == '"':
            j = sql.find('"', i + 1)
            j = n - 1 if j < 0 else j
            buf.append(sql[i:j + 1])
            i = j + 1
        elif c == "$" and nxt == "$":
            j = sql.find("$$", i + 2)
            j = n - 2 if j < 0 else j
            buf.append(sql[i:j + 2])
            i = j + 2
        elif (c == "-" and nxt == "-") or (c == "/" and nxt == "/"):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            buf.append(sql[i:j])
            i = j
        elif c == "/" and nxt == "*":
            j = sql.find("*/", i + 2)
            j = n - 2 if j < 0 else j
            buf.append(sql[i:j + 2])
            i = j + 2
        elif c == ";":
            statements.append("".join(buf))
            buf, i = [], i + 1
        else:
            buf.append(c)
            i += 1
    statements.append("".join(buf))
    return [s.strip() for s in statements if strip_comments(s).strip()]


def strip_comments(sql):
    """Remove comments outside strings and $$ bodies (used for hashing and keyword checks)."""
    out, i, n = [], 0, len(sql)
    while i < n:
        c, nxt = sql[i], sql[i + 1] if i + 1 < n else ""
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            out.append(sql[i:j + 1])
            i = j + 1
        elif c == "$" and nxt == "$":
            j = sql.find("$$", i + 2)
            j = n - 2 if j < 0 else j
            out.append(sql[i:j + 2])
            i = j + 2
        elif (c == "-" and nxt == "-") or (c == "/" and nxt == "/"):
            j = sql.find("\n", i)
            i = n if j < 0 else j
        elif c == "/" and nxt == "*":
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def code_hash(sql):
    """Hash of the SQL with comments and whitespace removed, so comment edits don't count."""
    normalized = re.sub(r"\s+", " ", strip_comments(sql)).strip()
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]


def parse_config(config_path):
    """Read sql/runbook_config.sql: the one place shared values are set."""
    statements, values = [], {}
    for line in Path(config_path).read_text(encoding="utf-8").splitlines():
        body = strip_comments(line).strip()
        if not body:
            continue
        statements.append(body.rstrip(";"))
        m = re.match(r"(?i)^SET\s+(\w+)\s*=\s*(.+?);?$", body)
        if m:
            raw = m.group(2).strip()
            values[m.group(1).lower()] = (raw[1:-1] if raw.startswith("'") and raw.endswith("'")
                                          else int(raw) if re.fullmatch(r"-?\d+", raw) else raw)
        m = re.match(r"(?i)^USE\s+(ROLE|DATABASE|WAREHOUSE|SCHEMA)\s+(\S+?);?$", body)
        if m:
            values[m.group(1).lower()] = m.group(2)
    return statements, values


# ---------------------------------------------------------------------------
# Runbook
# ---------------------------------------------------------------------------
@dataclass
class Decision:
    step: str
    action: str            # RUN, SKIP, DRIFT, NOT_INCLUDED
    reasons: list
    cost: str
    estimate: str = ""
    upstream_only: bool = False
    inputs: dict = field(default_factory=dict)


class Runbook:
    def __init__(self, session, workspace_dir, options):
        self.session = session
        self.root = Path(workspace_dir)
        self.sql_dir = self.root / "sql"
        self.options = options
        self.run_id = uuid.uuid4().hex[:12]
        self.sections = parse_sections(self.sql_dir)
        self.config_statements, self.config = parse_config(self.sql_dir / "runbook_config.sql")
        self.plan = {}
        self.freshness = None
        self._kinds = None
        self.halted_reason = None      # set by halt(); every build, snapshot and scoring call checks it
        self.verdicts = []             # sign-test verdicts of this run, saved in runbook_runs.summary

    # -- halting ----------------------------------------------------------------
    def halt(self, reason, status=None):
        """Stop this run: later build, snapshot, experiment and scoring calls refuse to run."""
        self.halted_reason = reason
        if status:
            self.end_run(status, {"halted": reason, "plan": self.plan_table().to_dict("records")})
        return reason

    def _guard(self, what):
        if not self.plan:
            raise RuntimeError(f"{what}: there is no run plan yet. Run the 'Run plan' cell (rb.make_plan()) first.")
        if self.halted_reason:
            raise RuntimeError(f"{what}: this run is halted ({self.halted_reason})")

    # -- session and recording ------------------------------------------------
    def apply_config(self):
        """Run sql/runbook_config.sql so every section sees the same session values."""
        for statement in self.config_statements:
            self.session.sql(statement).collect()
        # sections that log per run (09e, ask_log) read $runbook_run_id; the config file sets 'manual'
        self.session.sql(f"SET runbook_run_id = '{self.run_id}'").collect()   # run_id is 12 hex characters
        self.fq = f"{self.config['database']}.{self.config['schema']}"
        return pd.DataFrame(sorted(self.config.items()), columns=["setting", "value"])

    def ensure_record_tables(self):
        self.refresh_kinds()
        kinds = self._object_kinds()
        # One-time move: the method-grain history table becomes a frozen legacy copy,
        # and retrieval_scores_history becomes a view over the question-grain fact.
        if kinds.get("retrieval_scores_history") == "table" and "retrieval_scores_history_legacy" not in kinds:
            self.session.sql("ALTER TABLE retrieval_scores_history RENAME TO retrieval_scores_history_legacy").collect()
        ddl = [
            """CREATE TABLE IF NOT EXISTS runbook_runs (
                 run_id VARCHAR, mode VARCHAR, label VARCHAR, change_note VARCHAR,
                 options VARIANT, config VARIANT, user_name VARCHAR, role_name VARCHAR,
                 warehouse VARCHAR, started_at TIMESTAMP_TZ, ended_at TIMESTAMP_TZ,
                 status VARCHAR, summary VARIANT)""",
            "ALTER TABLE runbook_runs ADD COLUMN IF NOT EXISTS experiment_name VARCHAR",
            "ALTER TABLE runbook_runs ADD COLUMN IF NOT EXISTS baseline_run_id VARCHAR",
            # champion = the most recently promoted run; changed only by promote()
            "ALTER TABLE runbook_runs ADD COLUMN IF NOT EXISTS promoted_at TIMESTAMP_TZ",
            "ALTER TABLE runbook_runs ADD COLUMN IF NOT EXISTS promoted_reason VARCHAR",
            """CREATE TABLE IF NOT EXISTS runbook_step_runs (
                 run_id VARCHAR, step VARCHAR, decision VARCHAR, reasons VARIANT,
                 status VARCHAR, code_hash VARCHAR, config_hash VARCHAR,
                 input_fingerprints VARIANT, output_fingerprints VARIANT,
                 sections VARIANT, checks VARIANT, query_ids VARIANT, error VARCHAR,
                 started_at TIMESTAMP_TZ, ended_at TIMESTAMP_TZ)""",
            "ALTER TABLE runbook_step_runs ADD COLUMN IF NOT EXISTS elapsed_ms NUMBER",
            """CREATE TABLE IF NOT EXISTS runbook_source_freshness (
                 run_id VARCHAR, checked_at TIMESTAMP_TZ, program_id NUMBER, phase VARCHAR,
                 details VARIANT, recommendation VARCHAR, reason VARCHAR)""",
            # question-grain history fact: one row per run, method and question
            """CREATE TABLE IF NOT EXISTS retrieval_question_scores_history (
                 run_id VARCHAR, recorded_at TIMESTAMP_TZ, label VARCHAR, experiment_name VARCHAR,
                 method VARCHAR, k NUMBER, eval_set VARCHAR, golden_version NUMBER, eval_fingerprint VARCHAR,
                 question_id VARCHAR, question_type VARCHAR, source_type VARCHAR, answerable BOOLEAN,
                 first_relevant_rank NUMBER, relevant_items NUMBER, items_found NUMBER,
                 recall_at_10 FLOAT, ndcg_at_10 FLOAT, best_correct_score FLOAT,
                 groundedness FLOAT, answer_relevance FLOAT, context_relevance FLOAT,
                 refused BOOLEAN, refusal_correct BOOLEAN, judge_model VARCHAR)""",
            """CREATE OR REPLACE VIEW retrieval_scores_history AS
               SELECT run_id, MIN(recorded_at) AS recorded_at, label, method,
                      COUNT(*) AS questions,
                      ROUND(COUNT_IF(first_relevant_rank = 1) / COUNT(*), 3) AS hit_at_1,
                      ROUND(COUNT_IF(first_relevant_rank <= 5) / COUNT(*), 3) AS hit_at_5,
                      ROUND(AVG(COALESCE(1 / first_relevant_rank, 0)), 3) AS mrr_at_10,
                      ROUND(AVG(recall_at_10), 3) AS recall_at_10,
                      ROUND(AVG(ndcg_at_10), 3) AS ndcg_at_10,
                      ANY_VALUE(eval_fingerprint) AS eval_fingerprint
               FROM retrieval_question_scores_history
               WHERE method <> 'ANSWER' AND answerable
               GROUP BY run_id, label, method""",
            """CREATE TABLE IF NOT EXISTS slide_descriptions_history (
                 run_id VARCHAR, saved_at TIMESTAMP_TZ, slide_id VARCHAR, description VARCHAR,
                 describe_model VARCHAR, describe_max_chars NUMBER, source VARCHAR)""",
            # measured AI usage per run and step (tokens from AI_COUNT_TOKENS or AI_COMPLETE usage)
            """CREATE TABLE IF NOT EXISTS runbook_ai_usage (
                 run_id VARCHAR, step VARCHAR, function_name VARCHAR, model VARCHAR,
                 calls NUMBER, input_tokens NUMBER, output_tokens NUMBER, source VARCHAR,
                 recorded_at TIMESTAMP_TZ)""",
            # credits per million tokens; fill from the Snowflake Service Consumption Table
            """CREATE TABLE IF NOT EXISTS ai_token_rates (
                 function_name VARCHAR, model VARCHAR, credits_per_million_input FLOAT,
                 credits_per_million_output FLOAT, source_note VARCHAR, updated_at TIMESTAMP_TZ)""",
            # human-in-the-loop grades: kept across runs, joined to the judge by run and question
            """CREATE TABLE IF NOT EXISTS hitl_reviews (
                 run_id VARCHAR, question_id VARCHAR, method VARCHAR, sample_reason VARCHAR,
                 human_score NUMBER, human_refusal_ok BOOLEAN, notes VARCHAR,
                 reviewed_by VARCHAR, reviewed_at TIMESTAMP_TZ)""",
        ]
        for statement in ddl:
            self.session.sql(statement).collect()
        self.ensure_report_view()
        self.refresh_kinds()

    def start_run(self):
        o = self.options
        # EXPERIMENT_NAME is a free label; left blank it becomes the run date, e.g. "2026-11-25"
        if not str(o.get("EXPERIMENT_NAME") or "").strip():
            o["EXPERIMENT_NAME"] = datetime.date.today().isoformat()
        self.champion_run_id = self.champion()
        self.session.sql(
            """INSERT INTO runbook_runs (run_id, mode, label, change_note, options, config,
                 user_name, role_name, warehouse, started_at, status, experiment_name, baseline_run_id)
               SELECT ?, ?, ?, ?, PARSE_JSON(?), PARSE_JSON(?), CURRENT_USER(), CURRENT_ROLE(),
                      CURRENT_WAREHOUSE(), CURRENT_TIMESTAMP(), 'RUNNING', ?, ?""",
            params=[self.run_id, o["MODE"], o.get("LABEL"), o.get("CHANGE_NOTE"),
                    json.dumps(o, default=str), json.dumps(self.config, default=str),
                    o.get("EXPERIMENT_NAME"), self.champion_run_id],
        ).collect()

    # -- champion baseline: one flag on runbook_runs, changed only by promote() -------
    def champion(self):
        """run_id of the current champion (latest promoted run), or None."""
        rows = self.session.sql(
            "SELECT run_id FROM runbook_runs WHERE promoted_at IS NOT NULL ORDER BY promoted_at DESC LIMIT 1").collect()
        return rows[0][0] if rows else None

    def promote(self, run_id, reason):
        """Make run_id the champion. It must have finished SUCCESS and have recorded scores."""
        if not (reason or "").strip():
            raise ValueError("promote() needs a reason, e.g. the verdict that justified it")
        ok = self.session.sql(
            """SELECT r.status = 'SUCCESS' AND EXISTS (SELECT 1 FROM retrieval_question_scores_history h WHERE h.run_id = r.run_id)
               FROM runbook_runs r WHERE r.run_id = ?""", params=[run_id]).collect()
        if not ok or not ok[0][0]:
            raise ValueError(f"run {run_id} is not a SUCCESS run with recorded scores, so it cannot be champion")
        self.session.sql("UPDATE runbook_runs SET promoted_at = CURRENT_TIMESTAMP(), promoted_reason = ? WHERE run_id = ?",
                         params=[reason.strip(), run_id]).collect()
        return f"champion is now {run_id}: {reason.strip()}"

    def adopt_restored_state(self, note):
        """After a restore from an export: record every step's current fingerprints as this run's state,
        so the next plan skips steps whose outputs exist instead of rerunning AI steps. A CSV round trip
        can shift fingerprints slightly (floats keep 16 digits), which would otherwise read as changed inputs.
        Steps with a missing output are not recorded, so the next plan runs them."""
        self.refresh_kinds()
        out = []
        for step in PIPELINE_ORDER:
            if not self.step_build(step):
                continue
            outputs = self.fingerprints(self.step_writes(step), step=step)
            missing = [k for k, v in outputs.items() if v is None]
            check = self.consistency(step)
            detail = "no consistency check" if check is None else ("passed: " if check[0] else "FAILED: ") + check[1]
            if missing:
                out.append({"step": step, "adopted": False, "detail": f"output missing: {', '.join(missing)}"})
                continue
            d = Decision(step, "SKIP", [f"{note}; consistency check {detail}"], self.step_cost(step))
            d.inputs = self.fingerprints(self.step_reads(step))
            self.record_step(d, "SKIPPED_CONSISTENT", outputs=outputs)
            out.append({"step": step, "adopted": True, "detail": detail})
        return pd.DataFrame(out)

    def end_run(self, status, summary=None):
        summary = dict(summary or {})
        if self.verdicts:
            summary["verdicts"] = self.verdicts
        self.session.sql(
            """UPDATE runbook_runs SET ended_at = CURRENT_TIMESTAMP(), status = ?,
                 summary = PARSE_JSON(?) WHERE run_id = ?""",
            params=[status, json.dumps(summary, default=str), self.run_id],
        ).collect()

    def record_step(self, decision, status, sections=None, checks=None, query_ids=None,
                    error=None, started_at=None, outputs=None):
        step_sections = self.step_sections(decision.step)
        build = [s for s in step_sections if s.role in ("BUILD", "DEFINE")]
        self.session.sql(
            """INSERT INTO runbook_step_runs (run_id, step, decision, reasons, status, code_hash,
                 config_hash, input_fingerprints, output_fingerprints, sections, checks,
                 query_ids, error, started_at, ended_at)
               SELECT ?, ?, ?, PARSE_JSON(?), ?, ?, ?, PARSE_JSON(?), PARSE_JSON(?),
                      PARSE_JSON(?), PARSE_JSON(?), PARSE_JSON(?), ?, ?, CURRENT_TIMESTAMP()""",
            params=[self.run_id, decision.step, decision.action, json.dumps(decision.reasons),
                    status, self.step_code_hash(decision.step), self.step_config_hash(decision.step),
                    json.dumps(decision.inputs, default=str),
                    json.dumps(outputs if outputs is not None else self.fingerprints(self.step_writes(decision.step), step=decision.step), default=str),
                    json.dumps(sections or [s.id for s in build]), json.dumps(checks or [], default=str),
                    json.dumps(query_ids or []), (error or "")[:4000],
                    started_at or datetime.datetime.now(datetime.timezone.utc).isoformat()],
        ).collect()

    def last_state(self, step):
        """The latest recorded state of a step that counts as a baseline."""
        rows = self.session.sql(
            """SELECT code_hash, config_hash, input_fingerprints, output_fingerprints, status, ended_at
               FROM runbook_step_runs
               WHERE step = ? AND status IN ('SUCCESS', 'SKIPPED_CONSISTENT', 'SKIPPED_UNCHANGED')
               QUALIFY ROW_NUMBER() OVER (ORDER BY ended_at DESC) = 1""",
            params=[step],
        ).collect()
        if not rows:
            return None
        r = rows[0]
        return {"code_hash": r[0], "config_hash": r[1],
                "inputs": json.loads(r[2]) if r[2] else {},
                "outputs": json.loads(r[3]) if r[3] else {}, "status": r[4], "at": r[5]}

    # -- step metadata --------------------------------------------------------
    def step_sections(self, step):
        return [s for s in self.sections.values() if s.step == step]

    def step_build(self, step):
        return [s for s in self.step_sections(step) if s.role in ("BUILD", "DEFINE")]

    def step_reads(self, step):
        writes = set(self.step_writes(step))
        reads = []
        for s in self.step_build(step):
            reads += [r for r in s.items("reads") if r not in writes and r not in reads]
        return reads

    def step_writes(self, step):
        out = []
        for s in self.step_build(step):
            out += [w for w in s.items("writes") if w not in out]
        return out

    def step_cost(self, step):
        costs = {s.cost for s in self.step_build(step)}
        return "external" if "external" in costs else "ai" if "ai" in costs else "none"

    def step_code_hash(self, step):
        return code_hash("\n".join(s.sql for s in self.step_build(step)))

    def step_config_keys(self, step):
        keys = []
        for s in self.step_sections(step):
            keys += [k.lower() for k in s.items("config") if k.lower() not in keys]
        return keys

    def step_config_hash(self, step):
        subset = {k: self.config.get(k) for k in self.step_config_keys(step)}
        return hashlib.sha256(json.dumps(subset, sort_keys=True, default=str).encode()).hexdigest()[:16]

    def upstream_steps(self, step):
        base = lambda names: {n.split("#", 1)[0] for n in names}   # retrieval_results#IMAGE -> retrieval_results
        reads = base(self.step_reads(step))
        earlier = PIPELINE_ORDER[:PIPELINE_ORDER.index(step)]
        return [u for u in earlier if reads & base(self.step_writes(u))]

    # -- fingerprints ---------------------------------------------------------
    def _object_kinds(self):
        if self._kinds is None:
            kinds = {}
            for row in self.session.sql(
                    f"SELECT table_name, table_type FROM {self.config['database']}.information_schema.tables "
                    f"WHERE table_schema = '{self.config['schema'].upper()}'").collect():
                kinds[row[0].lower()] = "view" if row[1] == "VIEW" else "table"
            for row in self.session.sql("SHOW CORTEX SEARCH SERVICES IN SCHEMA").collect():
                kinds[row["name"].lower()] = "service"
            for row in self.session.sql("SHOW USER PROCEDURES IN SCHEMA").collect():
                kinds.setdefault(row["name"].lower(), "procedure")
            for row in self.session.sql("SHOW USER FUNCTIONS IN SCHEMA").collect():
                kinds.setdefault(row["name"].lower(), "function")
            self._kinds = kinds
        return self._kinds

    def refresh_kinds(self):
        self._kinds = None

    def fingerprint(self, name):
        """Content fingerprint of one object, or None if it does not exist."""
        name = name.strip()
        try:
            if "#" in name:  # one method's rows of a shared table, e.g. retrieval_results#IMAGE
                table, methods = name.split("#", 1)
                if self._object_kinds().get(table.lower()) != "table":
                    return None
                wanted = [m for m in methods.split("+") if re.fullmatch(r"[A-Z0-9_]+", m)]
                in_list = ", ".join(f"'{m}'" for m in wanted)
                r = self.session.sql(f"SELECT COUNT(*), HASH_AGG(*) FROM {table} WHERE method IN ({in_list})").collect()[0]
                return f"rows={r[0]}|h={r[1]}" if r[0] else None
            if name.startswith("@"):
                r = self.session.sql(
                    f"SELECT COUNT(*), HASH_AGG(relative_path, size, md5) FROM DIRECTORY({name})").collect()[0]
                return f"files={r[0]}|h={r[1]}"
            kind = self._object_kinds().get(name.lower())
            if kind in ("table", "view"):
                r = self.session.sql(f"SELECT COUNT(*), HASH_AGG(*) FROM {name}").collect()[0]
                return f"rows={r[0]}|h={r[1]}"
            if kind == "service":
                row = [r for r in self.session.sql(f"SHOW CORTEX SEARCH SERVICES LIKE '{name}' IN SCHEMA").collect()][0]
                d = row.as_dict()
                return (f"rows={d.get('source_data_num_rows')}|state={d.get('serving_state')}|"
                        f"def={code_hash(d.get('definition') or '')}|created={d.get('created_on')}")
            if kind in ("procedure", "function"):
                cmd = "SHOW USER PROCEDURES" if kind == "procedure" else "SHOW USER FUNCTIONS"
                args = sorted(r["arguments"] for r in self.session.sql(f"{cmd} LIKE '{name}' IN SCHEMA").collect())
                return "sig=" + ";".join(args)
        except Exception as exc:  # missing stage or a dropped object reads as missing
            if "does not exist" in str(exc).lower() or "not authorized" in str(exc).lower():
                return None
            raise
        return None

    def fingerprints(self, names, step=None):
        exists_only = step is not None and any(s.attrs.get("track") == "exists" for s in self.step_build(step))
        out = {}
        for n in names:
            fp = self.fingerprint(n)
            out[n] = ("exists" if fp is not None else None) if exists_only else fp
        return out

    # -- consistency checks (work with no history) ----------------------------
    def consistency(self, step):
        """Compare a step's outputs with its inputs directly. Returns (ok, detail) or None."""
        q = lambda sql: self.session.sql(sql).collect()[0]
        try:
            if step in ("02", "08", "10", "12"):
                return self._define_consistency(step)
            if step == "04b":
                r = q("""SELECT (SELECT COUNT(DISTINCT lesson_slug) FROM lesson_transcripts WHERE TRIM(transcript_text) <> ''),
                                (SELECT COUNT(DISTINCT lesson_slug) FROM transcript_chunks)""")
                return r[0] == r[1], f"{r[1]} of {r[0]} transcripts are chunked"
            if step == "05c":
                r = q("""WITH latest AS (SELECT deck_id, raw_result FROM slide_parse_results
                           WHERE parse_mode = 'LAYOUT' AND raw_result:error::STRING IS NULL
                           QUALIFY ROW_NUMBER() OVER (PARTITION BY deck_id ORDER BY parsed_at DESC) = 1)
                         SELECT (SELECT SUM(ARRAY_SIZE(raw_result:value:pages)) FROM latest),
                                (SELECT COUNT(*) FROM slide_pages)""")
                return r[0] == r[1], f"slide_pages has {r[1]} rows; latest parses have {r[0]} pages"
            if step == "11a":
                r = q("SELECT (SELECT COUNT(*) FROM slide_pages), (SELECT COUNT(*) FROM slide_images)")
                return r[0] == r[1], f"{r[1]} rendered images for {r[0]} parsed pages"
            if step == "11b":
                r = q("""SELECT (SELECT COUNT(*) FROM slide_images),
                                (SELECT COUNT(*) FROM slide_image_embeddings WHERE embedding IS NOT NULL)""")
                return r[0] == r[1], f"{r[1]} image embeddings for {r[0]} images"
            if step == "11e":
                rule = self.describe_filter()
                r = q(f"""SELECT (SELECT COUNT(*) FROM slide_pages p WHERE {rule}),
                                 (SELECT COUNT(*) FROM slide_descriptions d JOIN slide_pages p ON p.slide_id = d.slide_id
                                  WHERE {rule}),
                                 (SELECT COUNT(*) FROM slide_descriptions)""")
                ok = r[0] == r[1] == r[2]
                return ok, f"{r[2]} descriptions; {r[0]} slides match the 11e describe rule"
            if step == "06a":
                r = q("""SELECT (SELECT COUNT(*) FROM slide_descriptions),
                                (SELECT COUNT(*) FROM slide_descriptions d JOIN search_corpus c ON c.source_id = d.slide_id
                                 WHERE CONTAINS(c.search_text, d.description)),
                                (SELECT COUNT(*) FROM transcript_chunks) + (SELECT COUNT(*) FROM slide_pages)
                                  + (SELECT COUNT(*) FROM academy_faqs),
                                (SELECT COUNT(*) FROM search_corpus)""")
                ok = r[0] == r[1] and r[2] == r[3]
                return ok, (f"{r[1]} of {r[0]} current slide descriptions are in search_corpus; "
                            f"corpus has {r[3]} rows, sources have {r[2]}")
            if step == "06b":
                r = q("""SELECT (SELECT COUNT(*) FROM search_corpus),
                                (SELECT COUNT(*) FROM text_embeddings e JOIN search_corpus c USING (source_id)),
                                (SELECT COUNT(*) FROM text_embeddings WHERE embedding_model <> $text_embed_model OR embedding IS NULL),
                                (SELECT MAX(created) FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'SEARCH_CORPUS') <=
                                (SELECT MAX(created) FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'TEXT_EMBEDDINGS')""")
                ok = r[0] == r[1] and r[2] == 0 and bool(r[3])
                return ok, (f"{r[1]} of {r[0]} corpus rows embedded; {r[2]} with the wrong model or no vector; "
                            f"embedded after the corpus was built: {bool(r[3])}")
            if step == "07a":
                svc = self.session.sql(f"SHOW CORTEX SEARCH SERVICES LIKE '{self.config['search_service']}' IN SCHEMA").collect()
                if not svc:
                    return False, "service does not exist"
                d = svc[0].as_dict()
                r = q("""SELECT (SELECT COUNT(*) FROM search_corpus),
                                (SELECT MAX(created) FROM information_schema.tables WHERE table_schema = CURRENT_SCHEMA() AND table_name = 'SEARCH_CORPUS')""")
                created = d.get("created_on")
                fresh = created is not None and r[1] is not None and created >= r[1]
                ok = int(d.get("source_data_num_rows") or -1) == r[0] and fresh and d.get("serving_state") == "ACTIVE"
                return ok, (f"service rows {d.get('source_data_num_rows')} vs corpus {r[0]}; "
                            f"built after the corpus was built: {fresh}; serving {d.get('serving_state')}")
            if step == "09b":
                return self._eval_set_consistency()
            if step == "09c":
                r = q("""SELECT (SELECT COUNT(*) FROM eval_questions WHERE answerable),
                                (SELECT COUNT(*) FROM eval_query_embeddings),
                                (SELECT COUNT(DISTINCT question_id) FROM retrieval_results WHERE method = 'VECTOR'),
                                (SELECT COUNT(DISTINCT question_id) FROM retrieval_results WHERE method = 'CORTEX_SEARCH')""")
                ok = r[0] == r[1] == r[2] == r[3]
                return ok, f"{r[0]} answerable; embedded {r[1]}; VECTOR {r[2]}; CORTEX_SEARCH {r[3]}"
            if step == "11d":
                r = q("""SELECT (SELECT COUNT(DISTINCT q.question_id) FROM eval_questions q JOIN eval_expected e
                                   ON e.question_id = q.question_id AND e.source_type = 'slide' WHERE q.answerable),
                                (SELECT COUNT(DISTINCT question_id) FROM retrieval_results WHERE method = 'IMAGE')""")
                return r[0] == r[1], f"IMAGE results for {r[1]} of {r[0]} slide questions"
            if step == "09d":
                r = q("""SELECT (SELECT COUNT(*) FROM information_schema.views
                                 WHERE table_schema = CURRENT_SCHEMA() AND table_name IN ('RETRIEVAL_QUESTION_SCORES', 'RETRIEVAL_SCORES'))""")
                return r[0] == 2, f"{r[0]} of 2 score views exist"
        except Exception as exc:
            return False, f"check could not run: {str(exc)[:200]}"
        return None

    def _define_consistency(self, step):
        missing = []
        for s in self.step_build(step):
            for m in re.finditer(r"CREATE OR REPLACE PROCEDURE\s+(\w+)\s*\((.*?)\)\s*\n\s*RETURNS",
                                 strip_comments(s.sql), re.S):
                name, args = m.group(1), m.group(2)
                types = [re.split(r"\s+DEFAULT\s+", a.strip(), flags=re.I)[0].split()[1].upper()
                         for a in args.split(",") if a.strip()]
                wanted = f"{name.upper()}({', '.join(types)})"
                rows = self.session.sql(f"SHOW USER PROCEDURES LIKE '{name}' IN SCHEMA").collect()
                have = [re.sub(r"DEFAULT ", "", r["arguments"]).split(" RETURN")[0] for r in rows]
                if wanted not in have:
                    missing.append(f"{wanted} (have: {', '.join(have) or 'none'})")
        return (not missing), ("all procedure signatures match the file" if not missing
                               else "missing or outdated: " + "; ".join(missing))

    def describe_filter(self):
        """The WHERE condition of 11e.build (which slides get a description), read from the .sql file
        so the consistency check and the cost estimate always use the same rule as the step."""
        sql = strip_comments(self.sections["11e.build"].sql)
        return re.search(r"\bWHERE\b(.*?);", sql, re.S | re.I).group(1).strip()

    def _eval_set_consistency(self):
        sql = strip_comments(self.sections["09b.build"].sql)
        counts = {}
        # the questions go into eval_questions; the answer list into eval_expected
        for table in ("eval_questions", "eval_expected"):
            stmt = [s for s in split_statements(sql) if re.search(rf"INSERT\s+INTO\s+{table}\b", s, re.I)][0]
            counts[table] = len(re.findall(r"\(\s*'Q\d+'", stmt))
        r = self.session.sql(
            "SELECT (SELECT COUNT(*) FROM eval_questions), (SELECT COUNT(*) FROM eval_expected)").collect()[0]
        # every question in the file is version 1 unless it says otherwise, so the table can hold fewer
        # rows than the file only when $golden_version filters some out
        ok = r[0] <= counts["eval_questions"] and r[0] > 0 and r[1] == counts["eval_expected"]
        return ok, (f"eval_questions: table {r[0]} vs file {counts['eval_questions']}; "
                    f"eval_expected: table {r[1]} vs file {counts['eval_expected']}")

    # -- lint: values DDL cannot read from session variables --------------------
    def lint(self):
        issues = []
        ddl = strip_comments(self.sections["07a.build"].sql)
        m_model = re.search(r"EMBEDDING_MODEL\s*=\s*'([^']+)'", ddl, re.I)
        m_wh = re.search(r"WAREHOUSE\s*=\s*'([^']+)'", ddl, re.I)
        m_name = re.search(r"CORTEX SEARCH SERVICE\s+(\w+)", ddl, re.I)
        if m_model and m_model.group(1) != self.config.get("text_embed_model"):
            issues.append(f"07a EMBEDDING_MODEL '{m_model.group(1)}' differs from $text_embed_model "
                          f"'{self.config.get('text_embed_model')}' (sql/07_cortex_search.sql)")
        if m_wh and m_wh.group(1).lower() != str(self.config.get("warehouse")).lower():
            issues.append(f"07a WAREHOUSE '{m_wh.group(1)}' differs from USE WAREHOUSE '{self.config.get('warehouse')}'")
        if m_name and m_name.group(1).lower() != str(self.config.get("search_service")).lower():
            issues.append(f"07a service name '{m_name.group(1)}' differs from $search_service "
                          f"'{self.config.get('search_service')}'")
        return issues

    # -- catalog and explore index ----------------------------------------------
    def catalog(self, roles=None):
        rows = []
        for s in self.sections.values():
            if roles and s.role not in roles:
                continue
            rows.append({"section": s.id, "role": s.role, "cost": s.cost, "where": s.location,
                         "purpose": s.purpose})
        order = {step: i for i, step in enumerate(PIPELINE_ORDER)}
        return (pd.DataFrame(rows)
                .assign(_o=lambda d: d["section"].str.split(".").str[0].map(order).fillna(99))
                .sort_values(["_o", "section"]).drop(columns="_o").reset_index(drop=True))

    # -- planning -------------------------------------------------------------
    def estimate(self, step):
        try:
            q = lambda sql: self.session.sql(sql).collect()[0][0]
            return {
                "05a": lambda: f"~{q('SELECT COUNT(*) FROM slide_decks d WHERE NOT EXISTS (SELECT 1 FROM slide_parse_results r WHERE r.deck_id = d.deck_id AND r.raw_result:error::STRING IS NULL)')} AI_PARSE_DOCUMENT calls",
                "11b": lambda: f"~{q('SELECT COUNT(*) FROM slide_images')} image AI_EMBED calls",
                "11e": lambda: f"~{q(f'SELECT COUNT(*) FROM slide_pages p WHERE {self.describe_filter()}')} AI_COMPLETE calls (output differs every run)",
                "06b": lambda: f"~{q('SELECT COUNT(*) FROM search_corpus')} AI_EMBED calls",
                "07a": lambda: "Cortex Search index rebuild (warehouse credits; then refreshes daily)",
                "09c": lambda: f"~{q('SELECT COUNT(*) FROM eval_questions WHERE answerable')} AI_EMBED calls + the same number of searches",
                "11d": lambda: "image AI_EMBED call per slide question",
                "03a": lambda: "3 API requests",
                "03d": lambda: f"API requests for up to {self.config.get('ingest_max_lessons')} lessons",
                "13b": lambda: "downloads every program video again",
                "13c": lambda: "AI_MULTI_EMBED per new video (billed by video length)",
                "13f": lambda: "AI_MULTI_EMBED per video question",
                "09e": lambda: (f"~{q('SELECT COUNT(*) FROM eval_questions')} answer + the same number of judge "
                                f"AI_COMPLETE calls ({self.config.get('answer_model')} answers, "
                                f"{self.config.get('judge_model')} judges) and searches; "
                                f"~{q('SELECT COUNT(*) FROM eval_questions')} x {self.config.get('gen_top_k')} sources of prompt text each"),
            }.get(step, lambda: "")()
        except Exception:
            return ""

    def make_plan(self):
        o = self.options
        self.halted_reason = None
        force = set(o.get("FORCE_STEPS") or [])
        unknown = sorted(force - set(PIPELINE_ORDER))
        if unknown:   # a typo like "3d" would otherwise be ignored silently
            raise ValueError(f"FORCE_STEPS has unknown step IDs {unknown}; valid IDs: {', '.join(PIPELINE_ORDER)}")
        if o.get("MODE") not in ("score_existing", "full_experiment", "maintenance"):
            raise ValueError("MODE must be 'score_existing', 'full_experiment' or 'maintenance'")
        if o.get("REFRESH_SOURCES") not in ("auto", True, False):
            raise ValueError("REFRESH_SOURCES must be 'auto', True or False")
        self.refresh_kinds()
        plan = {}
        for step in PIPELINE_ORDER:
            if not self.step_build(step):
                continue
            cost = self.step_cost(step)
            d = Decision(step, "SKIP", [], cost)
            d.inputs = self.fingerprints(self.step_reads(step))
            if step in VIDEO_STEPS and not o.get("INCLUDE_VIDEO"):
                d.action, d.reasons = "NOT_INCLUDED", ["video path is off (INCLUDE_VIDEO=False)"]
                plan[step] = d
                continue
            if step in ANSWER_STEPS and not o.get("INCLUDE_ANSWER_EVAL"):
                d.action, d.reasons = "NOT_INCLUDED", ["answer quality is off (INCLUDE_ANSWER_EVAL=False)"]
                plan[step] = d
                continue
            if step in force:
                d.action, d.reasons = "RUN", ["forced (FORCE_STEPS)"]
            elif step in EXTERNAL_STEPS:
                rec = (self.freshness or {}).get("recommendation", "NOT NEEDED")
                if step == "03a" and (self.freshness or {}).get("probe_ran"):
                    d.action, d.reasons = "SKIP", ["already ran as the catalog probe in the freshness check"]
                elif rec == "REFRESH" and (step != "13b" or o.get("INCLUDE_VIDEO")):
                    d.action, d.reasons = "RUN", [f"source refresh: {self.freshness.get('reason')}"]
                else:
                    d.reasons = [f"source refresh not needed: {(self.freshness or {}).get('reason', 'freshness not checked')}"]
            else:
                outputs = self.fingerprints(self.step_writes(step), step=step)
                missing = [k for k, v in outputs.items() if v is None]
                last = self.last_state(step)
                if missing:
                    d.action, d.reasons = "RUN", [f"output missing: {', '.join(missing)}"]
                elif last:
                    if last["code_hash"] != self.step_code_hash(step):
                        d.reasons.append("its SQL changed since the last successful run")
                    if last["config_hash"] != self.step_config_hash(step):
                        d.reasons.append(f"a setting it uses changed ({', '.join(self.step_config_keys(step))})")
                    changed = [k for k, v in d.inputs.items() if last["inputs"].get(k) != v]
                    if changed:
                        d.reasons.append(f"input changed since it last ran: {', '.join(changed)}")
                    if d.reasons:
                        d.action = "RUN"
                    else:
                        exists_only = any(s.attrs.get("track") == "exists" for s in self.step_build(step))
                        drift = [] if exists_only else [
                            k for k, v in outputs.items() if last["outputs"].get(k) not in (None, v)]
                        if drift:
                            d.action = "DRIFT"
                            d.reasons = [f"output changed outside the runbook: {', '.join(drift)} "
                                         "(add the step to FORCE_STEPS to rebuild it)"]
                        else:
                            d.reasons = ["inputs, SQL and settings unchanged since the last run"]
                else:
                    check = self.consistency(step)
                    if check is None:
                        d.reasons = ["no history yet and no consistency check; recording a baseline"]
                    elif check[0]:
                        d.reasons = [f"no history yet; consistency check passed ({check[1]})"]
                    else:
                        d.action, d.reasons = "RUN", [f"consistency check failed: {check[1]}"]
            # a step downstream of a step that runs must run too
            if d.action in ("SKIP",) and step not in EXTERNAL_STEPS:
                ups = [u for u in self.upstream_steps(step) if plan.get(u) and plan[u].action == "RUN"]
                if ups:
                    d.action, d.upstream_only = "RUN", True
                    d.reasons = [f"downstream of {', '.join(ups)}, which will run"]
            if d.action == "RUN":
                d.estimate = self.estimate(step)
            plan[step] = d
        self.plan = plan
        # Halts. Set here so every later call (execute_step, snapshot, scoring) sees the same flag.
        table = self.plan_table()
        costly = table[(table.decision == "RUN") & (table.cost != "none")]
        if int(self.config.get("eval_top_k", 0)) < METRIC_K:
            self.halt(f"$eval_top_k is {self.config.get('eval_top_k')} in sql/runbook_config.sql; it must be at least "
                      f"{METRIC_K}, because every metric is computed at @{METRIC_K}.", "HALTED_CONFIG")
        elif o.get("DRY_RUN"):
            self.halt("DRY_RUN=True: plan shown, nothing run. Set DRY_RUN=False to run.", "DRY_RUN")
        elif o.get("REQUIRE_APPROVAL_FOR_COST") and len(costly):
            self.halt("REQUIRE_APPROVAL_FOR_COST=True: review the costly steps above, then set it to False "
                      "and rerun from Setup.", "AWAITING_APPROVAL")
        return table

    def plan_table(self):
        return pd.DataFrame([{"step": d.step, "decision": d.action, "cost": d.cost,
                              "estimate": d.estimate, "reason": "; ".join(d.reasons)}
                             for d in self.plan.values()])

    # -- running sections -------------------------------------------------------
    def run_section(self, section):
        """Run every statement of a section; return [(statement, DataFrame or None, query_id)]."""
        results = []
        for statement in split_statements(section.sql):
            df = self.session.sql(statement)
            rows = df.collect()
            qid = self.session.sql("SELECT LAST_QUERY_ID()").collect()[0][0]
            frame = None
            if rows:
                frame = pd.DataFrame([r.as_dict() for r in rows])
            else:
                try:  # keep column names for an empty SELECT result
                    frame = pd.DataFrame(columns=[f.name for f in df.schema.fields])
                except Exception:
                    frame = pd.DataFrame()
            results.append((statement, frame, qid))
        return results

    def evaluate_expectations(self, section, results):
        expects = section.items("expect") or ["output"]
        checks = []
        for i, (statement, frame, qid) in enumerate(results):
            expect = expects[min(i, len(expects) - 1)]
            rows = 0 if frame is None else len(frame)
            if expect == "zero_rows":
                ok, detail = rows == 0, f"{rows} rows (expect 0)"
            elif expect.startswith("col:"):
                col, value = expect[4:].split("=", 1)
                cols = {c.upper(): c for c in (frame.columns if frame is not None else [])}
                if frame is None or col.upper() not in cols:
                    ok, detail = False, f"column {col} not returned"
                else:
                    bad = frame[frame[cols[col.upper()]].astype(str) != value]
                    ok, detail = bad.empty, f"{len(bad)} rows where {col} <> {value}"
            else:
                ok, detail = True, f"{rows} rows"
            checks.append({"section": section.id, "statement": i + 1, "expect": expect,
                           "passed": bool(ok), "detail": detail, "query_id": qid})
        return checks

    def execute_step(self, step, display=print):
        """Build cell: run (or skip) a step's BUILD sections and record the result."""
        self._guard(f"execute_step({step})")
        d = self.plan[step]
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        if d.action == "RUN" and d.upstream_only:
            # recheck: if upstream reran but produced identical content, this step can skip
            last = self.last_state(step)
            baseline = last["inputs"] if last else d.inputs
            current = self.fingerprints(self.step_reads(step))
            if current == baseline and all(v is not None for v in self.fingerprints(self.step_writes(step), step=step).values()):
                d.action = "SKIP"
                d.reasons = [d.reasons[0] + "; but its inputs came out identical, so it is skipped"]
                d.inputs = current
        if d.action != "RUN":
            status = {"SKIP": "SKIPPED_UNCHANGED", "DRIFT": "DRIFT", "NOT_INCLUDED": "NOT_INCLUDED"}[d.action]
            if d.action == "SKIP" and d.reasons and d.reasons[0].startswith("no history"):
                status = "SKIPPED_CONSISTENT"
            if d.action == "SKIP" and step in EXTERNAL_STEPS:
                status = "SKIPPED_SOURCE"
            self.record_step(d, status, started_at=started)
            display(f"{step}: {d.action} - {'; '.join(d.reasons)}")
            return None
        d.inputs = self.fingerprints(self.step_reads(step))
        query_ids, ran = [], []
        try:
            for section in self.step_build(step):
                display(f"{step}: running {section.id} ({section.location}) - {section.purpose}")
                results = self.run_section(section)
                query_ids += [qid for _, _, qid in results]
                ran.append(section.id)
            self.refresh_kinds()
            if step == "11e":
                self.save_descriptions("11e run")
            self.record_step(d, "SUCCESS", sections=ran, query_ids=query_ids, started_at=started)
            self.record_usage(step)
            self.record_elapsed(step, query_ids)
            display(f"{step}: done ({len(query_ids)} statements)")
        except Exception as exc:
            self.record_step(d, "FAILED", sections=ran, query_ids=query_ids, error=str(exc), started_at=started)
            raise
        return query_ids

    def check_step(self, step, display_frame=None):
        """Check cell: run the step's CHECK sections and stop on a failed expectation."""
        d = self.plan.get(step)
        all_checks = []
        if d is not None and d.action == "NOT_INCLUDED":
            return pd.DataFrame(all_checks)
        for section in [s for s in self.step_sections(step) if s.role == "CHECK"]:
            if section.cost == "ai" and (d is None or d.action != "RUN"):
                all_checks.append({"section": section.id, "passed": True,
                                   "detail": "skipped: costs an AI call and the step did not run"})
                continue
            results = self.run_section(section)
            checks = self.evaluate_expectations(section, results)
            all_checks += checks
            if display_frame:
                for (statement, frame, _), check in zip(results, checks):
                    display_frame(section, check, frame)
        failed = [c for c in all_checks if not c["passed"]]
        if all_checks:
            self.session.sql(
                """UPDATE runbook_step_runs SET checks = PARSE_JSON(?)
                   WHERE run_id = ? AND step = ?""",
                params=[json.dumps(all_checks, default=str), self.run_id, step]).collect()
        if failed and not self.options.get("CONTINUE_ON_CHECK_FAIL"):
            raise RuntimeError(f"{step}: check failed - " + "; ".join(f"{c['section']}: {c['detail']}" for c in failed))
        return pd.DataFrame(all_checks)

    def output_step(self, step):
        """Output cell: run the step's OUTPUT sections and return their frames."""
        frames = []
        for section in [s for s in self.step_sections(step) if s.role == "OUTPUT"]:
            for statement, frame, _ in self.run_section(section):
                frames.append((section, frame))
        return frames

    # -- cost: measured tokens and elapsed time ----------------------------------
    # Tokens are measured when the step runs (AI_COUNT_TOKENS on the exact inputs, or the
    # usage block AI_COMPLETE returns), so cost is known right away and can be recomputed
    # from runbook_ai_usage x ai_token_rates. ACCOUNT_USAGE is only an optional later check.
    USAGE_SQL = {
        "06b": [("AI_EMBED", "$text_embed_model",
                 "SELECT COUNT(*), SUM(AI_COUNT_TOKENS('ai_embed', $text_embed_model, search_text)), 0 FROM search_corpus")],
        "09c": [("AI_EMBED", "$text_embed_model",
                 "SELECT COUNT(*), SUM(AI_COUNT_TOKENS('ai_embed', $text_embed_model, 'query: ' || question)), 0 "
                 "FROM eval_questions WHERE answerable"),
                ("CORTEX_SEARCH_QUERY", "$search_service",
                 "SELECT COUNT(*), NULL, NULL FROM eval_questions WHERE answerable")],
        "11d": [("AI_EMBED", "$image_embed_model",
                 "SELECT COUNT(*), NULL, NULL FROM eval_image_query_embeddings")],
        "09e": [("AI_COMPLETE", "$answer_model",
                 "SELECT COUNT(*), SUM(answer_input_tokens), SUM(answer_output_tokens) FROM answer_judgments WHERE run_id = $runbook_run_id"),
                ("AI_COMPLETE", "$judge_model",
                 "SELECT COUNT(*), SUM(judge_input_tokens), SUM(judge_output_tokens) FROM answer_judgments WHERE run_id = $runbook_run_id"),
                ("CORTEX_SEARCH_QUERY", "$search_service",
                 "SELECT COUNT(*), NULL, NULL FROM answer_judgments WHERE run_id = $runbook_run_id")],
    }

    def record_usage(self, step):
        for function_name, model_var, sql in self.USAGE_SQL.get(step, []):
            model = self.config.get(model_var.lstrip("$"))
            try:
                calls, tin, tout = self.session.sql(sql).collect()[0]
                source = "AI_COMPLETE usage" if step == "09e" and function_name == "AI_COMPLETE" else (
                    "AI_COUNT_TOKENS on the inputs" if tin is not None else "call count only (not billed per token)")
            except Exception as exc:   # e.g. a model AI_COUNT_TOKENS does not know: keep the call count
                calls, tin, tout, source = None, None, None, f"not measured: {str(exc)[:150]}"
            self.session.sql(
                """INSERT INTO runbook_ai_usage (run_id, step, function_name, model, calls, input_tokens,
                     output_tokens, source, recorded_at) SELECT ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP()""",
                params=[self.run_id, step, function_name, model, calls, tin, tout, source]).collect()

    def record_elapsed(self, step, query_ids):
        """Elapsed time of this step's statements, from this session's query history (current to the second)."""
        ids = [q for q in query_ids if q and re.fullmatch(r"[0-9a-f-]{36}", q)]
        if not ids:
            return
        in_list = ", ".join(f"'{q}'" for q in ids)
        try:
            ms = self.session.sql(
                f"""SELECT SUM(total_elapsed_time) FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10000))
                    WHERE query_id IN ({in_list})""").collect()[0][0]
        except Exception:
            return
        self.session.sql("UPDATE runbook_step_runs SET elapsed_ms = ? WHERE run_id = ? AND step = ?",
                         params=[ms, self.run_id, step]).collect()

    def run_cost(self, run_id=None):
        """Tokens, credits (where a rate is set in ai_token_rates) and elapsed time for one run."""
        rid = run_id or self.run_id
        usage = self.session.sql(
            """SELECT u.step, u.function_name, u.model, u.calls, u.input_tokens, u.output_tokens, u.source,
                      ROUND(u.input_tokens / 1e6 * r.credits_per_million_input
                            + COALESCE(u.output_tokens, 0) / 1e6 * COALESCE(r.credits_per_million_output, 0), 6) AS credits,
                      IFF(r.function_name IS NULL AND u.input_tokens IS NOT NULL,
                          'no rate in ai_token_rates for this model', NULL) AS credits_note
               FROM runbook_ai_usage u
               LEFT JOIN ai_token_rates r ON r.function_name = u.function_name AND r.model = u.model
               WHERE u.run_id = ? ORDER BY u.step, u.function_name""", params=[rid]).to_pandas()
        elapsed = self.session.sql(
            """SELECT step, status, ROUND(elapsed_ms / 1000, 1) AS elapsed_s FROM runbook_step_runs
               WHERE run_id = ? AND elapsed_ms IS NOT NULL ORDER BY started_at""", params=[rid]).to_pandas()
        return usage, elapsed

    # -- AI output history ----------------------------------------------------
    def save_descriptions(self, source):
        self.session.sql(
            """INSERT INTO slide_descriptions_history (run_id, saved_at, slide_id, description,
                 describe_model, describe_max_chars, source)
               SELECT ?, CURRENT_TIMESTAMP(), slide_id, description, $describe_model, $describe_max_chars, ?
               FROM slide_descriptions""", params=[self.run_id, source]).collect()

    def ensure_descriptions_saved(self):
        """Save the current descriptions once if this exact text has never been saved."""
        r = self.session.sql(
            """SELECT COUNT(*) FROM slide_descriptions d
               WHERE NOT EXISTS (SELECT 1 FROM slide_descriptions_history h
                                 WHERE h.slide_id = d.slide_id AND h.description = d.description)""").collect()[0][0]
        if r:
            self.save_descriptions("baseline (first time the runbook saw these descriptions)")
        return r

    # -- source freshness -----------------------------------------------------
    def check_freshness(self):
        o, c = self.options, self.config
        pid = int(c["program_id"])
        q = lambda sql, params=None: self.session.sql(sql, params=params or []).collect()
        prog = q("SELECT program_name, start_date, end_date FROM programs WHERE program_id = ?", [pid])
        today = datetime.date.today()
        name, start, end = (prog[0][0], prog[0][1], prog[0][2]) if prog else ("unknown", None, None)
        grace = datetime.timedelta(days=int(o.get("ACTIVE_GRACE_DAYS", 7)))
        if start and end and start <= today <= end + grace:
            phase, max_age = "active", o.get("SOURCE_MAX_AGE_DAYS_ACTIVE", 7)
        elif start and today < start:
            phase, max_age = "not started", o.get("SOURCE_MAX_AGE_DAYS_ACTIVE", 7)
        else:
            phase, max_age = "ended", o.get("SOURCE_MAX_AGE_DAYS_INACTIVE")
        last = q("""SELECT (SELECT MAX(fetched_at) FROM api_responses),
                           (SELECT MAX(fetched_at) FROM lesson_transcripts),
                           (SELECT MAX(fetched_at) FROM slide_decks)""")[0]
        lessons_sql = """SELECT slug, title, has_slides, duration_seconds, sort_order FROM lessons
                         WHERE program_id = ? ORDER BY sort_order, lesson_id"""
        before = pd.DataFrame([r.as_dict() for r in q(lessons_sql, [pid])])
        probe = {"ran": False, "new": [], "changed": [], "removed": []}
        if o.get("PROBE_CATALOG", True):
            self.session.sql("CALL ingest_catalog()").collect()
            after = pd.DataFrame([r.as_dict() for r in q(lessons_sql, [pid])])
            probe["ran"] = True
            b = before.set_index("SLUG") if not before.empty else pd.DataFrame()
            a = after.set_index("SLUG") if not after.empty else pd.DataFrame()
            probe["new"] = sorted(set(a.index) - set(b.index))
            probe["removed"] = sorted(set(b.index) - set(a.index))
            for slug in sorted(set(a.index) & set(b.index)):
                diffs = [col for col in ("TITLE", "HAS_SLIDES", "DURATION_SECONDS")
                         if str(a.at[slug, col]) != str(b.at[slug, col])]
                if diffs:
                    probe["changed"].append(f"{slug} ({', '.join(diffs).lower()})")
            lessons = after
        else:
            lessons = before
        cap = int(c.get("ingest_max_lessons", 40))
        coverage = q("""WITH l AS (SELECT slug, has_slides, duration_seconds,
                                          ROW_NUMBER() OVER (ORDER BY sort_order, lesson_id) AS n
                                   FROM lessons WHERE program_id = ?)
                        SELECT COUNT(*),
                               COUNT_IF(t.lesson_slug IS NOT NULL),
                               COUNT_IF(l.has_slides), COUNT_IF(d.lesson_slug IS NOT NULL),
                               COUNT_IF(l.n > ?),
                               ARRAY_AGG(IFF(l.duration_seconds > 0 AND t.lesson_slug IS NULL AND l.n <= ?, l.slug, NULL)),
                               ARRAY_AGG(IFF(l.has_slides AND d.lesson_slug IS NULL AND l.n <= ?, l.slug, NULL))
                        FROM l
                        LEFT JOIN (SELECT DISTINCT lesson_slug FROM lesson_transcripts) t ON t.lesson_slug = l.slug
                        LEFT JOIN (SELECT DISTINCT lesson_slug FROM slide_decks) d ON d.lesson_slug = l.slug""",
                     [pid, cap, cap, cap])[0]
        recorded_no_transcript = json.loads(coverage[5]) if coverage[5] else []
        slides_missing = json.loads(coverage[6]) if coverage[6] else []
        # Gaps that a successful 03d ingest already tried to fill are "known": the API had nothing
        # for them then, so they only count again once the catalog or the age rule says so.
        tried = q("""SELECT f.details FROM runbook_source_freshness f
                     JOIN runbook_step_runs s ON s.run_id = f.run_id AND s.step = '03d' AND s.status = 'SUCCESS'
                     WHERE f.program_id = ? ORDER BY f.checked_at DESC LIMIT 1""", [pid])
        tried = json.loads(tried[0][0]) if tried else {}
        known = set(tried.get("recorded_but_no_transcript", [])) | set(tried.get("slides_but_no_deck", []))
        new_transcript_gaps = [s for s in recorded_no_transcript if s not in known]
        new_deck_gaps = [s for s in slides_missing if s not in known]
        newest = max([t for t in last[1:] if t is not None], default=None)
        age_days = (datetime.datetime.now(datetime.timezone.utc) - newest).days if newest else None
        reasons = []
        if probe["new"]:
            reasons.append(f"{len(probe['new'])} new lessons in the catalog")
        if probe["changed"]:
            reasons.append(f"{len(probe['changed'])} lessons changed in the catalog")
        if new_transcript_gaps:
            reasons.append(f"{len(new_transcript_gaps)} lessons have a recording length but no transcript loaded "
                           "(not yet tried by an ingest)")
        if new_deck_gaps:
            reasons.append(f"{len(new_deck_gaps)} lessons have slides but no deck loaded (not yet tried by an ingest)")
        if max_age is not None and age_days is not None and age_days > int(max_age):
            reasons.append(f"last lesson ingest is {age_days} days old (limit {max_age} while {phase})")
        setting = o.get("REFRESH_SOURCES", "auto")
        if setting is True:
            rec, reason = "REFRESH", "forced (REFRESH_SOURCES=True)"
        elif setting is False:
            rec, reason = "NOT NEEDED", "turned off (REFRESH_SOURCES=False)"
        elif reasons:
            rec, reason = "REFRESH", "; ".join(reasons)
        else:
            rec, reason = "NOT NEEDED", (f"catalog unchanged, no coverage gaps, last ingest {age_days} days ago; "
                                         f"program {phase}")
        details = {
            "program": f"{pid} {name}", "dates": f"{start} to {end}", "phase": phase,
            "last_catalog_fetch": str(last[0]), "last_transcript_fetch": str(last[1]),
            "last_deck_fetch": str(last[2]), "ingest_age_days": age_days,
            "catalog_probe": "ran" if probe["ran"] else "off (PROBE_CATALOG=False)",
            "new_lessons": probe["new"], "changed_lessons": probe["changed"], "removed_lessons": probe["removed"],
            "lessons_in_catalog": coverage[0], "with_transcript": coverage[1],
            "flagged_has_slides": coverage[2], "with_deck": coverage[3],
            "beyond_ingest_cap": f"{coverage[4]} lessons after the first {cap} are never checked (raise $ingest_max_lessons)",
            "recorded_but_no_transcript": recorded_no_transcript, "slides_but_no_deck": slides_missing,
            "gaps_already_tried_by_last_ingest": sorted(known & set(recorded_no_transcript + slides_missing)),
        }
        self.session.sql(
            """INSERT INTO runbook_source_freshness (run_id, checked_at, program_id, phase, details,
                 recommendation, reason) SELECT ?, CURRENT_TIMESTAMP(), ?, ?, PARSE_JSON(?), ?, ?""",
            params=[self.run_id, pid, phase, json.dumps(details, default=str), rec, reason]).collect()
        self.freshness = {"recommendation": rec, "reason": reason, "probe_ran": probe["ran"], "details": details}
        return rec, reason, pd.DataFrame([(k, json.dumps(v, default=str) if isinstance(v, list) else v)
                                          for k, v in details.items()], columns=["signal", "value"])

    # -- experiments ----------------------------------------------------------
    def label(self):
        label = str(self.options.get("LABEL") or "").upper()
        if not LABEL_PATTERN.match(label):
            raise ValueError("LABEL must be upper-case letters, digits or _, for example BEFORE_DESC")
        return label

    def baseline_names(self):
        suffix = self.label().lower()
        return {"corpus": f"search_corpus_{suffix}", "embeddings": f"text_embeddings_{suffix}",
                "questions": f"eval_query_embeddings_{suffix}", "results": f"retrieval_results_{suffix}",
                "scores": f"question_scores_{suffix}", "service": f"{self.config['search_service']}_{suffix}"}

    def snapshot_baseline(self):
        """Copy the current state to *_<label> before a change. Never overwrites an existing snapshot."""
        self._guard("snapshot_baseline")
        names, done = self.baseline_names(), []
        self.refresh_kinds()
        kinds = self._object_kinds()
        pairs = [("search_corpus", names["corpus"]), ("text_embeddings", names["embeddings"]),
                 ("eval_query_embeddings", names["questions"]), ("retrieval_results", names["results"])]
        for source, target in pairs:
            if target in kinds:
                done.append(f"{target}: already exists, kept")
                continue
            self.session.sql(f"CREATE TABLE {target} CLONE {source}").collect()
            done.append(f"{target}: cloned from {source}")
        if names["scores"] not in kinds:
            self.session.sql(f"CREATE TABLE {names['scores']} AS SELECT * FROM retrieval_question_scores").collect()
            done.append(f"{names['scores']}: saved from retrieval_question_scores")
        else:
            done.append(f"{names['scores']}: already exists, kept")
        self.refresh_kinds()
        return done

    def ensure_baseline_service(self):
        self._guard("ensure_baseline_service")
        names = self.baseline_names()
        self.refresh_kinds()
        kinds = self._object_kinds()
        if names["corpus"] not in kinds:
            raise RuntimeError(f"{names['corpus']} does not exist: snapshot the baseline first")
        if names["service"] in kinds:
            return f"{names['service']}: already exists"
        self.session.sql(
            f"""CREATE CORTEX SEARCH SERVICE {names['service']}
                ON search_text ATTRIBUTES source_type, lesson_slug
                WAREHOUSE = {self.config['warehouse']} TARGET_LAG = '1 day'
                EMBEDDING_MODEL = '{self.config['text_embed_model']}'
                AS SELECT source_id, source_type, lesson_slug, lesson_title, citation, search_text
                   FROM {names['corpus']}""").collect()
        self.refresh_kinds()
        return f"{names['service']}: created on {names['corpus']}"

    def score_baseline(self):
        """Score the same questions against the baseline as VECTOR_<LABEL> and CORTEX_SEARCH_<LABEL>."""
        self._guard("score_baseline")
        label, names = self.label(), self.baseline_names()
        k = int(self.config["eval_top_k"])
        out = []
        r = self.session.sql("CALL run_search_eval(?, ?, ?)",
                             params=[k, names["service"], f"CORTEX_SEARCH_{label}"]).collect()[0][0]
        out.append(json.loads(r) if isinstance(r, str) else r)
        self.session.sql("DELETE FROM retrieval_results WHERE method = ?", params=[f"VECTOR_{label}"]).collect()
        self.session.sql(
            f"""INSERT INTO retrieval_results (method, question_id, result_rank, source_id, score_cosine)
                SELECT ?, q.question_id,
                       ROW_NUMBER() OVER (PARTITION BY q.question_id
                                          ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding) DESC, e.source_id),
                       e.source_id,
                       VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding)
                FROM eval_query_embeddings q CROSS JOIN {names['embeddings']} e
                QUALIFY ROW_NUMBER() OVER (PARTITION BY q.question_id
                                           ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding) DESC, e.source_id) <= ?""",
            params=[f"VECTOR_{label}", k]).collect()
        n = self.session.sql("SELECT COUNT(*) FROM retrieval_results WHERE method = ?",
                             params=[f"VECTOR_{label}"]).collect()[0][0]
        out.append({"method": f"VECTOR_{label}", "rows": n})
        # The baseline rows just added to retrieval_results change the 09d score views. Record that as
        # this run's 09d output (and as the input of steps that read those views, e.g. 13f), so the next
        # run does not report DRIFT or rerun them for a change this run made itself.
        views = self.step_writes("09d")
        self.session.sql("UPDATE runbook_step_runs SET output_fingerprints = PARSE_JSON(?) WHERE run_id = ? AND step = '09d'",
                         params=[json.dumps(self.fingerprints(views, step="09d"), default=str), self.run_id]).collect()
        for step in [s for s in PIPELINE_ORDER if set(self.step_reads(s)) & set(views)]:
            self.session.sql("UPDATE runbook_step_runs SET input_fingerprints = PARSE_JSON(?) WHERE run_id = ? AND step = ?",
                             params=[json.dumps(self.fingerprints(self.step_reads(step)), default=str),
                                     self.run_id, step]).collect()
        return out

    def compare_ranks(self):
        label = self.label()
        return self.session.sql(f"""
            SELECT question_id, question,
                   MAX(IFF(method = 'VECTOR_{label}', first_relevant_rank, NULL))        AS vector_before,
                   MAX(IFF(method = 'VECTOR', first_relevant_rank, NULL))                AS vector_after,
                   MAX(IFF(method = 'CORTEX_SEARCH_{label}', first_relevant_rank, NULL)) AS search_before,
                   MAX(IFF(method = 'CORTEX_SEARCH', first_relevant_rank, NULL))         AS search_after,
                   MAX(IFF(method = 'IMAGE', first_relevant_rank, NULL))                 AS image_control
            FROM retrieval_question_scores
            GROUP BY question_id, question
            ORDER BY question_id""").to_pandas()

    def compare_scores(self):
        label = self.label()
        return self.session.sql(f"""
            SELECT REGEXP_REPLACE(method, '_{label}$', '') AS method_family,
                   IFF(method LIKE '%_{label}', 'before ({label})', 'after (current)') AS version,
                   questions, hit_at_1, hit_at_5, mrr_at_10, recall_at_10, ndcg_at_10
            FROM retrieval_scores
            WHERE method IN ('VECTOR', 'CORTEX_SEARCH', 'VECTOR_{label}', 'CORTEX_SEARCH_{label}', 'IMAGE')
            ORDER BY method_family, version""").to_pandas()

    def compare_margins(self):
        """What changed per answer, similarity and margin before/after (VECTOR, by label)."""
        n = self.baseline_names()
        return self.session.sql(f"""
            WITH q AS (SELECT question_id, embedding FROM eval_query_embeddings),
            rel AS (SELECT question_id, source_id FROM eval_relevant_sources),
            best_wrong AS (
                SELECT q.question_id,
                       MAX(VECTOR_COSINE_SIMILARITY(o.embedding, q.embedding)) AS wrong_before,
                       MAX(VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding)) AS wrong_after
                FROM q
                JOIN text_embeddings e ON TRUE
                JOIN {n['embeddings']} o ON o.source_id = e.source_id
                WHERE NOT EXISTS (SELECT 1 FROM rel r WHERE r.question_id = q.question_id AND r.source_id = e.source_id)
                GROUP BY q.question_id)
            SELECT rel.question_id, rel.source_id,
                   CASE
                       WHEN cb.search_text = ca.search_text THEN 'unchanged (control)'
                       WHEN ca.search_text = cb.search_text || '\\nImage description: ' || d.description
                           THEN 'search_text changed: AI_COMPLETE image description appended (step 11 -> step 6a)'
                       WHEN STARTSWITH(ca.search_text, cb.search_text)
                           THEN 'search_text changed: text added to the end that does not match slide_descriptions (check step 6a / step 11)'
                       ELSE 'search_text changed: original text was edited, not just added to (check steps 5 -> 6a)'
                   END AS change_applied,
                   IFF(STARTSWITH(ca.search_text, cb.search_text),
                       SUBSTR(ca.search_text, LENGTH(cb.search_text) + 1), NULL) AS actual_text_added,
                   IFF(nb.embedding_model = na.embedding_model, 'same model', 'MODEL CHANGED') AS model_check,
                   ROUND(VECTOR_COSINE_SIMILARITY(nb.embedding, q.embedding), 4) AS sim_before,
                   ROUND(VECTOR_COSINE_SIMILARITY(na.embedding, q.embedding), 4) AS sim_after,
                   ROUND(sim_after - sim_before, 4) AS sim_change,
                   ROUND(sim_before - bw.wrong_before, 4) AS margin_before,
                   ROUND(sim_after - bw.wrong_after, 4) AS margin_after
            FROM rel
            JOIN q ON q.question_id = rel.question_id
            JOIN {n['embeddings']} nb ON nb.source_id = rel.source_id
            JOIN text_embeddings na ON na.source_id = rel.source_id
            JOIN {n['corpus']} cb ON cb.source_id = rel.source_id
            JOIN search_corpus ca ON ca.source_id = rel.source_id
            LEFT JOIN slide_descriptions d ON d.slide_id = rel.source_id
            JOIN best_wrong bw ON bw.question_id = rel.question_id
            ORDER BY change_applied DESC, rel.question_id""").to_pandas()

    def record_scores(self):
        """Append this run's per-question scores to retrieval_question_scores_history (replaces this run's rows)."""
        self._guard("record_scores")
        # a maintenance run has no baseline, so its scores carry no label
        label = None if self.options.get("MODE") == "maintenance" else self.options.get("LABEL")
        experiment = self.options.get("EXPERIMENT_NAME")
        fp = self.eval_fingerprint()
        self.session.sql("DELETE FROM retrieval_question_scores_history WHERE run_id = ?", params=[self.run_id]).collect()
        self.session.sql(
            f"""INSERT INTO retrieval_question_scores_history (run_id, recorded_at, label, experiment_name,
                 method, k, eval_set, golden_version, eval_fingerprint, question_id, question_type, source_type,
                 answerable, first_relevant_rank, relevant_items, items_found, recall_at_10, ndcg_at_10,
                 best_correct_score)
               SELECT ?, CURRENT_TIMESTAMP(), ?, ?, method, {METRIC_K}, eval_set, $golden_version, ?, question_id,
                      question_type, source_type, TRUE, first_relevant_rank, relevant_items, items_found,
                      recall_at_10, ndcg_at_10, best_correct_score
               FROM retrieval_question_scores""",
            params=[self.run_id, label, experiment, fp]).collect()
        answers = 0
        if self._object_kinds().get("answer_judgments") == "table":
            answers = self.session.sql(
                """INSERT INTO retrieval_question_scores_history (run_id, recorded_at, label, experiment_name,
                     method, k, eval_set, golden_version, eval_fingerprint, question_id, question_type, source_type,
                     answerable, groundedness, answer_relevance, context_relevance, refused, refusal_correct, judge_model)
                   SELECT ?, CURRENT_TIMESTAMP(), ?, ?, 'ANSWER', j.gen_top_k, q.eval_set, $golden_version, ?,
                          j.question_id, q.question_type, q.source_type, q.answerable, j.groundedness,
                          j.answer_relevance, j.context_relevance, j.refused, j.refused <> q.answerable, j.judge_model
                   FROM answer_judgments j JOIN eval_questions q ON q.question_id = j.question_id
                   WHERE j.run_id = ?""",
                params=[self.run_id, label, experiment, fp, self.run_id]).collect()[0][0]
        video = 0
        if self._object_kinds().get("video_question_scores") == "view" and self.options.get("INCLUDE_VIDEO"):
            # step 13f: VIDEO_VISUAL / _AUDIO / _TRANSCRIPTION / _COMBINED ranks join the same fact,
            # so the report and the sign test treat them like any other method
            video = self.session.sql(
                f"""INSERT INTO retrieval_question_scores_history (run_id, recorded_at, label, experiment_name,
                     method, k, eval_set, golden_version, eval_fingerprint, question_id, question_type, source_type,
                     answerable, first_relevant_rank)
                   SELECT ?, CURRENT_TIMESTAMP(), ?, ?, v.method, {METRIC_K}, q.eval_set, $golden_version, ?,
                          v.question_id, q.question_type, 'video', TRUE, v.first_relevant_rank
                   FROM video_question_scores v JOIN eval_questions q ON q.question_id = v.question_id
                   WHERE v.method LIKE 'VIDEO_%'""",
                params=[self.run_id, label, experiment, fp]).collect()[0][0]
        return {"eval_fingerprint": fp, "answer_rows": answers, "video_rows": video}

    def eval_fingerprint(self):
        """One hash of the eval set (questions with type/status, and the answer list) from step 09b."""
        outs = (self.last_state("09b") or {}).get("outputs", {})
        payload = {k: outs.get(k) for k in ("eval_questions", "eval_expected")}
        return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()[:16]

    # -- paired comparison: win/loss/tie + exact sign test ------------------------
    @staticmethod
    def sign_test(wins, losses):
        """Exact two-sided binomial test on wins vs losses (ties dropped)."""
        n = wins + losses
        if n == 0:
            return 1.0
        tail = sum(math.comb(n, i) for i in range(min(wins, losses) + 1)) / 2 ** n
        return min(1.0, 2 * tail)

    def compare_methods(self, method_a, method_b, run_a=None, run_b=None, eval_set="tune", record=True):
        """Per-question paired comparison of A (baseline) vs B (variant) on reciprocal rank @10.

        A win means B ranked the first correct source higher than A (a miss counts as 1/rank = 0, so both
        missing is a tie). The overall verdict needs MIN_SHARED_QUESTIONS shared questions; slices below
        MIN_SLICE_QUESTIONS show counts only. Works for any two methods and runs, e.g. CHARACTER vs CUE.
        """
        run_a, run_b = run_a or self.run_id, run_b or self.run_id
        df = self.session.sql(
            """SELECT a.question_id, a.question_type, a.source_type,
                      a.first_relevant_rank AS rank_a, b.first_relevant_rank AS rank_b,
                      COALESCE(1 / a.first_relevant_rank, 0) AS rr_a, COALESCE(1 / b.first_relevant_rank, 0) AS rr_b,
                      a.recall_at_10 AS recall_a, b.recall_at_10 AS recall_b
               FROM retrieval_question_scores_history a
               JOIN retrieval_question_scores_history b ON b.question_id = a.question_id
               WHERE a.run_id = ? AND a.method = ? AND b.run_id = ? AND b.method = ?
                 AND a.answerable AND a.eval_set = ? AND b.eval_set = ?
               ORDER BY a.question_id""",
            params=[run_a, method_a, run_b, method_b, eval_set, eval_set]).to_pandas()
        df.columns = [c.lower() for c in df.columns]
        if not df.empty:
            diff = df.rr_b.astype(float) - df.rr_a.astype(float)
            df["outcome"] = ["win" if d > 1e-9 else "loss" if d < -1e-9 else "tie" for d in diff]
        else:
            df["outcome"] = []

        def tally(frame, min_n):
            w, l, t = (int((frame.outcome == o).sum()) for o in ("win", "loss", "tie"))
            n = len(frame)
            p = self.sign_test(w, l)
            if n < min_n:
                verdict = f"counts only (n={n} < {min_n})"
            elif p < SIGN_TEST_ALPHA:
                verdict = "improved" if w > l else "regressed"
            else:
                verdict = "inconclusive"
            mean = lambda col: round(float(frame[col].astype(float).mean()), 3) if n else None
            return {"questions": n, "wins": w, "losses": l, "ties": t, "p_value": round(p, 4),
                    "verdict": verdict, "mrr_a": mean("rr_a"), "mrr_b": mean("rr_b"),
                    "recall_a": mean("recall_a"), "recall_b": mean("recall_b")}

        overall = tally(df, MIN_SHARED_QUESTIONS)
        slices = []
        for kind in ("question_type", "source_type"):
            for value, frame in (df.groupby(kind) if not df.empty else []):
                slices.append({"slice_kind": kind, "slice": value, **tally(frame, MIN_SLICE_QUESTIONS)})
        result = {"a": f"{run_a}:{method_a}", "b": f"{run_b}:{method_b}", "eval_set": eval_set,
                  "metric": f"reciprocal rank @{METRIC_K}", **overall,
                  "summary": (f"{method_b} vs {method_a}: {overall['wins']} wins, {overall['losses']} losses, "
                              f"{overall['ties']} ties on {overall['questions']} shared questions "
                              f"(sign test p = {overall['p_value']}) -> {overall['verdict']}")}
        if record:
            self.verdicts = [v for v in self.verdicts if (v["a"], v["b"], v["eval_set"]) != (result["a"], result["b"], eval_set)]
            self.verdicts.append(result)
        return result, pd.DataFrame(slices), df

    def default_comparisons(self):
        """The comparisons every run records: baseline label vs current, champion vs this run, and methods."""
        pairs = []
        if self.options.get("MODE") in ("score_existing", "full_experiment"):
            label = self.label()
            pairs += [(f"VECTOR_{label}", "VECTOR", None), (f"CORTEX_SEARCH_{label}", "CORTEX_SEARCH", None)]
        champ = getattr(self, "champion_run_id", None)
        if champ and champ != self.run_id:
            fps = self.session.sql(
                """SELECT COUNT(DISTINCT eval_fingerprint) FROM retrieval_question_scores_history
                   WHERE run_id IN (?, ?) AND method <> 'ANSWER'""", params=[champ, self.run_id]).collect()[0][0]
            if fps == 1:
                pairs += [(m, m, champ) for m in ("VECTOR", "CORTEX_SEARCH", "IMAGE")]
            else:   # different question set or answer list: a question-by-question verdict would mislead
                self.verdicts.append({"a": f"{champ}:*", "b": f"{self.run_id}:*", "eval_set": "tune",
                                      "verdict": "not comparable",
                                      "summary": f"not compared with champion {champ}: its eval set fingerprint differs"})
        pairs.append(("VECTOR", "CORTEX_SEARCH", None))
        out = []
        for a, b, run_a in pairs:
            result, slices, detail = self.compare_methods(a, b, run_a=run_a)
            if result["questions"]:
                out.append((result, slices, detail))
        return out

    # -- reporting view ---------------------------------------------------------
    REPORT_VIEW = f"""
        CREATE OR REPLACE VIEW eval_run_report AS
        WITH f AS (
            SELECT run_id, label, experiment_name, method, k, eval_set, golden_version, eval_fingerprint,
                   question_id, question_type, source_type, answerable, first_relevant_rank, recall_at_10,
                   ndcg_at_10, groundedness, answer_relevance, context_relevance, refusal_correct
            FROM retrieval_question_scores_history),
        sliced AS (
            SELECT f.*, 'all' AS slice_kind, 'all' AS slice FROM f
            UNION ALL SELECT f.*, 'question_type', question_type FROM f
            UNION ALL SELECT f.*, 'source_type', source_type FROM f),
        cost AS (
            SELECT run_id, SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
                   SUM(u.input_tokens / 1e6 * r.credits_per_million_input
                       + COALESCE(u.output_tokens, 0) / 1e6 * COALESCE(r.credits_per_million_output, 0)) AS ai_credits,
                   COUNT_IF(u.input_tokens IS NOT NULL AND r.function_name IS NULL) AS usage_rows_without_rate
            FROM runbook_ai_usage u
            LEFT JOIN ai_token_rates r ON r.function_name = u.function_name AND r.model = u.model
            GROUP BY run_id),
        elapsed AS (SELECT run_id, ROUND(SUM(elapsed_ms) / 1000, 1) AS elapsed_s FROM runbook_step_runs GROUP BY run_id),
        fresh AS (SELECT run_id, ANY_VALUE(recommendation) AS source_freshness, ANY_VALUE(details) AS details
                  FROM runbook_source_freshness GROUP BY run_id)
        SELECT s.run_id, ANY_VALUE(r.started_at) AS started_at, ANY_VALUE(r.mode) AS mode, s.label,
               s.experiment_name, ANY_VALUE(r.baseline_run_id) AS baseline_run_id,
               ANY_VALUE(r.change_note) AS change_note, s.method, s.k, s.eval_set, s.slice_kind, s.slice,
               COUNT(*) AS questions,
               IFF(s.slice_kind = 'all', COUNT(*) >= {MIN_SHARED_QUESTIONS}, COUNT(*) >= {MIN_SLICE_QUESTIONS}) AS verdict_allowed,
               IFF(s.method = 'ANSWER', NULL, ROUND(COUNT_IF(s.first_relevant_rank = 1) / COUNT(*), 3)) AS hit_at_1,
               IFF(s.method = 'ANSWER', NULL, ROUND(COUNT_IF(s.first_relevant_rank <= 5) / COUNT(*), 3)) AS hit_at_5,
               IFF(s.method = 'ANSWER', NULL, ROUND(COUNT_IF(s.first_relevant_rank <= 10) / COUNT(*), 3)) AS hit_at_10,
               IFF(s.method = 'ANSWER', NULL, ROUND(AVG(COALESCE(1 / s.first_relevant_rank, 0)), 3)) AS mrr_at_10,
               ROUND(AVG(s.recall_at_10), 3) AS recall_at_10,
               ROUND(AVG(s.ndcg_at_10), 3) AS ndcg_at_10,
               ROUND(AVG(s.groundedness), 2) AS groundedness,
               ROUND(AVG(s.answer_relevance), 2) AS answer_relevance,
               ROUND(AVG(s.context_relevance), 2) AS context_relevance,
               ROUND(COUNT_IF(s.refusal_correct) / NULLIF(COUNT(s.refusal_correct), 0), 3) AS refusal_accuracy,
               ANY_VALUE(s.golden_version) AS golden_version,
               ANY_VALUE(s.eval_fingerprint) AS eval_fingerprint,
               COUNT(DISTINCT s.eval_fingerprint) AS eval_fingerprints_in_run,
               ANY_VALUE(r.config:text_embed_model::VARCHAR) AS text_embed_model,
               ANY_VALUE(r.config:eval_top_k::NUMBER) AS eval_top_k,
               ANY_VALUE(r.config:search_service::VARCHAR) AS search_service,
               ANY_VALUE(r.config:answer_model::VARCHAR) AS answer_model,
               ANY_VALUE(r.config:judge_model::VARCHAR) AS judge_model,
               ANY_VALUE(r.config:gen_top_k::NUMBER) AS gen_top_k,
               ANY_VALUE(c.input_tokens) AS ai_input_tokens, ANY_VALUE(c.output_tokens) AS ai_output_tokens,
               ANY_VALUE(c.ai_credits) AS ai_credits, ANY_VALUE(c.usage_rows_without_rate) AS usage_rows_without_rate,
               ANY_VALUE(e.elapsed_s) AS elapsed_s,
               ANY_VALUE(fr.source_freshness) AS source_freshness,
               ANY_VALUE(fr.details:ingest_age_days::NUMBER) AS ingest_age_days,
               ANY_VALUE(fr.details:with_transcript::NUMBER) AS lessons_with_transcript,
               ANY_VALUE(fr.details:lessons_in_catalog::NUMBER) AS lessons_in_catalog,
               ANY_VALUE(r.summary:verdicts) AS verdicts
        FROM sliced s
        JOIN runbook_runs r ON r.run_id = s.run_id
        LEFT JOIN cost c ON c.run_id = s.run_id
        LEFT JOIN elapsed e ON e.run_id = s.run_id
        LEFT JOIN fresh fr ON fr.run_id = s.run_id
        GROUP BY s.run_id, s.label, s.experiment_name, s.method, s.k, s.eval_set, s.slice_kind, s.slice"""

    def ensure_report_view(self):
        self.session.sql(self.REPORT_VIEW).collect()

    # -- human-in-the-loop review -------------------------------------------------
    def hitl_sample(self, n_random=5, run_id=None):
        """Rows where a human check adds the most: judge disagreement, near misses, and a calibration sample."""
        rid = run_id or self.run_id
        df = self.session.sql(
            """WITH a AS (SELECT question_id, groundedness, answer_relevance, context_relevance, refused, refusal_correct
                          FROM retrieval_question_scores_history WHERE run_id = ? AND method = 'ANSWER'),
                    r AS (SELECT question_id, first_relevant_rank FROM retrieval_question_scores_history
                          WHERE run_id = ? AND method = 'CORTEX_SEARCH'),
                    q AS (SELECT question_id, question, answerable FROM eval_questions),
                    base AS (
                        SELECT q.question_id, q.question, q.answerable, r.first_relevant_rank,
                               a.groundedness, a.answer_relevance, a.context_relevance, a.refused, a.refusal_correct,
                               CASE WHEN r.first_relevant_rank = 1 AND a.groundedness <= 2
                                        THEN 'disagreement: right source at #1, low groundedness'
                                    WHEN a.refusal_correct = FALSE THEN 'refusal wrong'
                                    WHEN r.first_relevant_rank BETWEEN 2 AND 5 THEN 'boundary: right source at #2-#5'
                               END AS sample_reason,
                               ROW_NUMBER() OVER (ORDER BY HASH(q.question_id, ?)) AS calibration_order
                        FROM q LEFT JOIN r ON r.question_id = q.question_id
                               LEFT JOIN a ON a.question_id = q.question_id)
               SELECT b.question_id, COALESCE(b.sample_reason, 'calibration sample') AS review_reason
               FROM base b
               WHERE b.sample_reason IS NOT NULL OR b.calibration_order <= ?""",
            params=[rid, rid, rid, int(n_random)]).to_pandas() if self._object_kinds().get("answer_judgments") else None
        if df is None:
            return None
        # Queue the sample once per run as pending rows (human_score NULL); rerunning adds nothing.
        for row in df.itertuples(index=False):
            self.session.sql(
                """MERGE INTO hitl_reviews h
                   USING (SELECT ? AS run_id, ? AS question_id, ? AS sample_reason) s
                   ON h.run_id = s.run_id AND h.question_id = s.question_id AND h.method = 'ANSWER'
                   WHEN NOT MATCHED THEN INSERT (run_id, question_id, method, sample_reason)
                   VALUES (s.run_id, s.question_id, 'ANSWER', s.sample_reason)""",
                params=[rid, row[0], row[1]]).collect()
        return self.hitl_queue(rid)

    def hitl_queue(self, run_id=None):
        """This run's review rows (pending first) with the question, answer, sources and the judge's scores."""
        return self.session.sql(
            """SELECT h.question_id, IFF(h.human_score IS NULL, 'pending', 'graded') AS status, h.sample_reason,
                      j.question, j.answer, j.sources, j.groundedness, j.answer_relevance, j.context_relevance,
                      j.refused, q.answerable, h.human_score, h.human_refusal_ok, h.notes
               FROM hitl_reviews h
               LEFT JOIN answer_judgments j ON j.run_id = h.run_id AND j.question_id = h.question_id
               LEFT JOIN eval_questions q ON q.question_id = h.question_id
               WHERE h.run_id = ? AND h.method = 'ANSWER'
               ORDER BY status DESC, h.sample_reason, h.question_id""", params=[run_id or self.run_id]).to_pandas()

    def save_review(self, question_id, human_score=None, notes=None, human_refusal_ok=None,
                    sample_reason=None, method="ANSWER", run_id=None):
        """Save one human grade (1-5) for a question's answer in a run. Saving again overwrites the grade."""
        if human_score is not None and not 1 <= int(human_score) <= 5:
            raise ValueError("human_score must be 1 to 5")
        self.session.sql(
            """MERGE INTO hitl_reviews h
               USING (SELECT ? AS run_id, ? AS question_id, ? AS method, ? AS sample_reason, ? AS human_score,
                             ? AS human_refusal_ok, ? AS notes) s
               ON h.run_id = s.run_id AND h.question_id = s.question_id AND h.method = s.method
               WHEN MATCHED THEN UPDATE SET human_score = s.human_score, human_refusal_ok = s.human_refusal_ok,
                    notes = s.notes, reviewed_by = CURRENT_USER(), reviewed_at = CURRENT_TIMESTAMP()
               WHEN NOT MATCHED THEN INSERT (run_id, question_id, method, sample_reason, human_score,
                    human_refusal_ok, notes, reviewed_by, reviewed_at)
               VALUES (s.run_id, s.question_id, s.method, COALESCE(s.sample_reason, 'added by hand'), s.human_score,
                       s.human_refusal_ok, s.notes, CURRENT_USER(), CURRENT_TIMESTAMP())""",
            params=[run_id or self.run_id, question_id, method, sample_reason, human_score,
                    human_refusal_ok, notes]).collect()

    def judge_agreement(self):
        """How close the judge's groundedness is to your grades, over every reviewed answer."""
        return self.session.sql(
            """SELECT COUNT(*) AS reviewed,
                      ROUND(AVG(ABS(h.human_score - f.groundedness)), 2) AS mean_abs_diff,
                      ROUND(COUNT_IF(ABS(h.human_score - f.groundedness) <= 1) / NULLIF(COUNT(*), 0), 3) AS within_1,
                      COUNT_IF(h.human_refusal_ok IS NOT NULL AND h.human_refusal_ok <> f.refusal_correct) AS refusal_disagreements
               FROM hitl_reviews h
               JOIN retrieval_question_scores_history f
                 ON f.run_id = h.run_id AND f.question_id = h.question_id AND f.method = 'ANSWER'
               WHERE h.human_score IS NOT NULL""").to_pandas()

    def drop_baseline_service(self):
        name = self.baseline_names()["service"]
        if self.options.get("CONFIRM_DROP"):
            self.session.sql(f"DROP CORTEX SEARCH SERVICE IF EXISTS {name}").collect()
            return f"dropped {name}"
        return f"kept {name}. To stop its daily refresh, set CONFIRM_DROP=True or run: DROP CORTEX SEARCH SERVICE {name};"

    def run_summary(self):
        return self.session.sql(
            """SELECT step, decision, status, reasons, checks, error, ended_at
               FROM runbook_step_runs WHERE run_id = ? ORDER BY started_at""",
            params=[self.run_id]).to_pandas()
