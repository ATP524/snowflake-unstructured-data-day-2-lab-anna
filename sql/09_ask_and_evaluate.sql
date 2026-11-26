-- Step 9: ask cited questions, then measure which retrieval method finds the
-- right source.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.

------------------------------------------------------------------------------
-- 9a. Ask. ask_course retrieves with Cortex Search, sends numbered sources to
-- AI_COMPLETE, and logs the answer. The default model is claude-sonnet-4-5;
-- pass a different one if your region lacks it, for example
-- CALL ask_course('...', 6, 'llama3.3-70b');
------------------------------------------------------------------------------
--NOTE: ask_course
-- @runbook:begin 09a.explore_ask role=EXPLORE cost=ai writes=ask_log purpose=Ask four cited questions with ask_course (AI_COMPLETE per call; each adds a row to ask_log)
CALL ask_course('Why should I convert video to MP3 before transcribing it?');
CALL ask_course('What is the refund policy for live boot camps?');
--OUTPUT
/*
{
  "answer": "Based on the course materials, the refund policy for live boot camps is [1][2]:\n\n- Requests made **within one week after purchase** will incur a **25% processing fee** [1][2]\n- Requests made **within two weeks after purchase** will incur a **50% processing fee** [1][2]\n- **No refunds** will be issued **after 14 days** [1][2]",
  "question": "What is the refund policy for live boot camps?",
  "sources": [
    {
      "citation": "Academy FAQ: What is the refund policy?",
      "n": 1,
      "source_id": "faq:9"
    },
    {
      "citation": "Kick off, senior_ai_analytics_engineering_boot_camp_starting_nov_16th.pdf page 14 of 19",
      "n": 2,
      "source_id": "1259d2079a8b8cdb:p014"
    },
    {
      "citation": "Unstructured Data Modeling on Snowflake Day 2 Lab, transcript about 47:09-48:32",
      "n": 3,
      "source_id": "unstructureddatamodelingonsnowflakeday2lab-nov26:t0039"
    },
    {
      "citation": "Unstructured Data Modeling on Snowflake Day 2 Lab, transcript about 35:04-36:27",
      "n": 4,
      "source_id": "unstructureddatamodelingonsnowflakeday2lab-nov26:t0029"
    },
    {
      "citation": "Kick off, senior_ai_analytics_engineering_boot_camp_starting_nov_16th.pdf page 13 of 19",
      "n": 5,
      "source_id": "1259d2079a8b8cdb:p013"
    },
    {
      "citation": "Unstructured Data Modeling on Snowflake Day 2 Lab, transcript about 48:21-49:44",
      "n": 6,
      "source_id": "unstructureddatamodelingonsnowflakeday2lab-nov26:t0040"
    }
  ]
}
*/
CALL ask_course('What are the three AI_PARSE_DOCUMENT modes and when do I use each?');
-- Not in the course materials. The right answer is a refusal.
CALL ask_course('What is the parking policy at the DataExpert office?');
-- @runbook:end 09a.explore_ask

-- Check every answer: each [n] citation must point at a retrieved source.
-- you can log the things people are asking your AI
-- ATP Note: this is where I created workspace scanner to understand the top to bottom defining custom function, writing to the custom function, and now using custom function of ask_course
-- @runbook:begin 09a.explore_log role=EXPLORE cost=none purpose=Review recent ask_log answers and citations; unpack the latest answer's sources
SELECT asked_at, question, answer,
       ARRAY_SIZE(sources) AS sources_retrieved,
       REGEXP_SUBSTR_ALL(answer, '\\[([0-9]+)\\]', 1, 1, 'e', 1) AS cited,
       answer ILIKE 'I could not find that in the course materials%' AS declined
FROM ask_log
ORDER BY asked_at DESC
LIMIT 10;

-- Unpack one answer's sources to open the original slide page or recording time.
SELECT s.value:n::INT AS n, s.value:citation::VARCHAR AS citation, c.source_type,
       c.source_filename, c.page_number, fmt_ts(c.start_seconds) AS starts_at
FROM (SELECT sources FROM ask_log ORDER BY asked_at DESC LIMIT 1) a,
     LATERAL FLATTEN(INPUT => a.sources) s
LEFT JOIN search_corpus c ON c.source_id = s.value:source_id::VARCHAR
ORDER BY n;
-- @runbook:end 09a.explore_log

------------------------------------------------------------------------------
-- 9b. Labeled questions. Each expected source was checked against program
-- 908's transcripts, slides, and FAQs. A transcript match is any chunk that
-- overlaps the time window. Questions about another program need new labels.

