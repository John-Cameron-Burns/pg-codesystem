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
