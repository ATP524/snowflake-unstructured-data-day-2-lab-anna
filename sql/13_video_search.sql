-- Step 13: search lesson videos in 30-second clips with AI_MULTI_EMBED.
-- Transcripts tell you what was said. Video embeddings also capture what was on
-- screen and how it sounded, so a query can find the moment a demo or chart
-- appears even when nobody describes it out loud. Run 12_video_procedure.sql
-- first.
--
-- AI_MULTI_EMBED (twelvelabs-marengo-embed-3-0) runs natively in AWS US East 1.
-- In other regions it needs cross-region inference enabled by your instructor.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.
-- This step is optional in the runbook (INCLUDE_VIDEO). The Marengo model name stays
-- written out below because it has not been tested as a session variable yet.

-- ATP Note: I think we need a mod from Zach on what he used to build this?
-- Capstone: talk to Zach about setting up S3 ; if external videos, need Zach to create work rule to ingest videos over HTTP, S3 presigned URL
-- Set up your own stage via copying 01_setup
-- Overall project purpose: be a valuable data engineer -- the data in snowflake shouldn't to stay in snowflake; building API in ingest data amd then build context, AI, and then MCP that allows for snowflake to take action like creating blogs, sending emails, etc.
------------------------------------------------------------------------------
-- 13a. A stage and a table for the videos. Server-side encryption, as for
-- slides, so the AI functions can read staged files.
------------------------------------------------------------------------------
-- @runbook:begin 13a.build role=BUILD cost=none track=exists writes=lesson_videos,@lesson_videos purpose=Create the video stage and table if they do not exist
CREATE STAGE IF NOT EXISTS lesson_videos
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- One row per staged video. video_id is the first 16 hex characters of the
-- file's SHA-256, so a changed video gets a new ID.
CREATE TABLE IF NOT EXISTS lesson_videos (
    run_id           VARCHAR,
    video_id         VARCHAR,
    lesson_id        NUMBER,
    lesson_slug      VARCHAR,
    lesson_title     VARCHAR,
    source_url       VARCHAR,       -- Storage URL without its expiring signature
    source_filename  VARCHAR,
    stage_path       VARCHAR,       -- Path inside @lesson_videos
    content_type     VARCHAR,
    file_bytes       NUMBER,
    sha256           VARCHAR,
    fetched_at       TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);
-- @runbook:end 13a.build

------------------------------------------------------------------------------
-- 13b. Download the program's videos (no AI calls). Lessons without a video
-- count as missing. A lecture video can be hundreds of megabytes, so expect
-- several minutes. If errors is above 0, read error_details.
------------------------------------------------------------------------------
-- $program_id and $ingest_max_lessons are set once in sql/runbook_config.sql.
-- @runbook:begin 13b.build role=BUILD cost=external reads=lessons writes=lesson_videos,@lesson_videos config=program_id,ingest_max_lessons purpose=Download the program's videos (re-downloads every video to hash it; unchanged ones are not re-uploaded)
CALL ingest_videos($program_id, $ingest_max_lessons);
-- @runbook:end 13b.build

-- @runbook:begin 13b.check role=CHECK expect=output,output purpose=Videos loaded and files on the video stage
SELECT lesson_slug, lesson_title, source_filename, content_type,
       ROUND(file_bytes / 1048576) AS mb, stage_path
FROM lesson_videos
ORDER BY lesson_slug;

SELECT relative_path, ROUND(size / 1048576) AS mb, last_modified
FROM DIRECTORY(@lesson_videos);
-- @runbook:end 13b.check