--ATP note: in 06 COALESCE was added to include descriptions that are created in 11 (re-ran 06,07,09 to include); thus, we also need to ensure eval questions are added to test descriptions
--descriptions only help slides whose meaning is in the picture and not in the text. Your eval set only had one such question, and it was already at #1. To show the effect, describe the right slides, ask questions only the picture can answer, and use a metric like similarity that can register an improvement at #1.
------------------------------------------------------------------------------
-- @runbook:begin 09b.build role=BUILD cost=none writes=eval_questions,eval_expected config=lecture,lecture_day2,lab,onboarding,kickoff,golden_version purpose=Load the eval questions (with type labels) for $golden_version, and load the answer list
-- version = the question-set version that added the question; $golden_version (runbook_config.sql) picks
-- which versions this run uses. origin: curated | synthetic. eval_set: tune (pick winners) | holdout
-- (report only). Any edit to a question changes the eval fingerprint, so the runbook reports
-- "not comparable" against runs scored on the old questions instead of comparing them.
CREATE OR REPLACE TABLE eval_questions (
    question_id VARCHAR, question VARCHAR, answerable BOOLEAN, note VARCHAR,
    question_type VARCHAR, source_type VARCHAR,
    origin VARCHAR DEFAULT 'curated', eval_set VARCHAR DEFAULT 'tune', version NUMBER DEFAULT 1
);
INSERT INTO eval_questions (question_id, question, answerable, note) VALUES
 ('Q01', 'Why should I convert video files to MP3 before transcribing them?', TRUE, 'transcript + slide'),
 ('Q02', 'What share of all data is unstructured text, video, and audio?', TRUE, 'transcript + slide'),
 ('Q03', 'When should I use an array data type?', TRUE, 'transcript + slide'),
 ('Q04', 'Which data types compress best in Snowflake?', TRUE, 'transcript + slide'),
 ('Q05', 'What are the three AI_PARSE_DOCUMENT modes?', TRUE, 'exact function name'),
 ('Q06', 'How can I create ground truth to evaluate AI extraction?', TRUE, 'transcript + slides'),
 ('Q07', 'When are live classes held?', TRUE, 'FAQ + schedule slide'),
 ('Q08', 'What is the refund policy for live boot camps?', TRUE, 'FAQ + slide'),
 ('Q09', 'How do I connect the lab GitHub repository in Snowflake Workspaces?', TRUE, 'two transcripts'),
 ('Q10', 'How do I reset my Snowflake password during onboarding?', TRUE, 'transcript'),
 ('Q11', 'How do I submit homework and how is it graded?', TRUE, 'slide'),
 ('Q12', 'How are study groups formed?', TRUE, 'slide'),
 ('Q13', 'Which three financial metrics does the Day 1 lab extract first?', TRUE, 'transcript'),
 ('Q14', 'Chart plotting ground truth methods by reliability versus manual effort', TRUE, 'visual slide'),
 ('Q15', 'Line chart of data volume in zettabytes from 2010 to 2025', TRUE, 'visual slide'),
 ('Q16', 'What is the parking policy at the DataExpert office?', FALSE, 'unanswerable'),
 -- add to eval_questions
 ('Q17', 'Diagram showing two parallel paths for adding structure to raw data', TRUE, 'visual slide (described)'),
 ('Q18', 'Layered graph diagram explaining how HNSW vector search works', TRUE, 'visual slide (described)'),
 ('Q19', 'Which slide(s) shows old world vs new world data modeling?', TRUE, 'visual slide (described)'),
 ('Q20', 'Which slide talks about sizing context', TRUE, 'slide'),
 ('Q21', 'Which slide shows graph for vectors using theta angle between two items?', TRUE, 'visual slide (described)');

-- question_type is the main reporting slice (visual, text, exact_term, faq, unanswerable, video);
-- source_type lists the expected source types (from eval_expected below).
UPDATE eval_questions q
SET question_type = t.question_type, source_type = t.source_type
FROM (SELECT column1 AS question_id, column2 AS question_type, column3 AS source_type FROM VALUES
        ('Q01', 'text', 'slide+transcript'),
        ('Q02', 'text', 'slide+transcript'),
        ('Q03', 'text', 'slide+transcript'),
        ('Q04', 'text', 'slide+transcript'),
        ('Q05', 'exact_term', 'slide+transcript'),
        ('Q06', 'text', 'slide+transcript'),
        ('Q07', 'faq', 'faq+slide'),
        ('Q08', 'faq', 'faq+slide'),
        ('Q09', 'text', 'transcript'),
        ('Q10', 'text', 'transcript'),
        ('Q11', 'text', 'slide'),
        ('Q12', 'text', 'slide'),
        ('Q13', 'text', 'transcript'),
        ('Q14', 'visual', 'slide'),
        ('Q15', 'visual', 'slide'),
        ('Q16', 'unanswerable', 'none'),
        ('Q17', 'visual', 'slide'),
        ('Q18', 'visual', 'slide'),
        ('Q19', 'visual', 'slide'),
        ('Q20', 'text', 'slide'),
        ('Q21', 'visual', 'slide')) t
