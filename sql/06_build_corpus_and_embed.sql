-- Step 6: combine transcript chunks, slide pages, and academy FAQs into one
-- searchable corpus with citations, then embed it with AI_EMBED.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.

-- 6a. One row per searchable unit. search_text starts with a short context
-- header so a chunk still says which lesson or deck it belongs to.
-- ATP NOTE: Why in the second UNION are some of the columns not named: in a UNION ALL, column names come only from the first SELECT. 
-- Every SELECT after the first one fills those columns by position, not by name. Line 17 names the 5th line item, 7th column. The same rule names other 
-- unnamed columns: 'slide' becomes source_type and the line 38 expression becomes citation.
-- @runbook:begin 06a.build role=BUILD cost=none reads=transcript_chunks,slide_pages,slide_descriptions,academy_faqs writes=search_corpus purpose=Combine transcript chunks, slide pages (plus 11e descriptions) and FAQs into one corpus
CREATE OR REPLACE TABLE search_corpus AS
SELECT chunk_id                         AS source_id,
       'transcript'                     AS source_type,
       lesson_id, lesson_slug, lesson_title,
       -- Times are estimated from position in the text (step 4), hence "about".
       lesson_title || ', transcript about ' || fmt_ts(start_seconds) || '-' || fmt_ts(end_seconds)
                                        AS citation, --ATP NOTE: This is critical to always have in the vector database for context for AI
       'Lesson: ' || lesson_title || '\n' || chunk_text AS search_text,
       start_seconds, end_seconds,
       NULL::VARCHAR AS deck_id, NULL::NUMBER AS page_number, NULL::NUMBER AS faq_id,
    NULL::VARCHAR AS source_filename
FROM transcript_chunks
UNION ALL
--Original method: before adding in descriptions generated from AI_COMPLETE in step 11
-- SELECT slide_id,
--        'slide',
--        lesson_id, lesson_slug, lesson_title,
--        lesson_title || ', ' || source_filename || ' page ' || page_number || ' of ' || page_count,
--        'Lesson: ' || lesson_title || '\nSlides: ' || COALESCE(pdf_title, source_filename)
--            || ', page ' || page_number || ' of ' || page_count || '\n' || content,
--        NULL, NULL,
--        deck_id, page_number, NULL,
--        source_filename
-- FROM slide_pages

SELECT p.slide_id,
       'slide',
       p.lesson_id, p.lesson_slug, p.lesson_title,
       p.lesson_title || ', ' || p.source_filename || ' page ' || p.page_number || ' of ' || p.page_count,
       'Lesson: ' || p.lesson_title || '\nSlides: ' || COALESCE(p.pdf_title, p.source_filename)
           || ', page ' || p.page_number || ' of ' || p.page_count || '\n' || p.content
           || COALESCE('\nImage description: ' || d.description, ''),   -- AI_COMPLETE text from step 11
       NULL, NULL,
       p.deck_id, p.page_number, NULL,
       p.source_filename
FROM slide_pages p
LEFT JOIN slide_descriptions d ON d.slide_id = p.slide_id

UNION ALL
SELECT 'faq:' || faq_id,
       'faq',
       NULL, NULL, NULL,
       'Academy FAQ: ' || question,
       'DataExpert.io Academy FAQ\nQ: ' || question || '\nA: ' || answer,
       NULL, NULL,
       NULL, NULL, faq_id,
       NULL
FROM academy_faqs;
-- @runbook:end 06a.build

-- @runbook:begin 06a.check role=CHECK expect=output,zero_rows purpose=Rows per source type with description count; duplicate IDs (expect none)
SELECT source_type, COUNT(*) AS rows_, ROUND(AVG(LENGTH(search_text))) AS avg_characters
,COUNT_IF(search_text ILIKE '%Image description:%') AS new_text_check
FROM search_corpus
GROUP BY source_type;

-- IDs must be unique, because evaluation and citations join on them.
SELECT source_id, COUNT(*) FROM search_corpus GROUP BY source_id HAVING COUNT(*) > 1;
-- @runbook:end 06a.check

