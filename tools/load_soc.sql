-- Loads UK SOC 2020 and its ONS extension (data/prepared/uk_soc_2020*.csv, from tools/prepare_soc.py).
\set ON_ERROR_STOP on
CREATE TEMP TABLE stg (code text, level text, parent text, label text);

\copy stg FROM 'data/prepared/uk_soc_2020.csv' (FORMAT csv, HEADER)
SELECT define_code_system('uk_soc_2020',
   '[{"name":"major",    "width":1,"charset":"[0-9]","link":"none",  "expected":9},
     {"name":"sub_major","width":2,"charset":"[0-9]","link":"prefix","expected":26},
     {"name":"minor",    "width":3,"charset":"[0-9]","link":"prefix","expected":104},
     {"name":"unit",     "width":4,"charset":"[0-9]","link":"prefix","expected":412}]',
   'SELECT * FROM stg', 'UK Standard Occupational Classification 2020', 'Office for National Statistics') AS uk_soc_2020_revision;

TRUNCATE stg;
\copy stg FROM 'data/prepared/uk_soc_2020_extended.csv' (FORMAT csv, HEADER)
-- the extension adds the sub-unit group (1111/01) to SOC 2020; the first four levels are SOC 2020 exactly
SELECT define_code_system('uk_soc_2020_extended',
   '[{"name":"major",    "width":1,"charset":"[0-9]",  "link":"none",  "expected":9},
     {"name":"sub_major","width":2,"charset":"[0-9]",  "link":"prefix","expected":26},
     {"name":"minor",    "width":3,"charset":"[0-9]",  "link":"prefix","expected":104},
     {"name":"unit",     "width":4,"charset":"[0-9]",  "link":"prefix","expected":412},
     {"name":"sub_unit", "width":7,"charset":"[0-9/]", "link":"prefix","expected":1384}]',
   'SELECT * FROM stg', 'Extended Standard Occupational Classification 2020 (ONS, version 7)', 'Office for National Statistics',
   refines => 'uk_soc_2020') AS uk_soc_2020_extended_revision;

SELECT name, current_revision, ncodes, levels FROM code_systems WHERE name LIKE 'uk_soc%';