WHERE t.question_id = q.question_id;
UPDATE eval_questions SET question_type = COALESCE(question_type, 'unlabeled'), source_type = COALESCE(source_type, 'unlabeled');

-- Only the versions this run uses.
DELETE FROM eval_questions WHERE version > $golden_version;

--TODO: if I am hard coding slug_id via lecture varible then I need to make sure I've ingested all the slugs (i.e. day1 and day2 slides)
-- $lecture, $lecture_day2, $lab, $onboarding and $kickoff are set once in sql/runbook_config.sql.
-- The 9b check below lists any answer whose lesson or page is not in the corpus, which covers the TODO above.


--For the correct item, you choose it once per question in eval_expected. Only list items that actually answer the question. If you list several, the margin uses the highest-scoring one.

-- PURPOSE: create your answer list below in eval_expected
CREATE OR REPLACE TABLE eval_expected (
    question_id VARCHAR, source_type VARCHAR, lesson_slug VARCHAR,
    page_number NUMBER, faq_id NUMBER, start_seconds FLOAT, end_seconds FLOAT
);
INSERT INTO eval_expected VALUES
 ('Q01', 'transcript', $lecture, NULL, NULL, 955, 1000),
 ('Q01', 'slide', $lecture, 13, NULL, NULL, NULL),
 ('Q02', 'transcript', $lecture, NULL, NULL, 535, 575),
 ('Q02', 'slide', $lecture, 8, NULL, NULL, NULL),
 ('Q03', 'transcript', $lecture, NULL, NULL, 1700, 1770),
 ('Q03', 'slide', $lecture, 24, NULL, NULL, NULL),
 ('Q04', 'transcript', $lecture, NULL, NULL, 2180, 2210),
 ('Q04', 'slide', $lecture, 32, NULL, NULL, NULL),
 ('Q05', 'transcript', $lecture, NULL, NULL, 1060, 1115),
 ('Q05', 'slide', $lecture, 15, NULL, NULL, NULL),
 ('Q06', 'transcript', $lecture, NULL, NULL, 1227, 1530),
 ('Q06', 'slide', $lecture, 17, NULL, NULL, NULL),
 ('Q06', 'slide', $lecture, 19, NULL, NULL, NULL),
 ('Q06', 'slide', $lecture, 20, NULL, NULL, NULL),
 ('Q07', 'faq', NULL, NULL, 8, NULL, NULL),
 ('Q07', 'slide', $kickoff, 9, NULL, NULL, NULL),
 ('Q08', 'faq', NULL, NULL, 9, NULL, NULL),
 ('Q08', 'slide', $kickoff, 14, NULL, NULL, NULL),
 ('Q09', 'transcript', $lab, NULL, NULL, 20, 70),
 ('Q09', 'transcript', $onboarding, NULL, NULL, 125, 160),
 ('Q10', 'transcript', $onboarding, NULL, NULL, 70, 100),
 ('Q11', 'slide', $kickoff, 10, NULL, NULL, NULL),
 ('Q12', 'slide', $kickoff, 7, NULL, NULL, NULL),
 ('Q13', 'transcript', $lab, NULL, NULL, 1655, 1680),
 ('Q14', 'slide', $lecture, 19, NULL, NULL, NULL),
 ('Q15', 'slide', $lecture, 3, NULL, NULL, NULL),
 -- add to eval_expected
 ('Q17', 'slide', $lecture, 11, NULL, NULL, NULL),
 ('Q18', 'slide', $lecture_day2, 25, NULL, NULL, NULL), --was hard coded b/c $lecture is set to day1; now uses $lecture_day2 from runbook_config.sql
 ('Q19', 'slide', $lecture_day2, 6, NULL, NULL, NULL),
 ('Q19', 'slide', $lecture_day2, 7, NULL, NULL, NULL),
 ('Q20', 'slide', $lecture_day2, 19, NULL, NULL, NULL),
 ('Q21', 'slide', $lecture_day2, 23, NULL, NULL, NULL)
 ;
-- @runbook:end 09b.build

