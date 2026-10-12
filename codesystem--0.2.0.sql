-- codesystem 0.1.0
--
-- A code system is a named, versioned set of codes with a hierarchy: SIC, SOC, ISIC, NACE, ISCO, NUTS, GSS, ICD, HS ...
-- It is defined once, in one call, and the whole definition is checked:
--
--   SELECT define_code_system('isic_rev4',
--      '[{"name":"section", "width":1, "charset":"[A-Z]", "link":"none",     "expected":21},
--        {"name":"division","width":2, "charset":"[0-9]", "link":"grouping", "expected":88},
--        {"name":"group",   "width":3, "charset":"[0-9]", "link":"prefix",   "expected":238},
--        {"name":"class",   "width":4, "charset":"[0-9]", "link":"prefix",   "expected":419}]',
--      'SELECT code, level, parent, label FROM isic_staging',
--      'ISIC Rev.4', 'United Nations Statistics Division');
--
-- and then used as a type, locked to a system if you like:
--
--   CREATE TABLE firms (name text, activity code('isic_rev4'));
--   INSERT INTO firms VALUES ('Acme', 'isic_rev4:4711');  -- a class of isic_rev4; anything else is refused
--   COPY firms FROM 'firms.csv' (FORMAT csv);             -- a bare 4711 is fine from text: the column says which system
--   SELECT code_ancestor(activity, 'division'), count(*) FROM firms GROUP BY 1;

-- ---- the registry -----------------------------------------------------------------------------------------------
-- Four tables, all included in pg_dump (they are the definitions, and stored values are decoded with them). There are no foreign
-- keys between them, because a restore may load them in any order.

CREATE TABLE codesystem_system (
   id         smallint PRIMARY KEY CHECK (id BETWEEN 1 AND 32767),
   name       text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9_]{0,62}$'),
   name_hash  integer NOT NULL UNIQUE,
   title      text,
   publisher  text,
   created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE codesystem_system IS
   'The code systems. name_hash is what a column''s type modifier code(''name'') holds: a hash of the name, so a restore can create the column before this table has been loaded. Use define_code_system(), not INSERT.';

CREATE TABLE codesystem_revision (
   system_id  smallint NOT NULL,
   revision   smallint NOT NULL CHECK (revision BETWEEN 1 AND 255),
   ncodes     bigint NOT NULL,
   created_at timestamptz NOT NULL DEFAULT now(),
   PRIMARY KEY (system_id, revision)
);
COMMENT ON TABLE codesystem_revision IS
   'Every revision of every code system. A code is stored as its rank among the codes of one revision, so the codes of a revision never change; a changed list is the next revision, and a stored value keeps decoding with the revision it was written under.';

CREATE TABLE codesystem_level (
   system_id  smallint NOT NULL,
   revision   smallint NOT NULL,
   ord        smallint NOT NULL,
   name       text NOT NULL,
   width      smallint NOT NULL,
   charset    text NOT NULL,
   link       text NOT NULL CHECK (link IN ('none', 'prefix', 'grouping')),
   expected   bigint,
   PRIMARY KEY (system_id, revision, ord)
);
COMMENT ON TABLE codesystem_level IS
   'The levels of a revision, top first. link says how a code finds its parent: none (the top level), prefix (the parent is the code''s first characters) or grouping (the parent is stated, as ISIC''s section is for a division).';

