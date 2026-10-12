-- Loads NACE Rev.2 from data/prepared/nace_rev2.csv, which comes with the package, into the database you are connected to,
-- where the extension is installed:
--
--    psql -d yourdb -f tools/load_nace.sql
--
-- NACE Rev.2 is derived from ISIC Rev.4 (the same sections and divisions, its own groups and classes), so isic_rev4 must be
-- installed first:  SELECT * FROM codesystem_install_isic_rev4();   (tools/install_isic_isco.sql)
--
-- Run it again after a new version of the list is prepared: an unchanged list changes nothing, a changed one becomes the next revision.
\set ON_ERROR_STOP on
DO $$ BEGIN
   IF NOT EXISTS (SELECT 1 FROM code_systems WHERE name = 'isic_rev4') THEN
      RAISE EXCEPTION 'isic_rev4 is not installed: run  SELECT * FROM codesystem_install_isic_rev4();  first (tools/install_isic_isco.sql)';
   END IF;
END $$;
CREATE TEMP TABLE stg (code text, level text, parent text, label text);

\copy stg FROM 'data/prepared/nace_rev2.csv' (FORMAT csv, HEADER)
SELECT define_code_system('nace_rev2',
   '[{"name":"section", "width":1,"charset":"[A-Z]","link":"none",    "expected":21},
     {"name":"division","width":2,"charset":"[0-9]","link":"grouping","expected":88},
     {"name":"group",   "width":3,"charset":"[0-9]","link":"prefix",  "expected":272},
     {"name":"class",   "width":4,"charset":"[0-9]","link":"prefix",  "expected":615}]',
   'SELECT * FROM stg', 'Statistical classification of economic activities in the European Community, Rev.2', 'Eurostat',
   refines => 'isic_rev4', shared_levels => 2) AS nace_rev2_revision;

SELECT name, current_revision, ncodes, levels FROM code_systems WHERE name = 'nace_rev2';
