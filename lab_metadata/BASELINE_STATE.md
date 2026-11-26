# Day 2 lab pipeline: baseline state (frozen 2026-11-25)

Pick-up notes for the lab pipeline before the homework build (hw1, video). Snowflake objects live in
`BOOTCAMP.ATP524`. The workspace export (2026-11-26) also saves the Day 2 data and media; see "Export and restore".

## Status: baseline verified

| Item | Value |
| --- | --- |
| Champion run | `9dfccaf7f3c4` (`desc_v2_image_aware`), promoted 2026-11-25 17:41 |
| Previous champion | `287e36936493` (`0_baseline`) |
| Verification run | `f2d3a54fca8a`: SUCCESS, 26 of 26 steps skipped, all ties vs champion |
| Eval fingerprint | `0a5cf3cb3571997a` (21 questions, golden version 1) |
| Live search service | `COURSE_SEARCH` only (both baseline services dropped) |
| Options cell left at | `MODE="maintenance"`, `FORCE_STEPS=[]`, `EXPERIMENT_NAME=""`, `REFRESH_SOURCES="auto"` |

Run history (newest first, from `runbook_runs`):

| Run | What it was | Result |
| --- | --- | --- |
| `f2d3a54fca8a` | Verification after the 09d fix | all skip, all ties |
| `bde2c7b0b1c9` | `FORCE_STEPS=["09d"]` to clear a DRIFT left by the desc v2 experiment | 09d rebuilt, no AI calls |
| `51a16c05dd5e` | First verification vs new champion | found the 09d DRIFT (fixed, see below) |
| `9dfccaf7f3c4` | full_experiment `BEFORE_DESC_V2`: image-aware 11e describe rule | **champion** |
| `5a27f20352c5` | 09b simplified (eval_questions loaded directly) | same fingerprint, all ties |
| `bbbf6c8651fc` | Verification vs `287e36936493` | all skip, all ties |
| `287e36936493` | Phase baseline | first champion |
| `86183c0dc237` | Failed 09e (`'None'` stored as text) | FAILED, rows cleaned |

## Champion scores (`eval_run_report`, run `9dfccaf7f3c4`, all questions)

| Method | Questions | Hit@1 | Hit@5 | MRR@10 | Recall@10 | nDCG@10 |
| --- | --- | --- | --- | --- | --- | --- |
| CORTEX_SEARCH | 20 | 0.800 | 1.000 | 0.900 | 0.975 | 0.898 |
| VECTOR | 20 | 0.800 | 1.000 | 0.900 | 0.950 | 0.859 |
| IMAGE | 17 | 0.765 | 1.000 | 0.882 | 0.980 | 0.896 |
| VIDEO_TRANSCRIPTION | 9 | 0.667 | 0.889 | 0.766 | | |
| VIDEO_COMBINED | 9 | 0.556 | 0.778 | 0.676 | | |
| VIDEO_VISUAL | 9 | 0.556 | 0.778 | 0.615 | | |
| VIDEO_AUDIO | 9 | 0.222 | 0.333 | 0.312 | | |

- Answers (09e): 21 judged, refusal accuracy 1.000 (Q16 correctly refused; Q21 no longer wrongly refused).
- Desc v2 vs previous champion: CORTEX_SEARCH and VECTOR each 4 wins / 0 losses / 16 ties, p = 0.125
  (Q14, Q19, Q20, Q21 improved; IMAGE unchanged as the control).

## What changed in this phase (where to look)

- **11e describe rule v2** (`sql/11_slide_image_search.sql`, 11e build): describe a slide if
  `p.content LIKE '%![img-%'` OR its real text (image links and the footer stripped) is under
  `$describe_max_chars`. 13 -> 63 slides described. `Runbook.describe_filter()` in
  `lab_metadata/runbook_lib.py` reads this WHERE clause so the 11e check and cost estimate use the same rule.