------------------------------------------------------------------------------
-- 13c. Embed each video once. This step calls AI and incurs charges, billed
-- by video length.
--
-- Marengo cuts a video into fixed-length segments of 1 to 10 seconds
-- (use_fixed_length_sec). For 30-second clips, this asks for 10-second
-- segments and 13d averages each run of three. That is one call per video.
-- The alternative, one call per 30-second window using start_sec, end_sec,
-- and embedding_scope 'asset', makes about 90 calls per 45-minute lecture.
--
-- Each 10-second segment gets three embeddings: visual (what is on screen),
-- audio (the sound), and transcription (the words spoken).
------------------------------------------------------------------------------
-- @runbook:begin 13c.build role=BUILD cost=ai reads=lesson_videos,@lesson_videos writes=video_embed_results purpose=Embed each new video once with AI_MULTI_EMBED (billed by video length; incremental)
CREATE TABLE IF NOT EXISTS video_embed_results (
    video_id     VARCHAR,
    lesson_slug  VARCHAR,
    raw_result   VARIANT,
    embedded_at  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- Embeds only videos without a successful result, so a rerun costs nothing.
INSERT INTO video_embed_results (video_id, lesson_slug, raw_result)
SELECT v.video_id, v.lesson_slug,
       TO_VARIANT(AI_MULTI_EMBED(
           'twelvelabs-marengo-embed-3-0',
           TO_FILE('@lesson_videos', v.stage_path),
           {'embedding_options': ['visual', 'audio', 'transcription'],
            'embedding_scope': ['clip'],
            'use_fixed_length_sec': 10}))
FROM lesson_videos v
WHERE NOT EXISTS (SELECT 1 FROM video_embed_results r
                  WHERE r.video_id = v.video_id
                    AND r.raw_result:error::STRING IS NULL);
-- @runbook:end 13c.build

-- Expect zero rows.
-- @runbook:begin 13c.check role=CHECK expect=zero_rows purpose=No video failed to embed (expect zero rows)
SELECT video_id, lesson_slug, raw_result:error AS error
FROM video_embed_results
WHERE raw_result:error::STRING IS NOT NULL;
-- @runbook:end 13c.check

-- One row per 10-second segment and modality. Cast through ARRAY: a VARIANT
-- can't be cast to VECTOR directly.
-- @runbook:begin 13c.build_segments role=BUILD cost=none reads=video_embed_results,lesson_videos writes=video_segments purpose=One row per 10-second segment and modality
CREATE OR REPLACE TABLE video_segments AS
SELECT r.video_id,
       r.lesson_slug,
       s.value:embedding_option::VARCHAR AS modality,
       s.value:start_sec::FLOAT          AS start_sec,
       s.value:end_sec::FLOAT            AS end_sec,
       s.value:embedding::ARRAY::VECTOR(FLOAT, 512) AS embedding
FROM video_embed_results r,
     LATERAL FLATTEN(INPUT => r.raw_result:value) s
WHERE r.raw_result:error::STRING IS NULL
  AND r.video_id IN (SELECT video_id FROM lesson_videos);
-- @runbook:end 13c.build_segments

-- Expect three modalities per video. Visual and audio segments are 10
-- seconds long. Transcription segments follow the speech, so their times
-- and lengths vary, and silent stretches have none.
-- @runbook:begin 13c.output role=OUTPUT purpose=Segments per lesson and modality
SELECT lesson_slug, modality, COUNT(*) AS segments,
       ROUND(AVG(end_sec - start_sec), 1) AS avg_seconds,
       fmt_ts(MAX(end_sec)) AS video_length
FROM video_segments
GROUP BY lesson_slug, modality
ORDER BY lesson_slug, modality;
-- @runbook:end 13c.output

------------------------------------------------------------------------------
-- 13d. Build 30-second clips. Every segment that starts in the same
-- 30-second window joins that clip, and VECTOR_AVG averages their vectors
-- per modality. Cosine similarity ignores vector length, so the average
-- needs no normalizing. The last clip of a video can be shorter, and a clip
-- with no speech has no transcription vector.
------------------------------------------------------------------------------
-- @runbook:begin 13d.build role=BUILD cost=none reads=video_segments writes=video_clips purpose=Average segments into 30-second clips per modality
CREATE OR REPLACE TABLE video_clips AS
SELECT video_id || ':c' || LPAD(FLOOR(start_sec / 30)::VARCHAR, 4, '0') AS clip_id,
       video_id,
       lesson_slug,
       modality,
       FLOOR(start_sec / 30)::NUMBER AS clip_index,
       MIN(start_sec) AS start_sec,
       MAX(end_sec)   AS end_sec,
       COUNT(*)       AS segments,
       VECTOR_AVG(embedding) AS embedding
FROM video_segments
GROUP BY video_id, lesson_slug, modality, FLOOR(start_sec / 30);
-- @runbook:end 13d.build

-- Expect visual and audio clips of about 30 seconds, three segments each.
-- @runbook:begin 13d.output role=OUTPUT purpose=Clips per lesson and modality (expect about 30 seconds, 3 segments each)
SELECT lesson_slug, modality, COUNT(*) AS clips,
       ROUND(AVG(end_sec - start_sec), 1) AS avg_seconds,
       ROUND(AVG(segments), 2) AS avg_segments
FROM video_clips
GROUP BY lesson_slug, modality
ORDER BY lesson_slug, modality;
-- @runbook:end 13d.output

------------------------------------------------------------------------------
-- 13e. Search the clips with text. The same model embeds the question into
-- the same space. Each modality gets its own similarity, and combined is
-- their average. The transcript column shows the overlapping chunk from
-- step 4, and watch_url opens the video at the clip's start.
------------------------------------------------------------------------------
-- @runbook:begin 13e.explore role=EXPLORE cost=ai purpose=Search 30-second video clips with text (edit $video_question); shows visual, audio and transcription scores
SET video_question = 'Why should I convert video to MP3 before transcribing it?';

WITH q AS (
    SELECT (AI_MULTI_EMBED('twelvelabs-marengo-embed-3-0', $video_question))
               :value[0]:embedding::ARRAY::VECTOR(FLOAT, 512) AS v
),
sims AS (
    SELECT c.clip_id, c.video_id, c.lesson_slug, c.start_sec, c.end_sec, c.modality,
           VECTOR_COSINE_SIMILARITY(c.embedding, q.v) AS similarity
    FROM video_clips c
    CROSS JOIN q
),
per_clip AS (
    SELECT clip_id, video_id, lesson_slug,
           MIN(start_sec) AS start_sec, MAX(end_sec) AS end_sec,
           ROUND(MAX(IFF(modality = 'visual', similarity, NULL)), 3) AS visual,
           ROUND(MAX(IFF(modality = 'audio', similarity, NULL)), 3) AS audio,
           ROUND(MAX(IFF(modality = 'transcription', similarity, NULL)), 3) AS transcription,
           AVG(similarity) AS combined_raw
    FROM sims
    GROUP BY clip_id, video_id, lesson_slug
),
scored AS (
    SELECT *, ROUND(combined_raw, 3) AS combined
    FROM per_clip
    QUALIFY ROW_NUMBER() OVER (ORDER BY combined_raw DESC) <= 10
),
said AS (
    SELECT s.clip_id, LEFT(t.chunk_text, 200) AS transcript
    FROM scored s
    JOIN transcript_chunks t
      ON t.lesson_slug = s.lesson_slug
     AND t.start_seconds < s.end_sec
     AND t.end_seconds > s.start_sec
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.clip_id ORDER BY t.start_seconds) = 1
)
SELECT v.lesson_title,
       fmt_ts(s.start_sec) || '-' || fmt_ts(s.end_sec) AS clip,
       s.combined, s.visual, s.audio, s.transcription,
       d.transcript,
       GET_PRESIGNED_URL(@lesson_videos, v.stage_path, 3600)
           || '#t=' || FLOOR(s.start_sec) || ',' || CEIL(s.end_sec) AS watch_url