-- Every expected source must exist in your corpus. Expect zero rows; a row
-- here means a lesson was not ingested or a deck changed.
-- Test what the performance of our evaluation and retrieval
-- @runbook:begin 09b.check role=CHECK expect=zero_rows purpose=Every expected answer exists in the corpus (expect zero rows)
SELECT e.*
FROM eval_expected e
WHERE NOT EXISTS (
    SELECT 1 FROM search_corpus c
    WHERE c.source_type = e.source_type
      AND (   (e.source_type = 'faq' AND c.faq_id = e.faq_id)
           OR (e.source_type = 'slide' AND c.lesson_slug = e.lesson_slug
               AND c.page_number = e.page_number)
           OR (e.source_type = 'transcript' AND c.lesson_slug = e.lesson_slug
               AND c.start_seconds <= e.end_seconds AND c.end_seconds >= e.start_seconds)));

-- @runbook:end 09b.check

-- @runbook:begin 09b.build_view role=BUILD cost=none reads=eval_expected,search_corpus writes=eval_relevant_sources,eval_relevant_items purpose=Map each expected answer to corpus source_ids (per source, and per expected item for recall and nDCG)
CREATE OR REPLACE VIEW eval_relevant_sources AS
SELECT DISTINCT e.question_id, c.source_id
FROM eval_expected e
JOIN search_corpus c
  ON c.source_type = e.source_type
 AND (   (e.source_type = 'faq' AND c.faq_id = e.faq_id)
      OR (e.source_type = 'slide' AND c.lesson_slug = e.lesson_slug
          AND c.page_number = e.page_number)
      OR (e.source_type = 'transcript' AND c.lesson_slug = e.lesson_slug
          AND c.start_seconds <= e.end_seconds AND c.end_seconds >= e.start_seconds));

-- One row per expected item (one eval_expected row) and each corpus source that covers it.
-- Recall and nDCG count items, not chunks: a long transcript window overlaps several chunks,
-- and finding any one of them finds that item.
CREATE OR REPLACE VIEW eval_relevant_items AS
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
-- @runbook:end 09b.build_view

------------------------------------------------------------------------------
-- 9c. Retrieve the top 10 for each question with both text methods.
------------------------------------------------------------------------------
-- @runbook:begin 09c.build role=BUILD cost=ai reads=eval_questions,text_embeddings,course_search writes=eval_query_embeddings,retrieval_results#VECTOR+CORTEX_SEARCH config=text_embed_model,eval_top_k,search_service purpose=Embed questions, rank VECTOR top k, run CORTEX_SEARCH top k
CREATE OR REPLACE TABLE eval_query_embeddings AS
SELECT question_id,
       AI_EMBED($text_embed_model, 'query: ' || question) AS embedding
FROM eval_questions
WHERE answerable;

-- Scores next to each rank. VECTOR and IMAGE store cosine similarity. CORTEX_SEARCH stores the
-- service's own @scores (cosine_similarity, text_match, reranker_score). The scales differ, so
-- compare scores only within one method, never across methods.
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_cosine FLOAT;
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_text FLOAT;
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_rerank FLOAT;

DELETE FROM retrieval_results WHERE method = 'VECTOR';
INSERT INTO retrieval_results (method, question_id, result_rank, source_id, score_cosine)
SELECT 'VECTOR', q.question_id,
       ROW_NUMBER() OVER (PARTITION BY q.question_id
                          ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding) DESC,
                                   e.source_id),   -- tie-breaker keeps ranks the same on every run (as in 11d)
       e.source_id,
       VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding)
FROM eval_query_embeddings q
CROSS JOIN text_embeddings e
QUALIFY ROW_NUMBER() OVER (PARTITION BY q.question_id
                           ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding) DESC,
                                    e.source_id) <= $eval_top_k;

CALL run_search_eval($eval_top_k, $search_service, 'CORTEX_SEARCH');
-- @runbook:end 09c.build

-- @runbook:begin 09c.explore role=EXPLORE cost=none purpose=Look at every method's stored results for one question (change Q15)
SELECT * FROM retrieval_results
WHERE question_id = 'Q15'
ORDER BY question_id, method, result_rank
;
-- @runbook:end 09c.explore

------------------------------------------------------------------------------
-- 9d. Score. hit@k: the share of questions with a correct source in the top k.
-- MRR: the average of 1 / rank of the first correct source (0 if none in 10).
-- IMAGE (step 11) returns only slides, so it is scored only on questions
-- that have an expected slide.
-- Every metric uses rank <= 10, whatever $eval_top_k is (the runbook stops if it is below 10),
-- so mrr_at_10 really means @10. recall_at_10 = share of the question's expected items found in the
-- top 10; ndcg_at_10 rewards finding them early (gain 1 the first time an item is found).
------------------------------------------------------------------------------
-- @runbook:begin 09d.build role=BUILD cost=none reads=retrieval_results#VECTOR+CORTEX_SEARCH+IMAGE,eval_questions,eval_expected,eval_relevant_sources,eval_relevant_items writes=retrieval_question_scores purpose=Per-question first relevant rank, recall@10, nDCG@10 and best correct score for every method (new method labels appear automatically)
CREATE OR REPLACE VIEW retrieval_question_scores AS
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
-- @runbook:end 09d.build