CREATE TABLE codesystem_code (
   system_id  smallint NOT NULL,
   revision   smallint NOT NULL,
   code       text COLLATE "C" NOT NULL,
   level      text NOT NULL,
   parent     text COLLATE "C" NOT NULL,
   label      text,
   PRIMARY KEY (system_id, revision, code)
);
COMMENT ON TABLE codesystem_code IS
   'The codes of every revision, with the level each is at, its parent ('''' at the top) and the publisher''s title. Only the title can be changed afterwards.';

SELECT pg_extension_config_dump('codesystem_system', '');
SELECT pg_extension_config_dump('codesystem_revision', '');
SELECT pg_extension_config_dump('codesystem_level', '');
SELECT pg_extension_config_dump('codesystem_code', '');

-- A derived standard (UK SIC 2007 from NACE Rev.2, which is ISIC Rev.4 with a few more details): one revision of one system
-- refines one revision of another, and shares its first shared_levels levels exactly. Checked when it is defined.
CREATE TABLE codesystem_derivation (
   system_id      smallint NOT NULL,
   revision       smallint NOT NULL,
   base_system_id smallint NOT NULL,
   base_revision  smallint NOT NULL,
   shared_levels  smallint NOT NULL CHECK (shared_levels >= 1),
   PRIMARY KEY (system_id, revision)
);
COMMENT ON TABLE codesystem_derivation IS
   'Which system a revision refines, and how many of its top levels are exactly the base system''s. Permanent: code_rollup() follows it.';
SELECT pg_extension_config_dump('codesystem_derivation', '');

-- Systems that merely correspond (SIC 2003 and SIC 2007) are tied by a crosswalk: pairs of codes. Nothing is stored in values that
-- depends on it, so a crosswalk can be replaced by defining it again.
CREATE TABLE codesystem_crosswalk (
   from_system_id smallint NOT NULL,
   to_system_id   smallint NOT NULL,
   from_code      text COLLATE "C" NOT NULL,
   to_code        text COLLATE "C" NOT NULL,
   PRIMARY KEY (from_system_id, to_system_id, from_code, to_code)
);
COMMENT ON TABLE codesystem_crosswalk IS 'Pairs of corresponding codes of two systems. Use define_crosswalk(), not INSERT.';
SELECT pg_extension_config_dump('codesystem_crosswalk', '');

-- what is defined cannot be changed, only added to: a stored value is a rank in a list that must not move
CREATE FUNCTION codesystem_permanent()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
BEGIN
   IF TG_OP = 'UPDATE' THEN
      IF TG_TABLE_NAME = 'codesystem_code' THEN
         -- the title (label) is only a title
         IF NEW.system_id = OLD.system_id AND NEW.revision = OLD.revision AND NEW.code = OLD.code
            AND NEW.level = OLD.level AND NEW.parent = OLD.parent THEN
            RETURN NEW;
         END IF;
      ELSIF TG_TABLE_NAME = 'codesystem_system' THEN
         -- as are the title and publisher of a system
         IF NEW.id = OLD.id AND NEW.name = OLD.name AND NEW.name_hash = OLD.name_hash THEN
            RETURN NEW;
         END IF;
      END IF;
   END IF;
   RAISE EXCEPTION '% rows are permanent: stored codes are decoded with them', TG_TABLE_NAME
      USING HINT = 'to change a code system, call define_code_system() again with the new list: it becomes the next revision';
END;
$$;
CREATE TRIGGER codesystem_system_permanent BEFORE UPDATE OR DELETE ON codesystem_system
   FOR EACH ROW EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_revision_permanent BEFORE UPDATE OR DELETE ON codesystem_revision
   FOR EACH ROW EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_level_permanent BEFORE UPDATE OR DELETE ON codesystem_level
   FOR EACH ROW EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_code_permanent BEFORE UPDATE OR DELETE ON codesystem_code
   FOR EACH ROW EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_system_permanent_truncate BEFORE TRUNCATE ON codesystem_system
   FOR EACH STATEMENT EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_revision_permanent_truncate BEFORE TRUNCATE ON codesystem_revision
   FOR EACH STATEMENT EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_level_permanent_truncate BEFORE TRUNCATE ON codesystem_level
   FOR EACH STATEMENT EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_code_permanent_truncate BEFORE TRUNCATE ON codesystem_code
   FOR EACH STATEMENT EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_derivation_permanent BEFORE UPDATE OR DELETE ON codesystem_derivation
   FOR EACH ROW EXECUTE FUNCTION codesystem_permanent();
CREATE TRIGGER codesystem_derivation_permanent_truncate BEFORE TRUNCATE ON codesystem_derivation
   FOR EACH STATEMENT EXECUTE FUNCTION codesystem_permanent();

-- a definition added in a transaction that rolls back must not linger in other sessions' caches
CREATE FUNCTION code_registry_changed()
   RETURNS trigger
   AS 'MODULE_PATHNAME'
   LANGUAGE C;
CREATE TRIGGER codesystem_system_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON codesystem_system
   FOR EACH STATEMENT EXECUTE FUNCTION code_registry_changed();
CREATE TRIGGER codesystem_revision_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON codesystem_revision
   FOR EACH STATEMENT EXECUTE FUNCTION code_registry_changed();
CREATE TRIGGER codesystem_level_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON codesystem_level
   FOR EACH STATEMENT EXECUTE FUNCTION code_registry_changed();
CREATE TRIGGER codesystem_code_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON codesystem_code
   FOR EACH STATEMENT EXECUTE FUNCTION code_registry_changed();

-- ---- the type -------------------------------------------------------------------------------------------------------
-- 63 bits: system (15) | revision (8) | rank (40). The top bit is clear, so it compares and sorts as a signed integer. Written
-- "system:code", or just "code" where the column is declared code('system'). Fixed length and passed by value.
CREATE TYPE code;

CREATE FUNCTION code_in(cstring, oid, integer)
   RETURNS code
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION code_out(code)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION code_recv(internal, oid, integer)
   RETURNS code
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION code_send(code)
   RETURNS bytea
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION code_typmod_in(cstring[])
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION code_typmod_out(integer)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

CREATE TYPE code (
   INPUT      = code_in,
   OUTPUT     = code_out,
   RECEIVE    = code_recv,
   SEND       = code_send,
   TYPMOD_IN  = code_typmod_in,
   TYPMOD_OUT = code_typmod_out,
   LIKE       = pg_catalog.int8,
   CATEGORY   = 'S'
);
COMMENT ON TYPE code IS
   'A code of a code system, validated against its list: ''isic_rev4:4711''. Declare a column code(''isic_rev4'') to lock it to one system; COPY and text values then take the bare code.';

-- the lock: a column declared code('isic_rev4') accepts only that system's codes, on INSERT, UPDATE, COPY and ::code('isic_rev4')
CREATE FUNCTION code_enforce(code, integer, boolean)
   RETURNS code
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;
CREATE CAST (code AS code) WITH FUNCTION code_enforce(code, integer, boolean) AS IMPLICIT;

CREATE FUNCTION code_cmp(code, code) RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_eq(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_ne(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_lt(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_gt(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_le(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_ge(code, code)  RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_hash(code)      RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;

CREATE OPERATOR = (PROCEDURE = code_eq, LEFTARG = code, RIGHTARG = code, COMMUTATOR = =, NEGATOR = <>,
                   RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES);
CREATE OPERATOR <> (PROCEDURE = code_ne, LEFTARG = code, RIGHTARG = code, COMMUTATOR = <>, NEGATOR = =,
                    RESTRICT = neqsel, JOIN = neqjoinsel);
-- the standard estimators, as for int4 and text: without them the planner cannot use column statistics for a range predicate
CREATE OPERATOR <  (PROCEDURE = code_lt, LEFTARG = code, RIGHTARG = code, COMMUTATOR = >,  NEGATOR = >=,
                    RESTRICT = scalarltsel, JOIN = scalarltjoinsel);
CREATE OPERATOR >  (PROCEDURE = code_gt, LEFTARG = code, RIGHTARG = code, COMMUTATOR = <,  NEGATOR = <=,
                    RESTRICT = scalargtsel, JOIN = scalargtjoinsel);
CREATE OPERATOR <= (PROCEDURE = code_le, LEFTARG = code, RIGHTARG = code, COMMUTATOR = >=, NEGATOR = >,
                    RESTRICT = scalarlesel, JOIN = scalarlejoinsel);
CREATE OPERATOR >= (PROCEDURE = code_ge, LEFTARG = code, RIGHTARG = code, COMMUTATOR = <=, NEGATOR = <,
                    RESTRICT = scalargesel, JOIN = scalargejoinsel);

CREATE FUNCTION code_smaller(code, code) RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_larger(code, code)  RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE AGGREGATE min(code) (SFUNC = code_smaller, STYPE = code, SORTOP = <, PARALLEL = SAFE, COMBINEFUNC = code_smaller);
CREATE AGGREGATE max(code) (SFUNC = code_larger,  STYPE = code, SORTOP = >, PARALLEL = SAFE, COMBINEFUNC = code_larger);

CREATE OPERATOR CLASS code_ops DEFAULT FOR TYPE code USING btree AS
   OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >, FUNCTION 1 code_cmp(code, code);
CREATE OPERATOR CLASS code_hash_ops DEFAULT FOR TYPE code USING hash AS
   OPERATOR 1 =, FUNCTION 1 code_hash(code);

-- ---- reading a code ---------------------------------------------------------------------------------------------------
CREATE FUNCTION code_text(code) RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION code_text(code) IS
   'The code without its system: code_text(''isic_rev4:4711''::code) is ''4711''. This is also what ::text gives.';
-- not IMPLICIT: an implicit cast would make min(code) and sum-like aggregates quietly resolve to the text versions, and lose the type
CREATE CAST (code AS text) WITH FUNCTION code_text(code) AS ASSIGNMENT;

CREATE FUNCTION code_cast_text(text, integer, boolean) RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE CAST (text AS code) WITH FUNCTION code_cast_text(text, integer, boolean) AS ASSIGNMENT;

CREATE FUNCTION code_from(text, text) RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION code_from(text, text) IS
   'code_from(''4711'', ''isic_rev4''): the code of a system, from the bare code and the name of the system. An error if it is not a code of that system.';

CREATE FUNCTION code_is_valid(text, text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C STABLE;
COMMENT ON FUNCTION code_is_valid(text, text) IS
   'Whether a bare code is a code of the named system: code_is_valid(''4711'', ''isic_rev4''). False for NULL or an unknown code, an error for an unknown system.';

CREATE FUNCTION code_system(code)   RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_revision(code) RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_level(code)    RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_parent(code)   RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_ancestor(code, text) RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_children(code) RETURNS SETOF code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT ROWS 10;
CREATE FUNCTION code_label(code)    RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION code_system(code)   IS 'The name of the code''s system.';
COMMENT ON FUNCTION code_revision(code) IS 'The revision of its system the code was written under.';
COMMENT ON FUNCTION code_level(code)    IS 'The name of the level the code is at: code_level(''isic_rev4:4711'') is ''class''.';
COMMENT ON FUNCTION code_parent(code)   IS 'The code one level up, or NULL at the top level.';
COMMENT ON FUNCTION code_ancestor(code, text) IS
   'The code''s ancestor at the named level, or the code itself if it is at that level; NULL if the level is below the code or no ancestor is at it. The way to group by a coarser level: code_ancestor(activity, ''division'').';
COMMENT ON FUNCTION code_children(code) IS 'The codes one level below this one.';
COMMENT ON FUNCTION code_label(code)    IS 'The publisher''s title of the code.';

CREATE FUNCTION code_name_hash(text) RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_list_check(text[]) RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION code_name_hash(text) IS 'The type modifier of code(''name''): a hash of the name.';
COMMENT ON FUNCTION code_list_check(text[]) IS
   'Checks a list of codes sorted in byte order and returns the number of states of its automaton. An error says where the list goes wrong.';

CREATE VIEW code_systems AS
   SELECT s.name, s.title, s.publisher, r.revision AS current_revision, r.ncodes,
          (SELECT string_agg(l.name || ' (' || l.width || ')', ' > ' ORDER BY l.ord)
             FROM codesystem_level l WHERE l.system_id = s.id AND l.revision = r.revision) AS levels,
          (SELECT count(*) FROM codesystem_revision x WHERE x.system_id = s.id) AS revisions
   FROM codesystem_system s
   LEFT JOIN LATERAL (SELECT * FROM codesystem_revision r WHERE r.system_id = s.id ORDER BY r.revision DESC LIMIT 1) r ON true
   ORDER BY s.name;
COMMENT ON VIEW code_systems IS 'The code systems defined here, their current revision and their levels.';

-- ---- defining a code system -------------------------------------------------------------------------------------------
CREATE FUNCTION define_code_system(sys_name text, levels jsonb, codes_query text, title text DEFAULT NULL, publisher text DEFAULT NULL,
                                refines text DEFAULT NULL, shared_levels integer DEFAULT NULL)
   RETURNS integer
   LANGUAGE plpgsql AS $$
DECLARE
   problems text[] := '{}';
   n        bigint;
   ex       text;
   sysid    integer;
   cur      integer;
   rev      integer;
   same     boolean;
   sorted   text[];
   lv       jsonb;
   i        integer;
   bsys     integer;
   brev     integer;
   nshared  integer;
   nbase    integer;
   nderiv   integer;
BEGIN
   IF sys_name IS NULL OR sys_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
      RAISE EXCEPTION 'a code system name is lower case letters, digits and _, starting with a letter, at most 63 characters; got %', sys_name;
   END IF;
   IF levels IS NULL OR jsonb_typeof(levels) <> 'array' OR jsonb_array_length(levels) NOT BETWEEN 1 AND 8 THEN
      RAISE EXCEPTION 'levels must be a JSON array of 1 to 8 levels, each {"name", "width", "charset", "link"[, "expected"]}';
   END IF;

   -- ---- the levels
   IF to_regclass('pg_temp.cs_levels') IS NOT NULL THEN DROP TABLE pg_temp.cs_levels; END IF;
   IF to_regclass('pg_temp.cs_stage') IS NOT NULL THEN DROP TABLE pg_temp.cs_stage; END IF;
   CREATE TEMP TABLE cs_levels (ord smallint, name text, width integer, charset text, link text, expected bigint) ON COMMIT DROP;
   FOR i IN 1 .. jsonb_array_length(levels) LOOP
      lv := levels -> (i - 1);
      IF jsonb_typeof(lv) <> 'object' OR NOT (lv ? 'name' AND lv ? 'width' AND lv ? 'charset' AND lv ? 'link') THEN
         RAISE EXCEPTION 'level %: needs "name", "width", "charset" and "link"', i;
      END IF;
      INSERT INTO cs_levels VALUES (i, lv ->> 'name', (lv ->> 'width')::integer, lv ->> 'charset', lv ->> 'link', (lv ->> 'expected')::bigint);
   END LOOP;
   FOR ex IN SELECT format('level %s (%s): %s', c.ord, c.name, c.why) FROM (
      SELECT ord, name, CASE
         WHEN name !~ '^[a-z][a-z0-9_]{0,62}$' THEN 'a level name is lower case letters, digits and _'
         WHEN width NOT BETWEEN 1 AND 40 THEN 'the width must be 1 to 40'
         WHEN charset !~ '^\[[^\]]+\]$' THEN 'the charset must be a bracket expression such as [0-9] or [A-Z0-9]'
         WHEN link NOT IN ('none', 'prefix', 'grouping') THEN 'the link must be none, prefix or grouping'
         WHEN ord = 1 AND link <> 'none' THEN 'the top level has no parent, so its link is none'
         WHEN ord > 1 AND link = 'none' THEN 'only the top level has the link none'
         END AS why FROM cs_levels) c WHERE c.why IS NOT NULL
   LOOP problems := problems || ex; END LOOP;
   IF (SELECT count(DISTINCT name) FROM cs_levels) <> (SELECT count(*) FROM cs_levels) THEN
      problems := problems || 'two levels have the same name'::text;
   END IF;
   IF cardinality(problems) > 0 THEN
      RAISE EXCEPTION E'the levels are not valid:\n  %', array_to_string(problems, E'\n  ');
   END IF;
   FOR ex IN SELECT format('level %s (%s): its width %s must be more than the %s of the level above, which it is the prefix of',
                           l.ord, l.name, l.width, p.width)
             FROM cs_levels l JOIN cs_levels p ON p.ord = l.ord - 1 WHERE l.link = 'prefix' AND l.width <= p.width
   LOOP problems := problems || ex; END LOOP;
   IF cardinality(problems) > 0 THEN
      RAISE EXCEPTION E'the levels are not valid:\n  %', array_to_string(problems, E'\n  ');
   END IF;

   -- ---- the codes
   BEGIN
      EXECUTE format('CREATE TEMP TABLE cs_stage ON COMMIT DROP AS SELECT q.code::text AS code, q.level::text AS level, coalesce(q.parent::text, '''') AS parent, q.label::text AS label FROM (%s) q', codes_query);
   EXCEPTION WHEN undefined_column THEN
      RAISE EXCEPTION 'the query must return the columns code, level, parent and label: %', SQLERRM
         USING HINT = 'e.g. SELECT sic AS code, ''class'' AS level, left(sic, 2) AS parent, title AS label FROM ...';
   END;
   SELECT count(*) INTO n FROM cs_stage;
   IF n = 0 THEN RAISE EXCEPTION 'the query returned no codes'; END IF;

   -- every check names what is wrong and gives examples; all of them are reported together
   SELECT count(*), min(s.level) INTO n, ex FROM cs_stage s WHERE NOT EXISTS (SELECT 1 FROM cs_levels l WHERE l.name = s.level);
   IF n > 0 THEN problems := problems || format('%s code(s) name a level that is not defined, e.g. %L (the levels are %s)', n, ex,
                                                (SELECT string_agg(name, ', ' ORDER BY ord) FROM cs_levels)); END IF;

   SELECT count(*), (array_agg(s.code ORDER BY s.code))[1] INTO n, ex FROM cs_stage s JOIN cs_levels l ON l.name = s.level
     WHERE s.code !~ ('^' || l.charset || '{' || l.width || '}$');
   IF n > 0 THEN problems := problems || format('%s code(s) are not the width and characters of their level, e.g. %L', n, ex); END IF;

   SELECT count(*), min(code) INTO n, ex FROM (SELECT code FROM cs_stage GROUP BY code HAVING count(*) > 1) d;
   IF n > 0 THEN problems := problems || format('%s code(s) appear more than once, e.g. %L', n, ex); END IF;

   SELECT count(*), min(s.code) INTO n, ex FROM cs_stage s JOIN cs_levels l ON l.name = s.level WHERE l.ord = 1 AND s.parent <> '';
   IF n > 0 THEN problems := problems || format('%s top-level code(s) name a parent, e.g. %L', n, ex); END IF;

   SELECT count(*), min(s.code) INTO n, ex FROM cs_stage s JOIN cs_levels l ON l.name = s.level
     WHERE l.ord > 1 AND NOT EXISTS (SELECT 1 FROM cs_stage p JOIN cs_levels pl ON pl.name = p.level
                                     WHERE p.code = s.parent AND pl.ord = l.ord - 1);
   IF n > 0 THEN problems := problems || format('%s code(s) have a parent that is not a code of the level above, e.g. %L', n, ex); END IF;

   SELECT count(*), min(s.code) INTO n, ex FROM cs_stage s JOIN cs_levels l ON l.name = s.level JOIN cs_levels pl ON pl.ord = l.ord - 1
     WHERE l.link = 'prefix' AND s.parent <> left(s.code, pl.width);
   IF n > 0 THEN problems := problems || format('%s code(s) have a parent that is not their own prefix, e.g. %L', n, ex); END IF;

   FOR ex IN SELECT format('%s %s code(s), but the publisher says %s', c.n, c.name, c.expected)
             FROM (SELECT l.name, l.expected, (SELECT count(*) FROM cs_stage s WHERE s.level = l.name) AS n FROM cs_levels l WHERE l.expected IS NOT NULL) c
             WHERE c.n <> c.expected
   LOOP problems := problems || ex; END LOOP;

   FOR ex IN SELECT format('%s %s code(s) have no children, e.g. %L', c.n, c.name, c.example)
             FROM (SELECT l.name, count(*) AS n, min(s.code) AS example FROM cs_stage s JOIN cs_levels l ON l.name = s.level
                   WHERE l.ord < (SELECT max(ord) FROM cs_levels) AND NOT EXISTS (SELECT 1 FROM cs_stage k WHERE k.parent = s.code)
                   GROUP BY l.name) c
   LOOP problems := problems || ex; END LOOP;

   IF cardinality(problems) > 0 THEN
      RAISE EXCEPTION E'% is not a valid code system: % problem(s)\n  %', sys_name, cardinality(problems), array_to_string(problems, E'\n  ');
   END IF;

   -- the list itself: upper case printable ASCII, at most 40 characters, in byte order, and small enough to number
   SELECT array_agg(code ORDER BY code COLLATE "C") INTO sorted FROM cs_stage;
   PERFORM code_list_check(sorted);

   -- ---- a derived standard: its top levels must be exactly the base system's
   IF refines IS NOT NULL THEN
      IF refines = sys_name THEN RAISE EXCEPTION 'a code system cannot refine itself'; END IF;
      SELECT s.id, (SELECT max(r.revision) FROM codesystem_revision r WHERE r.system_id = s.id) INTO bsys, brev
        FROM codesystem_system s WHERE s.name = refines;
      IF bsys IS NULL OR brev IS NULL THEN
         RAISE EXCEPTION 'refines: the code system "%" is not defined', refines USING HINT = 'define the base system first';
      END IF;
      SELECT count(*) INTO nbase FROM codesystem_level bl WHERE bl.system_id = bsys AND bl.revision = brev;
      nshared := coalesce(shared_levels, nbase);
      IF nshared < 1 OR nshared > nbase OR nshared > (SELECT count(*) FROM cs_levels) THEN
         RAISE EXCEPTION 'shared_levels must be from 1 to the number of levels of both systems (% has %, this has %)',
            refines, nbase, (SELECT count(*) FROM cs_levels);
      END IF;
      FOR ex IN SELECT format('level %s: %s has %s, %s has %s', coalesce(a.ord, b.ord), refines,
                              coalesce(b.name || ' (' || b.width || ' ' || b.charset || ', ' || b.link || ')', 'nothing'),
                              sys_name, coalesce(a.name || ' (' || a.width || ' ' || a.charset || ', ' || a.link || ')', 'nothing'))
                FROM cs_levels a FULL JOIN (SELECT * FROM codesystem_level bl WHERE bl.system_id = bsys AND bl.revision = brev) b ON b.ord = a.ord
                WHERE coalesce(a.ord, b.ord) <= nshared
                  AND (a.name, a.width, a.charset, a.link) IS DISTINCT FROM (b.name, b.width, b.charset, b.link)
      LOOP problems := problems || ex; END LOOP;
      IF cardinality(problems) = 0 THEN
         SELECT count(*), min(x.code) INTO n, ex FROM (
            SELECT s.code, s.level, s.parent FROM cs_stage s JOIN cs_levels l ON l.name = s.level WHERE l.ord <= nshared
            EXCEPT SELECT c.code, c.level, c.parent FROM codesystem_code c WHERE c.system_id = bsys AND c.revision = brev) x;
         IF n > 0 THEN problems := problems || format('%s code(s) of the shared levels are not in %s (or have another parent), e.g. %L', n, refines, ex); END IF;
         SELECT count(*), min(x.code) INTO n, ex FROM (
            SELECT c.code, c.level, c.parent FROM codesystem_code c JOIN codesystem_level bl
                 ON bl.system_id = c.system_id AND bl.revision = c.revision AND bl.name = c.level
              WHERE c.system_id = bsys AND c.revision = brev AND bl.ord <= nshared
            EXCEPT SELECT s.code, s.level, s.parent FROM cs_stage s) x;
         IF n > 0 THEN problems := problems || format('%s code(s) of %s are missing from the shared levels, e.g. %L', n, refines, ex); END IF;
      END IF;
      IF cardinality(problems) > 0 THEN
         RAISE EXCEPTION E'% does not refine %: % problem(s)\n  %', sys_name, refines, cardinality(problems), array_to_string(problems, E'\n  ');
      END IF;
   END IF;

   -- ---- the system, and its revision
   LOCK TABLE codesystem_system IN SHARE ROW EXCLUSIVE MODE;
   SELECT id INTO sysid FROM codesystem_system WHERE name = sys_name;
   IF sysid IS NULL THEN
      SELECT coalesce(max(id), 0) + 1 INTO sysid FROM codesystem_system;
      IF sysid > 32767 THEN RAISE EXCEPTION 'there is room for 32767 code systems'; END IF;
      SELECT name INTO ex FROM codesystem_system WHERE name_hash = code_name_hash(sys_name);
      IF ex IS NOT NULL THEN
         RAISE EXCEPTION 'the name % cannot be used: it would be mistaken for %, because a column''s type modifier holds only a hash of the name', sys_name, ex
            USING HINT = 'choose a different name';
      END IF;
      INSERT INTO codesystem_system (id, name, name_hash, title, publisher) VALUES (sysid, sys_name, code_name_hash(sys_name), title, publisher);
   ELSIF title IS NOT NULL OR publisher IS NOT NULL THEN
      UPDATE codesystem_system s SET title = coalesce(define_code_system.title, s.title), publisher = coalesce(define_code_system.publisher, s.publisher) WHERE s.id = sysid;
   END IF;

   SELECT max(revision) INTO cur FROM codesystem_revision WHERE system_id = sysid;
   IF cur IS NOT NULL THEN
      same := NOT EXISTS (SELECT code, level, parent FROM codesystem_code WHERE system_id = sysid AND revision = cur
                          EXCEPT SELECT code, level, parent FROM cs_stage)
          AND NOT EXISTS (SELECT code, level, parent FROM cs_stage
                          EXCEPT SELECT code, level, parent FROM codesystem_code WHERE system_id = sysid AND revision = cur)
          AND (SELECT array_agg(l.ord || l.name || l.width || l.charset || l.link ORDER BY l.ord) FROM codesystem_level l WHERE l.system_id = sysid AND l.revision = cur)
            = (SELECT array_agg(c.ord || c.name || c.width || c.charset || c.link ORDER BY c.ord) FROM cs_levels c)
          AND (SELECT (d.base_system_id::integer, d.shared_levels::integer) FROM codesystem_derivation d WHERE d.system_id = sysid AND d.revision = cur)
              IS NOT DISTINCT FROM (SELECT (bsys, nshared) WHERE refines IS NOT NULL);
      IF same THEN
         -- the same codes: never a new revision (which would make different values). The titles are only titles.
         UPDATE codesystem_code c SET label = s.label FROM cs_stage s
            WHERE c.system_id = sysid AND c.revision = cur AND c.code = s.code AND c.label IS DISTINCT FROM s.label;
         RETURN cur;
      END IF;
   END IF;
   rev := coalesce(cur, 0) + 1;
   IF rev > 255 THEN RAISE EXCEPTION '% already has 255 revisions, the most there is room for', sys_name; END IF;

   INSERT INTO codesystem_revision (system_id, revision, ncodes) SELECT sysid, rev, count(*) FROM cs_stage;
   INSERT INTO codesystem_level (system_id, revision, ord, name, width, charset, link, expected)
      SELECT sysid, rev, ord, name, width, charset, link, expected FROM cs_levels;
   INSERT INTO codesystem_code (system_id, revision, code, level, parent, label)
      SELECT sysid, rev, code, level, parent, label FROM cs_stage;
   IF refines IS NOT NULL THEN
      INSERT INTO codesystem_derivation (system_id, revision, base_system_id, base_revision, shared_levels) VALUES (sysid, rev, bsys, brev, nshared);
   END IF;
   DROP TABLE cs_stage;
   DROP TABLE cs_levels;
   RETURN rev;
