-- pattern systems: identifiers with a syntax and no list (a company number), named parts, padding, and the guards
\set VERBOSITY terse
\set SHOW_CONTEXT never
DROP SCHEMA IF EXISTS t CASCADE;
DROP EXTENSION IF EXISTS codesystem;
CREATE EXTENSION codesystem;
CREATE SCHEMA t;
SET search_path = t, public;

SELECT define_code_system_pattern('crn', $$/\d{8}|(?<prefix>SC|NI|OC)(?<number>\d{6})/$$, 'number', 'Company number', 'Companies House');
SELECT name, kind, current_revision, ncodes, levels, pattern FROM code_systems;
-- the same codes, written another way, are not a new revision; a different pattern is
SELECT define_code_system_pattern('crn', $$/(?<prefix>SC|NI|OC)(?<number>\d{6})|\d{8}/$$, 'number');
SELECT define_code_system_pattern('crn', $$/\d{8}|(?<prefix>SC|NI|OC)(?<number>\d{6})/$$, 'number');

SELECT 'crn:SC123456'::code, 'crn:01234567'::code, 'crn:sc123456'::code;
SELECT 'crn:SX123456'::code;
SELECT 'crn:1234567'::code;
SELECT 'crn:SC12345'::code;
SELECT code_text('crn:SC123456'), code_level('crn:SC123456'), code_parent('crn:SC123456'), code_ancestor('crn:SC123456', 'number'), code_label('crn:SC123456');
SELECT count(*) FROM code_children('crn:SC123456');
-- named parts
SELECT code_part('crn:SC123456', 'prefix'), code_part('crn:SC123456', 'number'), code_part('crn:01234567', 'prefix'), code_part('crn:01234567', 'number');
SELECT code_parts('crn:SC123456'), code_parts('crn:01234567');
SELECT code_part('crn:SC123456', 'nosuch');

-- a column locked to the system, ordering, ranges
CREATE TABLE firms (name text, crn code('crn'));
INSERT INTO firms VALUES ('a', 'crn:SC000002');
INSERT INTO firms VALUES ('b', '00000123'::text);
INSERT INTO firms VALUES ('c', 'crn:NI000001');
INSERT INTO firms VALUES ('d', 'crn:12345678');
INSERT INTO firms VALUES ('e', 'crn:OC300001');
INSERT INTO firms VALUES ('f', 'crn:SC123456');
SELECT name, crn::text FROM firms ORDER BY crn;
-- digits sort before letters, as text does, and a prefix is one range
SELECT name FROM firms WHERE crn BETWEEN code_first_with_prefix('SC', 'crn') AND code_last_with_prefix('SC', 'crn') ORDER BY crn;
SELECT code_first_with_prefix('SC', 'crn'), code_last_with_prefix('SC', 'crn'), code_first_with_prefix('0', 'crn'), code_last_with_prefix('0', 'crn'), code_first_with_prefix('XX', 'crn');
SELECT code_first_with_prefix('SC', 'nosuch');
SELECT code_part(crn, 'prefix') AS prefix, count(*) FROM firms GROUP BY 1 ORDER BY 1 NULLS FIRST;
INSERT INTO firms VALUES ('bad', 'crn:XX000001');

-- padding what a spreadsheet stripped
SELECT code_from_padded('1234567', 'crn'), code_from_padded('123', 'crn'), code_from_padded('12345678', 'crn');
SELECT code_from_padded('SC123', 'crn');
SELECT code_from_padded('123456789', 'crn');
SELECT code_from_padded('1', 'nosuch');

-- the guards: a pattern whose parts are ambiguous, one that is not valid, one that is too big; a list is not a pattern
SELECT define_code_system_pattern('amb', $$/(?<a>\d{1,2})(?<b>\d{1,2})/$$);
SELECT define_code_system_pattern('bad1', $$/(\d{3}/$$);
SELECT define_code_system_pattern('bad2', $$/[A-Z0-9]{9}/$$);
SELECT define_code_system_pattern('Bad Name', $$/\d{3}/$$);
SELECT define_code_system_pattern('crn', $$/\d{3}/$$, 'Level 1');
SELECT count(*) FROM codesystem_system;
CREATE TABLE stg AS SELECT 'A' AS code, 'l' AS level, '' AS parent, 'x' AS label;
SELECT define_code_system('crn', '[{"name":"l","width":1,"charset":"[A-Z]","link":"none"}]', 'SELECT * FROM stg');
SELECT define_code_system('lst', '[{"name":"l","width":1,"charset":"[A-Z]","link":"none"}]', 'SELECT * FROM stg');
SELECT define_code_system_pattern('lst', $$/[A-Z]/$$);

-- a new pattern is a new revision; old values keep their meaning
SELECT define_code_system_pattern('crn', $$/\d{8}|(?<prefix>SC|NI|OC|SO)(?<number>\d{6})/$$, 'number');
SELECT name, current_revision, ncodes, revisions FROM code_systems WHERE name = 'crn';
SELECT crn::text, code_revision(crn), code_is_current(crn), code_current(crn)::text FROM firms WHERE name IN ('a', 'b') ORDER BY name;
SELECT 'crn:SO000001'::code;

-- parts of a template, and a flat system without parts
SELECT define_code_system_pattern('tmpl', 'AA-NNN');
SELECT 'tmpl:ab123'::code, code_part('tmpl:AB123', 'x');
