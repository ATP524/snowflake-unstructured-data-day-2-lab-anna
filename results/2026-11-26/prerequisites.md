# Prerequisites for a restore (values are never exported)

| Object | What to create |
| --- | --- |
| secret | dataexpert_api_key (GENERIC_STRING, your DataExpert API key) |
| network_rule | dataexpert_api_hosts (see sql/00_instructor_setup.sql) |
| external_access_integration | dataexpert_api_access (see sql/00_instructor_setup.sql; needs ACCOUNTADMIN) |
| secret in source schema | DATAEXPERT_API_KEY (recreate with your own key: `CREATE SECRET dataexpert_api_key TYPE = GENERIC_STRING SECRET_STRING = '<key>';`) |
| warehouse | compute_wh (any warehouse; set it in sql/runbook_config.sql) |
| role | all_users_role (needs CREATE SCHEMA/TABLE/VIEW/STAGE/PROCEDURE and CORTEX SEARCH SERVICE, and SNOWFLAKE.CORTEX_USER) |
| models | claude-sonnet-4-5, llama3.3-70b, snowflake-arctic-embed-l-v2.0, voyage-multimodal-3 (may need cross-region inference) |

Without the secret and the external access integration everything restores and the pipeline runs on the exported data, 
but ingest (steps 02, 03, 12, 13b) cannot fetch new lessons: run the runbook with `REFRESH_SOURCES=False`.