- **09b simplified** (`sql/09_ask_and_evaluate.sql`, 09b build): `eval_questions` is loaded directly;
  `golden_seed_v1` and `eval_questions_golden` were dropped. `$golden_version` filters on `version`.
- **Human review** (`runbook_lib.py` `hitl_sample` / `hitl_queue` / `save_review`): the sample is queued
  in `hitl_reviews` as pending rows; saving updates the row (no duplicates).
- **EXPERIMENT_NAME** blank = run date (`start_run`).
- **09d DRIFT after experiments** (`score_baseline`): baseline rows added to `retrieval_results` after 09d
  ran made the next run report DRIFT and rerun 13f. `score_baseline` now re-records 09d's outputs and the
  inputs of steps that read them. If DRIFT on 09d ever appears again, `FORCE_STEPS=["09d"]` clears it at no AI cost.

## Known limits (not blockers)

1. **The judge does not discriminate.** Every champion answer got groundedness 5. Answer-quality metrics
   are not trustworthy until the judge is checked: grade some of the 19 pending rows in `hitl_reviews`
   (`SELECT * FROM hitl_reviews WHERE human_score IS NULL;`), then read `judge_agreement`. A stricter
   judge prompt (bump `$judge_prompt_version`) or a different `$judge_model` are the next things to try.
2. **The eval set is small.** 20 answerable questions: even 4W / 0L only reaches p = 0.125; a clean sweep
   needs 6 or more moved questions for p < 0.05. Slices need 20 questions for a verdict, so per-slice
   verdicts never fire yet. The homework question set is the fix.
3. **Credits are not computed.** `ai_token_rates` is empty, so cost shows tokens only. Fill it from the
   Snowflake Service Consumption Table to get credits in the Cost cell and `eval_run_report`.
4. **11e is nondeterministic.** `AI_COMPLETE` writes different descriptions every run; rerunning 11e changes
   06a's input and every score downstream. History is in `slide_descriptions_history`. Only rerun 11e as a
   `full_experiment`.
5. **Describe rule edge cases.** The footer strip matches `Zach Wilson's DataExpert.io Boot Camp` exactly;
   another deck's footer would count as real text. 15 of 78 slides are not described.
6. **Video slice is 9 questions** (`VIDEO_*` methods). Counts only, no verdicts, until the homework adds more.
7. **Leftover experiment tables** kept as history: `*_BEFORE_DESC`, `*_BEFORE_DESC_V2` (corpus, embeddings,
   query embeddings, results, question scores) and `RETRIEVAL_SCORES_HISTORY_LEGACY`. Their search services
   are dropped, so they cost storage only. They can be re-scored offline.

## What the export does not hold

The zips and `results/` hold the data and media (see "Export and restore" below). They do not hold
the secret's value, or account objects such as the external access integration. To keep a
copy of the Snowflake state as of this baseline inside this account as well:

```sql
CREATE SCHEMA bootcamp.atp524_baseline_20261125 CLONE bootcamp.atp524;
```

Clones add no storage cost until data changes. Not verified here: whether the clone includes the Cortex
Search service. Check with `SHOW CORTEX SEARCH SERVICES IN SCHEMA bootcamp.atp524_baseline_20261125;`
and rebuild `course_search` (step 07a) if you ever restore from the clone and it is missing. If the clone
does include it, drop it there so it does not bill serving credits.

## Export and restore (2026-11-26)

The Day 2 state is exported, and a test restore proved it rebuilds exactly. Day 1 objects are never included.

**What the export holds** (`lab_metadata/workspace_export.ipynb`, engine `lab_metadata/export_lib.py`):

| Part | Where | In git? |
| --- | --- | --- |
| 42 Day 2 tables and 13 views as CSV; DDL of tables, views, stages, functions, procedures and `course_search`; stage manifest with MD5; `prerequisites.md`; `SUMMARY.md` | `results/2026-11-26/` (210 MB; CSVs over 20 MB are split into `NAME.partNN.csv`, largest file 24 MB) | yes |
| Copies of the 91 Day 2 stage files (`LESSON_SLIDES` 3, `SLIDE_IMAGES` 78, `LESSON_VIDEOS` 10) | `@BOOTCAMP.ATP524.LAB_EXPORT_STAGE_D2_RAG_EVAL/2026-11-26/stage_files/` | no |
| Media zip (2.74 GB) and code zip (44 MB, the workspace as git sees it, including `results/`) | same stage, `2026-11-26/*.zip` | no / it is the repo |

