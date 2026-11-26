"""Export and restore engine for the Day 2 lab pipeline. Used by workspace_export.ipynb and
workspace_restore.ipynb.

Export writes the Day 2 tables, views, DDL and checks into results/<date>/ (files that go into git),
copies the Day 2 stage files into a project export stage, and uploads a media zip and a code zip.
Restore rebuilds all of it in any account and schema from those files.

Scope is Day 2 only. An object is Day 2 when its name appears in this workspace's own code
(sql/*.sql, python/*.py, lab_metadata/runbook_lib.py), or when it is a runbook experiment snapshot
(<day 2 table>_<run label>). Everything else in the schema (Day 1) is listed as excluded and never exported.
No AI calls are made by anything in this module.
"""
import csv
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import zipfile
from pathlib import Path

import pandas as pd

NULL = "\\N"                                   # CSV marker for SQL NULL (an empty string stays an empty string)
TS_FMT = "YYYY-MM-DD HH24:MI:SS.FF9"
TS_TZ_FMT = "YYYY-MM-DD HH24:MI:SS.FF9 TZH:TZM"
CODE_FILES = ("sql/*.sql", "python/*.py", "lab_metadata/runbook_lib.py")
SPLIT_OVER_BYTES = 20_000_000                  # a CSV larger than this is split into NAME.partNN.csv files
PREREQUISITES = {   # account objects the procedures need; values are never exported
    "secret": "dataexpert_api_key (GENERIC_STRING, your DataExpert API key)",
    "network_rule": "dataexpert_api_hosts (see sql/00_instructor_setup.sql)",
    "external_access_integration": "dataexpert_api_access (see sql/00_instructor_setup.sql; needs ACCOUNTADMIN)",
}


def q(name):
    """Quote an identifier exactly as stored (upper-case names from INFORMATION_SCHEMA)."""
    return '"' + name.replace('"', '""') + '"'


def rows(session, sql, params=None):
    return [r.as_dict() for r in session.sql(sql, params=params or []).collect()]


# ---------------------------------------------------------------------------
# Scope: which objects are Day 2
# ---------------------------------------------------------------------------
def code_tokens(workspace):
    """Every identifier-like word in the Day 2 code, lower case."""
    tokens = set()
    for pattern in CODE_FILES:
        for path in Path(workspace).glob(pattern):
            tokens |= {t.lower() for t in re.findall(r"[A-Za-z_][A-Za-z0-9_$]*", path.read_text(encoding="utf-8"))}
    return tokens


def day2_scope(session, workspace, database, schema, exclude_stages=()):
    """Return (included, excluded): {kind: [names]} for tables, views, stages, functions, procedures,
    file formats, Cortex Search services and secrets in database.schema."""
    tokens = code_tokens(workspace)
    labels = set()
    try:
        labels = {r["L"].lower() for r in rows(
            session, f"SELECT DISTINCT label AS l FROM {database}.{schema}.runbook_runs WHERE label IS NOT NULL")}
    except Exception:
        pass
    info = f"{database}.information_schema"
    objs = {
        "table": [r["N"] for r in rows(session, f"SELECT table_name n FROM {info}.tables WHERE table_schema = ? AND table_type = 'BASE TABLE' ORDER BY 1", [schema])],
        "view": [r["N"] for r in rows(session, f"SELECT table_name n FROM {info}.tables WHERE table_schema = ? AND table_type = 'VIEW' ORDER BY 1", [schema])],
        "stage": [r["N"] for r in rows(session, f"SELECT stage_name n FROM {info}.stages WHERE stage_schema = ? ORDER BY 1", [schema])],
        "function": sorted({r["N"] for r in rows(session, f"SELECT function_name n FROM {info}.functions WHERE function_schema = ?", [schema])}),
        "procedure": sorted({r["N"] for r in rows(session, f"SELECT procedure_name n FROM {info}.procedures WHERE procedure_schema = ?", [schema])}),
        "file_format": [r["N"] for r in rows(session, f"SELECT file_format_name n FROM {info}.file_formats WHERE file_format_schema = ? ORDER BY 1", [schema])],
        "cortex_search_service": [r["name"] for r in session.sql(f"SHOW CORTEX SEARCH SERVICES IN SCHEMA {database}.{schema}").collect()],
        "secret": [r["name"] for r in session.sql(f"SHOW SECRETS IN SCHEMA {database}.{schema}").collect()],
    }
    included, excluded = {}, {}
    table_names = {t.lower() for t in objs["table"]}
    for kind, names in objs.items():
        for name in names:
            low = name.lower()
            # a runbook snapshot: <table>_<label>, where <table> is itself Day 2 code
            snapshot = any(low.endswith("_" + lab) and low[: -len(lab) - 1] in tokens for lab in labels)
            snapshot = snapshot or any(low == f"question_scores_{lab}" for lab in labels)
            day2 = (low in tokens or snapshot) and name.upper() not in {s.upper() for s in exclude_stages}
            (included if day2 else excluded).setdefault(kind, []).append(name)
    return included, excluded


