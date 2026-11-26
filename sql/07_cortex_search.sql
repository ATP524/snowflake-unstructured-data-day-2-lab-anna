-- Step 7: build a Cortex Search service over the corpus and compare its hybrid
-- (keyword + vector) ranking with the vector-only ranking from step 6.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.

--TODO: add OpenAI integration to this to get better value 

-- 7a. Cortex Search creates and refreshes its own embeddings, so it reads
-- search_text directly, not text_embeddings. ATTRIBUTES are filterable columns.
-- Replace COURSE_WAREHOUSE with your assigned warehouse. The first build takes
-- a few minutes.

--creates indexed version of vectors to search in faster and more convenient way; indexes the embeddings for faster lookup
-- runs embeddings and then Indexes those embeddings
-- DDL cannot read session variables here: the service name, WAREHOUSE and EMBEDDING_MODEL
-- below must match $search_service, the USE WAREHOUSE and $text_embed_model in
-- sql/runbook_config.sql. The notebook runbook checks this and warns on a mismatch.
-- @runbook:begin 07a.build role=BUILD cost=ai reads=search_corpus writes=course_search config=text_embed_model,search_service purpose=Build the Cortex Search service (indexing credits; refreshes daily)
CREATE OR REPLACE CORTEX SEARCH SERVICE course_search
    ON search_text
    ATTRIBUTES source_type, lesson_slug
    WAREHOUSE = 'COMPUTE_WH'
    TARGET_LAG = '1 day'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS
SELECT source_id, source_type, lesson_slug, lesson_title, citation, search_text
FROM search_corpus;
-- @runbook:end 07a.build

-- CONTEXT ON BELOW:
/*
What to look at in the result:

Indexing / serving state. Shows whether the index has finished building and whether queries can be served. If you query with SEARCH_PREVIEW before it's ready, you can get errors or empty results.
Data timestamp. When the service last read search_corpus. After you rerun step 6 with the slide descriptions, this tells you whether the service has picked up the new text.
Source row count. Should match SELECT COUNT(*) FROM search_corpus.
Search column, attribute columns, definition. Confirm it indexes search_text, filters on source_type and lesson_slug, and reads from search_corpus.
*/



-- @runbook:begin 07a.check role=CHECK expect=output,output,output purpose=Service state, rows and definition; source_data_num_rows should equal the corpus count
SHOW CORTEX SEARCH SERVICES LIKE 'course_search';
--ATP NOTE: vector similarity matching is slow; search service is faster and gives us ability to filter for a specific source type; filtering on metadata is very important!
SELECT COUNT(*) FROM search_corpus; --PASS both 337
--For more detail on the same service, run:
DESCRIBE CORTEX SEARCH SERVICE course_search;
-- @runbook:end 07a.check

-- 7b. Query it. SEARCH_PREVIEW takes literal arguments only, so edit the text
-- inside the JSON to ask something else.
-- @runbook:begin 07b.explore role=EXPLORE cost=ai purpose=Ask the service one question and preview the top 5 results
SELECT r.index + 1 AS result_rank,
       r.value:source_type::VARCHAR AS source_type,
    r.value:citation::VARCHAR AS citation,
       LEFT(r.value:search_text::VARCHAR, 220) AS preview
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    $search_service,
    '{"query": "Why should I convert video to MP3 before transcribing it?",
      "columns": ["source_id", "source_type", "citation", "search_text"],
      "limit": 5}'
    )):results)) r;
-- @runbook:end 07b.explore

-- 7c. Filter with attributes: the same question, slides only.
-- @runbook:begin 07c.explore role=EXPLORE cost=ai purpose=Same question filtered to slides with an ATTRIBUTES filter
SELECT r.index + 1 AS result_rank,
       r.value:citation::VARCHAR AS citation,
       LEFT(r.value:search_text::VARCHAR, 220) AS preview
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    $search_service,
    '{"query": "Why should I convert video to MP3 before transcribing it?",
      "columns": ["source_id", "citation", "search_text"],
      "filter": {"@eq": {"source_type": "slide"}},
      "limit": 5}'
    )):results)) r;
-- @runbook:end 07c.explore

-- 7d. Exact terms are where keyword matching helps. Compare both rankings for
-- a query with a function name in it.
-- @runbook:begin 07d.explore role=EXPLORE cost=ai purpose=Vector-only vs Cortex Search ranking for a query with an exact function name
SET question = 'What does AI_PARSE_DOCUMENT LAYOUT mode do?';

WITH q AS (
    SELECT AI_EMBED($text_embed_model, 'query: ' || $question) AS v
),
     vector_rank AS (
         SELECT c.citation,
                ROW_NUMBER() OVER (ORDER BY VECTOR_COSINE_SIMILARITY(e.embedding, q.v) DESC) AS rnk
         FROM text_embeddings e
                  JOIN search_corpus c ON c.source_id = e.source_id
                  CROSS JOIN q
             QUALIFY rnk <= 5
    ),
    search_rank AS (
SELECT r.value:citation::VARCHAR AS citation, r.index + 1 AS rnk
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    $search_service,
    '{"query": "What does AI_PARSE_DOCUMENT LAYOUT mode do?",
      "columns": ["citation"], "limit": 5}'
    )):results)) r
    )
SELECT COALESCE(v.rnk, s.rnk) AS result_rank,
       v.citation AS vector_only,
       s.citation AS cortex_search
FROM vector_rank v
         FULL OUTER JOIN search_rank s ON s.rnk = v.rnk
ORDER BY result_rank;
-- @runbook:end 07d.explore


--If we want to be able to compare previous CORTEXT_SEARCH index to new one, we need to export:
-- Comparing by creating a second service on the cloned corpus
-- run_search_eval now takes service_name and method_label (08_search_procedures.sql), so a baseline service can be scored
-- without editing the procedure: CALL run_search_eval($eval_top_k, 'course_search_before_desc', 'CORTEX_SEARCH_BEFORE_DESC');
-- Indexing the service also costs credits, and it keeps refreshing daily until you DROP it. IMAGE doesn't need a "before". The descriptions don't affect it.
-- To match the new questions to the right old ranks in your side-by-side query, set the relevant results with eval_relevant_sources, the same way retrieval_question_scores does.
-- The notebook runbook (experiment mode) creates and scores this baseline service by label.



-- @runbook:begin 07x.experiment role=EXPERIMENT cost=ai reads=search_corpus_before_desc writes=course_search_before_desc purpose=Hand-run version: baseline service over the before-descriptions corpus (drop when done)
CREATE OR REPLACE CORTEX SEARCH SERVICE bootcamp.atp524.course_search_before_desc
    ON search_text
    ATTRIBUTES source_type, lesson_slug
    WAREHOUSE = 'COMPUTE_WH'
    TARGET_LAG = '1 day'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS
SELECT source_id, source_type, lesson_slug, lesson_title, citation, search_text
FROM bootcamp.atp524.search_corpus_before_desc;
-- @runbook:end 07x.experiment


--run_search_eval used to have SERVICE_NAME = "course_search" hard-coded (08_search_procedures.sql); it now takes service_name and method_label parameters. Indexing the service also costs credits, and it keeps refreshing daily until you DROP it.
