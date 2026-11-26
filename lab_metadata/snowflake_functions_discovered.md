### All Snowflake & SQL Functions Discovered in this Workspace (110 Found)
| Function | Category | Purpose / Definition | Used In |
| :--- | :--- | :--- | :--- |
| `AI_COMPLETE()` | **Cortex AI** | Generates text completions or answers prompts using an LLM. | `python/course_search.py`<br>`sql/08_search_procedures.sql`<br>`sql/11_slide_image_search.sql` |
| `AI_EMBED()` | **Vector / RAG** | Converts text or images into vector embeddings. | `sql/06_build_corpus_and_embed.sql`<br>`sql/07_cortex_search.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql` |
| `AI_PARSE_DOCUMENT()` | **Document AI** | Extracts text, tables, and layout from PDFs/docs in a stage. | `sql/05_parse_slides.sql` |
| `DIRECTORY()` | **Stage / Files** | Queries file metadata (size, last modified, URL) in a stage. | `sql/03_ingest.sql`<br>`sql/05_parse_slides.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `FLATTEN()` | **Semi-Structured** | Explodes semi-structured arrays/objects into relational rows. | `sql/01_setup.sql`<br>`sql/03_ingest.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/05_parse_slides.sql`<br>`sql/07_cortex_search.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/13_video_search.sql` |
| `GET_PRESIGNED_URL()` | **Stage / Files** | Generates a temporary HTTPS link to access a staged file. | `sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `OBJECT_CONSTRUCT()` | **Semi-Structured** | Constructs a JSON/OBJECT value from key-value pairs. | `sql/05_parse_slides.sql` |
| `PARSE_JSON()` | **Semi-Structured** | Parses a JSON string into a Snowflake VARIANT object. | `python/course_search.py`<br>`python/dataexpert_ingest.py`<br>`sql/02_ingest_procedures.sql`<br>`sql/07_cortex_search.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SEARCH_PREVIEW()` | **Cortex Search** | Queries a Snowflake Cortex Search service for retrieval. | `python/course_search.py`<br>`sql/07_cortex_search.sql`<br>`sql/08_search_procedures.sql` |
| `SPLIT_TEXT_RECURSIVE_CHARACTER()` | **Text / RAG** | Splits long text into overlapping chunks for RAG embeddings. | `sql/04_chunk_transcripts.sql` |
| `VECTOR_COSINE_SIMILARITY()` | **Vector / RAG** | Measures cosine similarity (-1 to 1) between two vectors. | `sql/06_build_corpus_and_embed.sql`<br>`sql/07_cortex_search.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `AI_MULTI_EMBED()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/13_video_search.sql` |
| `ANY_VALUE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/13_video_search.sql` |
| `APIAUTHERROR()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `APICLIENT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `API_RESPONSES()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/dataexpert_ingest.py`<br>`sql/01_setup.sql`<br>`sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `APPEND()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ARRAY_SIZE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/03_ingest.sql`<br>`sql/06_build_corpus_and_embed.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql` |
| `ASK_LOG()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/course_search.py`<br>`sql/01_setup.sql`<br>`sql/08_search_procedures.sql` |
| `BYTESIO()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `CEIL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/13_video_search.sql` |
| `CLOSE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `COLLECT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `COMPILE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `CONVERT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `CORTEX()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `lab_metadata/helper_functions_scanner.ipynb` |
| `COUNT_IF()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/03_ingest.sql`<br>`sql/05_parse_slides.sql`<br>`sql/06_build_corpus_and_embed.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/13_video_search.sql` |
| `CREATE_DATAFRAME()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `CURRENT_DATABASE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql` |
| `CURRENT_ROLE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql` |
| `CURRENT_SCHEMA()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql` |
| `DUMPS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ENDSWITH()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ENUMERATE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `EVAL_EXPECTED()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/09_ask_and_evaluate.sql` |
| `EVAL_QUESTIONS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/09_ask_and_evaluate.sql` |
| `FLOOR()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/13_video_search.sql` |
| `FMT_TS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/03_ingest.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/06_build_corpus_and_embed.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/13_video_search.sql` |
| `FORMAT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `FROZENSET()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `GET()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `GETVALUE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `GET_DDL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/11_slide_image_search.sql` |
| `GET_GENERIC_SECRET_STRING()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `GET_SIZE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `GET_STREAM()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `GROUPS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `HEXDIGEST()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ISDIGIT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ISINSTANCE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `ITER_CONTENT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `JSON()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `KEY()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `LAG()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/04_chunk_transcripts.sql` |
| `LEAD()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/04_chunk_transcripts.sql` |
| `LEAST()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/04_chunk_transcripts.sql` |
| `LENGTH()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/03_ingest.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/05_parse_slides.sql`<br>`sql/06_build_corpus_and_embed.sql`<br>`sql/11_slide_image_search.sql` |
| `LESSON_TRANSCRIPTS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/dataexpert_ingest.py`<br>`sql/01_setup.sql`<br>`sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `LESSON_VIDEOS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/dataexpert_ingest.py`<br>`sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql`<br>`sql/13_video_search.sql` |
| `LITERAL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `LOADS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `LPAD()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/05_parse_slides.sql`<br>`sql/13_video_search.sql` |
| `MATCH()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `MOD()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql` |
| `MODE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `OPEN()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `OVER()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/05_parse_slides.sql`<br>`sql/07_cortex_search.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `PDFDOCUMENT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `PDFREADER()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `POSITION()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/04_chunk_transcripts.sql` |
| `PROMPT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/11_slide_image_search.sql` |
| `PUT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `PUT_STREAM()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `RANGE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `READ()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `REGEXP_REPLACE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/04_chunk_transcripts.sql` |
| `REGEXP_SUBSTR_ALL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/09_ask_and_evaluate.sql` |
| `RETRIEVAL_RESULTS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql` |
| `RETURN()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `ROUND()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/03_ingest.sql`<br>`sql/04_chunk_transcripts.sql`<br>`sql/06_build_corpus_and_embed.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `ROW_NUMBER()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/01_setup.sql`<br>`sql/05_parse_slides.sql`<br>`sql/07_cortex_search.sql`<br>`sql/09_ask_and_evaluate.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `RSPLIT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `RUNTIMEERROR()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SAVE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `SAVE_AS_TABLE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `SESSION()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SHA256()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SLEEP()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SLIDE_DECKS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/dataexpert_ingest.py`<br>`sql/01_setup.sql`<br>`sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SLIDE_IMAGES()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/render_slides.py`<br>`sql/01_setup.sql`<br>`sql/10_slide_image_procedure.sql` |
| `SLIDE_PARSE_RESULTS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/05_parse_slides.sql` |
| `SNOWFLAKE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/render_slides.py`<br>`sql/10_slide_image_procedure.sql` |
| `SORTED()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/08_search_procedures.sql` |
| `STARTSWITH()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `STRIP()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `SUB()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `TELL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `TEMPORARYDIRECTORY()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `TO_FILE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/05_parse_slides.sql`<br>`sql/11_slide_image_search.sql`<br>`sql/13_video_search.sql` |
| `TO_PIL()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/10_slide_image_procedure.sql` |
| `TO_VARIANT()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/05_parse_slides.sql`<br>`sql/13_video_search.sql` |
| `TRY_TO_TIMESTAMP_TZ()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `python/dataexpert_ingest.py`<br>`sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `TUPLE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `UNQUOTE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `URLPARSE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `UUID4()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
| `VALUEERROR()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/08_search_procedures.sql`<br>`sql/10_slide_image_procedure.sql`<br>`sql/12_video_procedure.sql` |
| `VECTOR_AVG()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/13_video_search.sql` |
| `VIDEO_EMBED_RESULTS()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/13_video_search.sql` |
| `WRITE()` | **Other / Unmapped** | [Needs Definition] Discovered in SQL | `sql/02_ingest_procedures.sql`<br>`sql/12_video_procedure.sql` |