END;
$$;
COMMENT ON FUNCTION define_code_system(text, jsonb, text, text, text, text, integer) IS
   'Define a code system, or give it its next revision. levels is a JSON array, top level first, of {"name", "width", "charset", "link": none|prefix|grouping, "expected": the publisher''s count}. The query returns code, level, parent and label. Everything is checked and every problem is reported together, with examples. The same codes again change nothing but the titles; different codes are the next revision, and values already stored keep the revision they were written under. Returns the revision. refines names a base system whose top levels (shared_levels of them, default all) this one repeats exactly: a national variant such as UK SIC 2007 adding a level to NACE.';

-- ---- derived standards and crosswalks ----------------------------------------------------------------------------------------
CREATE FUNCTION code_rollup(c code, target text)
   RETURNS code
   LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
   cur   code := c;
   d     record;
   lord  integer;
   hops  integer := 0;
BEGIN
   LOOP
      IF code_system(cur) = target THEN RETURN cur; END IF;
      hops := hops + 1;
      IF hops > 8 THEN RETURN NULL; END IF;
      SELECT dv.shared_levels AS shared, bs.name AS base_name INTO d
        FROM codesystem_derivation dv
        JOIN codesystem_system s ON s.id = dv.system_id
        JOIN codesystem_system bs ON bs.id = dv.base_system_id
       WHERE s.name = code_system(cur) AND dv.revision = code_revision(cur);
      IF NOT FOUND THEN RETURN NULL; END IF;
      SELECT l.ord INTO lord FROM codesystem_level l JOIN codesystem_system s ON s.id = l.system_id
       WHERE s.name = code_system(cur) AND l.revision = code_revision(cur) AND l.name = code_level(cur);
      IF lord > d.shared THEN
         cur := code_ancestor(cur, (SELECT l.name FROM codesystem_level l JOIN codesystem_system s ON s.id = l.system_id
                                     WHERE s.name = code_system(cur) AND l.revision = code_revision(cur) AND l.ord = d.shared));
      END IF;
      cur := code_from(code_text(cur), d.base_name);
   END LOOP;
