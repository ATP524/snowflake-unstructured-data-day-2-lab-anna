# Instructor setup

Date: 2026-11-18  
POC: Course instructor  
TL;DR: Run `sql/00_instructor_setup.sql` once, confirm the Python packages and Cortex models in the course region, then rehearse the full lab as `all_users_role` with a real student key.

## Account setup

Run [`sql/00_instructor_setup.sql`](../sql/00_instructor_setup.sql) as `ACCOUNTADMIN`. It creates:

- Network rule `dataexpert_api_hosts`, egress to `www.dataexpert.io:443` and `techcreator.s3.us-west-2.amazonaws.com:443`. The second host serves the presigned slide URLs; without it, slide downloads fail and transcripts still work.
- External access integration `dataexpert_api_access` with `ALLOWED_AUTHENTICATION_SECRETS = ALL`, granted to `all_users_role`. Each student binds their own `dataexpert_api_key` secret from their own schema, so the integration can't list secrets ahead of time. Egress stays limited to the two hosts.
- The `SNOWFLAKE.CORTEX_USER` grant and warehouse usage. Replace `COURSE_WAREHOUSE`.

If Day 1 needed per-function AI grants in this account, add the same grants for `AI_EMBED` and `AI_COMPLETE` here.

Students create their own secret, stages, procedures, and Cortex Search service. Schema owners already have those privileges. They don't need `CREATE INTEGRATION` for this lab.

If the slide bucket ever changes, update both the network rule and `SLIDE_HOSTS` in `python/dataexpert_ingest.py`, then regenerate the worksheets.

For the video path (steps 12 and 13), `VIDEO_HOSTS` defaults to the slide bucket. Before class, run `python3 python/check_api.py --program 908 --videos` with a key. It shows which host serves each video, without downloading. If the host differs, add it to `VIDEO_HOSTS` and to `dataexpert_api_hosts`, regenerate with `python3 python/build_sql.py`, and have students rerun step 12.

## Check region support before class

| Feature | Used in | What to check |
| --- | --- | --- |
| `requests`, `pypdf`, `pypdfium2`, `pillow` | Steps 2 and 10 | The package query at the end of the setup script returns all five rows |
| `AI_PARSE_DOCUMENT`, `AI_EMBED` with `snowflake-arctic-embed-l-v2.0` | Steps 5 and 6 | One call each succeeds as `all_users_role` |
| Cortex Search | Step 7 | A service builds; note the first build time |
| `AI_COMPLETE` with `claude-sonnet-4-5` | Step 9 | If unavailable, tell students which model to pass instead |
| `AI_EMBED` with `voyage-multimodal-3` on images and on text | Step 11 | Image input is native in AWS US West 2, AWS US East 1, AWS Europe Central 1, and Azure West Europe; elsewhere it needs cross-region inference, which needs organizational approval. The reference lists this model for images only, so confirm the text check at the top of 11b returns 1024 |
| `AI_MULTI_EMBED` with `twelvelabs-marengo-embed-3-0`, and `VECTOR_AVG` | Step 13 | Native in AWS US East 1 only; elsewhere it needs cross-region inference, which needs organizational approval. Embed one short video first and note its cost per minute |

## Rehearsal checklist

The SQL and procedures have not yet run in a Snowflake account. The Python handlers passed offline tests and a replay of the real API responses. Before class:

1. Get an active student key from onboarding. The key used while building this lab has since been deactivated.
2. On your laptop: `export DATAEXPERT_API_KEY=...` and run `python3 python/check_api.py --program 908`. Expect 3 transcripts and 2 decks.
3. As `all_users_role` in a fresh schema, run worksheets 01 through 09 in order, then 10 and 11, then 12 and 13.
4. In step 3, expect `transcripts: 3`, `slide_decks_uploaded: 2`, and `errors: 0` in the `ingest_lessons` summary.
5. In step 4, expect a positive overlap (up to about 200 characters) and zero rows from the "no position" and "gaps" queries. Chunk times are estimated from position in the text, not read from cues. If a chunk has no position, the splitter changed the text, and that chunk has no time, so it can't match a transcript label in step 9. Also check that the step 9 existence check still returns zero rows: the labeled time windows are narrow, and the estimated times can drift.
6. In step 5, expect 52 pages and no parse errors.
7. In step 9, the existence check returns zero rows and `retrieval_scores` has `VECTOR` and `CORTEX_SEARCH` rows.
8. In step 13, `ingest_videos` returns `errors: 0`, 13c's error query returns zero rows, and visual and audio clips average about 30 seconds. Note how long the downloads and embeddings take, and the size of each video.
9. Note the run time and credits for each step so you can set class expectations.

## Shared-account notes

Each student's API key stays in their own secret, but `all_users_role` is shared. Separate schemas prevent name collisions, not access. A student with the shared role can read another schema's tables, which include course content. Use per-student roles if that matters.

`api_responses` stores the full `/program` payload, which includes prices and Stripe price IDs but no personal data. Students' enrollment shows up only as which programs their key returns.

## Offline checks

```sh
python3 -m pip install -r requirements-dev.txt
python3 -m unittest discover -s tests -v
```

Tests cover the API client (Bearer header, no key sent to S3, redirect allowlist, PDF checks, retries, rejected keys), ingestion writes and reruns, page rendering, search literal escaping, the cited-answer prompt, evaluation writes, generated worksheets that match their Python source, and that no API key is committed. They do not run SQL against Snowflake.