FROM scored s
JOIN lesson_videos v ON v.video_id = s.video_id
LEFT JOIN said d ON d.clip_id = s.clip_id
ORDER BY s.combined_raw DESC;
-- @runbook:end 13e.explore

-- Now try a question about what is on screen rather than what is said, and
-- see whether the visual column leads. Edit and rerun the query above with:
-- SET video_question = 'Snowsight worksheet with SQL code on the screen';

------------------------------------------------------------------------------
-- 13f. Score video search on step 9's labeled questions. Only questions with
-- a labeled transcript window in a lesson that has a video count. A clip is
-- correct when it overlaps that window. VECTOR from step 9 on the same
-- questions is the baseline; it can also score with a slide or FAQ, so it
-- has more ways to be right.
------------------------------------------------------------------------------
-- @runbook:begin 13f.build role=BUILD cost=ai reads=eval_questions,eval_expected,lesson_videos,video_clips,retrieval_question_scores writes=eval_video_query_embeddings,video_eval_results,video_question_scores purpose=Score video search on the step 9 questions that have a transcript answer in a lesson with a video
CREATE OR REPLACE TABLE eval_video_query_embeddings AS
SELECT q.question_id,
       (AI_MULTI_EMBED('twelvelabs-marengo-embed-3-0', q.question))
           :value[0]:embedding::ARRAY::VECTOR(FLOAT, 512) AS embedding
