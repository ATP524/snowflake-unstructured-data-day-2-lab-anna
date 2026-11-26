-- Step 11: embed whole slide images and search them with text. Text from
-- AI_PARSE_DOCUMENT misses what a chart or photo shows; an image embedding
-- includes it. Run 10_slide_image_procedure.sql first.
--
-- Image embeddings use AI_EMBED with voyage-multimodal-3. Image input runs
-- natively in AWS US West 2, AWS US East 1, AWS Europe Central 1, and Azure
-- West Europe. In other regions it needs cross-region inference enabled by
-- your instructor.
-- Session context (role, database, warehouse, schema) and shared values live in
-- sql/runbook_config.sql. Run it first when running this file by hand.



-- 11a. Render every page to an image (no AI calls). About a minute for 52 pages.
-- @runbook:begin 11a.build role=BUILD cost=none reads=slide_decks,@lesson_slides writes=slide_images,@slide_images purpose=Render every slide page to a PNG (skips decks already rendered)
CALL render_slide_images(1600, FALSE);
-- @runbook:end 11a.build
--OUTPUT:
/*
{f
  "decks": 3,
  "decks_rendered": 3,
  "decks_skipped": 0,
  "pages": 78
}
*/

-- @runbook:begin 11a.check role=CHECK expect=output purpose=One rendered image per parsed page
SELECT i.slide_id, i.page_number, i.width_px, i.height_px,
       ROUND(i.image_bytes / 1024) AS kb, p.source_filename
FROM slide_images i
         JOIN slide_pages p ON p.slide_id = i.slide_id
ORDER BY i.deck_id, i.page_number;
-- @runbook:end 11a.check

-- Open one rendered page in your browser. The URL expires in an hour.
-- @runbook:begin 11a.explore role=EXPLORE cost=none purpose=Presigned URLs to open rendered pages; list the image stage
SELECT slide_id, GET_PRESIGNED_URL(@slide_images, image_path, 3600) AS image_url
FROM slide_images
WHERE page_number = 19
    LIMIT 2;


-- exploring the stage
SELECT * FROM DIRECTORY(@slide_images); --S3 bucket 
-- @runbook:end 11a.explore

-- 11b. Embed each image with AI_EMBED. voyage-multimodal-3 puts text and
-- images in one vector space, so a text query can rank images. AI_EMBED
-- returns a VECTOR directly, with no JSON to unpack.
--
-- Check first that the model also takes text in your account. Snowflake's
-- AI_EMBED reference lists voyage-multimodal-3 under images only. Expect one
-- row with 1024 dimensions. If this errors, stop and tell your instructor:
-- 11c and 11d need text queries.
-- @runbook:begin 11b.check_model role=CHECK cost=ai expect=col:DIMENSIONS=1024 purpose=The image model also embeds text (expect 1024 dimensions); runs only when 11b runs
SELECT ARRAY_SIZE(AI_EMBED($image_embed_model, 'reliability versus manual effort chart')::ARRAY) AS dimensions;
-- @runbook:end 11b.check_model

-- One call per page; this step incurs charges. Images must be PNG, JPEG,
-- WEBP, or BMP, under 10 MB and 8,000 x 8,000 pixels. The rendered pages are.
-- @runbook:begin 11b.build role=BUILD cost=ai reads=slide_images,@slide_images writes=slide_image_embeddings,slide_image_vectors config=image_embed_model purpose=Embed every slide image (one AI_EMBED call per page)
CREATE OR REPLACE TABLE slide_image_embeddings AS
SELECT i.slide_id, i.deck_id, i.page_number, i.image_path,
       AI_EMBED($image_embed_model, TO_FILE('@slide_images', i.image_path)) AS embedding
FROM slide_images i;

CREATE OR REPLACE VIEW slide_image_vectors AS
SELECT slide_id, deck_id, page_number, image_path, embedding
FROM slide_image_embeddings
WHERE embedding IS NOT NULL;
-- @runbook:end 11b.build

-- Expect zero rows.
-- @runbook:begin 11b.check role=CHECK expect=zero_rows purpose=No slide image failed to embed (expect zero rows)
SELECT slide_id
FROM slide_image_embeddings
WHERE embedding IS NULL;
-- @runbook:end 11b.check

