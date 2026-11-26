# Day 2 Unstructured Data Lab: search your course materials

Pull your boot camp's lesson transcripts, slide decks, and academy FAQs from the DataExpert.io content API into Snowflake. Then make them searchable with citations back to the exact recording time or slide page.

You will chunk full transcripts into overlapping pieces with estimated recording times and parse each slide PDF into one row per page that keeps the PDF's metadata. Then you'll embed everything, build a Cortex Search service, answer questions with cited sources, and measure which retrieval method finds the right source. An image path embeds whole slide images, so text queries can find charts and diagrams that have little text.

```text
DataExpert API ──► ingestion procedures ──► api_responses, lesson_transcripts, @lesson_slides
transcript text ─► SPLIT_TEXT_RECURSIVE_CHARACTER ─► transcript_chunks (with estimated times)
slide PDFs ──────► AI_PARSE_DOCUMENT (page_split) ─► slide_pages (with PDF metadata)
chunks + pages + FAQs ─► search_corpus ─► AI_EMBED vectors and a Cortex Search service
question ─► Cortex Search ─► AI_COMPLETE ─► answer with [n] citations
slide pages ─► rendered images ─► AI_EMBED (voyage-multimodal-3) ─► text-to-image search
lesson videos ─► AI_MULTI_EMBED (10-second segments) ─► 30-second clips ─► text-to-video search
```

## Lab sequence

| Step | Worksheet | What you get | Calls AI? |
| --- | --- | --- | --- |
| 1 | [sql/01_setup.sql](sql/01_setup.sql) | Schema, stages, tables, and catalog views | No |
| 2 | [sql/02_ingest_procedures.sql](sql/02_ingest_procedures.sql) | `ingest_catalog` and `ingest_lessons` procedures | No |
| 3 | [sql/03_ingest.sql](sql/03_ingest.sql) | Catalog, transcripts, and slide PDFs in Snowflake | No |
| 4 | [sql/04_chunk_transcripts.sql](sql/04_chunk_transcripts.sql) | Overlapping chunks of each full transcript, with estimated times | No |
| 5 | [sql/05_parse_slides.sql](sql/05_parse_slides.sql) | One row per slide page with its PDF's metadata | Yes, once per deck |
| 6 | [sql/06_build_corpus_and_embed.sql](sql/06_build_corpus_and_embed.sql) | One corpus of chunks, pages, and FAQs, plus vectors | Yes, once per row |
| 7 | [sql/07_cortex_search.sql](sql/07_cortex_search.sql) | A Cortex Search service, compared with vector search | Yes |
| 8 | [sql/08_search_procedures.sql](sql/08_search_procedures.sql) | `ask_course` and `run_search_eval` procedures | No |
| 9 | [sql/09_ask_and_evaluate.sql](sql/09_ask_and_evaluate.sql) | Cited answers and retrieval scores | Yes |
| 10 | [sql/10_slide_image_procedure.sql](sql/10_slide_image_procedure.sql) | `render_slide_images` procedure | No |
| 11 | [sql/11_slide_image_search.sql](sql/11_slide_image_search.sql) | Slide image embeddings, text-to-image search, and image scores | Yes |
| 12 | [sql/12_video_procedure.sql](sql/12_video_procedure.sql) | `ingest_videos` procedure | No |
| 13 | [sql/13_video_search.sql](sql/13_video_search.sql) | Lesson videos, 30-second clip embeddings, text-to-video search, and video scores | Yes, once per video |

Steps 10 and 11 are the image path. Do them if there is time and your instructor has confirmed `AI_EMBED` with `voyage-multimodal-3` works in the course account. Steps 12 and 13 are the video path, which needs `AI_MULTI_EMBED`.

## Before you begin

