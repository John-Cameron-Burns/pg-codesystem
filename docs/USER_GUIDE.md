# codesystem: user guide

codesystem stores codes in one PostgreSQL type, `code`, whatever the code system: an industrial classification, an occupation
list, a company or geography identifier, or one of your own. A value knows which system it belongs to, can only be a real code of
that system, sorts the way the codes sort, and can be asked its title, its level, its parent and its ancestors. It takes 8
bytes, whatever the length of the code.

A code system is defined in SQL, with no change to the extension. Two kinds are supported: **list** systems, where every code is
enumerated and the codes form a hierarchy (SIC, SOC, ISIC, NACE, ISCO ...), and **pattern** systems, for identifiers that have a
format but no complete list (a company number, a geography code). UK postcodes, and the postal codes of other countries, are
handled by the companion `postcode` extension.

Several systems come ready-made, and they are the examples throughout this guide. They are fully functional and production ready,
not samples: each is built from the publisher's own data and checked when it is loaded. The outputs shown are real, trimmed for width.

- [1. Getting started: look up a code, lock a column, group by level](#1-getting-started-look-up-a-code-lock-a-column-group-by-level)
- [2. Writing and reading codes](#2-writing-and-reading-codes)
- [3. Hierarchy](#3-hierarchy)
- [4. Defining your own code system](#4-defining-your-own-code-system)
- [5. Revisions: when a standard changes](#5-revisions-when-a-standard-changes)
- [6. Derived standards and roll-up](#6-derived-standards-and-roll-up)
- [7. Crosswalks: standards that merely correspond](#7-crosswalks-standards-that-merely-correspond)
- [8. Identifiers: pattern systems](#8-identifiers-pattern-systems)
- [9. The code systems included](#9-the-code-systems-included)
- [10. Looking after it](#10-looking-after-it)
- [11. Reference](#11-reference)
- [12. When something goes wrong](#12-when-something-goes-wrong)

## 1. Getting started: look up a code, lock a column, group by level

```sql
CREATE EXTENSION codesystem;          -- once per database; ALTER EXTENSION codesystem UPDATE after an upgrade
SELECT name, kind, current_revision AS rev, ncodes, levels FROM code_systems;
```
```
         name         |  kind   | rev |  ncodes   |                              levels
----------------------+---------+-----+-----------+-------------------------------------------------------------------
 isic_rev4            | list    |   1 |       766 | section (1) > division (2) > group (3) > class (4)
 nace_rev2            | list    |   1 |       996 | section (1) > division (2) > group (3) > class (4)
 uk_crn               | pattern |   1 | 407291360 | number (8)
 uk_sic_2007          | list    |   1 |      1724 | section (1) > division (2) > group (3) > class (4) > subclass (5)
 ...
```

A code is written `system:code`:

```sql
SELECT code_label('isic_rev4:4711'), code_level('isic_rev4:4711'), code_parent('isic_rev4:4711');
-- Retail sale in non-specialized stores with food, beverages or tobacco predominating | class | isic_rev4:471
```

Use it as a column type, locked to one system, and the database will refuse anything that is not a code of that system:

```sql
CREATE TABLE firms (name text, activity code('uk_sic_2007'));
INSERT INTO firms VALUES ('Acme Ltd', 'uk_sic_2007:47110'), ('Bolt plc', 'uk_sic_2007:47190'), ('Cog Ltd', 'uk_sic_2007:62012');
INSERT INTO firms VALUES ('Typo', 'uk_sic_2007:99999');
-- ERROR:  "99999" is not a code of uk_sic_2007 (revision 1)
```

Group by any level without string slicing:

```sql
SELECT code_label(code_ancestor(activity, 'division')) AS division, count(*)
  FROM firms GROUP BY 1 ORDER BY 1;
--  Computer programming, consultancy and related activities |     1
--  Retail trade, except of motor vehicles and motorcycles   |     2
```

## 2. Writing and reading codes

**In SQL text, write the system with the code**: `'uk_sic_2007:47110'`. A literal in a query cannot know which column it is
going into (PostgreSQL gives it no type modifier), so a bare `'47110'` is refused:

```
ERROR:  invalid input for code: "47110"
HINT:  write the system with the code, 'isic_rev4:4711'; a bare code is read only from text ...
```

**A bare code is fine when it comes from text**, because the column then says which system it is:

| you write | works? |
|---|---|
| `COPY firms FROM 'f.csv' (FORMAT csv)` with bare codes in the file | yes |
| `INSERT INTO firms SELECT name, sic_text FROM staging` (a `text` column) | yes |
| `'47110'::text::code('uk_sic_2007')` | yes |
| `code_from('4711', 'isic_rev4')` | yes (works anywhere) |
| `INSERT INTO firms VALUES ('x', '47110')` | no: write `'uk_sic_2007:47110'` |

Other things to know:

* Output is always `system:code`. For the bare code use `code_text(c)` or `c::text`.
* Letters are accepted in either case and printed in upper case.
* `code_is_valid('47110', 'uk_sic_2007')` answers true or false without raising an error (NULL and unknown codes are false).
* Codes compare and sort as the text does: `isic_rev4:01` < `isic_rev4:011` < `isic_rev4:0111`. Indexes (btree and hash),
  `ORDER BY`, `GROUP BY`, `DISTINCT`, joins, `min()` and `max()` all work. Codes of different systems can be compared; they
  order by system first.
* A column declared plain `code` (no system) holds codes of any system; `code('isic_rev4')` locks it to one.
* Bad input is refused with the code it did not like and the system it was checked against. Nothing is silently trimmed or corrected.

## 3. Hierarchy

Each system has levels (ISIC: section, division, group, class). Each code is at one level.

| function | gives |
|---|---|
| `code_level(c)` | the level's name, `'class'` |
| `code_parent(c)` | the code one level up, or NULL at the top |
| `code_ancestor(c, 'division')` | the ancestor at that level; `c` itself if it is already there; NULL if the level is below `c` |
| `code_children(c)` | the codes one level down (a set) |
| `code_label(c)` | the publisher's title |
| `code_system(c)`, `code_revision(c)` | which system, and which revision it was written under |

```sql
SELECT c, code_label(c) FROM code_children('isic_rev4:471') c;
--  isic_rev4:4711 | Retail sale in non-specialized stores with food, beverages or tobacco predominating
--  isic_rev4:4719 | Other retail sale in non-specialized stores

SELECT code_ancestor('uk_sic_2007:47110', 'section');         -- uk_sic_2007:G
```

A level is linked to the one above by **prefix** (a group is the first three characters of its class) or by **grouping**
(ISIC's section is a *set* of divisions, not part of their digits, so it is stated). `code_ancestor` follows either.
Titles can be edited (`UPDATE codesystem_code SET label = ...`); nothing else in the registry can.

## 4. Defining your own code system

A system is defined once, in one call, and the whole definition is checked. You supply the levels and a query returning the codes.

```sql
CREATE TEMP TABLE staging (code text, level text, parent text, label text);
\copy staging FROM 'my_classification.csv' (FORMAT csv, HEADER)

SELECT define_code_system(
   'my_classification',
   '[{"name":"section", "width":1, "charset":"[A-Z]", "link":"none",     "expected":21},
     {"name":"division","width":2, "charset":"[0-9]", "link":"grouping", "expected":88},
     {"name":"class",   "width":4, "charset":"[0-9]", "link":"prefix",   "expected":419}]',
   'SELECT * FROM staging',
   'Title of the standard', 'Publisher');
```

* `levels` is a JSON array, top level first. `width` is the length of a code at that level, `charset` the characters it may
  use, `link` is `none` (top), `prefix` or `grouping`. `expected` is the publisher's count; give it, and a missing code is caught.
* The query returns `code`, `level`, `parent` (empty at the top) and `label`.
* Codes are upper case printable ASCII, at most 40 characters. A system may have up to 8 levels.

Every problem is reported together, with an example of each, and nothing is stored:

```
ERROR:  x is not a valid code system: 6 problem(s)
  1 code(s) name a level that is not defined, e.g. 'nonsense' (the levels are section, division, group, class)
  1 code(s) are not the width and characters of their level, e.g. 'Z9'
  1 code(s) appear more than once, e.g. '0111'
  2 code(s) have a parent that is not a code of the level above, e.g. '03'
  1 code(s) have a parent that is not their own prefix, e.g. '0301'
  7 class code(s), but the publisher says 5
```

If you can get the publisher's file, load that and let the checks tell you what is wrong with it. The real UK SIC list had two
mistyped codes, found this way (`data/SOURCES.md`).

Loaders for the systems listed in section 9 are in `tools/`.

## 5. Revisions: when a standard changes

Internally a code is stored as its position in the system's sorted list, so adding a code moves the position of those after
it. To keep stored values meaningful, **a changed list is a new revision**, and each value remembers the revision it was written under:

```sql
SELECT define_code_system('my_classification', ..., 'SELECT * FROM staging');   -- same codes: returns the same revision, changes nothing
-- add a code to staging, run it again:                                           -- returns the next revision
```

* New input is always read against the **current** revision. Old values keep decoding with the revision they were written under.
* The same text in two revisions is **two different values**: `=` is false between them.
  `code_current(c)` brings a value to the current revision (an error if the code has since been withdrawn);
  `code_is_current(c)` tells you whether it is. Compare with `code_current(a) = code_current(b)`.
* Editions that are really different standards (UK SIC 2003 and 2007) are separate systems, not revisions.
* Titles can be corrected without a new revision.
* A revision, once written, can never be altered or removed. Up to 255 revisions per system.

## 6. Derived standards and roll-up

National standards are usually an international one with extra detail. Say so when you define it, and the extension **checks it**:

```sql
SELECT define_code_system('nace_rev2', ..., refines => 'isic_rev4', shared_levels => 2);
SELECT define_code_system('uk_sic_2007', ..., refines => 'nace_rev2');         -- shares all four of NACE's levels
```

The shared top levels must be *exactly* the base system's: same levels, same codes, same parents. Differences are listed:

```
ERROR:  uk_sic_2007 does not refine nace_rev2: 1 problem(s)
  1 code(s) of the shared levels are not in nace_rev2 (or have another parent), e.g. '7499'
```

Then roll a code up to any system it derives from, however many steps:

```sql
SELECT code_rollup('uk_sic_2007:47110', 'nace_rev2') AS nace,       -- nace_rev2:4711
       code_rollup('uk_sic_2007:47110', 'isic_rev4') AS isic;        -- isic_rev4:47  (NACE shares only sections and divisions with ISIC)
```

A code below the shared levels rolls up to its ancestor at the last shared level. If the target is not a base of the code's system the answer is NULL.

## 7. Crosswalks: standards that merely correspond

SIC 2003 and 2007 are not derived from each other; the ONS publishes pairs of corresponding codes. Load them with:

```sql
SELECT define_crosswalk('uk_sic_2003', 'uk_sic_2007', 'SELECT from_code, to_code FROM pairs');
```

Every code must exist in its system, and every finest-level code should have a counterpart, or the call stops and lists what
is missing. If that is how the publisher states it, pass `allow_unmapped => true` (you get a notice listing what was left).
Defining a crosswalk again replaces it.

```sql
SELECT code_map('uk_sic_2003:52111', 'uk_sic_2007');                    -- uk_sic_2007:47110   (works in either direction)
SELECT code_map_unique('uk_sic_2003:01110', 'uk_sic_2007');             -- NULL: this one maps to 12 codes
SELECT * FROM code_crosswalks;                                          -- pairs, and one to one / many to one / ... for each
```

`code_map_unique` answers only when there is exactly one counterpart. Most real correspondences are many-to-many; use
`code_map` and decide what to do with the extra rows. The SOC 2020 to ISCO-08 crosswalk is *derived* from the ONS job-title index
(a pair means at least one job title is coded to both), not a published table: see `data/SOURCES.md`.

## 8. Identifiers: pattern systems

Some codes have a syntax but no list: the Companies House company number has 13 million values and grows daily, and an ONS GSS geography code is a country letter, a two-digit area type and six digits. These are
**pattern systems**: the revision holds a regular expression, and a code is its position among everything the pattern allows, so
new numbers change nothing and need no revision.

```sql
SELECT define_code_system_pattern('my_id',
   '/(?<prefix>SC|NI)(?<number>\d{6})|\d{8}/',          -- a template ('AA-NNN') or a /regular expression/
   'number', 'My identifier', 'Me');

SELECT code_part('my_id:SC123456', 'prefix');            -- SC
SELECT code_parts('my_id:SC123456');                     -- {"number": "123456", "prefix": "SC"}
SELECT code_from_padded('1234567', 'my_id');             -- my_id:01234567   (digits a spreadsheet stripped of zeros)
SELECT * FROM firms WHERE crn BETWEEN code_first_with_prefix('SC', 'my_id') AND code_last_with_prefix('SC', 'my_id');
```

* **A pattern says what can be a number, not which numbers exist.** It catches a wrong prefix, a wrong length, a stray letter. It
  cannot know a number was never issued: that is still a join to the register.
* Templates: `N` a digit, `A` a letter, `X` either, space and `-` themselves, `[ ... ]` optional. Anything else is a regular
  expression between slashes: `( )`, `|`, `?`, `{n,m}`, `[A-Z0-9]`, `\d`. No unbounded `*` or `+`.
* Name parts with `(?<name>...)`. A name may be used once in a pattern; a part a given code does not have is NULL. The
  check refuses a pattern in which a code could be split into its parts two ways.
* A pattern may allow at most 2^40 codes and 2,048 states. A different pattern is a new revision; the same codes written
  another way are not.
* `tools/load_crn.sql` defines `uk_crn`, the real UK company number (see `docs/CRN.md` for how it was derived and what it
  accepts: all 13,549,728 numbers in the Companies House Bulk Downloads).

## 9. The code systems included

These are ordinary definitions, made with the calls in sections 4 and 8. Loaders are SQL scripts in `tools/`; run them from the repository root with `psql -d yourdb -f tools/...`. The prepared files for
NACE, UK SIC and the GSS entity types come with the package. **ISIC Rev.4 (United Nations) and ISCO-08 (ILO) do not**: they are
published under their owners' own terms, so you install them yourself, from the publisher, with two functions (`tools/install_isic_isco.sql`):

```sql
\i tools/install_isic_isco.sql                  -- once, as a superuser; needs plpython3u
SELECT * FROM codesystem_install_isic_rev4();   -- downloads ISIC Rev.4 from the UN (about 40 KB) and defines isic_rev4
SELECT * FROM codesystem_install_isco_08();     -- downloads ISCO-08 from the ILO (about 220 KB) and defines isco_08
```

Each checks the file against the publisher's own counts and returns the system, the number of codes, the revision before and
after, whether anything changed, and any repair made to the publisher's file (ISCO-08's file has lost the leading zeros of the
Armed Forces group; they are put back and listed). Run again, they change nothing unless the list has. Pass `source_url =>` to read a
file you downloaded yourself (`'file:///var/tmp/ISCO-08 EN.csv'`) or `dry_run => true` to fetch and check only. NACE needs
`isic_rev4` first. `data/SOURCES.md` says where each source comes from and what is in it, and the attributions the shipped
data files require are in `NOTICE`.

| system | what | loader | derived from |
|---|---|---|---|
| `isic_rev4` | UN industrial classification | `codesystem_install_isic_rev4()` | |
| `isco_08` | ILO occupations | `codesystem_install_isco_08()` | |
| `nace_rev2` | EU industrial classification | `load_nace.sql` | refines `isic_rev4` (2 levels) |
| `uk_sic_2007` | UK industrial classification | `load_uk_sic.sql` | refines `nace_rev2` (4 levels) |
| `uk_sic_2003` + crosswalk | previous UK SIC, 5-digit | `load_uk_sic.sql` | corresponds to `uk_sic_2007` |
| `uk_soc_2020` | UK occupations | `load_soc.sql` | |
| `uk_soc_2020_extended` | with the ONS sub-unit groups | `load_soc.sql` | refines `uk_soc_2020` |
| `uk_soc_2010` + crosswalk | previous UK SOC, unit groups | `load_soc2010.sql` | corresponds to `isco_08` |
| SOC 2020 to ISCO-08 | derived from the coding index | `load_soc2020_isco.sql` | |
| `uk_crn` | Companies House number | `load_crn.sql` | pattern system |
| `gss` | ONS GSS geography code, e.g. `E06000001` | `load_gss.sql` | pattern system |
| `gss_entity` | the types of area a GSS code can name (`E01`, `E06` ...) | `load_gss.sql` | |

**Keeping `gss_entity` current.** ONS publishes a new edition of the Register of Geographic Codes every few months. Load
`tools/gss_update.sql` once, as a superuser (it needs the `plpython3u` extension and a server that can reach www.arcgis.com), then:

```sql
SELECT * FROM gss_update_entity_types();                 -- the latest edition: downloads it (about 20 MB) and brings gss_entity up to date
SELECT * FROM gss_update_entity_types(dry_run => true);  -- fetch and check it, change nothing
SELECT * FROM gss_update_entity_types('ce24654e47e94906ae749cd9741ec318');   -- a particular edition, by its ArcGIS item id
```

It returns the edition, its item id, the number of entity types, the revision of `gss_entity` before and after, and whether it
changed. If the entity types are unchanged nothing happens; if they have changed, `gss_entity` gets the next revision and stored
values keep their meaning. Pinning an older edition can remove types a newer one has, which is also a new revision. It writes to
the registry, so on a replicated cluster run it on the primary. Run it from a scheduler such as pg_cron if you want it automatic.

## 10. Looking after it

**Dump and restore.** Values are dumped as text (`isic_rev4:4711`), which needs the definitions to read back. The registry
tables (`codesystem_*`) are part of the dump but `pg_restore` does not know to load them first. Use the script, with a
custom-format dump:

```
pg_dump -Fc mydb > mydb.dump
tools/restore.sh mydb.dump newdb
```

Restored in the wrong order, it stops with `the code system of this column is not defined here`; it never loads a wrong value.

**Upgrading.** Install the new files, then `ALTER EXTENSION codesystem UPDATE` in each database. A new binary running against
the old definitions keeps working until then.

**Permissions.** Defining systems writes the `codesystem_*` tables; give that right to whoever maintains them. Reading codes
needs `SELECT` on those tables, which is the default for everyone; do not revoke it.

**Size and speed.** A code is 8 bytes. Parsing or printing takes about 150 ns; looking up a label, a parent or children of a list
system uses a per-session cache, built the first time a system is used in a session (and again after its definition changes).
`code_label` reads the registry on each call, so for a big report join `codesystem_code` instead.

**Limits.** 32,767 systems; 255 revisions per system; codes of 1 to 40 characters; a list system's sorted list must compile to
at most 32,767 states (any real classification does; thousands of irregular codes would not); a pattern at most 2,048 states
and 2^40 codes; up to 8 levels.

**Transactions.** A system defined in a transaction that rolls back disappears from every session's cache; there is nothing to clean up.

## 11. Reference

Types: `code`, `code(system)`.

Defining: `define_code_system(name, levels jsonb, codes_query, title, publisher, refines, shared_levels)`,
`define_code_system_pattern(name, pattern, level_name, title, publisher)`, `define_crosswalk(from, to, pairs_query, allow_unmapped)`.

Reading: `code_text`, `code_system`, `code_revision`, `code_level`, `code_parent`, `code_ancestor(c, level)`, `code_children`,
`code_label`, `code_part(c, name)`, `code_parts(c)`.

Making codes: `code_from(text, system)`, `code_from_padded(text, system)`, `code_is_valid(text, system)`, casts `text::code('system')`.

Revisions: `code_current`, `code_is_current`.

Derivation: `code_rollup(c, target_system)`, `code_map(c, target_system)`, `code_map_unique(c, target_system)`.

Ranges: `code_first_with_prefix(prefix, system)`, `code_last_with_prefix(prefix, system)`.

Operators and aggregates: `= <> < > <= >=`, `min`, `max`, btree and hash operator classes.

Views: `code_systems`, `code_crosswalks`.

Tables (the definitions; read them, do not insert): `codesystem_system`, `codesystem_revision`, `codesystem_level`,
`codesystem_code`, `codesystem_derivation`, `codesystem_crosswalk`.

## 12. When something goes wrong

| message | meaning and what to do |
|---|---|
| `invalid input for code: "47110"` | a bare code in SQL text. Write `'uk_sic_2007:47110'`, or go through `text` |
| `"99999" is not a code of uk_sic_2007 (revision 1)` | the code does not exist in the current revision. Check the spelling; `code_is_valid()` tests without an error |
| `the code system "x" is not defined` | misspelt name, or the system is not loaded in this database. `SELECT * FROM code_systems` |
| `X is not a code of Y` | a value of one system going into a column of another |
| `the code system of this column is not defined here` | a restore loaded a table before the registry: use `tools/restore.sh` |
| `... is not a valid code system: N problem(s)` | the list below it says exactly what is wrong with the data |
| `... does not refine ...` | the derived system's shared levels differ from the base; the differences are listed |
| `the crosswalk ... leaves codes unmapped` | add the missing pairs, or `allow_unmapped => true` if the publisher says they have none |
| `codesystem_code rows are permanent` | you tried to change a stored definition. Define a new revision instead |
| `a code system is either a list or a pattern` | you used the wrong `define_` function for an existing system |
| a join or `=` between two codes that look the same finds nothing | they were written under different revisions, so they are different values: compare `code_current(a) = code_current(b)` |
