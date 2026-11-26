CREATE OR REPLACE FUNCTION "FMT_TS"("SECONDS" FLOAT)
RETURNS VARCHAR
LANGUAGE SQL
AS '
    IFF(seconds >= 3600,
        FLOOR(seconds / 3600)::INT::VARCHAR || '':''
            || LPAD(FLOOR(MOD(seconds, 3600) / 60)::INT::VARCHAR, 2, ''0''),
        FLOOR(seconds / 60)::INT::VARCHAR)
    || '':'' || LPAD(FLOOR(MOD(seconds, 60))::INT::VARCHAR, 2, ''0'')
';
