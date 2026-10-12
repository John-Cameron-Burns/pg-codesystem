# Source data

The classifications that `tools/` can load, the files each is read from, and what the files contain. The prepared form of
NACE, UK SIC and the GSS entity types comes with the package in `data/prepared/`, under their publishers' open licences (see
"Licences and attribution" below), so those load straight away. **ISIC Rev.4 and ISCO-08 are not distributed with the package:**
`codesystem_install_isic_rev4()` and `codesystem_install_isco_08()` (`tools/install_isic_isco.sql`) download them from the UN and the
ILO and define them. To rebuild the shipped files, or to prepare the other systems, fetch the source files into `data/raw/` and run
`make prepare`.

| System | Publisher | Source file in `data/raw/` | Prepared by | Loaded by |
|---|---|---|---|---|
| `isic_rev4` | UN Statistics Division | `ISIC_Rev_4_english_structure.Txt` | read directly by the install function | `codesystem_install_isic_rev4()` |
| `isco_08` | ILO | `ISCO-08_EN.csv` | read directly by the install function | `codesystem_install_isco_08()` |
| `nace_rev2` | Statistik Austria (open data portal), republishing the Eurostat classification | `NACERev.2_EN_CTI_20070214_131821_utf8.csv`, from `OGDEXT_KLASSDB_NACERev2_1.zip` | `prepare_nace.py`; shipped prepared | `load_nace.sql` |
| `uk_sic_2007`, `uk_sic_2003` and their crosswalk | ONS | the ONS SIC 2007 list and the SIC 2003 to 2007 equivalence table | shipped prepared, in `data/prepared/uk_sic_*.csv` | `load_uk_sic.sql` |
| `uk_soc_2020`, `uk_soc_2020_extended` | ONS | `Extended_SOC_framework.csv`, from the Extended SOC download | `prepare_soc.py` | `load_soc.sql` |
| `uk_soc_2010` and its ISCO-08 crosswalk | ONS | `ug201002soc2010toisco08v2_tcm77-283163.xls` (User Guide 2010: 02.1), exported to one CSV per sheet in `data/raw/soc2010_isco08/` | `prepare_soc2010.py` | `load_soc2010.sql` |
| SOC 2020 to ISCO-08 crosswalks | ONS | `soc2020volume2thecodingindexexcel20260827v2.xlsx` (SOC 2020 volume 2, the coding index, version 14) | `prepare_soc2020_isco.py` | `load_soc2020_isco.sql` |
| `gss_entity` | ONS | the entity table of the Register of Geographic Codes, shipped prepared in `data/prepared/gss_entity_types.csv` | | `load_gss.sql` |
| `gss` | ONS | none: defined by a pattern | | `load_gss.sql` |
| `uk_crn` | Companies House | none: defined by a pattern | | `load_crn.sql` |

Download locations:

