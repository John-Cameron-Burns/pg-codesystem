-- the code type: input, output, the column lock, comparison, binary I/O
\set VERBOSITY terse
\set SHOW_CONTEXT never
DROP SCHEMA IF EXISTS t CASCADE;
DROP EXTENSION IF EXISTS codesystem;
CREATE EXTENSION codesystem;
CREATE SCHEMA t;
SET search_path = t, public;
CREATE TABLE stg (code text, level text, parent text, label text);
INSERT INTO stg VALUES
 ('A','section','','Agriculture'), ('B','section','','Mining'),
 ('01','division','A','Crop'), ('02','division','A','Forestry'), ('05','division','B','Coal'),
 ('011','group','01','Annual crops'), ('012','group','01','Perennial crops'), ('021','group','02','Silviculture'), ('051','group','05','Hard coal'),
 ('0111','class','011','Cereals'), ('0112','class','011','Rice'), ('0121','class','012','Grapes'), ('0210','class','021','Silviculture'), ('0510','class','051','Hard coal');
SELECT define_code_system('toy', '[{"name":"section","width":1,"charset":"[A-Z]","link":"none"},{"name":"division","width":2,"charset":"[0-9]","link":"grouping"},{"name":"group","width":3,"charset":"[0-9]","link":"prefix"},{"name":"class","width":4,"charset":"[0-9]","link":"prefix"}]', 'SELECT * FROM stg');
SELECT define_code_system('mini', '[{"name":"all","width":2,"charset":"[A-Z]","link":"none"}]', $$SELECT * FROM (VALUES ('AB','all','','x'),('CD','all','','y')) v(code, level, parent, label)$$);

SELECT 'toy:0111'::code, 'toy:a'::code, 'toy:0111'::code::text, code_text('toy:0111'), code_from('0111', 'toy');
SELECT 'toy:9999'::code;
SELECT '0111'::code;
SELECT 'nosuch:01'::code;
SELECT code_from('0111', 'nosuch');
SELECT code_from('toy:0111', 'mini');
SELECT code_is_valid('0111', 'toy'), code_is_valid('9999', 'toy'), code_is_valid(NULL, 'toy'), code_is_valid('AB', 'mini');
SELECT code_is_valid('x', 'nosuch');

-- a column locked to a system
CREATE TABLE firms (name text, activity code('toy'));
\d firms
-- a bare literal cannot know its column (PostgreSQL gives a literal's input function no type modifier), so SQL text qualifies it;
-- a bare code is read from text: COPY, a text column, or a cast
INSERT INTO firms VALUES ('plain', '0111');
INSERT INTO firms VALUES ('qualified', 'toy:0121');
INSERT INTO firms VALUES ('from text', '0510'::text);
INSERT INTO firms VALUES ('cast from text', '0210'::text::code('toy'));
INSERT INTO firms SELECT 'from a column', c FROM (VALUES ('0112'::text)) v(c);
INSERT INTO firms VALUES ('bad code', 'toy:9999');
INSERT INTO firms VALUES ('bad bare code', '9999'::text);
INSERT INTO firms VALUES ('other system', 'mini:AB');
INSERT INTO firms VALUES ('wrong system named', 'mini:0111');
SELECT name, activity, activity::text AS bare, code_system(activity) FROM firms ORDER BY activity;
COPY firms FROM stdin;
copied	0210
\.
SELECT count(*) FROM firms;
INSERT INTO firms VALUES ('a', 'toy:0112'), ('b', 'toy:0112');
SELECT code_system(activity), count(*) FROM firms GROUP BY 1;

-- a column of any system
CREATE TABLE anything (c code);
INSERT INTO anything VALUES ('toy:0111'), ('mini:CD'), ('toy:A');
SELECT c FROM anything ORDER BY c;
SELECT min(c), max(c) FROM anything;
INSERT INTO anything VALUES ('0111');

-- comparison, ordering and indexes: a coarser code sorts just before the finer ones
SELECT 'toy:01'::code < 'toy:011'::code AND 'toy:011'::code < 'toy:0111'::code AND 'toy:0112'::code < 'toy:012'::code AS nested_order;
SELECT array_agg(c ORDER BY c)::text FROM (SELECT code_children('toy:A') c UNION ALL SELECT 'toy:A') s;
CREATE INDEX ON firms (activity);
SET enable_seqscan = off;
SELECT name FROM firms WHERE activity = 'toy:0121';
SELECT count(*) FROM firms WHERE activity >= 'toy:0111' AND activity < 'toy:0210';
RESET enable_seqscan;
SELECT count(DISTINCT activity) FROM firms;
SELECT count(*) FROM firms a JOIN firms b USING (activity);

-- the binary form
COPY (SELECT activity FROM firms ORDER BY activity) TO '/tmp/cs_codes.bin' (FORMAT binary);
CREATE TABLE back (activity code('toy'));
COPY back FROM '/tmp/cs_codes.bin' (FORMAT binary);
SELECT count(*), count(*) FILTER (WHERE activity IS NOT NULL) FROM back;
CREATE TABLE wrongback (activity code('mini'));
COPY wrongback FROM '/tmp/cs_codes.bin' (FORMAT binary);

-- type modifiers
SELECT code_name_hash('toy') = (SELECT name_hash FROM codesystem_system WHERE name = 'toy') AS hash_matches;
CREATE TABLE badmod (c code('Not A Name'));
CREATE TABLE badmod2 (c code('a', 'b'));
SELECT 'toy:0111'::code::code('mini');
SELECT 'toy:0111'::code::code('toy');
SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'firms'::regclass AND attname = 'activity';
-- a column whose system is not defined here (as in a restore before the registry is loaded) can be declared, and fails loudly on use
CREATE TABLE later (c code('not_yet'));
INSERT INTO later VALUES ('not_yet:AB');
SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'later'::regclass AND attname = 'c';

-- the list checker
SELECT code_list_check(ARRAY['A','AB','B']);
SELECT code_list_check(ARRAY['B','A']);
SELECT code_list_check(ARRAY['A','A']);
SELECT code_list_check(ARRAY['a']);
SELECT code_list_check('{}'::text[]);