END;
$$;
COMMENT ON FUNCTION code_rollup(code, text) IS
   'The code as a code of a system it refines, however many steps away: code_rollup(''uk_sic_2007:01110'', ''nace_rev2'') is nace_rev2:0111. A code below the shared levels becomes its ancestor at the last shared level. NULL if the target is not a base of the code''s system.';

CREATE FUNCTION code_current(c code)
   RETURNS code
   LANGUAGE sql STABLE STRICT AS $$ SELECT code_from(code_text(c), code_system(c)) $$;
COMMENT ON FUNCTION code_current(code) IS
   'The same code in the current revision of its system, so that values written under different revisions compare equal. An error if the code has been withdrawn.';

CREATE FUNCTION code_is_current(c code)
   RETURNS boolean
   LANGUAGE sql STABLE STRICT AS $$
   SELECT code_revision(c) = (SELECT max(r.revision) FROM codesystem_revision r JOIN codesystem_system s ON s.id = r.system_id WHERE s.name = code_system(c))
$$;
COMMENT ON FUNCTION code_is_current(code) IS 'Whether the value was written under the current revision of its system.';

CREATE FUNCTION define_crosswalk(from_sys text, to_sys text, pairs_query text, allow_unmapped boolean DEFAULT false)
   RETURNS bigint
   LANGUAGE plpgsql AS $$