* ISIC Rev.4: https://unstats.un.org/unsd/classifications/Econ/Download/In%20Text/ISIC_Rev_4_english_structure.Txt
* ISCO-08: https://www.ilo.org/ilostat-files/ISCO/newdocs-08-2021/ISCO-08/ISCO-08%20EN.csv
* NACE Rev.2: https://data.europa.eu/data/datasets/stat_nace-rev-2 (European Data Portal record of Statistik Austria's `OGDEXT_KLASSDB_NACERev2_1.zip`)
* GSS entity types: the Register of Geographic Codes, from the ONS Open Geography Portal (https://geoportal.statistics.gov.uk).
  Each edition is an ArcGIS item holding a zip, downloaded from `https://www.arcgis.com/sharing/rest/content/items/<item id>/data`
  (June 2026: item `ef9bb98c8c62471684aaf42b8898f220`, about 21 MB; March 2022: `ce24654e47e94906ae749cd9741ec318`). Editions are also
  listed on data.gov.uk, one package per edition (`register-of-geographic-codes-june-2026-for-the-uk`), whose `guid` gives the item id.
  The prepared file has the entity types of the June 2026 edition; `gss_update_entity_types()` (`tools/gss_update.sql`) brings
  `gss_entity` up to the latest edition from the ONS itself.
* The other ONS files come from the ONS classification pages.

## What the files contain

**ISIC Rev.4** has 766 rows: 21 sections (A-U), 88 divisions, 238 groups and 419 classes, the published structure. Divisions,
groups and classes form a strict prefix hierarchy. A division code is not prefixed by its section letter; the section comes
from the section's own row order, so a section is a grouping of divisions.

**ISCO** is one wide row per unit group, with four versions in one file (ISCO-08: 436 rows, ISCO-88: 390, ISCO-68: 285,
ISCO-58: 202), so the loader filters on `ISCO_version`. The file is Windows-1252, not UTF-8. ISCO-08 has the published 10 / 43 /
130 / 436 groups. Leading zeros are lost for the Armed Forces group (major `0`, sub-major `1` for `01`, minor `11` for `011`,
unit `110` for `0110`); `prepare_isco.py` repairs this and reports it on every run.

**NACE Rev.2** is `;`-separated with a German header: 21 sections, 88 divisions, 272 groups and 615 classes. Its sections
and divisions are exactly ISIC Rev.4's, so it is loaded with `refines => 'isic_rev4', shared_levels => 2`. The other files in the zip
(explanatory notes, German titles) are not used.

**UK SIC 2007** has 21 sections, 88 divisions, 272 groups, 615 classes and 728 subclasses. It repeats all of NACE Rev.2's codes
once, so it is loaded with `refines => 'nace_rev2'`, a three-system chain from ISIC. The prepared files
(`data/prepared/uk_sic_2007.csv`, `uk_sic_2003.csv`, `uk_sic_2003_2007_pairs.csv`) come with the package. They were
built from the ONS lists with these corrections:
* The ONS list has no row for division 16, nor for the four-digit classes, only padded five-digit forms. The hierarchy is
  rebuilt from the five-digit rows' own section, division, group and class columns.
* Two codes in the list are mistyped: 45119 should be 45112 and 82922 should be 82912. They are corrected, with a warning.
* Trailing spaces in some equivalence-table codes are trimmed.
* 74990 "Non-trading company" is a Companies House code, not part of SIC 2007, and is left out.

**UK SIC 2003** has 699 five-digit codes and no hierarchy. The ONS equivalence table gives 1,299 pairs to UK SIC 2007.

**UK SOC 2020** has 9 major, 26 sub-major, 104 minor and 412 unit groups, the published counts. The Extended SOC adds 1,384
sub-unit groups (codes like `1111/01`) and is loaded as `uk_soc_2020_extended` with `refines => 'uk_soc_2020'`. The
descriptions file in the same download is not loaded.

**UK SOC 2010 to ISCO-08**: 369 SOC 2010 unit groups (a flat system, since the file has no higher levels) and 385 pairs onto
291 ISCO-08 unit groups. The 50/50 and 40/60 split percentages are not kept. The file's "Unmapped ISCO08" sheet lists 145 ISCO-08
unit groups; 291 + 145 = 436, the number of ISCO-08 unit groups.

**SOC 2020 to ISCO-08** is derived from the coding index, because the ONS publishes no simple unit-group mapping for SOC 2020
(job titles split across several ISCO-08 groups). A pair means at least one of the 32,670 indexed job titles is coded to both
groups; nothing is said of how many titles a pair covers. There are 1,899 unit-group pairs (all 412 SOC 2020 unit groups mapped;
425 of 436 ISCO-08 unit groups reached) and 3,076 sub-unit pairs. 231 "see ..." cross-reference entries and 4 records without an
ISCO-08 code (3 of unit group 8160, 1 of 4131/06) are skipped. Reading the workbook needs `openpyxl`; the other loaders need only
the Python standard library.

**GSS codes** are nine characters: a country letter, a two-digit entity type and a six-digit number (`E01000001`). Eight country
letters are in use (E England, N Northern Ireland, S Scotland, W Wales, K for areas spanning the UK or Great Britain, and J, L and
M). The `gss` pattern system checks that shape and names the parts. The Register of Geographic Codes lists 206 entity types, 174
current and 32 archived; all are in `gss_entity`, because archived types still appear in older data. The individual areas
(hundreds of thousands of codes with their names) are not loaded: join your own table of area names to a `gss` column.

The `gss` pattern was checked against all 589,626 distinct codes in the ONS Code History Database and the Register of Geographic
Codes. Every one is accepted, converts to a `code` and back to the same text, and sorts in the same order as its text, and the
country letter and type of every one is an entity type in `gss_entity`.

## Licences and attribution

The same statements are in the `NOTICE` file.

* **NACE Rev.2** (`data/prepared/nace_rev2.csv`): Data source: Statistik Austria, Klassifikationsdatenbank, NACE Rev. 2, via the
  Austrian open data portal (listed at https://data.europa.eu/data/datasets/stat_nace-rev-2), licensed CC BY. The file has been
  converted to the prepared form (code, level, parent, label), nothing else changed.
* **UK SIC 2007 and 2003, the SIC crosswalk, and the GSS entity types** (`data/prepared/uk_sic_*.csv`, `gss_entity_types.csv`):
  Source: Office for National Statistics licensed under the Open Government Licence v.3.0. Contains public sector information
  licensed under the Open Government Licence v3.0 (https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
  Converted to the prepared form; two mistyped codes were corrected and one Companies House pseudo-code left out, as described above.
* **ISIC Rev.4** is © United Nations (https://www.un.org/en/about-us/terms-of-use) and **ISCO-08** is © International Labour
  Organization (https://www.ilo.org/rights-and-permissions). Neither is distributed with this package; the install functions fetch
  them from the publishers for you, under the publishers' terms.