-- @runbook:begin 09d.explore_all role=EXPLORE cost=none purpose=Every per-question rank row (long; the runbook shows the pivoted version)
SELECT * FROM retrieval_question_scores;
-- @runbook:end 09d.explore_all

-- is it in first result? is it in 5th result?
-- are we putting bad data into vectors?
-- If a question has several correct items, use the best correct one via first_relevant_rank counts
-- @runbook:begin 09d.build_scores role=BUILD cost=none reads=retrieval_question_scores writes=retrieval_scores,retrieval_scores_by_slice purpose=hit@1, hit@5, MRR@10, recall@10 and nDCG@10 per method, and per question_type / source_type slice with question counts
CREATE OR REPLACE VIEW retrieval_scores AS
SELECT method,
       COUNT(*) AS questions,
       ROUND(COUNT_IF(first_relevant_rank = 1) / COUNT(*), 3) AS hit_at_1,
       ROUND(COUNT_IF(first_relevant_rank <= 5) / COUNT(*), 3) AS hit_at_5,
       ROUND(AVG(COALESCE(1 / first_relevant_rank, 0)), 3) AS mrr_at_10,
       ROUND(AVG(recall_at_10), 3) AS recall_at_10,
       ROUND(AVG(ndcg_at_10), 3) AS ndcg_at_10
FROM retrieval_question_scores
GROUP BY method;

-- Each slice shows its question count. Slices under 20 questions are for reading counts, not for
-- picking a winner (verdict_allowed = FALSE).
CREATE OR REPLACE VIEW retrieval_scores_by_slice AS
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
-- @runbook:end 09d.build_scores

-- @runbook:begin 09d.output role=OUTPUT purpose=Scores per method, scores per slice (counts), then where the methods disagree per question
SELECT * FROM retrieval_scores ORDER BY method;

SELECT * FROM retrieval_scores_by_slice ORDER BY slice_kind, slice, method;

-- Where do the methods disagree? Start the discussion here.
SELECT question_id, question,
       MAX(IFF(method = 'VECTOR', first_relevant_rank, NULL)) AS vector_rank, --cosine simularity method 
       MAX(IFF(method = 'CORTEX_SEARCH', first_relevant_rank, NULL)) AS search_rank, --cortex indexing method
       MAX(IFF(method = 'IMAGE', first_relevant_rank, NULL)) AS image_rank
FROM retrieval_question_scores
GROUP BY question_id, question
ORDER BY question_id;
-- @runbook:end 09d.output

------------------------------------------------------------------------------
-- 9e. Answer quality (optional; the runbook runs it only with INCLUDE_ANSWER_EVAL=True).
-- run_answer_eval answers every eval question the way ask_course does (Cortex Search top
-- $gen_top_k -> AI_COMPLETE with $answer_model), then a pinned judge ($judge_model, temperature
-- $judge_temperature, prompt $judge_prompt_version) grades groundedness, answer relevance and
-- context relevance from 1 to 5 and says whether the answer refused. Q16 (unanswerable) should be
-- refused: refusal_correct = (refused <> answerable). Retrieval is still scored at @10 in 9d.
-- Cost: 2 AI_COMPLETE calls and 1 search per question; tokens are saved per call.
------------------------------------------------------------------------------
-- @runbook:begin 09e.build role=BUILD cost=ai reads=eval_questions,course_search writes=answer_judgments config=answer_model,gen_top_k,judge_model,judge_prompt_version,judge_temperature,search_service purpose=Answer every eval question with AI_COMPLETE, then grade each answer with the pinned judge model
CREATE TABLE IF NOT EXISTS answer_judgments (
    run_id VARCHAR, question_id VARCHAR, question VARCHAR, answer_model VARCHAR, gen_top_k NUMBER,
    answer VARCHAR, sources VARIANT, judge_model VARCHAR, judge_prompt_version VARCHAR,
    groundedness NUMBER, answer_relevance NUMBER, context_relevance NUMBER, refused BOOLEAN,
    rationale VARCHAR, judge_error VARCHAR, answer_input_tokens NUMBER, answer_output_tokens NUMBER,
    judge_input_tokens NUMBER, judge_output_tokens NUMBER, judged_at TIMESTAMP_TZ
);

