-- derived standards (refines), rollup, current revisions, crosswalks
\set VERBOSITY terse
\set SHOW_CONTEXT never
DROP SCHEMA IF EXISTS t CASCADE;
DROP EXTENSION IF EXISTS codesystem;
CREATE EXTENSION codesystem;
CREATE SCHEMA t;
SET search_path = t, public;

CREATE TABLE base_codes (code text, level text, parent text, label text);
INSERT INTO base_codes VALUES
 ('A','sec','','Agriculture'), ('B','sec','','Mining'),
 ('01','div','A','Crop'), ('02','div','A','Forestry'), ('05','div','B','Coal'),
 ('0111','cls','01','Cereals'), ('0112','cls','01','Rice'), ('0210','cls','02','Silviculture'), ('0510','cls','05','Hard coal');
\set base_levels '[{"name":"sec","width":1,"charset":"[A-Z]","link":"none"},{"name":"div","width":2,"charset":"[0-9]","link":"grouping"},{"name":"cls","width":4,"charset":"[0-9]","link":"prefix"}]'
\set uk_levels '[{"name":"sec","width":1,"charset":"[A-Z]","link":"none"},{"name":"div","width":2,"charset":"[0-9]","link":"grouping"},{"name":"cls","width":4,"charset":"[0-9]","link":"prefix"},{"name":"sub","width":5,"charset":"[0-9]","link":"prefix"}]'
SELECT define_code_system('base', :'base_levels', 'SELECT * FROM base_codes');

CREATE TABLE uk_codes AS SELECT * FROM base_codes;
INSERT INTO uk_codes VALUES ('01111','sub','0111','Wheat'), ('01112','sub','0111','Barley'), ('01120','sub','0112','Rice'),
                            ('02100','sub','0210','Silviculture'), ('05100','sub','0510','Hard coal');
SELECT define_code_system('uk', :'uk_levels', 'SELECT * FROM uk_codes', 'UK variant', 'Somebody', refines => 'base');
SELECT * FROM codesystem_derivation;
-- the same again changes nothing
SELECT define_code_system('uk', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'base');

-- a third level of variation: a local system refining uk
CREATE TABLE local_codes AS SELECT * FROM uk_codes;
INSERT INTO local_codes VALUES ('011111','tail','01111','Winter wheat'), ('011112','tail','01111','Spring wheat'), ('011121','tail','01112','Malting barley'),
                               ('011201','tail','01120','Paddy'), ('021001','tail','02100','Pine'), ('051001','tail','05100','Anthracite');
SELECT define_code_system('local', '[{"name":"sec","width":1,"charset":"[A-Z]","link":"none"},{"name":"div","width":2,"charset":"[0-9]","link":"grouping"},{"name":"cls","width":4,"charset":"[0-9]","link":"prefix"},{"name":"sub","width":5,"charset":"[0-9]","link":"prefix"},{"name":"tail","width":6,"charset":"[0-9]","link":"prefix"}]',
   'SELECT * FROM local_codes', refines => 'uk');

-- refusals
SELECT define_code_system('x', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'nosuch');
SELECT define_code_system('x', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'x');
SELECT define_code_system('x', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'base', shared_levels => 9);
-- a code missing from the shared levels, and one that is not the base's
CREATE TABLE short AS SELECT * FROM uk_codes WHERE code NOT IN ('0112', '01120');
SELECT define_code_system('x', :'uk_levels', 'SELECT * FROM short', refines => 'base');
CREATE TABLE extra AS SELECT * FROM uk_codes;
INSERT INTO extra VALUES ('03','div','A','Fishing'), ('0310','cls','03','Sea fishing'), ('03100','sub','0310','Sea');
SELECT define_code_system('x', :'uk_levels', 'SELECT * FROM extra', refines => 'base');
-- a level that differs
SELECT define_code_system('x', '[{"name":"sec","width":1,"charset":"[A-Z]","link":"none"},{"name":"div","width":2,"charset":"[0-9]","link":"grouping"},{"name":"class","width":4,"charset":"[0-9]","link":"prefix"}]',
   $$SELECT code, CASE level WHEN 'cls' THEN 'class' ELSE level END, parent, label FROM base_codes$$, refines => 'base');
