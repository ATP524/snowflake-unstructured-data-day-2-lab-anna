USE ROLE all_users_role;
USE DATABASE bootcamp;
USE WAREHOUSE compute_wh;
USE SCHEMA atp524;


-- DELETE DO NOT SAVE API KEY ANYWHERE
CREATE OR REPLACE SECRET dataexpert_api_key
    TYPE = GENERIC_STRING
    SECRET_STRING = '<paste your key here>';


SELECT method, slice_kind, slice, questions, verdict_allowed, mrr_at_10, refusal_accuracy, verdicts
FROM bootcamp.atp524.eval_run_report
WHERE run_id = '287e36936493' AND slice_kind = 'all';

--to find baseline at any time for run's options:
--What's guaranteed: every run's options, config and summary (including the verdicts) are saved in runbook_runs (start_run, runbook_lib.py:371-379; end_run :381). To find the baseline at any time:

SELECT run_id, experiment_name, started_at FROM bootcamp.atp524.runbook_runs WHERE status = 'SUCCESS' ORDER BY started_at DESC;



/*
because Step 10 only embeds rendered slide images from @slide_images, IMAGE can only retrieve slide pages—so comparing its raw 0.882 MRR against CORTEX_SEARCH (which runs across transcripts, FAQs, and slides) is an apples-to-oranges comparison unless filtered to slide-answerable questions.
Run this query on your existing report table to confirm the exact question count and slice breakdown for IMAGE:
*/
SELECT 
    method, 
    slice_kind, 
    slice, 
    questions, 
    verdict_allowed, 
    mrr_at_10, 
    recall_at_10
FROM bootcamp.atp524.eval_run_report
WHERE run_id = '287e36936493'
  AND (slice_kind = 'all' OR slice ILIKE '%slide%')
ORDER BY slice_kind, slice, method;


--Slide 23 (w1d2.pdf, page 23)
SELECT p.slide_id, p.source_filename, p.page_number, LENGTH(p.content) AS parsed_chars,
       p.content                AS parsed_text,           -- AI_PARSE_DOCUMENT (step 05)
       d.description            AS ai_description,        -- AI_COMPLETE (step 11e)
       c.search_text            AS indexed_text,          -- what CORTEX_SEARCH / VECTOR see (step 06a)
       REGEXP_LIKE(c.search_text, '.*(theta|angle|cosine).*', 'is') AS mentions_terms,
       (SELECT LISTAGG(r.method || ' #' || r.result_rank, ', ')
        FROM bootcamp.atp524.retrieval_results r
        WHERE r.question_id = 'Q21' AND r.source_id = p.slide_id) AS q21_ranks
FROM bootcamp.atp524.slide_pages p
LEFT JOIN bootcamp.atp524.slide_descriptions d ON d.slide_id = p.slide_id
LEFT JOIN bootcamp.atp524.search_corpus c ON c.source_id = p.slide_id
WHERE p.source_filename = 'w1d2.pdf' AND p.page_number = 23;


--pipeline gaps : addressing slide 23 Q21 miss
/*
$describe_max_chars is set to 120 in sql/runbook_config.sql. The idea is that slides with little text are the ones whose meaning is mostly in the picture.

Slide 23 is a picture-heavy slide that slips past that rule. Most of its 171 characters aren't real content: they're the title, image placeholders like ![img-25.jpeg](img-25.jpeg), and the footer "Zach Wilson's DataExpert.io Boot Camp". The diagram showing the angle is just one image link.

To see which slides were skipped and how close they came to the cutoff:
*/

SELECT p.slide_id, p.source_filename, p.page_number, LENGTH(p.content) AS parsed_chars,
p.content,
       d.slide_id IS NOT NULL AS has_description,
       p.content LIKE '%![img-%' AS has_image_tag,
       search_text,
       REGEXP_LIKE(c.search_text, '.*(img|jpeg|DataExpert.io|Wilson).*', 'is') AS mentions_terms
FROM bootcamp.atp524.slide_pages p
LEFT JOIN bootcamp.atp524.slide_descriptions d ON d.slide_id = p.slide_id
LEFT JOIN bootcamp.atp524.search_corpus c ON c.source_id = p.slide_id
WHERE REGEXP_LIKE(c.search_text, '.*(img|jpeg|DataExpert.io|Wilson).*', 'is')
ORDER BY parsed_chars;


--Q14 answer, judge scores and top source
SELECT j.question, j.answer, j.groundedness, j.answer_relevance, j.refused, j.sources[0]:citation::string AS top_source,
       (SELECT LISTAGG(e.lesson_slug||' p'||e.page_number, ', ') FROM bootcamp.atp524.eval_expected e WHERE e.question_id='Q14') AS expected
FROM bootcamp.atp524.answer_judgments j WHERE j.run_id='9dfccaf7f3c4' AND j.question_id='Q14'