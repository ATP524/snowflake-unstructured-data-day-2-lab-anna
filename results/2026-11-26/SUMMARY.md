# Day 2 export summary: d2_rag_eval, 2026-11-26

## Scope
- Source: `BOOTCAMP.ATP524`, this Day 2 workspace. Day 2 only; Day 1 objects are excluded (see `scope.csv`).
- Exported: 68 objects (42 table, 13 view, 3 stage, 1 function, 7 procedure, 1 cortex_search_service, 1 secret).
- Excluded: 34 objects: table: DDL_APPLIED, EXTRACTED_VALUES, EXTRACTION_RESULTS, INGEST_LOG, LAB_RUNS, LAB_SETTINGS, METRIC_CATALOG, METRIC_SEC_CONCEPTS, PARSE_RESULTS, REPORT_MANIFEST, SEC_FACTS, STATEMENT_HEADING_PATTERNS, STATEMENT_PAGE_SCAN, SYNTHETIC_GROUND_TRUTH; view: COMPARED_VALUES, EXTRACTED_FIELDS, HEADING_PATTERN_USAGE, METHOD_COMPARISON, METRIC_EVALUATION, METRIC_GROUND_TRUTH, NORMALIZED_EXTRACTIONS, PARSED_PAGES, PIPELINE_COVERAGE, REPORT_READINESS, REPORT_STATUS, SCOPE_METRICS, SEC_REFERENCE; stage: ANNUAL_REPORT_PDFS, LAB_EXPORT_STAGE; function: LAB_NUMBER, LAB_SCALE_MATCHES_EVIDENCE, LOCATOR_DECISION, PDF_PAGE_TEXT; file_format: SYNTHETIC_JSON_FORMAT.
- CSVs over 20 MB are split into plain-text parts (`NAME.part01.csv`, ...). VARIANT, ARRAY, OBJECT and VECTOR columns are JSON text; `\N` marks a SQL NULL.
- Floats are written with 16 significant digits (the most Snowflake text output carries); everything else round-trips exactly.

## Latest batch
- Run `f2d3a54fca8a`: SUCCESS, mode maintenance, experiment `2026-11-26`, started 2026-11-25 17:59:54.900000-08:00.
- Change note: Verification run: nothing changed since champion 9dfccaf7f3c4 (desc v2 image-aware); expect every step to skip and all ties vs the champion
- Verdicts:
  - VECTOR vs VECTOR: 0 wins, 0 losses, 20 ties on 20 shared questions (sign test p = 1.0) -> inconclusive
  - CORTEX_SEARCH vs CORTEX_SEARCH: 0 wins, 0 losses, 20 ties on 20 shared questions (sign test p = 1.0) -> inconclusive
  - IMAGE vs IMAGE: 0 wins, 0 losses, 17 ties on 17 shared questions (sign test p = 1.0) -> inconclusive
  - CORTEX_SEARCH vs VECTOR: 0 wins, 0 losses, 20 ties on 20 shared questions (sign test p = 1.0) -> inconclusive

## Champion
- Run `9dfccaf7f3c4` (`desc_v2_image_aware`), promoted 2026-11-25 17:41:08.970000-08:00: desc v2 image-aware: MRR 0.782→0.900, 4W/0L

## Check pass counts
| RUN_ID | CHECKS | PASSED |
| --- | --- | --- |
| 9dfccaf7f3c4 | 18 | 18 |
| f2d3a54fca8a | 18 | 18 |

## Data-quality checks (expect 0 bad rows)
| check | bad_rows | result |
| --- | --- | --- |
| corpus rows without an embedding | 0 | PASS |
| expected answers not found in the corpus (09b.check) | 0 | PASS |
| answerable eval questions with no expected answer | 0 | PASS |
| repeated (method, question, rank) in retrieval_results | 0 | PASS |
| slides the 11e rule selects that have no description | 0 | PASS |
| runs still RUNNING | 0 | PASS |
| champion missing | 0 | PASS |

## Stage files (copied to @LAB_EXPORT_STAGE_D2_RAG_EVAL/2026-11-26/stage_files/)
| stage | files | mb |
| --- | --- | --- |
| LESSON_SLIDES | 3 | 13.6 |
| LESSON_VIDEOS | 10 | 2719.7 |
| SLIDE_IMAGES | 78 | 11.1 |

