-- ONS GSS (Government Statistical Service) geography codes, as two systems:
--
--    gss          a pattern system: any code of the form E01000001, a country letter, a 2-digit entity type and a
--                 6-digit number. It checks the shape and gives the parts (country, type, area) and prefix ranges;
--                 it does not know which area numbers exist.
--    gss_entity   a list system: the entity types of the ONS Register of Geographic Codes (E01 Lower layer Super Output
--                 Areas, E06 Unitary Authorities, ...), with their names. Types that ONS has archived are included, because
--                 old data still uses them. Loaded from data/prepared/gss_entity_types.csv.
--                 tools/gss_update.sql brings it up to the latest edition of the Register.
--
-- To name an entity type from a gss code:
--
--    SELECT code_label(code_from(code_part(g, 'country') || code_part(g, 'type'), 'gss_entity')) FROM ...
\set ON_ERROR_STOP on
CREATE TEMP TABLE stg (code text, level text, parent text, label text);

SELECT define_code_system_pattern('gss',
   '/(?<country>[EJKLMNSW])(?<type>\d{2})(?<area>\d{6})/',
   'area', 'ONS GSS geography code', 'Office for National Statistics') AS gss_revision;

\copy stg FROM 'data/prepared/gss_entity_types.csv' (FORMAT csv, HEADER)
SELECT define_code_system('gss_entity',
   '[{"name":"entity","width":3,"charset":"[A-Z0-9]","link":"none"}]',
   'SELECT * FROM stg', 'ONS GSS entity types (Register of Geographic Codes)', 'Office for National Statistics') AS gss_entity_revision;

SELECT name, kind, ncodes, levels FROM code_systems WHERE name IN ('gss', 'gss_entity');