1. Get your API key from [dataexpert.io/onboarding](https://www.dataexpert.io/onboarding). Treat it like a password: it reads your enrolled content. It goes into a Snowflake secret in step 1 and nowhere else. Don't paste it into a worksheet that lives in Git, a notebook, a table, or a chat.
2. In Snowsight, select `all_users_role`, open **Projects → Workspaces → From Git repository**, and connect the Day 2 lab repository your instructor shares, the same way as Day 1 (API integration `dataexpert_course_git`, secret `course_credentials.git.dataexpert_course_token`).
3. Pick your assigned warehouse.
4. Every worksheet starts with `USE SCHEMA student_your_name;`. Replace it with your own schema name in each file, the same schema as Day 1 or a new one.

Your instructor has already created the `dataexpert_api_access` external access integration. It allows outbound calls to `www.dataexpert.io` and to the storage bucket that slide downloads redirect to. You don't create integrations in this lab.

## Step 1: create your objects and your API key secret

Run [sql/01_setup.sql](sql/01_setup.sql). It creates two stages, the landing tables, the `fmt_ts` timestamp helper, and views (`programs`, `lessons`, `academy_faqs`) that flatten the raw API JSON. The views are empty until step 3. The last query should show your role, database, schema, `1:15`, and `1:02:05`.

Then store your key. Open a new SQL file outside the Git repository (for example **+ → SQL File** in your personal workspace), paste this, add your key, and run it:

```sql
USE ROLE all_users_role;
USE DATABASE bootcamp;
USE SCHEMA student_your_name;

CREATE OR REPLACE SECRET dataexpert_api_key
    TYPE = GENERIC_STRING
    SECRET_STRING = 'paste-your-key-here';
```

Delete the key from that file right after it runs. You can check the secret exists without revealing it:

```sql
SHOW SECRETS LIKE 'dataexpert_api_key';
```

To rotate the key later, rerun the same statement with the new key. The procedures read the secret every time they run.

## Step 2: create the ingestion procedures

Run all of [sql/02_ingest_procedures.sql](sql/02_ingest_procedures.sql). It creates two Python stored procedures. Their code is generated from [python/dataexpert_ingest.py](python/dataexpert_ingest.py), which is easier to read than the worksheet.

What the code does, and why:

- It sends your key as an `Authorization: Bearer` header, so the key never appears in a URL or a log.
- `/api/v1/lesson/<slug>/slides` answers with a redirect to a short-lived signed storage URL. The code follows the redirect only to the one allowed storage host and sends no API key there. It stores the URL without its signature.
- It checks every download is really a PDF and under 100 MB, the `AI_PARSE_DOCUMENT` limit.
- It names each deck by the SHA-256 of its bytes. A rerun skips unchanged decks, and a changed deck gets a new ID.
- It reads the PDF's own metadata (title, author, created date, page count) with `pypdf`.
- It retries rate limits and server errors, and returns a summary with counts of transcripts, decks, missing items, and errors, plus a short reason for each error in `error_details`.

They are caller's rights procedures, so they write to the schema you are using when you `CALL` them.

## Step 3: ingest the catalog and your program's lessons

Open [sql/03_ingest.sql](sql/03_ingest.sql) and run it one statement at a time.

`CALL ingest_catalog();` lands `/lesson`, `/academy`, and `/program` as raw `VARIANT` rows in `api_responses` and returns counts. Look at the raw JSON, then at the `programs` and `lessons` views, which turn it into rows with `FLATTEN`.

Find your program ID. The Senior AI Analytics Engineering Boot Camp is `908`. Then run:

```sql
SET program_id = 908;
CALL ingest_lessons($program_id, 40);
```

It requests a transcript for every lesson and slides for every lesson the catalog marks `has_slides`. Many lessons have neither yet: they're counted under `missing` in the summary, which is expected. For program 908, expect 3 transcripts and 2 slide decks:

| Lesson | Transcript | Slides |
| --- | --- | --- |
| Kick off | No | 19 pages |
| Snowflake Onboarding Instructions | 3 minutes | No |
| Unstructured Data Modeling Day 1 Lecture | 43 minutes | `w1d1.pdf`, 33 pages |
| Unstructured Data Modeling Day 1 Lab | 55 minutes | No |

The remaining queries show the transcripts and their cues, and each deck's PDF metadata and stage path. If the summary's `errors` count is above 0, read `error_details`, which names the lesson, the endpoint, and the reason, and fix it before you continue.

## Step 4: chunk the full transcripts

Run [sql/04_chunk_transcripts.sql](sql/04_chunk_transcripts.sql).

Each transcript arrives as one long, punctuated string (`transcript_text`). The worksheet splits that string directly; it does not use the cues.

1. It collapses repeated spaces, so every chunk can be found again in the original text.
2. It splits with `SPLIT_TEXT_RECURSIVE_CHARACTER(text, 'none', 1500, 200)`. Both numbers are characters, not tokens: 1,500 characters is roughly 300 tokens or 90 seconds of speech, and the 200-character overlap means a sentence on a boundary appears whole in at least one chunk.
3. It finds where each chunk starts with `POSITION` and estimates its start and end times from that position and the lesson's duration. A chunk that starts 40% of the way through the text starts about 40% of the way through the recording. The estimate can be off by tens of seconds, so citations say "about".

Check the inspection queries: every chunk has a time range, neighboring chunks overlap by up to about 200 characters, and the "no position" and "gaps" queries return zero rows. The last query splits the same text with no overlap so you can see chunks that end mid-sentence.

## Step 5: parse slides into pages with PDF metadata

Run [sql/05_parse_slides.sql](sql/05_parse_slides.sql).

`AI_PARSE_DOCUMENT` with `{'mode': 'LAYOUT', 'page_split': TRUE}` runs once per deck and returns a `pages` array. The third argument, `TRUE`, returns errors in the result instead of a silent NULL. `slide_pages` holds one row per page with:

- `slide_id`: `<deck_id>:p<page>`, stable for that exact file
- `page_index`: zero-based, as the parser reports it, and `page_number`, one-based, as people cite it
- the parent PDF's metadata: lesson, filename, stage path, SHA-256, PDF title and author, created date, and page count

Expect 52 pages for program 908. Look at the nearly empty pages. The "Reliability vs Manual Effort" chart on page 19 of `w1d1.pdf`, for example, parses to a handful of labels. Step 11 handles slides like this.

## Step 6: build one corpus and embed it

Run [sql/06_build_corpus_and_embed.sql](sql/06_build_corpus_and_embed.sql).

`search_corpus` combines three sources into one table: transcript chunks, slide pages, and one row per academy FAQ. Each row has a `source_id`, a `source_type`, a readable `citation`, and a `search_text` that starts with a short header naming the lesson or deck. Citations look like `<lesson title>, transcript 15:55-17:21` or `<lesson title>, w1d1.pdf page 13 of 33`. A chunk is about one topic, but on its own it does not say which lesson it came from. The header supplies that.

`AI_EMBED('snowflake-arctic-embed-l-v2.0', search_text)` turns each row into a 1,024-dimension vector in `text_embeddings`, about 140 calls for program 908. The last query is your first vector search: embed the question with the same model and rank by `VECTOR_COSINE_SIMILARITY`.

## Step 7: build a Cortex Search service

Open [sql/07_cortex_search.sql](sql/07_cortex_search.sql), replace `COURSE_WAREHOUSE` with your warehouse, and run it.

The service indexes `search_text` and lets you filter on `source_type` and `lesson_slug`. It generates and refreshes its own embeddings and combines vector similarity with keyword matching. The first build takes a few minutes; `SHOW CORTEX SEARCH SERVICES` shows its state.

`SNOWFLAKE.CORTEX.SEARCH_PREVIEW` accepts only literal arguments, so edit the JSON text to change a query. Try the slides-only filter. The last query puts vector-only and Cortex Search rankings side by side for a question containing an exact function name, `AI_PARSE_DOCUMENT`. Exact names are the kind of query where keyword matching helps.

## Step 8: create the search procedures

Run all of [sql/08_search_procedures.sql](sql/08_search_procedures.sql), generated from [python/course_search.py](python/course_search.py).

- `ask_course(question, top_k, answer_model)` retrieves the top results, numbers them, and asks `AI_COMPLETE` to answer from those sources only, citing them as `[n]`. If the sources don't answer the question, the model must reply `I could not find that in the course materials.` Every answer goes to `ask_log` with its sources.
- `run_search_eval(top_k)` runs every evaluation question through Cortex Search and stores the ranked results.

## Step 9: ask questions and evaluate retrieval

Open [sql/09_ask_and_evaluate.sql](sql/09_ask_and_evaluate.sql).

9a asks four questions. The last one, about office parking, is not covered anywhere in the materials; the correct output is the refusal. The default model is `claude-sonnet-4-5`. If it isn't available in your region, pass another as the third argument. Check that every `[n]` in an answer points to a retrieved source, then unpack one answer's sources to the slide page or recording time and verify the claim yourself.

9b loads 15 labeled questions. Each one lists the sources that answer it: a slide page, an FAQ, or a transcript time window that any overlapping chunk satisfies. The labels were checked against program 908's real transcripts and slides. Run the existence check: it should return zero rows. If you ingested a different program, write your own labels.

9c retrieves the top 10 for every question with both text methods. 9d scores them:

- `hit_at_1` and `hit_at_5`: the share of questions with a correct source at rank 1, or in the top 5
- `mrr_at_10`: the average of `1 / rank` of the first correct source, 0 if none is in the top 10

Use the per-question table to find where the methods disagree, then look at what a method returned instead.

## Steps 10 and 11: search slide images

Run [sql/10_slide_image_procedure.sql](sql/10_slide_image_procedure.sql) to create `render_slide_images`. Then run [sql/11_slide_image_search.sql](sql/11_slide_image_search.sql) one section at a time.

1. `CALL render_slide_images(1600, FALSE);` draws every page to a PNG in `@slide_images` with `pypdfium2`, about 60 to 360 KB per page. Rendering is not the same as `AI_PARSE_DOCUMENT`'s image extraction, which only pulls embedded pictures out of the page. Open one with the presigned URL query.
2. `AI_EMBED('voyage-multimodal-3', TO_FILE(...))` embeds each image as a 1,024-dimension vector. The same model embeds text queries into the same space, so text can rank images. Run the one-row text check at the top of 11b first: Snowflake's reference lists this model for images only, and 11c and 11d need it to accept text.
3. Search for the reliability chart with an image query, then with the slide-text query, and compare.
4. Add the `IMAGE` method to the evaluation. It only returns slides, so it is scored on the questions with a slide answer. Compare ranks, not similarity values: scores from different models are not comparable.
5. Optionally, have a vision model describe the text-light slides in `slide_descriptions`. To use the descriptions, append them to `search_text` in step 6, then rerun steps 6, 7, and 9 to see if text retrieval improves.

`AI_EMBED` with image input runs natively in AWS US West 2, AWS US East 1, AWS Europe Central 1, and Azure West Europe, and needs cross-region inference elsewhere. If it fails, ask your instructor before changing account settings.

## Steps 12 and 13: search lesson videos in 30-second clips

A transcript records what was said. A video embedding also captures what was on screen and what it sounded like, so a search can find the moment a demo or chart appears even if nobody describes it.

Run all of [sql/12_video_procedure.sql](sql/12_video_procedure.sql) to create `ingest_videos`. Like step 2, it's generated from [python/dataexpert_ingest.py](python/dataexpert_ingest.py). Then run [sql/13_video_search.sql](sql/13_video_search.sql) one section at a time.

1. 13a creates the `@lesson_videos` stage and the `lesson_videos` table.
2. 13b runs `CALL ingest_videos($program_id, 40);`. It requests `/api/v1/lesson/<slug>/video` for each lesson and treats video downloads the same way as slides: the key goes only to `www.dataexpert.io`, any redirect must point to an allowed storage host, and the stored URL drops its signature. Each video is streamed to a temporary file, checked, hashed, staged, and deleted before the next. Unchanged videos aren't re-uploaded, but they are downloaded again to check the hash. The summary counts uploads, missing videos, and errors, and `error_details` gives a reason for each error.
3. 13c makes one `AI_MULTI_EMBED('twelvelabs-marengo-embed-3-0', ...)` call per video. Marengo segments a video into fixed lengths of at most 10 seconds, so the call asks for 10-second segments. Each segment gets three 512-dimension vectors: `visual`, `audio`, and `transcription`. A rerun skips videos that already embedded.
4. 13d builds the 30-second clips. Each run of three segments in the same 30-second window is averaged with `VECTOR_AVG`, per modality. Embedding each 30-second window separately would also work, but it takes about 90 calls for a 45-minute lecture instead of one.
5. 13e searches the clips with a text question. It shows each modality's similarity, their average as `combined`, the overlapping transcript chunk from step 4, and a `watch_url` that opens the video at the clip's start. Then try a question about what is on screen and check whether `visual` leads.
6. 13f scores clip search on step 9's questions that have a transcript window in a lesson with video. A clip counts as correct when it overlaps the labeled window. Text `VECTOR` from step 9 on the same questions is the baseline. It can also be right with a slide or an FAQ, so it has more ways to win.

`AI_MULTI_EMBED` runs natively in AWS US East 1 and needs cross-region inference elsewhere. It accepts videos up to 4 hours and 6 GB; the procedure stops at 5 GB.

## What to report

- `retrieval_scores` for each method you ran, with the number of questions behind each score
- Two questions where the methods disagree, what each method returned, and a reason you can verify from the content
- One `ask_course` answer whose citations you checked against the original slide or recording, and whether the refusal question was refused
- One change you would make to chunking or the corpus, and how you would measure whether it helped
- If you ran the video path: the clip scores by modality next to `VECTOR`, and one clip you watched that a modality found and the transcript search missed, or the reverse

## Rerunning and costs

The ingestion procedures are safe to rerun. Transcripts are replaced, unchanged decks are skipped, and catalog responses are appended; the views read the latest response. Steps 4, 6, and 7 rebuild their tables. Step 5 parses only decks without a successful parse.

AI calls for program 908: 2 parse calls covering 52 pages, about 140 embeddings, one Cortex Search service, 4 answers, and 15 query embeddings plus 15 searches for evaluation. The image path adds 52 image embeddings, about 13 query embeddings, and about a dozen optional descriptions. The video path makes one `AI_MULTI_EMBED` call per video, billed by video length, plus about 10 query embeddings. Staged videos also use storage; `REMOVE @lesson_videos;` deletes them. Drop the search service when you are done to stop its refresh:

```sql
DROP CORTEX SEARCH SERVICE IF EXISTS course_search;
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `DataExpert API rejected the key (HTTP 401: API key is inactive)` | Get an active key from onboarding and rerun the `CREATE OR REPLACE SECRET` statement |
| `Secret ... does not exist or not authorized` | Create the secret in the same schema where you created and call the procedures |
| `Integration DATAEXPERT_API_ACCESS does not exist or not authorized` | Ask your instructor to run the instructor setup and grant usage |
| Request times out or is blocked | The network rule must include both `www.dataexpert.io` and the slide storage host; check `error_details` in the `ingest_lessons` summary |
| `No lessons for program ...` | Run `CALL ingest_catalog();` first, then check `SELECT * FROM programs;` |
| High `missing` count in the summary | Expected. Not every lesson has a transcript or slides yet |
| Parse result has an error | Inspect `slide_parse_results.raw_result:error`; the stage must use `SNOWFLAKE_SSE` |
| Cortex Search query fails right after creation | Wait for the first build; check `SHOW CORTEX SEARCH SERVICES` |
| `ask_course` fails on the model | Pass a model available in your region, for example `'llama3.3-70b'` |
| `AI_EMBED` rejects an image or `voyage-multimodal-3` | Image input needs a supported region or cross-region inference; skip step 11 or ask your instructor |
| The 11b text check fails | `voyage-multimodal-3` doesn't take text in this account, so text can't rank images; skip 11c and 11d |
| `Unexpected video redirect host` in `error_details` | Videos are served from a host the lab doesn't allow yet. The instructor adds it to `VIDEO_HOSTS` and the network rule, then you rerun steps 12 and 13b |
| Every lesson is `missing` in `ingest_videos` | The API has no videos for this program, or `/video` isn't live yet; run `python3 python/check_api.py --program 908 --videos` |
| `Video exceeds the 5 GB limit` | That video is too large for this lab; the others still load |
| `AI_MULTI_EMBED` unavailable | It needs AWS US East 1 or cross-region inference; skip step 13 or ask your instructor |
| Evaluation existence check returns rows | A labeled lesson was not ingested, or a deck changed page numbers |

## Files

| Path | Purpose |
| --- | --- |
| `sql/` | Worksheets, in order. `sql/00_instructor_setup.sql` is for the instructor only |
| `python/dataexpert_ingest.py` | API client and ingestion handlers, including videos |
| `python/course_search.py` | Cited answers and Cortex Search evaluation |
| `python/render_slides.py` | Page rendering for the image path |
| `python/build_sql.py` | Regenerates worksheets 02, 08, 10, and 12 from the handlers |
| `python/check_api.py` | Checks a key and lists available content, from your laptop |
| `tests/` | Offline tests with fake Snowflake sessions and HTTP |
| [docs/API_REFERENCE.md](docs/API_REFERENCE.md) | Observed API endpoints, responses, and errors |
| [docs/INSTRUCTOR_SETUP.md](docs/INSTRUCTOR_SETUP.md) | Account setup and rehearsal checklist |

To change a procedure, edit its Python file, run `python3 python/build_sql.py`, and rerun the generated worksheet.

## References

[AI_PARSE_DOCUMENT](https://docs.snowflake.com/en/sql-reference/functions/ai_parse_document) · [SPLIT_TEXT_RECURSIVE_CHARACTER](https://docs.snowflake.com/en/sql-reference/functions/split_text_recursive_character-snowflake-cortex) · [AI_EMBED](https://docs.snowflake.com/en/sql-reference/functions/ai_embed) · [AI_MULTI_EMBED](https://docs.snowflake.com/en/sql-reference/functions/ai_multi_embed) · [VECTOR_AVG](https://docs.snowflake.com/en/sql-reference/functions/vector_avg) · [Cortex Search](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search/cortex-search-overview) · [SEARCH_PREVIEW](https://docs.snowflake.com/en/sql-reference/functions/search_preview-snowflake-cortex) · [AI_COMPLETE](https://docs.snowflake.com/en/sql-reference/functions/ai_complete) · [External network access](https://docs.snowflake.com/en/developer-guide/external-network-access/creating-using-external-network-access)