DECLARE
   fid      integer;
   tid      integer;
   frev     integer;
   trev     integer;
   n        bigint;
   ex       text;
   problems text[] := '{}';
   unmapped text[] := '{}';
BEGIN
   SELECT s.id, (SELECT max(r.revision) FROM codesystem_revision r WHERE r.system_id = s.id) INTO fid, frev FROM codesystem_system s WHERE s.name = from_sys;
   SELECT s.id, (SELECT max(r.revision) FROM codesystem_revision r WHERE r.system_id = s.id) INTO tid, trev FROM codesystem_system s WHERE s.name = to_sys;
   IF fid IS NULL OR frev IS NULL THEN RAISE EXCEPTION 'the code system "%" is not defined', from_sys; END IF;
   IF tid IS NULL OR trev IS NULL THEN RAISE EXCEPTION 'the code system "%" is not defined', to_sys; END IF;
   IF fid = tid THEN RAISE EXCEPTION 'a crosswalk joins two different code systems'; END IF;

   IF to_regclass('pg_temp.cs_pairs') IS NOT NULL THEN DROP TABLE pg_temp.cs_pairs; END IF;
   BEGIN
      EXECUTE format('CREATE TEMP TABLE cs_pairs ON COMMIT DROP AS SELECT DISTINCT q.from_code::text AS from_code, q.to_code::text AS to_code FROM (%s) q', pairs_query);
   EXCEPTION WHEN undefined_column THEN
      RAISE EXCEPTION 'the query must return the columns from_code and to_code: %', SQLERRM;
   END;
   SELECT count(*) INTO n FROM cs_pairs;
   IF n = 0 THEN RAISE EXCEPTION 'the query returned no pairs'; END IF;

   SELECT count(DISTINCT p.from_code), min(p.from_code) INTO n, ex FROM cs_pairs p
     WHERE NOT EXISTS (SELECT 1 FROM codesystem_code c WHERE c.system_id = fid AND c.revision = frev AND c.code = p.from_code);
   IF n > 0 THEN problems := problems || format('%s from_code value(s) are not codes of %s, e.g. %L', n, from_sys, ex); END IF;
   SELECT count(DISTINCT p.to_code), min(p.to_code) INTO n, ex FROM cs_pairs p
     WHERE NOT EXISTS (SELECT 1 FROM codesystem_code c WHERE c.system_id = tid AND c.revision = trev AND c.code = p.to_code);
   IF n > 0 THEN problems := problems || format('%s to_code value(s) are not codes of %s, e.g. %L', n, to_sys, ex); END IF;
   IF cardinality(problems) > 0 THEN
      RAISE EXCEPTION E'the crosswalk from % to % is not valid: % problem(s)\n  %', from_sys, to_sys, cardinality(problems), array_to_string(problems, E'\n  ');
   END IF;

   -- every code with no children (the finest detail) should have a counterpart
   SELECT count(*), min(c.code) INTO n, ex FROM codesystem_code c
     WHERE c.system_id = fid AND c.revision = frev AND NOT EXISTS (SELECT 1 FROM codesystem_code k WHERE k.system_id = fid AND k.revision = frev AND k.parent = c.code)
       AND NOT EXISTS (SELECT 1 FROM cs_pairs p WHERE p.from_code = c.code);
   IF n > 0 THEN unmapped := unmapped || format('%s finest-level code(s) of %s have no counterpart in %s, e.g. %L', n, from_sys, to_sys, ex); END IF;
   SELECT count(*), min(c.code) INTO n, ex FROM codesystem_code c
     WHERE c.system_id = tid AND c.revision = trev AND NOT EXISTS (SELECT 1 FROM codesystem_code k WHERE k.system_id = tid AND k.revision = trev AND k.parent = c.code)
       AND NOT EXISTS (SELECT 1 FROM cs_pairs p WHERE p.to_code = c.code);
   IF n > 0 THEN unmapped := unmapped || format('%s finest-level code(s) of %s have no counterpart in %s, e.g. %L', n, to_sys, from_sys, ex); END IF;
   IF cardinality(unmapped) > 0 THEN
      IF NOT allow_unmapped THEN
         RAISE EXCEPTION E'the crosswalk from % to % leaves codes unmapped:\n  %', from_sys, to_sys, array_to_string(unmapped, E'\n  ')
            USING HINT = 'add the missing pairs, or pass allow_unmapped => true if that is how the publisher states it';
      END IF;
      RAISE NOTICE E'unmapped, as allowed:\n  %', array_to_string(unmapped, E'\n  ');
   END IF;

   DELETE FROM codesystem_crosswalk x WHERE (x.from_system_id = fid AND x.to_system_id = tid) OR (x.from_system_id = tid AND x.to_system_id = fid);
   INSERT INTO codesystem_crosswalk (from_system_id, to_system_id, from_code, to_code) SELECT fid, tid, p.from_code, p.to_code FROM cs_pairs p;
   GET DIAGNOSTICS n = ROW_COUNT;
   RETURN n;
