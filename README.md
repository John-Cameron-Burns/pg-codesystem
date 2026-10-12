# codesystem

A PostgreSQL extension for **codes**: it represents them compactly (8 bytes), validates them, normalises them, indexes them
efficiently, and understands their structure. One type, `code`, holds the codes of any code system.

A code system is something you define in SQL, in one call: either a **list** of codes, usually with a hierarchy (an industrial
classification, a product catalogue, a chart of accounts), or a **pattern** for identifiers that have a format but no complete list
(a registration number, a geography code). The extension checks the definition, and from then on every value of that system is
checked when it is stored, so a mistyped code is refused instead of quietly saved.

Several common systems come ready-made, and they are used for the examples throughout: industry codes (UK SIC, NACE, ISIC),
occupation codes (UK SOC, ISCO), UK company numbers and ONS GSS geography codes. They are not samples: each is fully functional
and production ready, built from the publisher's own data and checked when it is loaded. They are ordinary definitions, so yours
work the same way. (UK postcodes, and postal codes of other countries, are handled by the companion `postcode` extension.)

## Defining a code system

```sql
CREATE EXTENSION codesystem;

CREATE TEMP TABLE staging (code text, level text, parent text, label text);
INSERT INTO staging VALUES ('A',  'group', '',  'Fruit'),      ('A1', 'item', 'A', 'Apple'), ('A2', 'item', 'A', 'Pear'),
                           ('B',  'group', '',  'Vegetables'), ('B1', 'item', 'B', 'Carrot');

SELECT define_code_system('produce',
   '[{"name":"group","width":1,"charset":"[A-Z]","link":"none"},
     {"name":"item", "width":2,"charset":"[A-Z0-9]","link":"prefix"}]',
   'SELECT * FROM staging', 'Produce codes', 'Example Ltd');

CREATE TABLE stock (name text, kind code('produce'));
INSERT INTO stock VALUES ('crate 7', 'produce:A2');
INSERT INTO stock VALUES ('crate 8', 'produce:C9');
-- ERROR:  "C9" is not a code of produce (revision 1)

SELECT code_label(kind), code_label(code_ancestor(kind, 'group')) FROM stock;   -- Pear | Fruit
```

## What it does

* **Rejects bad codes.** A column declared `code('produce')` accepts only codes of that system. Nothing is trimmed or corrected
  behind your back.
* **Knows the structure.** `code_label`, `code_level`, `code_parent`, `code_ancestor` and `code_children` give a code's title, its
  level, the code directly above it, its ancestor at any level, and the codes below it. Group a table by a higher level without
  cutting strings apart.
* **Sorts and indexes like text.** Codes order as their text does, and work with indexes, `ORDER BY`, `GROUP BY`, joins, `min()`
  and `max()`. Prefix ranges (`code_first_with_prefix`, `code_last_with_prefix`) select a branch of the hierarchy from an index.
* **Understands derived standards.** A national variant of an international standard (UK SIC 2007 is NACE Rev.2 with extra
  detail, and NACE is ISIC Rev.4 with extra detail) is declared with `refines`, checked against the standard it builds on, and
  rolled up with `code_rollup('uk_sic_2007:47110', 'nace_rev2')`.
* **Translates between standards that only correspond.** `define_crosswalk` links two systems that are not versions of one
  another (UK SIC 2003 and 2007, SOC and ISCO). `code_map` follows the link, and the `code_crosswalks` view shows whether each link
  is one-to-one, many-to-one and so on.
* **Survives changes to the official lists.** When a list is updated, the old and new versions are kept side by side, so codes
  already stored keep their meaning. `code_current` brings old and new together.
* **Handles identifiers by pattern.** A system with a format but no complete list is described by a pattern. You can pick out its
  parts and select a range by prefix:

```sql
SELECT define_code_system_pattern('uk_crn', '/\d{8}|(?<prefix>SC|NI)(?<number>\d{6})/', 'number');
SELECT code_part('uk_crn:SC123456', 'prefix');                       -- SC
SELECT code_from_padded('1234567', 'uk_crn');                        -- uk_crn:01234567
WHERE crn BETWEEN code_first_with_prefix('SC','uk_crn') AND code_last_with_prefix('SC','uk_crn')
```

## Code systems included

SQL loaders in `tools/` define these from the publishers' files (`data/SOURCES.md` says where each comes from). Prepared files for
NACE, UK SIC and the GSS entity types come with the package. ISIC Rev.4 and ISCO-08 are published under their owners' own terms, so
two functions download them from the UN and the ILO when you ask (`codesystem_install_isic_rev4()`, `codesystem_install_isco_08()`):

| system | |
|---|---|
| `isic_rev4`, `isco_08` | UN industrial classification; ILO occupations |
| `nace_rev2` | EU industrial classification (refines ISIC Rev.4) |
| `uk_sic_2007`, `uk_sic_2003` | UK industrial classification (2007 refines NACE; 2003 corresponds to it) |
| `uk_soc_2020`, `uk_soc_2020_extended`, `uk_soc_2010` | UK occupations, with the ONS extension and the previous edition |
| `gss`, `gss_entity` | ONS GSS geography codes (pattern system) and the types of area they name; `gss_update_entity_types()` keeps the types current |
| `uk_crn` | Companies House company number (pattern system) |

## Install

Requires PostgreSQL 13 or later and the PostgreSQL development files.

    make
    make install
    make installcheck          # regression tests

then `CREATE EXTENSION codesystem;` in the database. Upgrade from an earlier version with `ALTER EXTENSION codesystem UPDATE`.

## Documentation

`docs/USER_GUIDE.md` covers writing and reading codes, the hierarchy, defining a code system, revisions, derived standards,
crosswalks, pattern systems and a function reference. `docs/CRN.md` explains the company-number pattern.

## Licence and attributions

The extension is BSD licensed (`LICENSE`). The prepared data files that come with it are third-party material under their
publishers' licences (`NOTICE`):

* **NACE Rev.2:** data source Statistik Austria, Klassifikationsdatenbank, licensed CC BY (via the Austrian open data portal).
* **UK SIC 2007 and 2003, and the GSS entity types:** source: Office for National Statistics licensed under the Open Government
  Licence v.3.0. Contains public sector information licensed under the Open Government Licence v3.0.

ISIC Rev.4 (© United Nations) and ISCO-08 (© International Labour Organization) are not included; the install functions download
them from the publishers.
