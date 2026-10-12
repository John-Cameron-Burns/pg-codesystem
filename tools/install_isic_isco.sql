-- Installs ISIC Rev.4 (United Nations Statistics Division) and ISCO-08 (International Labour Organization) from the publishers'
-- own files, on demand, so that no copy of either is distributed with this package:
--
--    \i tools/install_isic_isco.sql                        -- once, as a superuser: creates the functions (needs plpython3u)
--    SELECT * FROM codesystem_install_isic_rev4();         -- downloads ISIC Rev.4 from the UN and defines isic_rev4
--    SELECT * FROM codesystem_install_isco_08();           -- downloads ISCO-08 from the ILO and defines isco_08
--
-- Each function downloads the publisher's file (about 40 KB and 220 KB), checks it against the publisher's own counts, and
-- defines the system. Run again later, it changes nothing if the list is unchanged. Each takes optional arguments:
--
--    source_url   where to read the file from. The default is the publisher's address; any URL the database server can
--                 read works, including a file you downloaded yourself:  'file:///var/tmp/ISIC_Rev_4_english_structure.Txt'
--    dry_run      true: fetch the file and check it, change nothing
--
-- You are downloading the data from its publisher, under the publisher's terms of use: United Nations (https://www.un.org/en/about-us/terms-of-use)
-- and International Labour Organization (https://www.ilo.org/rights-and-permissions). Read them before you use the data.
--
-- nace_rev2 and uk_sic_2007 refine isic_rev4, and the SOC to ISCO crosswalks need isco_08, so install these first.
--
-- Each function returns one row: the system, where the data came from, how many codes, the revision before and after, whether it
-- changed, and any repairs made to the publisher's file (ISCO-08's file has lost leading zeros in the Armed Forces group; they are
-- put back and listed). It writes to the code system registry, so on a replicated cluster run it on the primary.

CREATE OR REPLACE FUNCTION codesystem_install_isic_rev4(
   source_url text DEFAULT 'https://unstats.un.org/unsd/classifications/Econ/Download/In%20Text/ISIC_Rev_4_english_structure.Txt',
   dry_run boolean DEFAULT false)
RETURNS TABLE (system text, source text, codes integer, revision_before integer, revision_after integer, changed boolean, repairs text)
LANGUAGE plpython3u AS $py$
import csv, io, urllib.request

# identifies this program to the publisher (the ILO refuses the anonymous default of Python's urllib)
UA = "codesystem/0.2 (PostgreSQL extension; +https://github.com/John-Cameron-Burns/pg-codesystem)"

url = source_url
with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=120) as resp:
    text = resp.read().decode("utf-8-sig")
reader = csv.reader(io.StringIO(text))
header = [h.strip() for h in next(reader)]
if header != ["Code", "Description"]:
    plpy.error("%s: expected the header Code,Description, found %s" % (url, header))
by_width = {1: "section", 2: "division", 3: "group", 4: "class"}
rows, section = [], ""
for n, rec in enumerate(reader, start=2):
    if not rec:
        continue
    code, label = rec[0].strip(), rec[1].strip()
    level = by_width.get(len(code))
    if level is None:
        plpy.error("%s line %d: %r has no level (an ISIC code is 1 to 4 characters)" % (url, n, code))
    if level == "section":
        section, parent = code, ""
    elif level == "division":
        if not section:
            plpy.error("%s line %d: division %r comes before any section" % (url, n, code))
        parent = section            # a section is a grouping of divisions: the one the file lists them under
    else:
        parent = code[:-1]
    rows.append((code, level, parent, label))
before = plpy.execute("SELECT current_revision FROM code_systems WHERE name = 'isic_rev4'")
rev_before = before[0]["current_revision"] if len(before) else None
if dry_run:
    return [("isic_rev4", url, len(rows), rev_before, rev_before, False, None)]
plpy.notice("ISIC Rev.4 is published by the United Nations Statistics Division; use is subject to https://www.un.org/en/about-us/terms-of-use")
plpy.execute("CREATE TEMP TABLE IF NOT EXISTS cs_isic_stg (code text, level text, parent text, label text) ON COMMIT DROP")
plpy.execute("TRUNCATE cs_isic_stg")
ins = plpy.prepare("INSERT INTO cs_isic_stg VALUES ($1, $2, $3, $4)", ["text", "text", "text", "text"])
for r in rows:
    plpy.execute(ins, list(r))
rev_after = plpy.execute(
    """SELECT define_code_system('isic_rev4',
          '[{"name":"section", "width":1,"charset":"[A-Z]","link":"none",    "expected":21},
            {"name":"division","width":2,"charset":"[0-9]","link":"grouping","expected":88},
            {"name":"group",   "width":3,"charset":"[0-9]","link":"prefix",  "expected":238},
            {"name":"class",   "width":4,"charset":"[0-9]","link":"prefix",  "expected":419}]',
          'SELECT * FROM cs_isic_stg',
          'International Standard Industrial Classification of All Economic Activities, Rev.4',
          'United Nations Statistics Division') AS r""")[0]["r"]