def scope_frame(included, excluded):
    out = []
    for flag, scope in (("Day 2 (exported)", included), ("excluded", excluded)):
        for kind, names in scope.items():
            out.append({"scope": flag, "kind": kind, "count": len(names), "names": ", ".join(names)})
    return pd.DataFrame(out)


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
def column_types(session, fq_name, kind="table"):
    return [(r["name"], r["type"]) for r in rows(session, f"DESCRIBE {'VIEW' if kind == 'view' else 'TABLE'} {fq_name}")
            if r.get("kind", "COLUMN") == "COLUMN"]


def export_expr(col, dtype):
    """SQL that turns one column into exact text (NULL becomes the \\N marker)."""
    c, t = q(col), dtype.upper()
    if t.startswith(("VARIANT", "OBJECT", "ARRAY")):
        e = f"TO_JSON({c})"
    elif t.startswith("VECTOR"):
        e = f"TO_JSON({c}::ARRAY)"
    elif t.startswith(("TIMESTAMP_TZ", "TIMESTAMP_LTZ")):
        e = f"TO_VARCHAR({c}, '{TS_TZ_FMT}')"
    elif t.startswith(("TIMESTAMP_NTZ", "TIMESTAMP", "DATETIME")):
        e = f"TO_VARCHAR({c}, '{TS_FMT}')"
    elif t.startswith("BINARY"):
        e = f"TO_VARCHAR({c}, 'HEX')"
    elif t.startswith(("FLOAT", "DOUBLE", "REAL")):
        e = f"TO_VARCHAR({c}, 'TM9')"      # 16 significant digits: the most Snowflake text output carries
    else:
        e = f"{c}::VARCHAR"
    return f"IFF({c} IS NULL, '{NULL.replace(chr(92), chr(92) * 2)}', {e}) AS {c}"


