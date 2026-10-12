-- SOC 2010 (flat: the unit groups that appear in the ONS correspondence) and its crosswalk to ISCO-08.
-- Needs ISCO-08 first: SELECT * FROM codesystem_install_isco_08(); Files from tools/prepare_soc2010.py. This is SOC 2010, not SOC 2020.
\set ON_ERROR_STOP on
CREATE TEMP TABLE stg (code text, level text, parent text, label text);
\copy stg FROM 'data/prepared/uk_soc_2010.csv' (FORMAT csv, HEADER)
SELECT define_code_system('uk_soc_2010', '[{"name":"unit","width":4,"charset":"[0-9]","link":"none","expected":369}]',
   'SELECT * FROM stg', 'UK Standard Occupational Classification 2010 (unit groups only)', 'Office for National Statistics') AS uk_soc_2010_revision;

CREATE TEMP TABLE pairs (from_code text, to_code text);
\copy pairs FROM 'data/prepared/uk_soc_2010_isco_08_pairs.csv' (FORMAT csv, HEADER)
-- the ONS file itself lists 145 ISCO-08 unit groups with no SOC 2010 counterpart: that is how the publisher states it
SELECT define_crosswalk('uk_soc_2010', 'isco_08', 'SELECT * FROM pairs', allow_unmapped => true) AS pairs_loaded;
SELECT * FROM code_crosswalks WHERE from_system = 'uk_soc_2010';