return [("isic_rev4", url, len(rows), rev_before, rev_after, rev_before != rev_after, None)]
$py$;

CREATE OR REPLACE FUNCTION codesystem_install_isco_08(
   source_url text DEFAULT 'https://www.ilo.org/ilostat-files/ISCO/newdocs-08-2021/ISCO-08/ISCO-08%20EN.csv',
   dry_run boolean DEFAULT false)
RETURNS TABLE (system text, source text, codes integer, revision_before integer, revision_after integer, changed boolean, repairs text)
LANGUAGE plpython3u AS $py$
import csv, io, urllib.request

# identifies this program to the publisher (the ILO refuses the anonymous default of Python's urllib)
UA = "codesystem/0.2 (PostgreSQL extension; +https://github.com/John-Cameron-Burns/pg-codesystem)"

url = source_url
with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=120) as resp:
    text = resp.read().decode("cp1252")          # the ILO file is Windows-1252, not UTF-8
source = list(csv.DictReader(io.StringIO(text)))
if not source or "ISCO_version" not in source[0]:
    plpy.error("%s: expected a column ISCO_version" % url)
chosen = [r for r in source if r["ISCO_version"] == "ISCO-08"]       # the file holds ISCO-08, -88, -68 and -58
if not chosen:
    plpy.error("%s: no ISCO-08 rows; the file has %s" % (url, sorted({r["ISCO_version"] for r in source})))
levels = [("major", 1, "major_label"), ("sub_major", 2, "sub_major_label"), ("minor", 3, "minor_label"), ("unit", 4, "description")]
rows, label_of, repaired = [], {}, {}
for r in chosen:
    parent = ""
    for name, width, label_column in levels:
        raw = r[name].strip()
        code = raw.zfill(width)                  # the Armed Forces group has lost its leading zeros: 1 for 01, 110 for 0110
        if code != raw:
            repaired.setdefault(name, {})[raw] = code
        label = r[label_column].strip()
        if code in label_of:
            if label_of[code] != label:
                plpy.error("%s: %s %r is called both %r and %r" % (url, name, code, label_of[code], label))
        else:
            label_of[code] = label
            rows.append((code, name, parent, label))
        parent = code
note = "; ".join("%d %s code(s) had lost leading zeros: %s" % (len(p), n, ", ".join("%s -> %s" % kv for kv in sorted(p.items())))
                 for n, p in repaired.items()) or None
before = plpy.execute("SELECT current_revision FROM code_systems WHERE name = 'isco_08'")
rev_before = before[0]["current_revision"] if len(before) else None
if dry_run:
    return [("isco_08", url, len(rows), rev_before, rev_before, False, note)]
plpy.notice("ISCO-08 is published by the International Labour Organization; use is subject to https://www.ilo.org/rights-and-permissions")
plpy.execute("CREATE TEMP TABLE IF NOT EXISTS cs_isco_stg (code text, level text, parent text, label text) ON COMMIT DROP")
plpy.execute("TRUNCATE cs_isco_stg")
ins = plpy.prepare("INSERT INTO cs_isco_stg VALUES ($1, $2, $3, $4)", ["text", "text", "text", "text"])
for r in rows:
    plpy.execute(ins, list(r))
rev_after = plpy.execute(
    """SELECT define_code_system('isco_08',
          '[{"name":"major",    "width":1,"charset":"[0-9]","link":"none",  "expected":10},
            {"name":"sub_major","width":2,"charset":"[0-9]","link":"prefix","expected":43},
            {"name":"minor",    "width":3,"charset":"[0-9]","link":"prefix","expected":130},
            {"name":"unit",     "width":4,"charset":"[0-9]","link":"prefix","expected":436}]',
          'SELECT * FROM cs_isco_stg',
          'International Standard Classification of Occupations, ISCO-08',
          'International Labour Organization') AS r""")[0]["r"]
return [("isco_08", url, len(rows), rev_before, rev_after, rev_before != rev_after, note)]
$py$;

COMMENT ON FUNCTION codesystem_install_isic_rev4(text, boolean) IS
'Downloads ISIC Rev.4 from the United Nations Statistics Division (or the given source_url) and defines the isic_rev4 code system. dry_run fetches and checks without changing anything.';
COMMENT ON FUNCTION codesystem_install_isco_08(text, boolean) IS
'Downloads ISCO-08 from the International Labour Organization (or the given source_url) and defines the isco_08 code system. dry_run fetches and checks without changing anything.';
