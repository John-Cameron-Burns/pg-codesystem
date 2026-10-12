-- Needs tools/load_nace.sql first (UK SIC 2007 refines NACE Rev.2).
-- Loads UK SIC 2007, UK SIC 2003 and the ONS crosswalk between them, from data/prepared/uk_sic_*.csv, which come with the package.
\set ON_ERROR_STOP on
CREATE TEMP TABLE stg (code text, level text, parent text, label text);

\copy stg FROM 'data/prepared/uk_sic_2007.csv' (FORMAT csv, HEADER)
SELECT define_code_system('uk_sic_2007',
   '[{"name":"section", "width":1,"charset":"[A-Z]","link":"none",    "expected":21},
     {"name":"division","width":2,"charset":"[0-9]","link":"grouping","expected":88},
     {"name":"group",   "width":3,"charset":"[0-9]","link":"prefix",  "expected":272},
     {"name":"class",   "width":4,"charset":"[0-9]","link":"prefix",  "expected":615},
     {"name":"subclass","width":5,"charset":"[0-9]","link":"prefix",  "expected":728}]',
   'SELECT * FROM stg', 'UK Standard Industrial Classification of Economic Activities 2007', 'Office for National Statistics',
   refines => 'nace_rev2') AS uk_sic_2007_revision;

TRUNCATE stg;
\copy stg FROM 'data/prepared/uk_sic_2003.csv' (FORMAT csv, HEADER)
SELECT define_code_system('uk_sic_2003', '[{"name":"code","width":5,"charset":"[0-9]","link":"none"}]',
   'SELECT * FROM stg', 'UK Standard Industrial Classification of Economic Activities 2003 (5-digit codes only)', 'Office for National Statistics') AS uk_sic_2003_revision;

CREATE TEMP TABLE pairs (from_code text, to_code text);
\copy pairs FROM 'data/prepared/uk_sic_2003_2007_pairs.csv' (FORMAT csv, HEADER)
SELECT define_crosswalk('uk_sic_2003', 'uk_sic_2007', 'SELECT * FROM pairs') AS pairs_loaded;
SELECT * FROM code_crosswalks;