-- 6b. Embed every row. This step calls AI and incurs charges, one call per row
-- (about 150 for program 908).


--6b quick test with LIMIT
-- @runbook:begin 06b.explore_test role=EXPLORE cost=ai purpose=Embed one corpus row and confirm the vector has 1024 dimensions
SELECT source_id,
       source_type,
       $text_embed_model AS embedding_model,
       AI_EMBED($text_embed_model, search_text) AS embedding, --takes text from an source (slide, words, transcript) and turns into numbers
       ARRAY_SIZE(AI_EMBED($text_embed_model, search_text)::ARRAY) AS embedding_size --num_dimensions OUTPUT: 1024; AI_EMBED always returns 1024 dimensions for cosine similarity; note vectors have to have the same dimensions to work
FROM search_corpus
LIMIT 1;
-- @runbook:end 06b.explore_test

--ATP NOTE: First part of the AI portion of the lab with AI_EMBED
-- @runbook:begin 06b.build role=BUILD cost=ai reads=search_corpus writes=text_embeddings config=text_embed_model purpose=Embed every corpus row (one AI_EMBED call per row)
CREATE OR REPLACE TABLE text_embeddings AS
SELECT source_id,
       source_type,
       $text_embed_model AS embedding_model,
       AI_EMBED($text_embed_model, search_text) AS embedding
FROM search_corpus;
-- @runbook:end 06b.build

-- @runbook:begin 06b.check role=CHECK expect=col:FAILED=0 purpose=Every corpus row embedded (failed = 0)
SELECT source_type, COUNT(*) AS embedded, COUNT_IF(embedding IS NULL) AS failed
FROM text_embeddings
GROUP BY source_type;
-- @runbook:end 06b.check

-- 6c. Your first vector search. Embed the question with the same model, then
-- rank by cosine similarity. The arctic-embed v2 model card recommends a
-- 'query: ' prefix on queries, but not on documents.
-- ATP Note: not using indexing here
-- Top 10 results with LIMIT 10
-- @runbook:begin 06c.explore_refund role=EXPLORE cost=ai purpose=First vector search: edit $question and rerun to try other questions
SET question = 'What is the refund policy for live boot camps?';

WITH q AS (
    SELECT AI_EMBED($text_embed_model, 'query: ' || $question) AS v
)
SELECT c.source_type,
       c.citation,
       ROUND(VECTOR_COSINE_SIMILARITY(e.embedding, q.v), 3) AS similarity,
    c.search_text
    --LEFT(c.search_text, 220) AS preview
FROM text_embeddings e
    JOIN search_corpus c ON c.source_id = e.source_id
    CROSS JOIN q
ORDER BY similarity DESC
    LIMIT 10;
-- @runbook:end 06c.explore_refund


-- EXAMPLE 2
-- Arctic embed snowflake vs. openAI embedding model: how good does it do semantic matching; Zach finds large model from OpenAI to be better as of Nov 2026 but this is why we do evaluations to do tests and see what is happening
-- sometimes the top result is incorrect and 3 or 4th result is actually what you want and answers your question --- this is where RE RANKING feature comes into play which we'll explore in later lab
-- @runbook:begin 06c.explore_parse role=EXPLORE cost=ai purpose=Second vector search example (AI_PARSE_DOCUMENT question); look for the right answer at rank 3-4
SET question = 'How should I process unstructured data with Snowflake AI_PARSE_DOCUMENT?';

WITH q AS (
    SELECT AI_EMBED($text_embed_model, 'query: ' || $question) AS v
)
SELECT c.source_type,
       c.citation,
       ROUND(VECTOR_COSINE_SIMILARITY(e.embedding, q.v), 3) AS similarity,
    c.search_text
    --LEFT(c.search_text, 220) AS preview
FROM text_embeddings e
    JOIN search_corpus c ON c.source_id = e.source_id
    CROSS JOIN q
ORDER BY similarity DESC
    LIMIT 10;
-- @runbook:end 06c.explore_parse