-- Step 5: parse every staged slide deck into one row per page and attach
-- the PDF metadata to each page.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.

-- @runbook:begin 05a.setup role=BUILD cost=none writes=slide_parse_results purpose=Create the parse results table if it does not exist
CREATE TABLE IF NOT EXISTS slide_parse_results (
                                                   deck_id     VARCHAR,
                                                   parse_mode  VARCHAR,
                                                   raw_result  VARIANT,
                                                   parsed_at   TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
    );
-- @runbook:end 05a.setup

-- 5a. One AI_PARSE_DOCUMENT call per deck that has not been parsed yet.
-- page_split returns a pages array. return_error_details (the third argument)
-- wraps the result as {value, error} so failures are visible, not NULL.
-- This step calls AI and incurs charges: 52 pages for program 908's two decks.
-- Check the decks and staged files you are about to parse.
-- @runbook:begin 05a.explore role=EXPLORE cost=none purpose=The decks and staged PDF files that 5a would parse
SELECT * FROM slide_decks;
SELECT * FROM DIRECTORY(@lesson_slides);
-- @runbook:end 05a.explore

-- @runbook:begin 05a.build role=BUILD cost=ai reads=slide_decks,@lesson_slides writes=slide_parse_results purpose=AI_PARSE_DOCUMENT each deck not yet parsed (incremental: parsed decks are skipped, failed ones retried)
INSERT INTO slide_parse_results (deck_id, parse_mode, raw_result)
SELECT d.deck_id, 'LAYOUT',
 --AI_PARSE_DOCUMENT returns a snowflake OBJECT type and we are storing it in VARIANT data type
 --Wrapping it in TO_VARIANT() cleanly converts that OBJECT into the VARIANT type expected by slide_parse_results.raw_result, allowing us to query raw_result:error, raw_result:metadata, and raw_result:value:pages downstream
       TO_VARIANT(AI_PARSE_DOCUMENT(
               TO_FILE('@lesson_slides', d.stage_path), --file_object argument
               OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', TRUE), --config object specifying LAYOUT mode with per-slide splittion (options)
               TRUE)) --true to enable strucutred error reporting (return_error_details)
FROM slide_decks d
WHERE NOT EXISTS (SELECT 1 FROM slide_parse_results r
                  WHERE r.deck_id = d.deck_id AND r.parse_mode = 'LAYOUT'
                    AND r.raw_result:error::STRING IS NULL); --r.raw_result:error::STRING IS NULL. That means if a previous run failed on a deck and recorded an error message in raw_result:error, this query will automatically retry that deck on the next run while skipping decks that already succeeded.
-- @runbook:end 05a.build

-- ATP NOTE : on AI_PARSE_DOCUMENT() arguments
--'mode', 'LAYOUT': Tells Cortex to preserve slide structure—such as headers, bullet lists, and Markdown-formatted tables—rather than stripping everything into flat OCR text.

--'page_split', TRUE: Instructs Snowflake to split the output by individual slide (supported for .pptx, .pdf, and .docx). Instead of returning one giant content blob for the entire deck, it returns a pages

-- Without TRUE (default FALSE), a corrupt or unreadable slide deck simply returns NULL with no explanation.
-- With TRUE, AI_PARSE_DOCUMENT() returns an OBJECT containing three top-level keys: value (your parsed slides), error (NULL on success, or an error message string on failure), and metadata (such as page counts).

--OUTPUT: 3 rows
-- 5b. Check for parse errors. Expect zero rows.
-- @runbook:begin 05b.check role=CHECK expect=zero_rows purpose=No deck failed to parse (expect zero rows)
SELECT deck_id, raw_result:error AS error, raw_result:value:errorInformation AS detail
FROM slide_parse_results
WHERE raw_result:error::STRING IS NOT NULL
   OR raw_result:value:errorInformation::STRING IS NOT NULL;
-- @runbook:end 05b.check

--SELECT * FROM slide_parse_results;

-- 5c. One row per page, carrying the parent PDF's metadata. page_index is
-- zero-based like AI_PARSE_DOCUMENT; page_number is what people cite.
-- @runbook:begin 05c.build role=BUILD cost=none reads=slide_parse_results,slide_decks writes=slide_pages purpose=One row per slide page with the parent PDF's metadata
CREATE OR REPLACE TABLE slide_pages AS
WITH latest_parse AS (
    SELECT deck_id, raw_result
    FROM slide_parse_results
    WHERE parse_mode = 'LAYOUT' AND raw_result:error::STRING IS NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY deck_id ORDER BY parsed_at DESC) = 1
),
pages AS (
    SELECT r.deck_id,
           r.raw_result:value:metadata:pageCount::INT AS parsed_page_count,
           p.value:index::INT AS page_index,
           TRIM(COALESCE(p.value:content::VARCHAR, '')) AS content
    FROM latest_parse r,
         LATERAL FLATTEN(INPUT => r.raw_result:value:pages) p
)
SELECT d.deck_id || ':p' || LPAD((p.page_index + 1)::VARCHAR, 3, '0') AS slide_id,
       d.deck_id,
       d.lesson_id,
       d.lesson_slug,
       d.lesson_title,
       d.source_filename,
       d.source_url,
       d.stage_path,
       d.sha256,
       d.pdf_title,
       d.pdf_author,
       d.pdf_created_at,
       COALESCE(p.parsed_page_count, d.pdf_page_count) AS page_count,
       p.page_index,
       p.page_index + 1 AS page_number,
       p.content
FROM pages p
         JOIN slide_decks d ON d.deck_id = p.deck_id;
-- @runbook:end 05c.build

-- 5d. Inspect. Every page should exist, even pages with almost no text.
-- @runbook:begin 05d.output role=OUTPUT purpose=Pages parsed per deck and nearly empty pages
SELECT lesson_slug, source_filename, pdf_title, page_count,
       COUNT(*) AS pages_parsed,
       COUNT_IF(LENGTH(content) < 40) AS nearly_empty_pages
FROM slide_pages
GROUP BY lesson_slug, source_filename, pdf_title, page_count;
-- @runbook:end 05d.output

-- @runbook:begin 05d.explore role=EXPLORE cost=none purpose=Preview every page's text; list text-light pages (the ones 11e describes)
SELECT slide_id, page_number, LENGTH(content) AS characters, LEFT(content, 200) AS preview
FROM slide_pages
ORDER BY lesson_slug, page_index;

-- Charts and photos produce little text. Slides like these are why step 11
-- embeds page images too.
SELECT slide_id, page_number, content, source_url
FROM slide_pages
WHERE LENGTH(content) < $describe_max_chars
ORDER BY lesson_slug, page_index;
-- @runbook:end 05d.explore
