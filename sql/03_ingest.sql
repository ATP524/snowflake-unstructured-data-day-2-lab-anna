-- Step 3: pull the catalog, choose your program, and ingest its lessons.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.


-- 3a. Land /lesson, /academy, and /program as raw JSON. Expect counts back.
-- @runbook:begin 03a.build role=BUILD cost=external writes=api_responses purpose=Fetch the lesson, academy and program catalog from the API (3 small requests; the runbook's catalog probe)
CALL ingest_catalog();
-- @runbook:end 03a.build
--OUTPUT:
/*
{
  "academy": "loaded",
  "faqs": 9,
  "lesson": "loaded",
  "lessons": 181,
  "program": "loaded",
  "programs": 4,
  "run_id": "8bbf88a9bacc4b94b006b59666132555"
}
*/

-- 3b. Explore the raw JSON, then the modeled views over it.
-- @runbook:begin 03b.check role=CHECK expect=output purpose=Latest fetch time per endpoint and lessons in the payload
SELECT endpoint, fetched_at, ARRAY_SIZE(payload:lessons) AS lessons_in_payload
FROM latest_api_responses;
-- @runbook:end 03b.check
--OUTPUT:
/*
/api/v1/academy  2026-11-22 08:32:11.621 -0800  
/api/v1/lesson  2026-11-22 08:32:09.927 -0800  181
/api/v1/program  2026-11-22 08:32:13.210 -0800  
*/
-- @runbook:begin 03b.explore role=EXPLORE cost=none purpose=Raw JSON payloads, programs, and lessons per program
SELECT * FROM latest_api_responses; --to see JSON payload

SELECT program_id, program_name, program_slug, is_active
FROM programs
ORDER BY program_id;

-- Lessons per program. has_slides comes from the catalog; transcripts are only
-- known after requesting them.
SELECT p.program_id, p.program_name,
       COUNT(*) AS lessons,
       COUNT_IF(l.has_slides) AS lessons_with_slides
FROM lessons l
         LEFT JOIN programs p ON p.program_id = l.program_id
GROUP BY p.program_id, p.program_name
ORDER BY lessons DESC;
-- @runbook:end 03b.explore

-- 3c. Pick your program. 908 is the Senior AI Analytics Engineering Boot Camp.
-- $program_id is set once in sql/runbook_config.sql.
-- @runbook:begin 03c.explore role=EXPLORE cost=none purpose=The lessons of $program_id in course order
SELECT sort_order, slug, title, module_name, has_slides
FROM lessons
WHERE program_id = $program_id
ORDER BY sort_order, lesson_id;
-- @runbook:end 03c.explore

-- 3d. Download transcripts and slides. 
-- Lessons without them are logged as MISSING. Program 908 takes about a minute.
-- this is one of two ingest_ type functions used in 02 ingest_procedures, it is more expensive API call than ingest_catalog
-- Purpose: building the massive knowledge base
-- ATP NOTE: Snowpark and Apache Spark are basically same thing
-- @runbook:begin 03d.build role=BUILD cost=external reads=lessons writes=lesson_transcripts,slide_decks,@lesson_slides config=program_id,ingest_max_lessons purpose=Download transcripts and slide PDFs for the program (unchanged decks are skipped by sha256)
CALL ingest_lessons($program_id, $ingest_max_lessons);
-- @runbook:end 03d.build
--OUTPUT:
/*
{
  "error_details": [],
  "errors": 0,
  "lessons_checked": 40,
  "missing": 32,
  "program_id": 908,
  "run_id": "c5daca92cebb401c8ab5cdd003ffa422",
  "slide_decks_unchanged": 0,
  "slide_decks_uploaded": 3,
  "transcripts": 8
}
*/

-- @runbook:begin 03d.output role=OUTPUT purpose=Transcripts loaded per lesson, and slide decks with their PDF metadata
SELECT lesson_slug, lesson_title, cue_count,
       fmt_ts(duration_seconds) AS duration,
       LENGTH(transcript_text) AS characters --how many words were said
FROM lesson_transcripts
ORDER BY lesson_slug;
-- @runbook:end 03d.output

-- Each cue is a few seconds of speech with start and end times.
-- Pirpose: what word was said at what time
-- @runbook:begin 03d.explore role=EXPLORE cost=none purpose=First 20 transcript cues with start and end times
SELECT lesson_slug,
       c.index AS cue_index,
       c.value:start::FLOAT AS start_seconds,
    c.value:end::FLOAT AS end_seconds,
    c.value:text::VARCHAR AS cue_text
FROM lesson_transcripts t,
     LATERAL FLATTEN(INPUT => t.transcript:cues) c
ORDER BY lesson_slug, cue_index
    LIMIT 20;
-- @runbook:end 03d.explore

-- PDF metadata travels with every slide later: lesson, file, hash, author, dates.
-- @runbook:begin 03d.output_decks role=OUTPUT purpose=Slide decks with their PDF metadata and stage path
SELECT lesson_slug, source_filename, pdf_title, pdf_author, pdf_page_count,
       pdf_created_at, ROUND(file_bytes / 1e6, 1) AS mb, deck_id, stage_path
FROM slide_decks
ORDER BY lesson_slug;
-- @runbook:end 03d.output_decks
--STAGE_PATH where it sits on the STAGE


-- @runbook:begin 03d.refresh role=BUILD cost=none writes=@lesson_slides purpose=Refresh the slide stage directory so new PDFs are listed
ALTER STAGE lesson_slides REFRESH; -- needs to occur so data refreshes and we can see data
-- @runbook:end 03d.refresh

--actual PDFs sitting on STAGE
-- @runbook:begin 03d.check role=CHECK expect=output purpose=PDFs on the slide stage
SELECT relative_path, size, last_modified FROM DIRECTORY(@lesson_slides);
-- @runbook:end 03d.check
--OUTPUT:
/*
kickoff-nov26/1259d2079a8b8cdb/senior_ai_analytics_engineering_boot_camp_starting_nov_16th.pdf  7619685  2026-11-22 08:37:38.000 -0800
unstructureddatamodelingonsnowflakeday1lecture-nov26/7dfc688d47438413/w1d1.pdf  3049512  2026-11-22 08:37:44.000 -0800
unstructureddatamodelingonsnowflakeday2lecture-nov26/179dec60040446a4/w1d2.pdf  2928518  2026-11-22 08:38:25.000 -0800
*/