def export_relation(session, fq_name, kind, out_dir):
    """Write one table or view to <out_dir>/<NAME>.csv (all text, JSON for semi-structured and VECTOR).
    Returns (rows, types, file names); types is [(column, data type)]."""
    types = column_types(session, fq_name, kind)
    select = ", ".join(export_expr(c, t) for c, t in types)
    df = session.sql(f"SELECT {select} FROM {fq_name}").to_pandas()
    path = Path(out_dir) / f"{fq_name.split('.')[-1]}.csv"
    df.to_csv(path, index=False, quoting=csv.QUOTE_ALL)
    names = [path.name]
    size = path.stat().st_size
    if size > SPLIT_OVER_BYTES:       # keep every file small enough for git (GitHub warns at 50 MB, rejects > 100 MB)
        parts = -(-size // SPLIT_OVER_BYTES)
        path.unlink()
        step = -(-len(df) // parts)
        names = []
        for i in range(parts):
            part = Path(out_dir) / f"{path.stem}.part{i + 1:02d}.csv"
            df.iloc[i * step:(i + 1) * step].to_csv(part, index=False, quoting=csv.QUOTE_ALL)
            names.append(part.name)
    return len(df), types, names


def csv_paths(folder, name):
    """The exported files for one table or view: NAME.csv, or NAME.partNN.csv when it was split."""
    plain = Path(folder) / f"{name}.csv"
    return [plain] if plain.exists() else sorted(Path(folder).glob(f"{name}.part[0-9][0-9].csv"))


def table_ddl(session, fq_name, kind):
    return session.sql(f"SELECT GET_DDL('{kind}', '{fq_name}')").collect()[0][0]


def stage_manifest(session, database, schema, stages):
    out = []
    for stage in stages:
        session.sql(f"ALTER STAGE {database}.{schema}.{stage} REFRESH").collect()
        for r in rows(session, f"SELECT relative_path, size, md5 FROM DIRECTORY(@{database}.{schema}.{stage}) ORDER BY 1"):
            out.append({"stage": stage, "relative_path": r["RELATIVE_PATH"], "size": r["SIZE"], "md5": r["MD5"]})
    return pd.DataFrame(out, columns=["stage", "relative_path", "size", "md5"])


def stage_ddl(session, database, schema, stage):
    row = [r.as_dict() for r in session.sql(f"SHOW STAGES LIKE '{stage}' IN SCHEMA {database}.{schema}").collect()][0]
    enc = "SNOWFLAKE_SSE" if "NO CSE" in (row.get("type") or "") else "SNOWFLAKE_FULL"
    directory = "TRUE" if row.get("directory_enabled") == "Y" else "FALSE"
    return (f"CREATE STAGE IF NOT EXISTS {stage.lower()}\n    DIRECTORY = (ENABLE = {directory})\n"
            f"    ENCRYPTION = (TYPE = '{enc}');")


def search_service_ddl(session, database, schema, name):
    d = [r.as_dict() for r in session.sql(f"SHOW CORTEX SEARCH SERVICES LIKE '{name}' IN SCHEMA {database}.{schema}").collect()][0]
    return (f"CREATE OR REPLACE CORTEX SEARCH SERVICE {name.lower()}\n    ON {d['search_column']}\n"
            f"    ATTRIBUTES {d['attribute_columns']}\n    WAREHOUSE = '{d['warehouse']}'\n"
            f"    TARGET_LAG = '{d['target_lag']}'\n    EMBEDDING_MODEL = '{d['embedding_model']}'\nAS\n{d['definition']};"), d


def routine_ddls(session, database, schema, kind, names):
    """GET_DDL text for every overload of the named functions or procedures."""
    cmd = "SHOW USER FUNCTIONS" if kind == "function" else "SHOW USER PROCEDURES"
    out = []
    for name in names:
        for r in session.sql(f"{cmd} LIKE '{name}' IN SCHEMA {database}.{schema}").collect():
            sig = re.sub(r"\s+RETURN.*$", "", re.sub(r"DEFAULT\s+", "", r["arguments"]))   # NAME(TYPE, TYPE)
            out.append(table_ddl(session, f"{database}.{schema}.{sig}", kind.upper()))
    return out


def data_quality(session, rb):
    """Day 2 data-quality checks; each returns the number of bad rows (expect 0)."""
    checks = [
        ("corpus rows without an embedding",
         "SELECT COUNT(*) FROM search_corpus c LEFT JOIN text_embeddings e ON e.source_id = c.source_id WHERE e.embedding IS NULL"),
        ("expected answers not found in the corpus (09b.check)",
         "SELECT COUNT(*) FROM (" + re.sub(r"--[^\n]*", "", rb.sections["09b.check"].sql).split(";")[0] + ")"),
        ("answerable eval questions with no expected answer",
         "SELECT COUNT(*) FROM eval_questions q WHERE answerable AND NOT EXISTS (SELECT 1 FROM eval_expected e WHERE e.question_id = q.question_id)"),
        ("repeated (method, question, rank) in retrieval_results",
         "SELECT COUNT(*) FROM (SELECT method, question_id, result_rank FROM retrieval_results GROUP BY 1, 2, 3 HAVING COUNT(*) > 1)"),
        ("slides the 11e rule selects that have no description",
         f"SELECT COUNT(*) FROM slide_pages p WHERE ({rb.describe_filter()}) AND NOT EXISTS (SELECT 1 FROM slide_descriptions d WHERE d.slide_id = p.slide_id)"),
        ("runs still RUNNING", "SELECT COUNT(*) FROM runbook_runs WHERE status = 'RUNNING'"),
        ("champion missing", "SELECT IFF(COUNT(*) = 0, 1, 0) FROM runbook_runs WHERE promoted_at IS NOT NULL"),
    ]
    out = []
    for name, sql in checks:
        try:
            bad = session.sql(sql).collect()[0][0]
            out.append({"check": name, "bad_rows": bad, "result": "PASS" if bad == 0 else "FAIL"})
        except Exception as exc:
            out.append({"check": name, "bad_rows": None, "result": f"ERROR: {str(exc)[:150]}"})
    return pd.DataFrame(out)


def run_overview(session):
    """Latest run, champion, and check pass counts for both."""
    latest = rows(session, "SELECT run_id, status, mode, experiment_name, change_note, started_at FROM runbook_runs ORDER BY started_at DESC LIMIT 1")
    champ = rows(session, "SELECT run_id, experiment_name, promoted_at, promoted_reason FROM runbook_runs WHERE promoted_at IS NOT NULL ORDER BY promoted_at DESC LIMIT 1")
    ids = [x["RUN_ID"] for x in latest + champ]
    passes = pd.DataFrame(rows(session, f"""
        SELECT s.run_id, COUNT(*) AS checks, COUNT_IF(c.value:passed::BOOLEAN) AS passed
        FROM runbook_step_runs s, LATERAL FLATTEN(s.checks) c
        WHERE s.run_id IN ({', '.join('?' for _ in ids)}) GROUP BY s.run_id""", ids)) if ids else pd.DataFrame()
    verdicts = rows(session, """SELECT v.value:summary::VARCHAR AS summary FROM runbook_runs r, LATERAL FLATTEN(r.summary:verdicts) v
                                WHERE r.run_id = ?""", [latest[0]["RUN_ID"]]) if latest else []
    return (latest[0] if latest else {}), (champ[0] if champ else {}), passes, [v["SUMMARY"] for v in verdicts]


def gitignore_patterns(workspace):
    path = Path(workspace) / ".gitignore"
    pats = [".git/", ".ipynb_checkpoints/"]
    if path.exists():
        pats += [l.strip() for l in path.read_text().splitlines() if l.strip() and not l.startswith("#")]
    return pats


def ignored(rel, patterns):
    parts = rel.split("/")
    for p in patterns:
        if p.endswith("/"):
            if p.rstrip("/") in parts[:-1] or p.rstrip("/") == parts[0]:
                return True
        elif fnmatch.fnmatch(parts[-1], p) or fnmatch.fnmatch(rel, p):
            return True
    return False


def zip_workspace(workspace, target):
    """Zip the workspace as git would see it (respects .gitignore). Returns (files, bytes)."""
    pats, n = gitignore_patterns(workspace), 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(workspace):
            for f in files:
                full = Path(root) / f
                rel = full.relative_to(workspace).as_posix()
                if not ignored(rel, pats):
                    z.write(full, rel)
                    n += 1
    return n, Path(target).stat().st_size


def zip_stage_files(session, manifest, fq_prefix, target, tmp_dir):
    """Build the media zip one file at a time: GET, add, delete. Videos are stored, not compressed."""
    tmp_dir = Path(tmp_dir)
    with zipfile.ZipFile(target, "w", allowZip64=True) as z:
        for r in manifest.itertuples():
            sub = Path(r.relative_path).parent.as_posix()
            folder = tmp_dir / r.stage / sub
            folder.mkdir(parents=True, exist_ok=True)
            stage_dir = f"{fq_prefix}/{r.stage}" + ("" if sub == "." else f"/{sub}")
            name = Path(r.relative_path).name
            # GET a folder with an exact-name pattern, so a.mp4 never also pulls a.mp4.bak
            session.file.get(stage_dir + "/", str(folder), pattern=f"(.*/)?{re.escape(name)}")
            got = folder / name
            mode = zipfile.ZIP_STORED if got.suffix.lower() in (".mp4", ".mp3", ".mov", ".png", ".jpg") else zipfile.ZIP_DEFLATED
            z.write(got, f"{r.stage}/{r.relative_path}", compress_type=mode)
            got.unlink()
    with zipfile.ZipFile(target) as z:
        sizes = {i.filename: i.file_size for i in z.infolist()}
    bad = [f"{r.stage}/{r.relative_path}" for r in manifest.itertuples() if sizes.get(f"{r.stage}/{r.relative_path}") != r.size]
    return len(sizes), Path(target).stat().st_size, bad


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
def restore_expr(col, dtype):
    """SQL that turns the exported text back into the column's type."""
    c, t = q(col), dtype.upper()
    nul = NULL.replace("\\", "\\\\")
    if t.startswith("VARIANT"):
        e = f"PARSE_JSON({c})"
    elif t.startswith(("OBJECT", "ARRAY")):
        e = f"PARSE_JSON({c})::{t}"
    elif t.startswith("VECTOR"):
        e = f"PARSE_JSON({c})::ARRAY::{t}"
    elif t.startswith("TIMESTAMP_TZ"):
        e = f"TO_TIMESTAMP_TZ({c}, '{TS_TZ_FMT}')"
    elif t.startswith("TIMESTAMP_LTZ"):
        e = f"TO_TIMESTAMP_LTZ({c}, '{TS_TZ_FMT}')"
    elif t.startswith(("TIMESTAMP_NTZ", "TIMESTAMP", "DATETIME")):
        e = f"TO_TIMESTAMP_NTZ({c}, '{TS_FMT}')"
    elif t.startswith("BINARY"):
        e = f"TO_BINARY({c}, 'HEX')"
    else:
        e = f"{c}::{t}"
    return f"IFF({c} = '{nul}', NULL, {e})"


def load_csv(session, csv_path, fq_table, types):
    """Load one exported CSV into an existing (empty) table with exact types. Returns rows loaded."""
    df = pd.read_csv(csv_path, dtype=str, keep_default_na=False)
    if df.empty:
        return 0
    stage_name = "EXPORT_LOAD_" + hashlib.md5(fq_table.encode()).hexdigest()[:8].upper()
    session.write_pandas(df, stage_name, auto_create_table=True, table_type="temporary",
                         overwrite=True, quote_identifiers=True)
    cols = ", ".join(q(c) for c, _ in types)
    exprs = ", ".join(restore_expr(c, t) for c, t in types)
    session.sql(f"INSERT INTO {fq_table} ({cols}) SELECT {exprs} FROM {q(stage_name)}").collect()
    session.sql(f"DROP TABLE IF EXISTS {q(stage_name)}").collect()
    return len(df)


def retarget(ddl, src_db, src_schema, db, schema):
    """Point DDL text that names the source schema at the target schema."""
    return re.sub(rf"\b{src_db}\s*\.\s*{src_schema}\s*\.", f"{db}.{schema}.", ddl, flags=re.I)


def runbook_for(runbook_lib, session, workspace, options, role, database, warehouse, schema):
    """A Runbook whose session context points at the given role/database/warehouse/schema,
    without changing sql/runbook_config.sql (used for a test restore into another schema)."""
    rb = runbook_lib.Runbook(session, workspace, options)
    wanted = {"role": role, "database": database, "warehouse": warehouse, "schema": schema}
    stmts = []
    for s in rb.config_statements:
        m = re.match(r"(?i)^USE\s+(ROLE|DATABASE|WAREHOUSE|SCHEMA)\s+", s)
        stmts.append(f"USE {m.group(1).upper()} {wanted[m.group(1).lower()]}" if m else s)
    rb.config_statements = stmts
    rb.config.update({k: v for k, v in wanted.items()})
    return rb


def write_config(workspace, role, database, warehouse, schema):
    """Set the four session values in sql/runbook_config.sql, and the 07a service warehouse,
    so the restored workspace runs against the new account with no other edits."""
    cfg = Path(workspace) / "sql" / "runbook_config.sql"
    text = cfg.read_text(encoding="utf-8")
    for key, value in (("ROLE", role), ("DATABASE", database), ("WAREHOUSE", warehouse), ("SCHEMA", schema)):
        text = re.sub(rf"(?im)^USE {key} \S+;", f"USE {key} {value.lower()};", text)
    cfg.write_text(text, encoding="utf-8")
    svc = Path(workspace) / "sql" / "07_cortex_search.sql"
    s = svc.read_text(encoding="utf-8")
    svc.write_text(re.sub(r"WAREHOUSE = '[^']+'", f"WAREHOUSE = '{warehouse.upper()}'", s, count=1), encoding="utf-8")
