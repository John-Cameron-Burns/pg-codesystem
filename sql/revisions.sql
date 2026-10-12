-- a changed list is a new revision; values written under the old one keep decoding
\set VERBOSITY terse
\set SHOW_CONTEXT never
DROP SCHEMA IF EXISTS t CASCADE;
DROP EXTENSION IF EXISTS codesystem;
CREATE EXTENSION codesystem;
CREATE SCHEMA t;
SET search_path = t, public;
CREATE TABLE stg (code text, level text, parent text, label text);
INSERT INTO stg VALUES ('A','l','','one'), ('AB','m','A','two'), ('B','l','','three'), ('BC','m','B','four');
\set levels '[{"name":"l","width":1,"charset":"[A-Z]","link":"none"},{"name":"m","width":2,"charset":"[A-Z]","link":"prefix"}]'
SELECT define_code_system('rv', :'levels', 'SELECT * FROM stg');

CREATE TABLE kept (c code('rv'));
INSERT INTO kept VALUES ('rv:BC');
INSERT INTO kept VALUES ('rv:AB');
SELECT c, code_revision(c) FROM kept ORDER BY c;

-- a code is added: A gets a second child, which shifts the rank of everything after it
INSERT INTO stg VALUES ('AC','m','A','five');
SELECT define_code_system('rv', :'levels', 'SELECT * FROM stg');
SELECT name, current_revision, ncodes, revisions FROM code_systems;
-- old values still mean what they meant, even though BC now has a different rank
SELECT c, code_revision(c), code_label(c) FROM kept ORDER BY c;
INSERT INTO kept VALUES ('rv:AC');
SELECT c, code_revision(c) FROM kept ORDER BY c;
-- values of different revisions of one system are all valid, and are the same code only if they are in the same revision
SELECT 'rv:BC'::code = c AS same_as_new FROM kept WHERE c::text = 'BC';
SELECT count(*) FROM kept WHERE c::text = 'BC';
SELECT code_children(code_ancestor('rv:AC', 'l'));

-- a code removed is a revision too, and a code that no longer exists cannot be entered
DELETE FROM stg WHERE code = 'AB';
SELECT define_code_system('rv', :'levels', 'SELECT * FROM stg');
INSERT INTO kept VALUES ('rv:AB');
SELECT c, code_revision(c), code_label(c) FROM kept ORDER BY c::text, code_revision(c);

-- the permanent rows
SELECT system_id, revision, count(*) FROM codesystem_code GROUP BY 1, 2 ORDER BY 2;
SELECT revision, ncodes FROM codesystem_revision ORDER BY revision;
DELETE FROM codesystem_revision WHERE revision = 1;