-- 11c. Search the images with text, then compare with slide text search.
-- @runbook:begin 11c.explore role=EXPLORE cost=ai purpose=Image search vs slide-text search for one question (edit $image_question)
SET image_question = 'Chart plotting ground truth methods by reliability versus manual effort';

WITH q AS (
    SELECT AI_EMBED($image_embed_model, $image_question) AS v
)
SELECT p.lesson_title, p.source_filename, p.page_number,
       ROUND(VECTOR_COSINE_SIMILARITY(i.embedding, q.v), 3) AS similarity,
    LEFT(p.content, 120) AS parsed_text,
    GET_PRESIGNED_URL(@slide_images, i.image_path, 3600) AS image_url
FROM slide_image_vectors i
    JOIN slide_pages p ON p.slide_id = i.slide_id
    CROSS JOIN q
ORDER BY similarity DESC
    LIMIT 10;

-- The same question against parsed slide text only.
-- the best slide from method above method was slide 19 from day 1, verified via image link that it has the graph, but that is not in the below results at all
SET image_question = 'Chart plotting ground truth methods by reliability versus manual effort';
WITH q AS (
    SELECT AI_EMBED($text_embed_model, 'query: ' || $image_question) AS v
)
SELECT c.citation,
       ROUND(VECTOR_COSINE_SIMILARITY(e.embedding, q.v), 3) AS similarity,
    LEFT(c.search_text, 160) AS preview
FROM text_embeddings e
    JOIN search_corpus c ON c.source_id = e.source_id
    CROSS JOIN q
WHERE c.source_type = 'slide'
ORDER BY similarity DESC
    LIMIT 5;
-- @runbook:end 11c.explore

-- 11d. Add IMAGE to the evaluation from step 9 (slide questions only).
-- Scores from different models are not comparable, so compare ranks.
-- @runbook:begin 11d.build role=BUILD cost=ai reads=eval_questions,eval_expected,slide_image_vectors writes=eval_image_query_embeddings,retrieval_results#IMAGE config=image_embed_model,eval_top_k purpose=Embed slide questions with the image model and rank IMAGE top k
CREATE OR REPLACE TABLE eval_image_query_embeddings AS
SELECT q.question_id,
       AI_EMBED($image_embed_model, q.question) AS embedding
FROM eval_questions q
WHERE q.answerable
  AND q.question_id IN (SELECT question_id FROM eval_expected WHERE source_type = 'slide');

-- Rebuild the IMAGE slice of retrieval_results. Safe to rerun:
-- clears prior IMAGE rows, then writes a fresh top 10 per question.
-- Other methods (TEXT, HYBRID, ...) are not touched.
BEGIN TRANSACTION;

DELETE FROM retrieval_results WHERE method = 'IMAGE';

INSERT INTO retrieval_results (method, question_id, result_rank, source_id, score_cosine)
SELECT 'IMAGE',
       q.question_id,
       ROW_NUMBER() OVER (PARTITION BY q.question_id
                          ORDER BY VECTOR_COSINE_SIMILARITY(i.embedding, q.embedding) DESC,
                                   i.slide_id) AS result_rank,   -- tie-breaker keeps ranks the same on every run
       i.slide_id,
       VECTOR_COSINE_SIMILARITY(i.embedding, q.embedding)   -- image-model cosine; compare only within IMAGE
FROM eval_image_query_embeddings q
CROSS JOIN slide_image_vectors i
QUALIFY result_rank <= $eval_top_k;

COMMIT;
-- @runbook:end 11d.build

-- @runbook:begin 11d.check role=CHECK expect=output,zero_rows purpose=IMAGE row count; no question with more than top-k rows or a repeated rank (expect zero rows)
SELECT COUNT(*) AS image_rows,
       COUNT(DISTINCT question_id) AS questions
FROM retrieval_results
WHERE method = 'IMAGE';   -- expect questions x top k rows (was 120 = 12 questions x 10; Q17-Q21 add slide questions, so it is now higher)


