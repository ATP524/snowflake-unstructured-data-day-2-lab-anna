create or replace view ACADEMY_FAQS(
	FAQ_ID,
	PROGRAM_ID,
	QUESTION,
	ANSWER,
	SORT_ORDER
) as
SELECT f.value:faq_id::NUMBER       AS faq_id,
    f.value:program_id::NUMBER   AS program_id,
    f.value:question::VARCHAR    AS question,
    f.value:answer::VARCHAR      AS answer,
    f.value:sort_order::NUMBER   AS sort_order
FROM latest_api_responses r,
     LATERAL FLATTEN(INPUT => r.payload:academy:faqs) f
WHERE r.endpoint = '/api/v1/academy';

create or replace view EVAL_RELEVANT_ITEMS(
	QUESTION_ID,
	ITEM_KEY,
	SOURCE_TYPE,
	SOURCE_ID
) as
SELECT DISTINCT e.question_id,
       HASH(e.source_type, e.lesson_slug, e.page_number, e.faq_id, e.start_seconds, e.end_seconds) AS item_key,
       e.source_type,
       c.source_id
FROM eval_expected e
JOIN search_corpus c
  ON c.source_type = e.source_type
 AND (   (e.source_type = 'faq' AND c.faq_id = e.faq_id)
      OR (e.source_type = 'slide' AND c.lesson_slug = e.lesson_slug
          AND c.page_number = e.page_number)
      OR (e.source_type = 'transcript' AND c.lesson_slug = e.lesson_slug
          AND c.start_seconds <= e.end_seconds AND c.end_seconds >= e.start_seconds));

create or replace view EVAL_RELEVANT_SOURCES(
	QUESTION_ID,
	SOURCE_ID
) as
SELECT DISTINCT e.question_id, c.source_id
FROM eval_expected e
JOIN search_corpus c
  ON c.source_type = e.source_type
 AND (   (e.source_type = 'faq' AND c.faq_id = e.faq_id)
      OR (e.source_type = 'slide' AND c.lesson_slug = e.lesson_slug
          AND c.page_number = e.page_number)
      OR (e.source_type = 'transcript' AND c.lesson_slug = e.lesson_slug
          AND c.start_seconds <= e.end_seconds AND c.end_seconds >= e.start_seconds));

create or replace view EVAL_RUN_REPORT(
	RUN_ID,
	STARTED_AT,
	MODE,
	LABEL,
	EXPERIMENT_NAME,
	BASELINE_RUN_ID,
	CHANGE_NOTE,
	METHOD,
	K,
	EVAL_SET,
	SLICE_KIND,
	SLICE,
	QUESTIONS,
	VERDICT_ALLOWED,
	HIT_AT_1,
	HIT_AT_5,
	HIT_AT_10,
	MRR_AT_10,
	RECALL_AT_10,
	NDCG_AT_10,
	GROUNDEDNESS,
	ANSWER_RELEVANCE,
	CONTEXT_RELEVANCE,
	REFUSAL_ACCURACY,
	GOLDEN_VERSION,
	EVAL_FINGERPRINT,
	EVAL_FINGERPRINTS_IN_RUN,
	TEXT_EMBED_MODEL,
	EVAL_TOP_K,
	SEARCH_SERVICE,
	ANSWER_MODEL,
	JUDGE_MODEL,
	GEN_TOP_K,
	AI_INPUT_TOKENS,
	AI_OUTPUT_TOKENS,
	AI_CREDITS,
	USAGE_ROWS_WITHOUT_RATE,
	ELAPSED_S,
	SOURCE_FRESHNESS,
	INGEST_AGE_DAYS,
	LESSONS_WITH_TRANSCRIPT,
	LESSONS_IN_CATALOG,
	VERDICTS
) as
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
               IFF(s.slice_kind = 'all', COUNT(*) >= 15, COUNT(*) >= 20) AS verdict_allowed,
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
        GROUP BY s.run_id, s.label, s.experiment_name, s.method, s.k, s.eval_set, s.slice_kind, s.slice;

create or replace view LATEST_API_RESPONSES(
	RUN_ID,
	ENDPOINT,
	FETCHED_AT,
	PAYLOAD
) as
SELECT *
FROM api_responses
         QUALIFY ROW_NUMBER() OVER (PARTITION BY endpoint ORDER BY fetched_at DESC) = 1;

