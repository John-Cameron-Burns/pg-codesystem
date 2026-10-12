-- levels, parents, ancestors, children, titles
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

SELECT c, code_level(c), code_parent(c), code_label(c) FROM (VALUES ('toy:A'::code), ('toy:01'), ('toy:011'), ('toy:0111')) v(c);
SELECT code_ancestor('toy:0111', 'class'), code_ancestor('toy:0111', 'group'), code_ancestor('toy:0111', 'division'), code_ancestor('toy:0111', 'section');
SELECT code_ancestor('toy:01', 'class');
SELECT code_ancestor('toy:01', 'nosuchlevel');
SELECT code_children('toy:A');
SELECT code_children('toy:011');
SELECT count(*) FROM code_children('toy:0111');
-- the division's section is a grouping, not a prefix
SELECT code_parent('toy:05'), code_parent('toy:0510');

CREATE TABLE firms (name text, activity code('toy'));
INSERT INTO firms VALUES ('a', 'toy:0111');
INSERT INTO firms VALUES ('b', 'toy:0112');
INSERT INTO firms VALUES ('c', 'toy:0121');
INSERT INTO firms VALUES ('d', 'toy:0510');
INSERT INTO firms VALUES ('e', 'toy:0210');
SELECT code_ancestor(activity, 'division') AS division, code_label(code_ancestor(activity, 'division')) AS title, count(*)
  FROM firms GROUP BY 1 ORDER BY 1;
SELECT code_ancestor(activity, 'section')::text AS section, count(*) FROM firms GROUP BY 1 ORDER BY 1;
