-- defining a code system: what is accepted, and every way a definition is refused
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
\set levels '[{"name":"section","width":1,"charset":"[A-Z]","link":"none","expected":2},{"name":"division","width":2,"charset":"[0-9]","link":"grouping","expected":3},{"name":"group","width":3,"charset":"[0-9]","link":"prefix","expected":4},{"name":"class","width":4,"charset":"[0-9]","link":"prefix","expected":5}]'

SELECT define_code_system('toy', :'levels', 'SELECT * FROM stg', 'Toy classification', 'Nobody');
SELECT name, title, publisher, current_revision, ncodes, levels, revisions FROM code_systems;
-- the same codes again change nothing
SELECT define_code_system('toy', :'levels', 'SELECT * FROM stg');
SELECT count(*) FROM codesystem_revision;

-- refusals
SELECT define_code_system('Bad Name', :'levels', 'SELECT * FROM stg');
SELECT define_code_system('x', '[]', 'SELECT * FROM stg');
SELECT define_code_system('x', '[{"name":"a","width":1,"charset":"[A-Z]","link":"prefix"}]', 'SELECT * FROM stg');
SELECT define_code_system('x', '[{"name":"a","width":1,"charset":"A-Z","link":"none"}]', 'SELECT * FROM stg');
SELECT define_code_system('x', '[{"name":"a","width":1,"charset":"[A-Z]","link":"none"},{"name":"b","width":1,"charset":"[0-9]","link":"prefix"}]', 'SELECT * FROM stg');
SELECT define_code_system('x', '[{"name":"a","width":1,"charset":"[A-Z]","link":"none"},{"name":"a","width":2,"charset":"[0-9]","link":"prefix"}]', 'SELECT * FROM stg');
SELECT define_code_system('x', :'levels', 'SELECT code FROM stg');
SELECT define_code_system('x', :'levels', 'SELECT * FROM stg WHERE false');

-- a mistake in the data: each is reported, with an example
CREATE TABLE bad AS SELECT * FROM stg;
INSERT INTO bad VALUES ('0111','class','011','Again'), ('Z9','division','A','Wrong characters'), ('03','division','Q','Orphan'),
                       ('0301','class','03','Not the prefix'), ('07','nonsense','A','No such level'), ('C','section','A','Top with parent');
SELECT define_code_system('x', :'levels', 'SELECT * FROM bad');
-- a code with no children, and a count that is not the publisher's
CREATE TABLE childless AS SELECT * FROM stg WHERE code <> '0510';
SELECT define_code_system('x', :'levels', 'SELECT * FROM childless');
SELECT count(*) FROM codesystem_system WHERE name = 'x';

-- the registry rows cannot be altered, apart from the titles
UPDATE codesystem_code SET code = '9999' WHERE code = '0111';
DELETE FROM codesystem_code;
TRUNCATE codesystem_level;
UPDATE codesystem_code SET label = 'Wheat and other cereals' WHERE code = '0111';
UPDATE codesystem_system SET publisher = 'Somebody';
SELECT code_label('toy:0111'), publisher FROM codesystem_system, (SELECT 1) x;