CALL run_answer_eval($gen_top_k, $answer_model, $judge_model, $judge_prompt_version,
                     $judge_temperature, $search_service, $runbook_run_id);
-- @runbook:end 09e.build

-- @runbook:begin 09e.check role=CHECK expect=zero_rows purpose=Every eval question has a judged answer for this run (expect zero rows; empty when 9e did not run this time)
SELECT q.question_id, j.judge_error
FROM eval_questions q
LEFT JOIN answer_judgments j ON j.question_id = q.question_id AND j.run_id = $runbook_run_id
WHERE (j.question_id IS NULL OR j.judge_error IS NOT NULL OR j.groundedness IS NULL)
  AND EXISTS (SELECT 1 FROM answer_judgments WHERE run_id = $runbook_run_id);
-- @runbook:end 09e.check

-- @runbook:begin 09e.output role=OUTPUT purpose=Answer quality per question for this run, lowest groundedness first
SELECT j.question_id, q.question_type, q.answerable, j.refused,
       j.refused <> q.answerable AS refusal_correct,   -- refusing is correct exactly when the question is unanswerable
       j.groundedness, j.answer_relevance, j.context_relevance, j.rationale, LEFT(j.answer, 300) AS answer
FROM answer_judgments j
JOIN eval_questions q ON q.question_id = j.question_id
WHERE j.run_id = $runbook_run_id
ORDER BY j.groundedness NULLS FIRST, j.question_id;
-- @runbook:end 09e.output

-- What did a method return instead? Change the question and method.
-- @runbook:begin 09d.explore_returned role=EXPLORE cost=none purpose=What one method returned for one question, with relevant flags (change method and Q14)
SELECT r.result_rank, c.source_type, c.citation,
       rel.source_id IS NOT NULL AS relevant
FROM retrieval_results r
JOIN search_corpus c ON c.source_id = r.source_id
LEFT JOIN eval_relevant_sources rel
  ON rel.question_id = r.question_id AND rel.source_id = r.source_id
WHERE r.method = 'CORTEX_SEARCH' AND r.question_id = 'Q14'
ORDER BY r.result_rank;
-- @runbook:end 09d.explore_returned



--Questions aren't the only way to move scores. There are three changes you can make:

--1. Better metric (no new questions needed). Rank only changes when two results swap places. Similarity scores show whether the correct slide moved closer to the question, even when it stays at #1. Compare the old and new embeddings:
-- comparing old and new embeddings:
-- @runbook:begin 09x.sim_before_after role=EXPERIMENT cost=none reads=text_embeddings_before_desc,text_embeddings purpose=Hand-run: similarity before/after for answers that got a description (the runbook compare section runs this by label)
WITH q AS (SELECT question_id, embedding FROM bootcamp.atp524.eval_query_embeddings),
rel AS (SELECT r.question_id, r.source_id FROM bootcamp.atp524.eval_relevant_sources r
        JOIN bootcamp.atp524.slide_descriptions d ON d.slide_id = r.source_id)
SELECT rel.question_id, rel.source_id,
       ROUND(VECTOR_COSINE_SIMILARITY(o.embedding, q.embedding), 4) AS sim_before,
       ROUND(VECTOR_COSINE_SIMILARITY(n.embedding, q.embedding), 4) AS sim_after
FROM rel
JOIN q ON q.question_id = rel.question_id
JOIN bootcamp.atp524.text_embeddings_before_desc o ON o.source_id = rel.source_id
JOIN bootcamp.atp524.text_embeddings n ON n.source_id = rel.source_id;
-- @runbook:end 09x.sim_before_after


--OUTPUT:
/*
QUESTION_ID	SOURCE_ID	SIM_BEFORE	SIM_AFTER
Q15	7dfc688d47438413:p003	0.2161	0.4805
*/

/*
Also track how far the correct slide is ahead of the best wrong result. A bigger gap means a more reliable #1.
What "margin" means
For one question, the search engine scores every item in the corpus and sorts them. Rank only tells you where the correct item landed. Margin tells you by how much it won:
margin = similarity(correct item) − similarity(best WRONG item)
The process
Score. For each question, calculate similarity against every corpus item.
Label. Mark each item correct or wrong using eval_relevant_sources.
Reduce. Per question, take the max correct score and the max wrong score.
Subtract. Margin = best correct − best wrong.
Compare. Put runs side by side (before/after a change) and summarize: average margin and the number of fragile wins (0 < margin < 0.02, for example).


2. Better inputs. Change which slides get described: lower the cutoff, or describe every slide in the lecture decks. This covers the Q06 and Q14 charts. Also tighten the prompt so it skips colors and backgrounds and focuses on chart type, axes, trends and the main point.

3. Harder questions. Add questions that only a description could answer. That means questions about what's drawn, not words printed on the slide.
*/