- The scope is derived from the code: an object is Day 2 when its name appears in `sql/`, `python/` or
  `runbook_lib.py`, or it is a `<table>_<run label>` snapshot (`export_lib.day2_scope`). The 34 excluded
  Day 1 objects are listed in `results/2026-11-26/scope.csv`.
- Floats are written with 16 significant digits, which is the most Snowflake text output carries. The test
  restore found every non-float value identical; the largest float difference was 5.6e-17. Vectors,
  VARIANT and timestamps restored bit for bit.
- The secret's value is never exported. Recreate it with your own key (`prerequisites.md`).

**Test restore** (`lab_metadata/workspace_restore.ipynb` into `BOOTCAMP.ATP524_RESTORE_TEST`, dropped afterwards):

- All 42 tables were loaded and their row counts match the source. All 91 media files match on size and MD5.
  All 13 views compiled. `fmt_ts` and the 08 and 10 procedures were created, and `course_search` reached ACTIVE with 392 rows.
- Restored run `aa1dc43b14db` adopted 24 of 26 steps (`Runbook.adopt_restored_state`, `runbook_lib.py`). It has the
  same eval fingerprint `0a5cf3cb3571997a` and ties the champion on every question. Every metric equals the
  champion's (CORTEX_SEARCH MRR@10 0.900), and it was promoted in the test schema.
- The 2 steps not adopted are 02 and 12: their ingest procedures need the `dataexpert_api_key` secret,
  which the test schema did not have. With the secret in place they restore like the rest.
- The restore makes `fmt_ts` from `ddl/functions.sql` rather than running 01.build. 01.build's
  `ALTER TABLE ask_log ADD COLUMN IF NOT EXISTS purpose ...` fails with "ambiguous column name" once the
  column already exists. This does not affect normal runs, where 01 is skipped as long as its outputs exist.

**Restoring in your own account:**

1. Clone the repo into a Snowflake workspace.
2. Download the media zip, unzip it, and upload its folders to a stage, for example with
   `snow stage copy ./media/ @<db>.<schema>.<stage>/ --recursive`. The videos are about 270 MB each, which may be
   too big for a Snowsight upload.
3. Optional: create the secret, network rule and integration listed in `prerequisites.md`.
4. In `workspace_restore.ipynb` **Settings**, replace every `<...>` value (role, database, schema, warehouse,
   `MEDIA_SOURCE`). Keep `WRITE_CONFIG = True` so `sql/runbook_config.sql` and the 07a warehouse are set for you.
   Then run all cells. The **Verify** cell lists any step the plan would still run.
5. Run `pipeline_runbook.ipynb` in `maintenance`. Without the secret, set `REFRESH_SOURCES=False`.

To export again later, run `workspace_export.ipynb` top to bottom. It writes `results/<today>/` and a new
dated folder on the same export stage. `OVERWRITE_DATE = True` is only needed to redo the same day.

## Picking up for the homework

- Homework (hw1, `homework_metadata/reference.sql`) gets its own runbook and must use the exact IDs
  Q1-Q8 and U1. Do not change the lab's Q01-Q21.
- Adding questions changes the eval fingerprint: the first run after that reports *not comparable*
  against the champion. Run it in `maintenance`, check the numbers, then promote it as the new champion.
- Every experiment: one change, `full_experiment` with a new `LABEL`, then the cleanup cell
  (`CONFIRM_DROP=True`) or `DROP CORTEX SEARCH SERVICE course_search_<label>;` right after reviewing.
- After promoting, set `PROMOTE = None` again (Run all would re-promote otherwise).