END;
$$;
COMMENT ON FUNCTION define_crosswalk(text, text, text, boolean) IS
   'Define the correspondence between two systems that are not derived from one another (SIC 2003 and SIC 2007): the query returns from_code and to_code. Every code must exist; every finest-level code should have a counterpart unless allow_unmapped. Defining it again replaces it. Returns the number of pairs.';

CREATE FUNCTION code_map(c code, target text)
   RETURNS SETOF code
   LANGUAGE sql STABLE STRICT AS $$
   SELECT code_from(m.other, target) FROM (
      SELECT x.to_code AS other FROM codesystem_crosswalk x
        JOIN codesystem_system fs ON fs.id = x.from_system_id JOIN codesystem_system ts ON ts.id = x.to_system_id
       WHERE fs.name = code_system(c) AND ts.name = target AND x.from_code = code_text(c)
      UNION
      SELECT x.from_code FROM codesystem_crosswalk x
        JOIN codesystem_system fs ON fs.id = x.from_system_id JOIN codesystem_system ts ON ts.id = x.to_system_id
       WHERE ts.name = code_system(c) AND fs.name = target AND x.to_code = code_text(c)) m
   ORDER BY 1
$$;
COMMENT ON FUNCTION code_map(code, text) IS 'The codes of the target system that correspond to this one, from the crosswalk (either direction).';