--VECTOR "before" for new questions: run the step 9 VECTOR ranking against the cloned embeddings, after step 9 has embedded the new questions into eval_query_embeddings:
-- (The runbook now scores every question against the baseline as method VECTOR_<LABEL> in retrieval_results.)
-- @runbook:begin 09x.vector_new_q role=EXPERIMENT cost=none reads=text_embeddings_before_desc writes=vector_new_q_before_desc purpose=Hand-run: VECTOR top 10 for new questions against the before-descriptions embeddings
CREATE OR REPLACE TABLE bootcamp.atp524.vector_new_q_before_desc AS
SELECT q.question_id,
       ROW_NUMBER() OVER (PARTITION BY q.question_id
                          ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.embedding) DESC, e.source_id) AS result_rank,
       e.source_id
FROM bootcamp.atp524.eval_query_embeddings q
CROSS JOIN bootcamp.atp524.text_embeddings_before_desc e
WHERE q.question_id NOT IN (SELECT question_id FROM bootcamp.atp524.question_scores_before_desc)
QUALIFY result_rank <= 10
ORDER BY question_id, result_rank;
-- @runbook:end 09x.vector_new_q




--Query that keeps the context: this version covers every relevant answer, not just described ones, so unchanged answers act as a control.
-- It also only measures the VECTOR method. CORTEX_SEARCH adds keyword matching and doesn't expose these similarity scores the same way.
--For each row it shows what changed, the added text, and how far ahead of the best wrong result the correct answer is:
-- @runbook:begin 09x.margin role=EXPERIMENT cost=none reads=text_embeddings_before_desc,search_corpus_before_desc purpose=Hand-run: what changed, similarity and margin before/after for every answer (the runbook compare section runs this by label)
WITH q AS (
    SELECT question_id, embedding FROM bootcamp.atp524.eval_query_embeddings
),
rel AS (
    SELECT question_id, source_id FROM bootcamp.atp524.eval_relevant_sources
)
,
-- best similarity among WRONG results, before and after
best_wrong AS 
(
    SELECT q.question_id,
           MAX(VECTOR_COSINE_SIMILARITY(o.embedding, q.embedding)) AS wrong_before,
           MAX(VECTOR_COSINE_SIMILARITY(n.embedding, q.embedding)) AS wrong_after
    FROM q
    JOIN bootcamp.atp524.text_embeddings n ON TRUE
    JOIN bootcamp.atp524.text_embeddings_before_desc o ON o.source_id = n.source_id
    WHERE NOT EXISTS (SELECT 1 FROM rel r WHERE r.question_id = q.question_id AND r.source_id = n.source_id)
    GROUP BY q.question_id
)
SELECT rel.question_id,
       rel.source_id,
       -- IFF(cb.search_text = ca.search_text, 'unchanged (control)',
       --     'search_text changed: AI_COMPLETE image description appended (step 11 -> step 6a)') AS change_applied,
CASE
        WHEN cb.search_text = ca.search_text
            THEN 'unchanged (control)'
        WHEN ca.search_text = cb.search_text || '\nImage description: ' || d.description
            THEN 'search_text changed: AI_COMPLETE image description appended (step 11 -> step 6a)'
        WHEN STARTSWITH(ca.search_text, cb.search_text)
            THEN 'search_text changed: text added to the end that does not match slide_descriptions (check step 6a / step 11)'
        ELSE 'search_text changed: original text was edited, not just added to (check steps 5 -> 6a)'
    END AS change_applied,
IFF(STARTSWITH(ca.search_text, cb.search_text),
    SUBSTR(ca.search_text, LENGTH(cb.search_text) + 1),
    NULL)                                                  AS actual_text_added,   -- the real difference, read from the tables
IFF(nb.embedding_model = na.embedding_model,
    'same model', 'MODEL CHANGED')                         AS model_check,
       nb.embedding_model                                                AS model_before,
       na.embedding_model                                                AS model_after,
       LENGTH(cb.search_text)                                            AS chars_before,
       LENGTH(ca.search_text)                                            AS chars_after,
       -- LEFT(d.description, 200)                                          AS text_added,
       ROUND(VECTOR_COSINE_SIMILARITY(nb.embedding, q.embedding), 4)     AS sim_before,
       ROUND(VECTOR_COSINE_SIMILARITY(na.embedding, q.embedding), 4)     AS sim_after,
       ROUND(sim_after - sim_before, 4)                                  AS sim_change,
       ROUND(bw.wrong_before,4)                                          AS sim_wrong_before,
       ROUND(sim_before - bw.wrong_before, 4)                            AS sim_margin_before,  -- >0 = ranked above every wrong result
       ROUND(wrong_after,4)                                              AS sim_wrong_after,
       ROUND(sim_after  - bw.wrong_after, 4)                             AS sim_margin_after
