-- Instructor only: run once per account before class. Students skip this file.
-- Creates the egress rule and external access integration that the students'
-- ingestion procedures use, then grants the course role what Day 2 needs.

USE ROLE ACCOUNTADMIN;
USE DATABASE bootcamp;
-- Use the course-owned schema that holds Day 1's network rules.
CREATE SCHEMA IF NOT EXISTS course_integrations;
USE SCHEMA course_integrations;

-- The API host plus the S3 bucket that /slides redirects to with a presigned URL.
-- The video path assumes /video redirects to the same bucket. If
-- check_api.py --videos shows another host, add it here and to VIDEO_HOSTS.
CREATE OR REPLACE NETWORK RULE dataexpert_api_hosts
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = ('www.dataexpert.io:443', 'techcreator.s3.us-west-2.amazonaws.com:443');

-- Each student stores their own API key in a secret in their own schema, so the
-- integration allows any secret. Egress is still limited to the two hosts above.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION dataexpert_api_access
    ALLOWED_NETWORK_RULES = (dataexpert_api_hosts)
    ALLOWED_AUTHENTICATION_SECRETS = ALL
    ENABLED = TRUE
    COMMENT = 'Day 2 lab: DataExpert content API and slide downloads';

GRANT USAGE ON INTEGRATION dataexpert_api_access TO ROLE all_users_role;

-- Cortex functions: AI_PARSE_DOCUMENT, AI_EMBED (text and images),
-- AI_MULTI_EMBED (video), AI_COMPLETE,
-- SPLIT_TEXT_RECURSIVE_CHARACTER, and Cortex Search.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE all_users_role;

-- Students create secrets, stages, procedures, and a Cortex Search service in
-- schemas they own. Schema owners already hold those privileges.
GRANT USAGE ON DATABASE bootcamp TO ROLE all_users_role;
GRANT CREATE SCHEMA ON DATABASE bootcamp TO ROLE all_users_role;
-- Replace with the assigned warehouse. Cortex Search also uses it for refreshes.
GRANT USAGE ON WAREHOUSE COURSE_WAREHOUSE TO ROLE all_users_role;

-- Optional image path: AI_EMBED with images (voyage-multimodal-3) runs natively
-- in AWS US West 2, AWS US East 1, AWS Europe Central 1, and Azure West Europe.
-- Optional video path: AI_MULTI_EMBED runs natively in AWS US East 1 only.
-- In other regions both need cross-region inference. Enable that only with approval:
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Rehearsal checks, as all_users_role in a fresh schema:
SHOW INTEGRATIONS LIKE 'dataexpert_api_access';
-- Expect five rows. Missing rows mean the package is unavailable in this account.
SELECT package_name, COUNT(*) AS versions_available
FROM information_schema.packages
WHERE language = 'python'
  AND package_name IN ('requests', 'pypdf', 'pypdfium2', 'pillow', 'snowflake-snowpark-python')
GROUP BY package_name
ORDER BY package_name;