create or replace view LESSONS(
	LESSON_ID,
	SLUG,
	TITLE,
	DESCRIPTION,
	PROGRAM_ID,
	MODULE_ID,
	MODULE_NAME,
	SORT_ORDER,
	HAS_SLIDES,
	DURATION_SECONDS,
	DATE_RECORDED
) as
SELECT l.value:lesson_id::NUMBER          AS lesson_id,
    l.value:slug::VARCHAR              AS slug,
    l.value:title::VARCHAR             AS title,
    l.value:description::VARCHAR       AS description,
    l.value:program_id::NUMBER         AS program_id,
    l.value:module_id::NUMBER          AS module_id,
    TRIM(l.value:module_name::VARCHAR) AS module_name,
       l.value:sort_order::NUMBER         AS sort_order,
    l.value:has_slides::BOOLEAN        AS has_slides,
    l.value:duration_seconds::NUMBER   AS duration_seconds,
    l.value:date_recorded::VARCHAR     AS date_recorded
FROM latest_api_responses r,
     LATERAL FLATTEN(INPUT => r.payload:lessons) l
WHERE r.endpoint = '/api/v1/lesson';

create or replace view PROGRAMS(
	PROGRAM_ID,
	PROGRAM_NAME,
	PROGRAM_SLUG,
	DESCRIPTION,
	IS_ACTIVE,
	START_DATE,
	END_DATE
) as
SELECT p.value:program_id::NUMBER     AS program_id,
    p.value:name::VARCHAR          AS program_name,
    p.value:slug::VARCHAR          AS program_slug,
    p.value:description::VARCHAR   AS description,
    p.value:is_active::BOOLEAN     AS is_active,
    p.value:start_date::DATE       AS start_date,
    p.value:end_date::DATE         AS end_date
FROM latest_api_responses r,
     LATERAL FLATTEN(INPUT => r.payload:programs) p
WHERE r.endpoint = '/api/v1/program';

create or replace view RETRIEVAL_QUESTION_SCORES(
	METHOD,
	QUESTION_ID,
	QUESTION,
	QUESTION_TYPE,
	SOURCE_TYPE,
	EVAL_SET,
	FIRST_RELEVANT_RANK,
	RELEVANT_ITEMS,
	ITEMS_FOUND,
	RECALL_AT_10,
	NDCG_AT_10,
	BEST_CORRECT_SCORE
) as
WITH slide_questions AS (
    SELECT DISTINCT question_id FROM eval_expected WHERE source_type = 'slide'
),
method_questions AS (
    SELECT m.method, q.question_id, q.question, q.question_type, q.source_type, q.eval_set
    FROM (SELECT DISTINCT method FROM retrieval_results) m
    JOIN eval_questions q ON q.answerable
    LEFT JOIN slide_questions s ON s.question_id = q.question_id
    WHERE m.method <> 'IMAGE' OR s.question_id IS NOT NULL
),
top10 AS (
    SELECT * FROM retrieval_results WHERE result_rank <= 10
),
-- first rank at which each expected item is found (IMAGE can only find slide items)
item_ranks AS (
    SELECT mq.method, mq.question_id, i.item_key, MIN(r.result_rank) AS item_rank
    FROM method_questions mq
    JOIN (SELECT DISTINCT question_id, item_key, source_type, source_id FROM eval_relevant_items) i
      ON i.question_id = mq.question_id
     AND (mq.method <> 'IMAGE' OR i.source_type = 'slide')
    LEFT JOIN top10 r
      ON r.method = mq.method AND r.question_id = mq.question_id AND r.source_id = i.source_id
    GROUP BY mq.method, mq.question_id, i.item_key
),
items AS (
    SELECT method, question_id,
           COUNT(*) AS relevant_items,
           COUNT(item_rank) AS items_found,
           SUM(IFF(item_rank IS NOT NULL, 1 / LOG(2, item_rank + 1), 0)) AS dcg
    FROM item_ranks
    GROUP BY method, question_id
),
-- ideal DCG for n items found at ranks 1..n (n capped at 10)
idcg AS (
    SELECT n, SUM(1 / LOG(2, n + 1)) OVER (ORDER BY n) AS idcg
    FROM (SELECT SEQ4() + 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 10)))
)
SELECT mq.method, mq.question_id, mq.question, mq.question_type, mq.source_type, mq.eval_set,
       MIN(IFF(rel.source_id IS NOT NULL, r.result_rank, NULL)) AS first_relevant_rank,
       ANY_VALUE(it.relevant_items) AS relevant_items,
       ANY_VALUE(it.items_found) AS items_found,
       ROUND(ANY_VALUE(it.items_found) / NULLIF(ANY_VALUE(it.relevant_items), 0), 3) AS recall_at_10,
       -- capped at 1 for the rare case where one source covers two items at the same rank
       ROUND(LEAST(1, ANY_VALUE(it.dcg) / NULLIF(ANY_VALUE(ig.idcg), 0)), 3) AS ndcg_at_10,
       MAX(IFF(rel.source_id IS NOT NULL, r.score_cosine, NULL)) AS best_correct_score