FROM rel
JOIN q ON q.question_id = rel.question_id
JOIN bootcamp.atp524.text_embeddings_before_desc nb ON nb.source_id = rel.source_id
JOIN bootcamp.atp524.text_embeddings            na ON na.source_id = rel.source_id
JOIN bootcamp.atp524.search_corpus_before_desc  cb ON cb.source_id = rel.source_id
JOIN bootcamp.atp524.search_corpus              ca ON ca.source_id = rel.source_id
LEFT JOIN bootcamp.atp524.slide_descriptions    d  ON d.slide_id   = rel.source_id
JOIN best_wrong bw ON bw.question_id = rel.question_id
ORDER BY change_applied DESC, rel.question_id;
-- @runbook:end 09x.margin


--example method for margin_before and margin_after
--margin before = 0.2161 − 0.3905 = −0.1744   (correct slide lost to p002)
--margin after  = 0.4805 − 0.4271 = +0.0534   (correct slide wins)

/*
margin is worth tracking: similarity alone shows a big gain for p003 from day1, but part of it is offset by p002 rising, too,

--the descriptions did change Q15's rankings.

Method	Saved "before" rank	Rank now
VECTOR	NULL (not in the top 10)	1
CORTEX_SEARCH	NULL (not in the top 10)	1
IMAGE	1	1 (control, unaffected as expected)
Earlier I said Q15 was "already #1 before the change", so a 0 difference was guaranteed. That was wrong. I read the current scores, which were taken after your rerun, instead of question_scores_before_desc. In your comparison query, improvement = rank_before − rank_after is NULL for these rows, not 0, because rank_before is NULL. So "all integer comparisons are 0" was correct, but the two rows that improved were the NULLs. Q15 went from not found to #1 in both text methods. Your other conclusions hold: only one question could be affected, so this is one success, not a reliable rate.

What the side-effect sentence means
Q15 under VECTOR, before and after:

Item	Before	After	Change	Rank before → after
p003 (correct, line chart)	0.2161	0.4805	+0.2644	#49 → #1
p002 (wrong, "1 billion Terabytes")	0.3905	0.4271	+0.0365	#1 → #2
t0028 (wrong, transcript)	0.3044	0.3043	0	#2 → #3
Both slides got a description, because both were under 120 characters. Both descriptions are about data volume, so both moved closer to the question.

text
margin before = 0.2161 − 0.3905 = −0.1744   (correct slide lost to p002)
margin after  = 0.4805 − 0.4271 = +0.0534   (correct slide wins)
If only p003 had been described, the margin would have been 0.4805 − 0.3905 = +0.0900. Because p002 also rose by 0.0365, the real margin is +0.0534. About 40% of the potential lead was cancelled by the competitor improving too.

Why that matters
Looking only at p003's similarity (+0.26) suggests a big, safe win.
The margin shows the actual result: it now wins, but only by 0.05 over a slide that also benefited.
So enriching every slide with descriptions doesn't only help correct answers. It also makes similar wrong answers more competitive. Measuring the margin is how you see that trade-off, and it's a reason to check descriptions on other questions too, not just on the ones they're meant to help.
*/

--Use it in place of the change_applied and text_added columns in the earlier query, with the same joins (cb/ca = corpus before/after, nb/na = embeddings before/after, d = slide_descriptions).
-- Kept for reference only: this is an unfinished column list (no SELECT or FROM), so it is commented out
-- to let the file run end to end. The revised CASE is already in the 09x.margin query above.
/*
CASE
    WHEN cb.search_text = ca.search_text
        THEN 'unchanged (control)'
    WHEN ca.search_text = cb.search_text || '\nImage description: ' || d.description
        THEN 'ONLY change: slide_descriptions.description appended'
    WHEN STARTSWITH(ca.search_text, cb.search_text)
        THEN 'text appended, but not exactly the description'
    ELSE 'text changed in some other way'
END                                                        AS change_applied,
IFF(STARTSWITH(ca.search_text, cb.search_text),
    SUBSTR(ca.search_text, LENGTH(cb.search_text) + 1),
    NULL)                                                  AS actual_text_added,   -- the real difference, read from the tables
IFF(nb.embedding_model = na.embedding_model,
    'same model', 'MODEL CHANGED')                         AS model_check,
*/