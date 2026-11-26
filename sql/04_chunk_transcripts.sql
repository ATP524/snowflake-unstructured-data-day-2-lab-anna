-- Step 4: chunk each full transcript with SPLIT_TEXT_RECURSIVE_CHARACTER.
-- No cues: the splitter works on the punctuated transcript_text directly, and
-- each chunk gets an estimated time range from where it sits in the text.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.

-- 4a. Look at what you are splitting: one long, punctuated string per lesson.
-- @runbook:begin 04a.explore role=EXPLORE cost=none purpose=Preview each lesson's full transcript text before chunking
SELECT lesson_slug, LENGTH(transcript_text) AS characters,
       fmt_ts(duration_seconds) AS duration,
    LEFT(transcript_text, 400) AS preview
FROM lesson_transcripts
WHERE TRIM(transcript_text) <> ''
ORDER BY lesson_slug;
-- @runbook:end 04a.explore

-- 4b. Chunk. Sizes are characters, not tokens: 1,500 characters is roughly
-- 300 tokens or 90 seconds of speech, under the 512-token chunk size
-- Snowflake recommends for Cortex Search. The 200-character overlap repeats
-- a sentence or two so a sentence on a boundary appears whole in at least one
-- chunk. The default separators go from coarse to fine: paragraphs, lines,
-- words, then characters as a last resort.
--
-- Times are estimates. Speech runs at a roughly steady rate, so a chunk that
-- starts 40% of the way through the text starts about 40% of the way through
-- the recording. Expect them to drift by tens of seconds.
-- @runbook:begin 04b.build role=BUILD cost=none reads=lesson_transcripts writes=transcript_chunks purpose=Split each transcript into overlapping 1,500-character chunks with estimated times
CREATE OR REPLACE TABLE transcript_chunks AS
WITH clean AS (
    -- Collapse repeated spaces first. The splitter drops empty pieces, so
    -- double spaces would make a chunk impossible to find in the original.
    SELECT lesson_id, lesson_slug, lesson_title, duration_seconds,
           TRIM(REGEXP_REPLACE(transcript_text, '[ \\t]+', ' ')) AS full_text
    FROM lesson_transcripts
    WHERE TRIM(transcript_text) <> ''
),
split AS (
    SELECT c.lesson_id, c.lesson_slug, c.lesson_title,
           c.duration_seconds,
           LENGTH(c.full_text) AS total_characters,
           s.index AS chunk_index,
           s.value::VARCHAR AS chunk_text,
           -- Where the chunk starts in the full text (1-based; 0 = not found).
           POSITION(s.value::VARCHAR IN c.full_text) AS start_char
    FROM clean c,
        --expanding out the text blob into many chunks; total of 1500 chunks, 200 character overlap
        -- no overlap means to run risk of cutting off complete thought
        -- ATP NOTE: maybe these numbers are not right and you need to evaluate this strategy
         LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
             c.full_text, 'none', 1500, 200)) s
)
SELECT lesson_slug || ':t' || LPAD(chunk_index::VARCHAR, 4, '0') AS chunk_id,
       lesson_id, lesson_slug, lesson_title, chunk_index,
       NULLIF(start_char, 0) AS start_char,
       NULLIF(start_char, 0) + LENGTH(chunk_text) - 1 AS end_char,
       ROUND((NULLIF(start_char, 0) - 1) / total_characters * duration_seconds, 1)
                                                                 AS start_seconds,
       ROUND(LEAST(NULLIF(start_char, 0) - 1 + LENGTH(chunk_text), total_characters)
                 / total_characters * duration_seconds, 1) AS end_seconds,
       TRIM(REGEXP_REPLACE(chunk_text, '\\s+', ' ')) AS chunk_text
FROM split;
-- @runbook:end 04b.build

