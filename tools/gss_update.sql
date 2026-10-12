-- gss_update_entity_types(): brings the gss_entity code system up to date with the ONS Register of Geographic Codes.
--
--    \i tools/gss_update.sql                                  -- once, as a superuser: creates the function
--    SELECT * FROM gss_update_entity_types();                 -- the latest published edition
--    SELECT * FROM gss_update_entity_types(dry_run => true);  -- fetch and check it, change nothing
--    SELECT * FROM gss_update_entity_types('ce24654e47e94906ae749cd9741ec318');   -- a particular edition, by its ArcGIS item id
--
-- The ONS publishes each edition of the Register as a zip on the Open Geography Portal (geoportal.statistics.gov.uk) and tags
-- exactly one edition as the latest. The function asks ArcGIS which edition that is, downloads its zip (about 20 MB), reads
-- the entity table inside it, and defines gss_entity from it. If the entity types have not changed, nothing happens and the
-- revision stays the same; if they have, gss_entity gets the next revision, and values already stored keep their meaning.
--
-- It returns one row: the edition, its item id, the number of entity types, the revision of gss_entity before and after,
-- and whether it changed. It needs the plpython3u extension (CREATE EXTENSION plpython3u), because a zip cannot be opened in
-- plain SQL, and the database server must be able to reach www.arcgis.com. It writes to the code system registry, so on a
-- replicated cluster it must be run on the primary. Every problem stops it with an error; nothing is changed half way.
CREATE OR REPLACE FUNCTION gss_update_entity_types(item_id text DEFAULT NULL, dry_run boolean DEFAULT false)
RETURNS TABLE (edition text, item text, entity_types integer, revision_before integer, revision_after integer, changed boolean)
LANGUAGE plpython3u AS $py$
import csv, io, json, urllib.parse, urllib.request, zipfile

ARCGIS = "https://www.arcgis.com/sharing/rest"

def get(url, timeout):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()

iid = item_id          # plpython3u makes the arguments globals: assign to another name, never to item_id itself
if iid is None:
    q = urllib.parse.urlencode({"q": 'tags:PRD_RGC AND categories:"/Categories/LATEST"', "f": "json"})
    found = json.loads(get(ARCGIS + "/search?" + q, 30)).get("results", [])
    if len(found) != 1:
        plpy.error("expected exactly one Register of Geographic Codes edition tagged as the latest, found %d: "
                   "the ONS tagging may have changed; pass an item id explicitly" % len(found))
    iid, edition = found[0]["id"], found[0]["title"]
else:
    meta = json.loads(get("%s/content/items/%s?f=json" % (ARCGIS, urllib.parse.quote(iid)), 30))
    if "title" not in meta or "PRD_RGC" not in (meta.get("tags") or []):
        plpy.error("item %s is not an edition of the Register of Geographic Codes (%s)" % (iid, meta.get("error") or meta.get("title")))
    edition = meta["title"]

blob = get("%s/content/items/%s/data" % (ARCGIS, iid), 300)
if blob[:2] != b"PK":
    plpy.error("%s did not download as a zip file" % edition)
zf = zipfile.ZipFile(io.BytesIO(blob))
names = [n for n in zf.namelist() if n.lower().endswith(".csv")]
if len(names) != 1:
    plpy.error("expected one CSV in %s, found %s" % (edition, names))
rows = []
for r in csv.DictReader(io.StringIO(zf.read(names[0]).decode("utf-8-sig"))):
    code = (r.get("Entity code") or "").strip()
    if code:
        rows.append((code.upper(), (r.get("Entity name") or "").strip()))
if not rows:
    plpy.error("no entity types found in %s: the columns may have changed" % edition)

before = plpy.execute("SELECT current_revision FROM code_systems WHERE name = 'gss_entity'")
rev_before = before[0]["current_revision"] if len(before) else None
if dry_run:
    return [(edition, iid, len(rows), rev_before, rev_before, False)]

plpy.execute("CREATE TEMP TABLE IF NOT EXISTS gss_entity_stg (code text, level text, parent text, label text) ON COMMIT DROP")
plpy.execute("TRUNCATE gss_entity_stg")
ins = plpy.prepare("INSERT INTO gss_entity_stg VALUES ($1, 'entity', '', $2)", ["text", "text"])
for code, name in sorted(rows):
    plpy.execute(ins, [code, name])
rev_after = plpy.execute(
    """SELECT define_code_system('gss_entity',
          '[{"name":"entity","width":3,"charset":"[A-Z0-9]","link":"none"}]',
          'SELECT * FROM gss_entity_stg', 'ONS GSS entity types (Register of Geographic Codes)',
          'Office for National Statistics') AS r""")[0]["r"]
return [(edition, iid, len(rows), rev_before, rev_after, rev_before != rev_after)]
$py$;

COMMENT ON FUNCTION gss_update_entity_types(text, boolean) IS
'Brings the gss_entity code system up to date with the latest edition of the ONS Register of Geographic Codes (or the edition with the given ArcGIS item id). dry_run fetches and checks without changing anything.';
