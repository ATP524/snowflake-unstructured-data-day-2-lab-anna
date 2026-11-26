-- Step 1: create your Day 2 objects. Run the whole worksheet in your schema.
-- Create the dataexpert_api_key secret separately (README step 1). Never put
-- your API key in this file.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.


-- USE ROLE all_users_role;
-- USE DATABASE bootcamp;
-- CREATE SCHEMA IF NOT EXISTS student_your_name;  -- Replace with your schema.
-- USE SCHEMA student_your_name;

-- @runbook:begin 01.build role=BUILD cost=none track=exists writes=@lesson_slides,@slide_images,api_responses,lesson_transcripts,slide_decks,slide_images,ask_log,retrieval_results,latest_api_responses,programs,lessons,academy_faqs,fmt_ts purpose=Create stages, tables (IF NOT EXISTS), catalog views and fmt_ts; safe to rerun
-- Server-side encryption lets the Cortex AI functions read staged files.
CREATE STAGE IF NOT EXISTS lesson_slides
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE STAGE IF NOT EXISTS slide_images
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

------------------------------------------------------------------------------
-- Landing tables written by the ingestion procedures
------------------------------------------------------------------------------

-- Raw JSON from /api/v1/lesson, /api/v1/academy, and /api/v1/program.
CREATE TABLE IF NOT EXISTS api_responses (
                                             run_id      VARCHAR,
                                             endpoint    VARCHAR,
                                             fetched_at  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    payload     VARIANT
    );

-- One row per lesson transcript. transcript holds the full API object,
-- including the timed cues array.
CREATE TABLE IF NOT EXISTS lesson_transcripts (
                                                  run_id            VARCHAR,
                                                  lesson_id         NUMBER,
                                                  lesson_slug       VARCHAR,
                                                  lesson_title      VARCHAR,
                                                  transcript_text   VARCHAR,
                                                  cue_count         NUMBER,
                                                  duration_seconds  FLOAT,
                                                  transcript        VARIANT,
                                                  fetched_at        TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
    );

-- One row per staged slide PDF. deck_id is the first 16 hex characters of the
-- file's SHA-256, so a changed deck gets a new ID and new page IDs.
CREATE TABLE IF NOT EXISTS slide_decks (
                                           run_id           VARCHAR,
                                           deck_id          VARCHAR,
                                           lesson_id        NUMBER,
                                           lesson_slug      VARCHAR,
                                           lesson_title     VARCHAR,
                                           source_url       VARCHAR,       -- Storage URL without its expiring signature
                                           source_filename  VARCHAR,
                                           stage_path       VARCHAR,       -- Path inside @lesson_slides
                                           file_bytes       NUMBER,
                                           sha256           VARCHAR,
                                           pdf_title        VARCHAR,       -- From the PDF's document information
                                           pdf_author       VARCHAR,
                                           pdf_page_count   NUMBER,
                                           pdf_created_at   TIMESTAMP_TZ,
                                           pdf_metadata     VARIANT,
                                           fetched_at       TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
    );


-- Written by render_slide_images() in the image path (steps 10 and 11).
CREATE TABLE IF NOT EXISTS slide_images (
                                            slide_id     VARCHAR,
                                            deck_id      VARCHAR,
                                            page_index   NUMBER,      -- Zero-based, matching AI_PARSE_DOCUMENT
                                            page_number  NUMBER,      -- One-based, as people cite pages
                                            image_path   VARCHAR,     -- Path inside @slide_images
                                            width_px     NUMBER,
                                            height_px    NUMBER,
                                            image_bytes  NUMBER,
                                            rendered_at  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
    );

-- Written by ask_course() and the evaluation steps.
CREATE TABLE IF NOT EXISTS ask_log (
                                       asked_at      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
    question      VARCHAR,
    answer_model  VARCHAR,
    answer        VARCHAR,
    sources       VARIANT
    );
-- Added for step 9e: which run asked (NULL or 'manual' when asked by hand), why ('adhoc' or 'eval'),
-- and the AI_COMPLETE token usage of the answer.
ALTER TABLE ask_log ADD COLUMN IF NOT EXISTS run_id VARCHAR;
ALTER TABLE ask_log ADD COLUMN IF NOT EXISTS purpose VARCHAR DEFAULT 'adhoc';
ALTER TABLE ask_log ADD COLUMN IF NOT EXISTS input_tokens NUMBER;
ALTER TABLE ask_log ADD COLUMN IF NOT EXISTS output_tokens NUMBER;

CREATE TABLE IF NOT EXISTS retrieval_results (
                                                 method       VARCHAR,     -- VECTOR, CORTEX_SEARCH, or IMAGE
                                                 question_id  VARCHAR,
                                                 result_rank  NUMBER,
                                                 source_id    VARCHAR
);
-- Scores next to each rank (09c, 11d, run_search_eval): cosine for VECTOR / IMAGE,
-- Cortex Search @scores for CORTEX_SEARCH. Compare scores only within one method.
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_cosine FLOAT;
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_text FLOAT;
ALTER TABLE retrieval_results ADD COLUMN IF NOT EXISTS score_rerank FLOAT;

------------------------------------------------------------------------------
-- Model the raw catalog JSON with FLATTEN (Day 1's semi-structured patterns)
------------------------------------------------------------------------------

CREATE OR REPLACE VIEW latest_api_responses AS
SELECT *
FROM api_responses
         QUALIFY ROW_NUMBER() OVER (PARTITION BY endpoint ORDER BY fetched_at DESC) = 1;

CREATE OR REPLACE VIEW programs AS
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

CREATE OR REPLACE VIEW lessons AS
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

CREATE OR REPLACE VIEW academy_faqs AS
SELECT f.value:faq_id::NUMBER       AS faq_id,
    f.value:program_id::NUMBER   AS program_id,
    f.value:question::VARCHAR    AS question,
    f.value:answer::VARCHAR      AS answer,
    f.value:sort_order::NUMBER   AS sort_order
FROM latest_api_responses r,
     LATERAL FLATTEN(INPUT => r.payload:academy:faqs) f
WHERE r.endpoint = '/api/v1/academy';

-- Seconds to a readable timestamp: 75.4 -> '1:15', 3725 -> '1:02:05'.
CREATE OR REPLACE FUNCTION fmt_ts(seconds FLOAT)
RETURNS VARCHAR
AS
$$
    IFF(seconds >= 3600,
        FLOOR(seconds / 3600)::INT::VARCHAR || ':'
            || LPAD(FLOOR(MOD(seconds, 3600) / 60)::INT::VARCHAR, 2, '0'),
        FLOOR(seconds / 60)::INT::VARCHAR)
    || ':' || LPAD(FLOOR(MOD(seconds, 60))::INT::VARCHAR, 2, '0')
$$;

-- @runbook:end 01.build

-- @runbook:begin 01.check role=CHECK expect=output purpose=Session context and fmt_ts examples ('1:15' and '1:02:05')
SELECT CURRENT_ROLE(), CURRENT_DATABASE(), CURRENT_SCHEMA(), fmt_ts(75.4), fmt_ts(3725);
-- @runbook:end 01.check
//function that we will use to format timestamp so when we query context and get video back and we get the actual human readable video timestamp