-- What we want in the data: expect exactly 1 row per (question, rank) and at most 10 per question
-- Find the problems query
-- Check: list questions whose IMAGE results break the rules
-- (more than 10 rows, or a repeated rank). Correct data returns 0 rows.
SELECT question_id, COUNT(*) AS n, COUNT(DISTINCT result_rank) AS ranks
FROM retrieval_results
WHERE method = 'IMAGE'
GROUP BY question_id
HAVING n > $eval_top_k OR n <> ranks;   -- should return 0 rows as it lists only questions that break the rule of each question have at most 10 rows (top k), with each rank appearing exactly once
-- @runbook:end 11d.check
/*
-- n > 10 catches a question with too many rows, for example from a duplicate load.
-- n <> ranks catches a repeated rank, for example two rows both ranked 3.
*/
--OLD: Zach's code of above TRANSACTION to COMMIT
/*
DELETE FROM retrieval_results WHERE method = 'IMAGE';
INSERT INTO retrieval_results (method, question_id, result_rank, source_id)
SELECT 'IMAGE', q.question_id,
       ROW_NUMBER() OVER (PARTITION BY q.question_id
                          ORDER BY VECTOR_COSINE_SIMILARITY(i.embedding, q.embedding) DESC),
    i.slide_id
FROM eval_image_query_embeddings q
         CROSS JOIN slide_image_vectors i
    QUALIFY ROW_NUMBER() OVER (PARTITION BY q.question_id
                           ORDER BY VECTOR_COSINE_SIMILARITY(i.embedding, q.embedding) DESC) <= 10;
*/
-- @runbook:begin 11d.output role=OUTPUT purpose=Scores per method (now including IMAGE)
SELECT * FROM retrieval_scores ORDER BY method;
-- @runbook:end 11d.output


-- @runbook:begin 11d.explore_ddl role=EXPLORE cost=none purpose=Show how retrieval_question_scores is defined
SELECT GET_DDL('VIEW', 'BOOTCAMP.ATP524.RETRIEVAL_QUESTION_SCORES');
-- @runbook:end 11d.explore_ddl
/*
--View definition 
LEFT JOIN eval_relevant_sources rel
  ON rel.question_id = r.question_id AND rel.source_id = r.source_id
...
MIN(IFF(rel.source_id IS NOT NULL, r.result_rank, NULL)) AS first_relevant_rank
*/
-- lower rank is better -- rank 1 means the method put the right answer first
-- NULL means method didn't find a correct answer in its top 10
-- @runbook:begin 11d.output_ranks role=OUTPUT purpose=VECTOR, CORTEX_SEARCH and IMAGE ranks side by side for slide questions
SELECT question_id, question,
       MAX(IFF(method = 'VECTOR', first_relevant_rank, NULL)) AS vector_rank,
       MAX(IFF(method = 'CORTEX_SEARCH', first_relevant_rank, NULL)) AS search_rank,
       MAX(IFF(method = 'IMAGE', first_relevant_rank, NULL)) AS image_rank
FROM retrieval_question_scores
GROUP BY question_id, question
HAVING MAX(IFF(method = 'IMAGE', 1, 0)) = 1
ORDER BY question_id;
-- @runbook:end 11d.output_ranks

-- 11e. Describe text-light slides with a vision model, so the text search can find
-- them too. Required: 06a appends these descriptions to slide search_text, and the
-- runbook runs 11e before 06a on every run. One AI_COMPLETE call per slide. Check that the model
-- accepts images in your region.
-- AI_COMPLETE writes different text on every run, so rerunning this changes 06a's input.
-- The runbook saves each run's descriptions to slide_descriptions_history.
-- @runbook:begin 11e.build role=BUILD cost=ai reads=slide_pages,slide_images,@slide_images writes=slide_descriptions config=describe_model,describe_max_chars purpose=Describe text-light slides with a vision model (one AI_COMPLETE call per slide; output differs every run)
CREATE OR REPLACE TABLE slide_descriptions AS
SELECT p.slide_id,
       AI_COMPLETE($describe_model,
                   PROMPT('Describe this lecture slide for search in at most 80 words. Name any chart type, axes, labels, and people shown. {0}',
                          TO_FILE('@slide_images', i.image_path))) AS description
FROM slide_pages p
         JOIN slide_images i ON i.slide_id = p.slide_id
