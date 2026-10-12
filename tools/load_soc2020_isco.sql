-- SOC 2020 to ISCO-08, from the ONS SOC 2020 coding index (tools/prepare_soc2020_isco.py). Needs ISCO-08
-- (SELECT * FROM codesystem_install_isco_08();) and tools/load_soc.sql first. A pair means at least one job title of the ONS index is coded to both; see the script.
\set ON_ERROR_STOP on
CREATE TEMP TABLE pairs (from_code text, to_code text);

\copy pairs FROM 'data/prepared/uk_soc_2020_isco_08_pairs.csv' (FORMAT csv, HEADER)
-- the ONS's job-title coding leaves some ISCO-08 unit groups unused: that is how the data is, so allow_unmapped
SELECT define_crosswalk('uk_soc_2020', 'isco_08', 'SELECT * FROM pairs', allow_unmapped => true) AS unit_pairs_loaded;

TRUNCATE pairs;
\copy pairs FROM 'data/prepared/uk_soc_2020_extended_isco_08_pairs.csv' (FORMAT csv, HEADER)
SELECT define_crosswalk('uk_soc_2020_extended', 'isco_08', 'SELECT * FROM pairs', allow_unmapped => true) AS sub_unit_pairs_loaded;

SELECT * FROM code_crosswalks WHERE from_system LIKE 'uk_soc_2020%';