CREATE FUNCTION code_map_unique(c code, target text)
   RETURNS code
   LANGUAGE sql STABLE STRICT AS $$
   SELECT CASE WHEN count(*) = 1 THEN min(m) END FROM code_map(c, target) m
$$;
COMMENT ON FUNCTION code_map_unique(code, text) IS 'The one corresponding code, or NULL if there are none or several: only a one-to-one mapping gives an answer.';

CREATE VIEW code_crosswalks AS
   SELECT fs.name AS from_system, ts.name AS to_system, count(*) AS pairs,
          count(DISTINCT x.from_code) AS from_codes, count(DISTINCT x.to_code) AS to_codes,
          CASE WHEN count(*) = count(DISTINCT x.from_code) AND count(*) = count(DISTINCT x.to_code) THEN 'one to one'
               WHEN count(*) = count(DISTINCT x.from_code) THEN 'many to one'
               WHEN count(*) = count(DISTINCT x.to_code) THEN 'one to many'
               ELSE 'many to many' END AS shape
   FROM codesystem_crosswalk x
   JOIN codesystem_system fs ON fs.id = x.from_system_id JOIN codesystem_system ts ON ts.id = x.to_system_id
   GROUP BY fs.name, ts.name ORDER BY 1, 2;
COMMENT ON VIEW code_crosswalks IS 'The crosswalks defined here, and whether they are one to one or not.';
-- codesystem 0.1.0 -> 0.2.0: pattern systems
--
-- A list system (ISIC, SOC, ...) is a finite list of codes with levels. An identifier with a syntax and no list -- the Companies
-- House company number, which has 13 million values and grows every day -- is a PATTERN system: the revision holds a regular
-- expression, a code is its rank among everything the expression allows, and adding companies changes nothing.
--
--   SELECT define_code_system_pattern('uk_crn', '/(?<prefix>SC|NI)(?<number>\d{6})|\d{8}/', 'number');
--   SELECT code_part('uk_crn:SC123456', 'prefix');          -- SC

ALTER TABLE codesystem_revision ADD COLUMN pattern text;
COMMENT ON COLUMN codesystem_revision.pattern IS
   'NULL for a list system. For a pattern system the regular expression (names included) that defines the codes; ncodes is how many it allows.';

-- a system is a list or a pattern, for all its revisions
CREATE FUNCTION codesystem_kind_check()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
DECLARE
   prev_is_pattern boolean;
BEGIN
   -- through TG_RELID: pg_restore runs with an empty search_path, so the table cannot be named
   EXECUTE format('SELECT r.pattern IS NOT NULL FROM %s r WHERE r.system_id = $1 AND r.revision <> $2 ORDER BY r.revision DESC LIMIT 1', TG_RELID::regclass)
      INTO prev_is_pattern USING NEW.system_id, NEW.revision;
   IF prev_is_pattern IS NOT NULL AND prev_is_pattern <> (NEW.pattern IS NOT NULL) THEN   -- (EXECUTE does not set FOUND)
      RAISE EXCEPTION 'a code system is either a list or a pattern, and this one is a %', CASE WHEN prev_is_pattern THEN 'pattern' ELSE 'list' END
         USING HINT = CASE WHEN prev_is_pattern THEN 'use define_code_system_pattern()' ELSE 'use define_code_system()' END;
   END IF;
   RETURN NEW;
END;
$$;
CREATE TRIGGER codesystem_revision_kind BEFORE INSERT ON codesystem_revision
   FOR EACH ROW EXECUTE FUNCTION codesystem_kind_check();

CREATE FUNCTION code_pattern_resolve(spec text) RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_pattern_total(regex text)  RETURNS bigint AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_pattern_maxlen(regex text) RETURNS integer AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_pattern_parts(regex text)  RETURNS text[] AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
CREATE FUNCTION code_pattern_same(a text, b text) RETURNS boolean AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION code_pattern_resolve(text) IS
   'Checks a pattern (a template, or a /regular expression/ between slashes, with optional (?<name>...) parts) and returns the regular expression it means. An error says what is wrong, including a pattern whose parts could be split two ways.';
COMMENT ON FUNCTION code_pattern_same(text, text) IS 'Whether two patterns allow exactly the same codes, however they are written.';

CREATE FUNCTION define_code_system_pattern(sys_name text, pattern text, level_name text DEFAULT 'code', title text DEFAULT NULL, publisher text DEFAULT NULL)
   RETURNS integer
   LANGUAGE plpgsql AS $$
DECLARE
   regex   text;
   total   bigint;
   maxlen  integer;
   sysid   integer;
   cur     integer;
   curpat  text;
   rev     integer;
   ex      text;
