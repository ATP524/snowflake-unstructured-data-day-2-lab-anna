-- Runbook config: the ONE place to set session context and shared values.
--
-- Running a step file by hand: run this file first, in the same worksheet session.
-- Running the notebook (lab_metadata/pipeline_runbook.ipynb): it reads and runs
-- this file automatically, so values are never typed in two places.
--
-- Format rule for the notebook parser: one USE or SET per line, value on the same line.

-- Session context
USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;

-- Program and ingest (steps 3 and 13)
SET program_id = 908;
SET ingest_max_lessons = 50;     -- program 908 lists 43 lessons, so 40 leaves the last 3 unchecked; raise to 50 to include them

-- Lesson slugs used by the eval answer list (step 9b)
SET lecture = 'unstructureddatamodelingonsnowflakeday1lecture-nov26';
SET lecture_day2 = 'unstructureddatamodelingonsnowflakeday2lecture-nov26';
SET lab = 'unstructureddatamodelingonsnowflakeday1lab-nov26';
SET onboarding = 'snowflakeonboardinginstructions-e4b81';
SET kickoff = 'kickoff-nov26';

-- Models (steps 6, 7, 9, 11)
SET text_embed_model = 'snowflake-arctic-embed-l-v2.0';   -- must match EMBEDDING_MODEL in the 07a service DDL
SET image_embed_model = 'voyage-multimodal-3';
SET describe_model = 'claude-sonnet-4-5';

-- Settings
SET describe_max_chars = 120;    -- 11e: describe slides whose parsed text is shorter than this
SET eval_top_k = 10;             -- 9c / 11d: results kept per question and method
SET search_service = 'course_search';   -- must match the service name in the 07a DDL

-- Eval set (step 9b): questions added in versions up to this one, and approved, are loaded
SET golden_version = 1;

-- Answer quality (step 9e, only with INCLUDE_ANSWER_EVAL=True). The judge is a different model
-- family from the answer model so it does not grade its own answers. Changing any of these
-- changes the 09e config fingerprint, so a new judge never looks like a pipeline change.
SET answer_model = 'claude-sonnet-4-5';
SET gen_top_k = 6;               -- 9e: sources passed to AI_COMPLETE (retrieval is still scored at @10)
SET judge_model = 'llama3.3-70b';
SET judge_prompt_version = 'v1'; -- bump when the judge prompt in python/course_search.py changes
SET judge_temperature = 0;

-- Run id for per-run logging (ask_log, 9e). The notebook replaces 'manual' with its run id.
SET runbook_run_id = 'manual';