-- 4c. Inspect. Every chunk should have a time range and overlap the next one.
-- ATP NOTE: yes there is duplicate data, which isn't good, but it's an art
-- @runbook:begin 04c.explore_inspect role=EXPLORE cost=none purpose=Every chunk with its overlap PASS/FAIL (uncomment the QUALIFY line to list only failures)
SELECT lesson_slug, chunk_index, chunk_id, fmt_ts(start_seconds) AS starts, fmt_ts(end_seconds) AS ends,
       LENGTH(chunk_text) AS characters,
    LEFT(chunk_text, 160) AS preview,
    RIGHT(chunk_text, 80) AS ending,
    --ATP NOTE: adding in the Inspect check
   CASE
       -- First chunk: just needs a valid range
       WHEN LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index) IS NULL
            THEN IFF(end_seconds > start_seconds, 'PASS', 'FAIL')
       -- Last chunk: overlaps previous, and ends after its own start and the previous end
       WHEN LEAD(chunk_index) OVER (PARTITION BY lesson_slug ORDER BY chunk_index) IS NULL
            THEN IFF(end_seconds > start_seconds
                     AND end_seconds > LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index)
                     AND start_seconds <= LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index),
                     'PASS', 'FAIL')
       -- Middle chunks: must overlap the previous chunk
       ELSE IFF(start_seconds <= LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index),
                'PASS', 'FAIL')
   END AS overlap_check
   /*
   -- CASE
   -- WHEN LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index) IS NULL
   --      THEN 'FIRST CHUNK (not evaluated)'
   -- -- Last chunk of the lesson: must end after its own start and after the previous end
   -- WHEN LEAD(chunk_index) OVER (PARTITION BY lesson_slug ORDER BY chunk_index) IS NULL
   --      THEN IFF(end_seconds > start_seconds
   --               AND end_seconds > LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index)
   --               AND start_seconds <= LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index),
   --               'LAST CHUNK OK', 'LAST CHUNK INVALID')
   -- WHEN start_seconds <= LAG(end_seconds) OVER (PARTITION BY lesson_slug ORDER BY chunk_index)
   --      THEN 'OVERLAPS PREVIOUS'
   -- ELSE 'GAP - NO OVERLAP'
    -- END AS overlap_check
    */
FROM transcript_chunks
--QUALIFY overlap_check = 'FAIL' --list only failing rows; RESULT: no results, PASS
ORDER BY lesson_slug, chunk_index;
    --LIMIT 25;
-- @runbook:end 04c.explore_inspect


-- @runbook:begin 04c.output role=OUTPUT purpose=Chunks, average size, seconds and overlap per lesson
SELECT lesson_slug,
       COUNT(*) AS chunks,
       ROUND(AVG(LENGTH(chunk_text))) AS avg_characters,
       ROUND(AVG(end_seconds - start_seconds)) AS avg_seconds,
       -- Overlap between neighbors, in characters. Expect up to about 200.
       ROUND(AVG(prev_end_char - start_char + 1)) AS avg_overlap_characters
FROM (SELECT *, LAG(end_char) OVER (PARTITION BY lesson_slug ORDER BY chunk_index)
                AS prev_end_char
      FROM transcript_chunks)
GROUP BY lesson_slug;
-- @runbook:end 04c.output

-- Chunks with no position? Expect 0 rows. A row means the splitter changed
-- the text (for example whitespace), so the chunk has no estimated time.
-- @runbook:begin 04c.check role=CHECK expect=zero_rows,zero_rows purpose=Every chunk has a position; no gaps between chunks (expect zero rows each)
SELECT chunk_id, LEFT(chunk_text, 160) AS preview
FROM transcript_chunks
WHERE start_char IS NULL;

-- Gaps? Expect 0 rows: each chunk should start at or before the previous
-- chunk's end, so no part of the transcript is skipped.
SELECT lesson_slug, chunk_index, prev_end_char, start_char
FROM (SELECT lesson_slug, chunk_index, start_char,
             LAG(end_char) OVER (PARTITION BY lesson_slug ORDER BY chunk_index)
                 AS prev_end_char
      FROM transcript_chunks)
WHERE start_char > prev_end_char + 2;
-- @runbook:end 04c.check

-- 4d. Compare: the same split with no overlap. Look at the chunk endings:
-- without overlap, a sentence cut at a boundary is never seen whole.
-- @runbook:begin 04d.explore role=EXPLORE cost=none purpose=Same split with no overlap, to see sentences cut at chunk boundaries
SELECT t.lesson_slug, s.index AS chunk_index, LENGTH(s.value::VARCHAR) AS characters,
    RIGHT(s.value::VARCHAR, 120) AS chunk_ending
FROM lesson_transcripts t,
    LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
    t.transcript_text, 'none', 1500, 0)) s
ORDER BY t.lesson_slug, chunk_index
    LIMIT 10;
-- @runbook:end 04d.explore