WHERE -- Trigger 1: Slide has an embedded image/diagram detected by AI_PARSE_DOCUMENT
      p.content LIKE '%![img-%'
   OR -- Trigger 2: Slide has very little real text after stripping image links, boilerplate footer, and whitespace
      LENGTH(TRIM(
          REGEXP_REPLACE(
              REGEXP_REPLACE(p.content, '!\\[[^\\]]*\\]\\([^)]*\\)', ''),   -- strip ![img-xx.jpeg](img-xx.jpeg)
              'Zach Wilson''s DataExpert\\.io Boot Camp', ''                -- strip recurring footer
          )
      )) < $describe_max_chars;
-- Before (desc v1): WHERE LENGTH(p.content) < $describe_max_chars;
-- @runbook:end 11e.build

-- @runbook:begin 11e.output role=OUTPUT purpose=Each description next to the parsed slide text it supplements
SELECT d.slide_id, p.content AS parsed_text, d.description
FROM slide_descriptions d
         JOIN slide_pages p ON p.slide_id = d.slide_id;
-- @runbook:end 11e.output
-- 06a appends each description to its slide's search_text automatically, and the runbook
-- reruns 06a, 06b, 07a and step 9 whenever these descriptions change. To measure a change to
-- this step, run it as a full_experiment with a new LABEL so the before/after scores are compared.
-- (Originally a hand step: "append each description to its slide's search_text in step 6,
-- then rerun steps 6, 7, and 9 and compare scores.")

--More details on above:
/*
(now automated in 06a: the steps below were done by hand at first; 06a now appends the descriptions to search_text on every run)
Right now descriptions are stored but nothing uses them; The query above it only shows the descriptions next to the parsed text. It doesn't change your search system yet. To make the descriptions affect search, you have to put them into the corpus and rebuild everything downstream.


`slide_descriptions` is a separate table. Your search methods never read it. They only look at what step 6 built:

- **Vector search** compares the question's embedding to embeddings made from each item's `search_text` in the corpus.
- **Cortex Search** (step 7) indexes that same `search_text`.

So when someone asks "which slide shows the bar chart of churn by month?", both methods only see a slide's parsed text. For a chart slide that might be just a title like "Q3 Results". The description "bar chart, x-axis months, y-axis churn rate…" exists, but no search ever looks at it, so the slide still ranks poorly.

For the descriptions to make a difference, their words have to be part of what gets searched:

1. Add each description to the slide's `search_text` in step 6, and re-embed it.
2. Rebuild the Cortex Search index in step 7 so it contains those words.

After that, a question about a "bar chart of churn" can match the slide through its description. Rerunning step 9 then shows whether the rankings actually improved.

Why this exists: For slides where LENGTH(p.content) < 120 (mostly charts, photos and diagrams), AI_PARSE_DOCUMENT pulled out very little text, so text search can barely find them. AI_COMPLETE reads the slide image and writes a description of up to 80 words. That gives those slides searchable text.

What the comment tells you to do:

Append each description to its slide's search_text in step 6 (sql/06_build_corpus_and_embed.sql). Step 6 builds the combined corpus and embeds it. Change it so a slide's search_text becomes its parsed text plus its description. A LEFT JOIN to slide_descriptions with CONCAT_WS(' ', p.content, d.description) works, and slides without a description stay unchanged.
Rerun step 6 so the embeddings include the new text.
Rerun step 7 (07_cortex_search.sql) so the Cortex Search service indexes the enriched corpus.
Rerun step 9 (09_ask_and_evaluate.sql) to recompute the retrieval scores.
Compare scores. Check whether the first relevant result now ranks higher for questions about visual slides. The retrieval_question_scores view has the vector_rank and search_rank numbers to compare.
In short, this is a test of whether text descriptions of slide images improve retrieval, measured against your earlier results.
*/


--before doing the above, save down the earlier results so I can compare them to the change of adding descriptions and how that affects the score 
-- To keep them, clone instead of downloading. Clones are instant, add no storage cost until the data changes, and let you compare directly in 
-- WARNING: run these only BEFORE step 6 includes the descriptions. Rerunning them now would overwrite the saved
-- baseline with the with-descriptions corpus. The runbook's experiment mode snapshots by label and never overwrites.
-- @runbook:begin 11x.snapshot role=EXPERIMENT cost=none reads=retrieval_results,search_corpus,text_embeddings,retrieval_question_scores writes=retrieval_results_before_desc,search_corpus_before_desc,text_embeddings_before_desc,question_scores_before_desc purpose=Hand-run: save the before-descriptions baseline (overwrites it if run again)
CREATE OR REPLACE TABLE bootcamp.atp524.retrieval_results_before_desc CLONE bootcamp.atp524.retrieval_results; --create in step 09
CREATE OR REPLACE TABLE bootcamp.atp524.search_corpus_before_desc     CLONE bootcamp.atp524.search_corpus; --created in step 06
CREATE OR REPLACE TABLE bootcamp.atp524.text_embeddings_before_desc   CLONE bootcamp.atp524.text_embeddings; --created in step 06

-- per-question ranks as they are now (the view recalculates from retrieval_results, so save a copy)
CREATE OR REPLACE TABLE bootcamp.atp524.question_scores_before_desc AS
SELECT * FROM bootcamp.atp524.retrieval_question_scores; --view created in step 09
-- @runbook:end 11x.snapshot


--to get a file download as well, run: 
-- @runbook:begin 11x.compare role=EXPERIMENT cost=none reads=question_scores_before_desc,retrieval_question_scores purpose=Hand-run: saved before ranks vs current ranks (the runbook compare section covers all questions by label)
SELECT * FROM bootcamp.atp524.question_scores_before_desc;


--After rerunning steps 6, 7 and 9, compare old and new ranks:
SELECT n.question_id, n.method,
       o.first_relevant_rank AS rank_before,
       n.first_relevant_rank AS rank_after
FROM bootcamp.atp524.retrieval_question_scores n
LEFT JOIN bootcamp.atp524.question_scores_before_desc o
  ON o.question_id = n.question_id AND o.method = n.method
WHERE n.method IN ('VECTOR', 'CORTEX_SEARCH')
ORDER BY n.question_id, n.method;

--NOTE: image isn't here b/c nothing would change based on the addition of description to the search_text that we just did in 06
/*
VECTOR reads text_embeddings, and CORTEX_SEARCH reads search_corpus.search_text. Rerunning step 6 rewrites both, so these can change.
IMAGE compares question embeddings to slide_image_vectors, which are embeddings of the slide pictures built in step 11 (11_slide_image_search.sql:127). Steps 6, 7 and 9 don't touch that table or the IMAGE rows in retrieval_results.
*/

--to still include it as a control. If its ranks didn't move, you know only the text-based methods changed. Remove the method filter:

SELECT n.question_id, n.method,
       o.first_relevant_rank AS rank_before,
       n.first_relevant_rank AS rank_after,
       o.first_relevant_rank - n.first_relevant_rank AS improvement   -- positive = relevant result found earlier
FROM bootcamp.atp524.retrieval_question_scores n
LEFT JOIN bootcamp.atp524.question_scores_before_desc o
  ON o.question_id = n.question_id AND o.method = n.method
ORDER BY n.question_id, n.method;
--ATP NOTE: IMAGE rows appear only for the 12 questions it was scored on. 09_ask_and_evaluate.sql:204 drops IMAGE for the rest. A NULL rank means no relevant result made the top 10, so improvement will also be NULL in those rows.
-- (Updated: the IMAGE filter is now the "WHERE m.method <> 'IMAGE' OR ..." line inside the 09d.build section of 09_ask_and_evaluate.sql, and Q17-Q21 add more slide questions than the original 12.)

SELECT n.method, o.first_relevant_rank AS saved_before, n.first_relevant_rank AS now_
FROM bootcamp.atp524.retrieval_question_scores n
LEFT JOIN bootcamp.atp524.question_scores_before_desc o ON o.question_id = n.question_id AND o.method = n.method
WHERE n.question_id = 'Q15'
ORDER BY n.method;
-- @runbook:end 11x.compare
--OUTPUT:
/*
METHOD	SAVED_BEFORE	NOW_
CORTEX_SEARCH		1
IMAGE	1	1
VECTOR		1
*/