BEGIN
   IF sys_name IS NULL OR sys_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
      RAISE EXCEPTION 'a code system name is lower case letters, digits and _, starting with a letter, at most 63 characters; got %', sys_name;
   END IF;
   IF level_name IS NULL OR level_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
      RAISE EXCEPTION 'a level name is lower case letters, digits and _; got %', level_name;
   END IF;
   regex := code_pattern_resolve(pattern);
   total := code_pattern_total(regex);
   maxlen := code_pattern_maxlen(regex);

   LOCK TABLE codesystem_system IN SHARE ROW EXCLUSIVE MODE;
   SELECT s.id INTO sysid FROM codesystem_system s WHERE s.name = sys_name;
   IF sysid IS NULL THEN
      SELECT coalesce(max(s.id), 0) + 1 INTO sysid FROM codesystem_system s;
      IF sysid > 32767 THEN RAISE EXCEPTION 'there is room for 32767 code systems'; END IF;
      SELECT s.name INTO ex FROM codesystem_system s WHERE s.name_hash = code_name_hash(sys_name);
      IF ex IS NOT NULL THEN
         RAISE EXCEPTION 'the name % cannot be used: it would be mistaken for %, because a column''s type modifier holds only a hash of the name', sys_name, ex
            USING HINT = 'choose a different name';
      END IF;
      INSERT INTO codesystem_system (id, name, name_hash, title, publisher) VALUES (sysid, sys_name, code_name_hash(sys_name), title, publisher);
   ELSIF title IS NOT NULL OR publisher IS NOT NULL THEN
      UPDATE codesystem_system s SET title = coalesce(define_code_system_pattern.title, s.title), publisher = coalesce(define_code_system_pattern.publisher, s.publisher) WHERE s.id = sysid;
   END IF;

   SELECT r.revision, r.pattern INTO cur, curpat FROM codesystem_revision r WHERE r.system_id = sysid ORDER BY r.revision DESC LIMIT 1;
   IF cur IS NOT NULL THEN
      IF curpat IS NULL THEN
         RAISE EXCEPTION 'a code system is either a list or a pattern, and % is a list', sys_name USING HINT = 'use define_code_system()';
      END IF;
      IF code_pattern_same(curpat, regex) THEN RETURN cur; END IF;      -- the same codes however written: not a new revision
   END IF;
   rev := coalesce(cur, 0) + 1;
   IF rev > 255 THEN RAISE EXCEPTION '% already has 255 revisions, the most there is room for', sys_name; END IF;
   INSERT INTO codesystem_revision (system_id, revision, ncodes, pattern) VALUES (sysid, rev, total, regex);
   INSERT INTO codesystem_level (system_id, revision, ord, name, width, charset, link, expected) VALUES (sysid, rev, 1, level_name, maxlen, 'pattern', 'none', NULL);
   RETURN rev;
END;
$$;
COMMENT ON FUNCTION define_code_system_pattern(text, text, text, text, text) IS
   'Define an identifier with a syntax and no list of values (a company number): the pattern is a template, or a /regular expression/ between slashes with optional (?<name>...) parts. A code is its rank among everything the pattern allows, so codes added later change nothing. A pattern that allows the same codes in another form is not a new revision; a different one is the next revision. Returns the revision.';

CREATE FUNCTION code_part(c code, part text) RETURNS text AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_parts(c code) RETURNS jsonb AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION code_part(code, text) IS 'The named part of a code of a pattern system, or NULL if this code has no such part: code_part(''uk_crn:SC123456'', ''prefix'') is SC.';
COMMENT ON FUNCTION code_parts(code) IS 'All the named parts a code has, as a JSON object.';

-- a number lost its leading zeros on the way through a spreadsheet: a string of digits shorter than the longest code is padded
CREATE FUNCTION code_from_padded(t text, sys text)
   RETURNS code
   LANGUAGE plpgsql STABLE STRICT AS $$
DECLARE
   w integer;
BEGIN
   IF t !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'code_from_padded takes digits only, got "%"', t USING HINT = 'use code_from() for anything else';
   END IF;
   SELECT max(l.width) INTO w FROM codesystem_level l JOIN codesystem_system s ON s.id = l.system_id
    WHERE s.name = sys AND l.revision = (SELECT max(r.revision) FROM codesystem_revision r WHERE r.system_id = s.id);
   IF w IS NULL THEN RAISE EXCEPTION 'the code system "%" is not defined', sys; END IF;
   RETURN code_from(CASE WHEN length(t) < w THEN lpad(t, w, '0') ELSE t END, sys);   -- lpad would cut a longer string short
END;
$$;
COMMENT ON FUNCTION code_from_padded(text, text) IS
   'code_from_padded(''1234567'', ''uk_crn'') is uk_crn:01234567: digits only, padded with zeros to the length of the longest code, then checked like any other. For numbers that a spreadsheet stripped. An error if the result is not a code.';

DROP VIEW code_systems;
CREATE VIEW code_systems AS
   SELECT s.name, s.title, s.publisher, r.revision AS current_revision, r.ncodes,
          (SELECT string_agg(l.name || ' (' || l.width || ')', ' > ' ORDER BY l.ord)
             FROM codesystem_level l WHERE l.system_id = s.id AND l.revision = r.revision) AS levels,
          (SELECT count(*) FROM codesystem_revision x WHERE x.system_id = s.id) AS revisions,
          CASE WHEN r.pattern IS NULL THEN 'list' ELSE 'pattern' END AS kind,
          r.pattern
   FROM codesystem_system s
   LEFT JOIN LATERAL (SELECT * FROM codesystem_revision r WHERE r.system_id = s.id ORDER BY r.revision DESC LIMIT 1) r ON true
   ORDER BY s.name;
COMMENT ON VIEW code_systems IS 'The code systems defined here, their current revision, their levels, and whether each is a list or a pattern.';

CREATE FUNCTION code_first_with_prefix(prefix text, sys text) RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
CREATE FUNCTION code_last_with_prefix(prefix text, sys text)  RETURNS code AS 'MODULE_PATHNAME' LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION code_first_with_prefix(text, text) IS
   'The first code of the system whose text starts with the prefix, NULL if none does. With code_last_with_prefix: crn BETWEEN code_first_with_prefix(''SC'',''uk_crn'') AND code_last_with_prefix(''SC'',''uk_crn'') finds every code starting SC, using the index. The codes that start with some text are consecutive, so this is exact.';
COMMENT ON FUNCTION code_last_with_prefix(text, text) IS 'The last code of the system whose text starts with the prefix; see code_first_with_prefix.';