## Files in results/2026-11-26/
| file | rows |
| --- | --- |
| tables/AI_TOKEN_RATES.csv | 0 |
| tables/ANSWER_JUDGMENTS.csv | 63 |
| tables/API_RESPONSES.csv | 54 |
| tables/ASK_LOG.csv | 70 |
| tables/EVAL_EXPECTED.csv | 32 |
| tables/EVAL_IMAGE_QUERY_EMBEDDINGS.csv | 17 |
| tables/EVAL_QUERY_EMBEDDINGS.csv | 20 |
| tables/EVAL_QUERY_EMBEDDINGS_BEFORE_DESC_V2.csv | 20 |
| tables/EVAL_QUESTIONS.csv | 21 |
| tables/EVAL_VIDEO_QUERY_EMBEDDINGS.csv | 9 |
| tables/HITL_REVIEWS.csv | 19 |
| tables/LESSON_TRANSCRIPTS.csv | 10 |
| tables/LESSON_VIDEOS.csv | 10 |
| tables/QUESTION_SCORES_BEFORE_DESC.csv | 42 |
| tables/QUESTION_SCORES_BEFORE_DESC_V2.csv | 97 |
| tables/RETRIEVAL_QUESTION_SCORES_HISTORY.csv | 1230 |
| tables/RETRIEVAL_RESULTS.csv | 1370 |
| tables/RETRIEVAL_RESULTS_BEFORE_DESC.csv | 420 |
| tables/RETRIEVAL_RESULTS_BEFORE_DESC_V2.csv | 970 |
| tables/RETRIEVAL_SCORES_HISTORY_LEGACY.csv | 15 |
| tables/RUNBOOK_AI_USAGE.csv | 18 |
| tables/RUNBOOK_RUNS.csv | 17 |
| tables/RUNBOOK_SOURCE_FRESHNESS.csv | 17 |
| tables/RUNBOOK_STEP_RUNS.csv | 292 |
| tables/SEARCH_CORPUS.csv | 392 |
| tables/SEARCH_CORPUS_BEFORE_DESC.csv | 337 |
| tables/SEARCH_CORPUS_BEFORE_DESC_V2.csv | 392 |
| tables/SLIDE_DECKS.csv | 3 |
| tables/SLIDE_DESCRIPTIONS.csv | 63 |
| tables/SLIDE_DESCRIPTIONS_HISTORY.csv | 76 |
| tables/SLIDE_IMAGES.csv | 78 |
| tables/SLIDE_IMAGE_EMBEDDINGS.csv | 78 |
| tables/SLIDE_PAGES.csv | 78 |
| tables/SLIDE_PARSE_RESULTS.csv | 3 |
| tables/TEXT_EMBEDDINGS.csv | 392 |
| tables/TEXT_EMBEDDINGS_BEFORE_DESC.csv | 337 |
| tables/TEXT_EMBEDDINGS_BEFORE_DESC_V2.csv | 392 |
| tables/TRANSCRIPT_CHUNKS.csv | 305 |
| tables/VIDEO_CLIPS.part01.csv + tables/VIDEO_CLIPS.part02.csv | 2523 |
| tables/VIDEO_EMBED_RESULTS.part01.csv + tables/VIDEO_EMBED_RESULTS.part02.csv + tables/VIDEO_EMBED_RESULTS.part03.csv + tables/VIDEO_EMBED_RESULTS.part04.csv | 10 |
| tables/VIDEO_EVAL_RESULTS.csv | 360 |
| tables/VIDEO_SEGMENTS.part01.csv + tables/VIDEO_SEGMENTS.part02.csv + tables/VIDEO_SEGMENTS.part03.csv + tables/VIDEO_SEGMENTS.part04.csv + tables/VIDEO_SEGMENTS.part05.csv | 7647 |
| views/ACADEMY_FAQS.csv | 9 |
| views/EVAL_RELEVANT_ITEMS.csv | 42 |
| views/EVAL_RELEVANT_SOURCES.csv | 42 |
| views/EVAL_RUN_REPORT.csv | 558 |
| views/LATEST_API_RESPONSES.csv | 3 |
| views/LESSONS.csv | 181 |
| views/PROGRAMS.csv | 4 |
| views/RETRIEVAL_QUESTION_SCORES.csv | 137 |
| views/RETRIEVAL_SCORES.csv | 7 |
| views/RETRIEVAL_SCORES_BY_SLICE.csv | 55 |
| views/RETRIEVAL_SCORES_HISTORY.csv | 76 |
| views/SLIDE_IMAGE_VECTORS.csv | 78 |
| views/VIDEO_QUESTION_SCORES.csv | 45 |
| ddl/tables.sql |  |
| ddl/views.sql |  |
| ddl/functions.sql |  |
| ddl/procedures.sql |  |
| ddl/stages.sql |  |
| ddl/cortex_search_services.sql |  |
| ddl/column_types.json |  |
| stage_manifest.csv | 91 |
| scope.csv |  |
| prerequisites.md |  |

## Failures
none

## How to restore
1. Create the prerequisites in `prerequisites.md` (secret with your key, network rule, external access integration).
2. Upload the media zip's folders to a stage (for example with `snow stage copy`), or use `@LAB_EXPORT_STAGE_D2_RAG_EVAL/2026-11-26/stage_files/` in this account.
3. Open `lab_metadata/workspace_restore.ipynb`, set your role, database, schema, warehouse, `RESULTS_DATE = "2026-11-26"` and the media location, and run it top to bottom.
4. It creates the tables, loads these CSVs, copies the media into the stages, rebuilds views, functions, procedures and the search service, and records the restored state as the champion.
5. Run `pipeline_runbook.ipynb`: every step should skip.
