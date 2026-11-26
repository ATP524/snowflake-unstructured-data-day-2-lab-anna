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
SERVICE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$")
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
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


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
    context = "\n\n".join(
        f"[{n}] {r.get('citation')}\n{r.get('search_text')}" for n, r in enumerate(results, 1)
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
        f"model_parameters => {{'temperature': {temperature}, 'max_tokens': {int(max_tokens)}}}"
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
    # the text 'None', while JSON null reads back as SQL NULL.
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

    purpose and run_id tag the ask_log row: 'adhoc' for hand-run questions, 'eval' for step 9e.
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
    Each row keeps the service's @scores (cosine_similarity, text_match, reranker_score).
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

    Answers are logged to ask_log with purpose 'eval' and this run_id. Judgments go to
    answer_judgments (this run's rows are replaced). The judge sees the same sources the
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
        context = "\n\n".join(
            f"[{n}] {r.get('citation')}\n{r.get('search_text')}" for n, r in enumerate(results, 1)
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
