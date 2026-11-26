CREATE OR REPLACE CORTEX SEARCH SERVICE course_search
    ON SEARCH_TEXT
    ATTRIBUTES SOURCE_TYPE,LESSON_SLUG
    WAREHOUSE = 'COMPUTE_WH'
    TARGET_LAG = '1 day'
    EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS
SELECT source_id, source_type, lesson_slug, lesson_title, citation, search_text
FROM search_corpus;