FROM method_questions mq
LEFT JOIN top10 r
  ON r.method = mq.method AND r.question_id = mq.question_id
LEFT JOIN eval_relevant_sources rel
  ON rel.question_id = r.question_id AND rel.source_id = r.source_id
LEFT JOIN items it
  ON it.method = mq.method AND it.question_id = mq.question_id
LEFT JOIN idcg ig
  ON ig.n = LEAST(it.relevant_items, 10)
GROUP BY mq.method, mq.question_id, mq.question, mq.question_type, mq.source_type, mq.eval_set;

create or replace view RETRIEVAL_SCORES(
	METHOD,
	QUESTIONS,
	HIT_AT_1,
	HIT_AT_5,
	MRR_AT_10,
	RECALL_AT_10,
	NDCG_AT_10
) as
SELECT method,
       COUNT(*) AS questions,
       ROUND(COUNT_IF(first_relevant_rank = 1) / COUNT(*), 3) AS hit_at_1,
       ROUND(COUNT_IF(first_relevant_rank <= 5) / COUNT(*), 3) AS hit_at_5,
       ROUND(AVG(COALESCE(1 / first_relevant_rank, 0)), 3) AS mrr_at_10,
       ROUND(AVG(recall_at_10), 3) AS recall_at_10,
       ROUND(AVG(ndcg_at_10), 3) AS ndcg_at_10
FROM retrieval_question_scores
GROUP BY method;

create or replace view RETRIEVAL_SCORES_BY_SLICE(
	METHOD,
	SLICE_KIND,
	SLICE,
	QUESTIONS,
	VERDICT_ALLOWED,
	HITS_AT_1,
	HITS_AT_5,
	HITS_AT_10,
	MRR_AT_10,
	RECALL_AT_10,
	NDCG_AT_10
) as
WITH s AS (
    SELECT method, 'question_type' AS slice_kind, question_type AS slice, first_relevant_rank, recall_at_10, ndcg_at_10
    FROM retrieval_question_scores
    UNION ALL
    SELECT method, 'source_type', source_type, first_relevant_rank, recall_at_10, ndcg_at_10
    FROM retrieval_question_scores
)
SELECT method, slice_kind, slice,
       COUNT(*) AS questions,
       COUNT(*) >= 20 AS verdict_allowed,
       COUNT_IF(first_relevant_rank = 1) AS hits_at_1,
       COUNT_IF(first_relevant_rank <= 5) AS hits_at_5,
       COUNT_IF(first_relevant_rank <= 10) AS hits_at_10,
       ROUND(AVG(COALESCE(1 / first_relevant_rank, 0)), 3) AS mrr_at_10,
       ROUND(AVG(recall_at_10), 3) AS recall_at_10,
       ROUND(AVG(ndcg_at_10), 3) AS ndcg_at_10
FROM s
GROUP BY method, slice_kind, slice;

create or replace view RETRIEVAL_SCORES_HISTORY(
	RUN_ID,
	RECORDED_AT,
	LABEL,
	METHOD,
	QUESTIONS,
	HIT_AT_1,
	HIT_AT_5,
	MRR_AT_10,
	RECALL_AT_10,
	NDCG_AT_10,
	EVAL_FINGERPRINT
) as
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
               GROUP BY run_id, label, method;

create or replace view SLIDE_IMAGE_VECTORS(
	SLIDE_ID,
	DECK_ID,
	PAGE_NUMBER,
	IMAGE_PATH,
	EMBEDDING
) as
SELECT slide_id, deck_id, page_number, image_path, embedding
FROM slide_image_embeddings
WHERE embedding IS NOT NULL;

create or replace view VIDEO_QUESTION_SCORES(
	QUESTION_ID,
	METHOD,
	FIRST_RELEVANT_RANK
) as
SELECT q.question_id, r.method,
       MIN(IFF(e.question_id IS NOT NULL, r.result_rank, NULL)) AS first_relevant_rank
FROM eval_video_query_embeddings q
JOIN video_eval_results r ON r.question_id = q.question_id
LEFT JOIN eval_expected e
  ON e.question_id = r.question_id
 AND e.source_type = 'transcript'
 AND e.lesson_slug = r.lesson_slug
 AND r.start_sec <= e.end_seconds
 AND r.end_sec >= e.start_seconds
GROUP BY q.question_id, r.method
UNION ALL
SELECT s.question_id, 'VECTOR (step 9)', s.first_relevant_rank
FROM retrieval_question_scores s
WHERE s.method = 'VECTOR'
  AND s.question_id IN (SELECT question_id FROM eval_video_query_embeddings);