SELECT count(*) FROM codesystem_system WHERE name = 'x';

-- rolling up
SELECT code_rollup('uk:01111', 'base'), code_rollup('uk:0111', 'base'), code_rollup('uk:A', 'base'), code_rollup('uk:01111', 'uk');
SELECT code_rollup('local:011111', 'uk'), code_rollup('local:011111', 'base'), code_rollup('local:0111', 'base');
SELECT code_rollup('base:0111', 'uk');
CREATE TABLE firms (name text, activity code('uk'));
INSERT INTO firms VALUES ('a', 'uk:01111'), ('b', 'uk:01112'), ('c', 'uk:01120'), ('d', 'uk:05100');
SELECT code_rollup(activity, 'base') AS base_class, count(*) FROM firms GROUP BY 1 ORDER BY 1;
SELECT code_rollup(code_ancestor(activity, 'div'), 'base') AS base_division, count(*) FROM firms GROUP BY 1 ORDER BY 1;

-- revisions: a new revision of uk compares equal to the old one after code_current()
INSERT INTO uk_codes VALUES ('01113','sub','0111','Oats');
SELECT define_code_system('uk', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'base');
SELECT code_revision(activity), code_is_current(activity), code_current(activity) = 'uk:01120' AS same_after_current FROM firms WHERE name = 'c';
SELECT activity = 'uk:01120' AS plain_equal, code_current(activity) = 'uk:01120' AS current_equal FROM firms WHERE name = 'c';
SELECT code_is_current('uk:01113'), code_is_current(activity) FROM firms WHERE name = 'a';
DELETE FROM uk_codes WHERE code = '01112';
SELECT define_code_system('uk', :'uk_levels', 'SELECT * FROM uk_codes', refines => 'base');
SELECT name, code_current(activity) FROM firms WHERE name = 'b';
SELECT revision, base_revision, shared_levels FROM codesystem_derivation d JOIN codesystem_system s ON s.id = d.system_id WHERE s.name = 'uk' ORDER BY revision;
DELETE FROM codesystem_derivation;

-- crosswalks: an old numbering and a new one
CREATE TABLE old_codes (code text, level text, parent text, label text);
INSERT INTO old_codes VALUES ('A','grp','',''), ('A1','item','A',''), ('A2','item','A',''), ('B1','item','B','') , ('B','grp','','');
SELECT define_code_system('old', '[{"name":"grp","width":1,"charset":"[A-Z]","link":"none"},{"name":"item","width":2,"charset":"[A-Z0-9]","link":"prefix"}]', 'SELECT * FROM old_codes');
-- the query must name its columns
SELECT define_crosswalk('old', 'base', $$VALUES ('A1','0111'), ('A2','0111'), ('A2','0112')$$);
SELECT define_crosswalk('old', 'nosuch', $$SELECT 'A1' AS from_code, '0111' AS to_code$$);
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('Z9','0111')) v(from_code, to_code)$$);
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('A1','9999')) v(from_code, to_code)$$);
SELECT define_crosswalk('old', 'base', $$SELECT 1$$);
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('A2','0111'), ('A2','0112'), ('B1','0210'), ('B1','0510')) v(from_code, to_code)$$);
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('A2','0111'), ('A2','0112'), ('B1','0210')) v(from_code, to_code)$$, allow_unmapped => true);
SELECT * FROM code_crosswalks;
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('A2','0111'), ('A2','0112'), ('B1','0210'), ('B1','0510')) v(from_code, to_code)$$, true);
SELECT * FROM code_crosswalks;
SELECT code_map('old:A2', 'base'), code_map('old:B1', 'base');
SELECT code_map('base:0111', 'old');
SELECT code_map('base:0112', 'old'), code_map_unique('base:0112', 'old'), code_map_unique('base:0111', 'old'), code_map_unique('base:0510', 'old');
SELECT code_map('old:A', 'base');
-- redefining replaces
SELECT define_crosswalk('old', 'base', $$SELECT * FROM (VALUES ('A1','0111'), ('A2','0112'), ('B1','0210'), ('B1','0510')) v(from_code, to_code)$$, true);
SELECT * FROM code_crosswalks;
SELECT count(*) FROM codesystem_crosswalk;