FROM eval_questions q
WHERE q.question_id IN (
    SELECT e.question_id
    FROM eval_expected e
    JOIN lesson_videos v ON v.lesson_slug = e.lesson_slug
    WHERE e.source_type = 'transcript');

CREATE OR REPLACE TABLE video_eval_results AS
WITH sims AS (
    SELECT q.question_id, c.clip_id, c.lesson_slug, c.start_sec, c.end_sec, c.modality,
           VECTOR_COSINE_SIMILARITY(c.embedding, q.embedding) AS similarity
    FROM eval_video_query_embeddings q
    CROSS JOIN video_clips c
),
methods AS (
    SELECT 'VIDEO_' || UPPER(modality) AS method, question_id, clip_id,
           lesson_slug, start_sec, end_sec, similarity
    FROM sims
    UNION ALL
    SELECT 'VIDEO_COMBINED', question_id, clip_id,
           ANY_VALUE(lesson_slug), MIN(start_sec), MAX(end_sec), AVG(similarity)
    FROM sims
    GROUP BY question_id, clip_id
)
SELECT method, question_id, clip_id, lesson_slug, start_sec, end_sec,
       ROW_NUMBER() OVER (PARTITION BY method, question_id ORDER BY similarity DESC) AS result_rank
FROM methods
QUALIFY ROW_NUMBER() OVER (PARTITION BY method, question_id ORDER BY similarity DESC) <= 10;

CREATE OR REPLACE VIEW video_question_scores AS
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
-- @runbook:end 13f.build

-- @runbook:begin 13f.output role=OUTPUT purpose=hit@1, hit@5 and MRR per video method, then where the modalities disagree
SELECT method,
       COUNT(*) AS questions,
       ROUND(COUNT_IF(first_relevant_rank = 1) / COUNT(*), 3) AS hit_at_1,
       ROUND(COUNT_IF(first_relevant_rank <= 5) / COUNT(*), 3) AS hit_at_5,
       ROUND(AVG(COALESCE(1 / first_relevant_rank, 0)), 3) AS mrr_at_10
FROM video_question_scores
GROUP BY method
ORDER BY method;

-- Where do the modalities disagree?
SELECT question_id,
       MAX(IFF(method = 'VIDEO_VISUAL', first_relevant_rank, NULL)) AS visual_rank,
       MAX(IFF(method = 'VIDEO_AUDIO', first_relevant_rank, NULL)) AS audio_rank,
       MAX(IFF(method = 'VIDEO_TRANSCRIPTION', first_relevant_rank, NULL)) AS transcription_rank,
       MAX(IFF(method = 'VIDEO_COMBINED', first_relevant_rank, NULL)) AS combined_rank,
       MAX(IFF(method = 'VECTOR (step 9)', first_relevant_rank, NULL)) AS text_vector_rank
FROM video_question_scores
GROUP BY question_id
ORDER BY question_id;
-- @runbook:end 13f.output
