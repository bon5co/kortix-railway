-- PostgREST settings stored in the database (PostgREST reads pgrst.* settings
-- of its login role at startup, "in-database configuration"). Platforms that
-- cannot carry plain environment values for the REST service (Railway's
-- template generator blanks them, and the PostgREST image has no shell) rely on
-- these; elsewhere they match the PGRST_* environment values.
ALTER ROLE authenticator SET pgrst.db_anon_role = 'anon';
ALTER ROLE authenticator SET pgrst.db_schemas = 'public';
ALTER ROLE authenticator SET pgrst.db_extra_search_path = 'public';
ALTER ROLE authenticator SET pgrst.db_max_rows = '1000';
