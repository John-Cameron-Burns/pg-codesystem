// codesystem: code systems (SIC, SOC, ISIC, ISCO, ...) as one generic, validated, hierarchical type.
//
// A value is 63 bits: system (15) | revision (8) | rank (40). The rank is the code's position, in byte order, among the codes of
// that revision (engine/cs_pattern.h), so the values sort as the codes sort and a value is valid exactly when its rank is.
// The definitions are in four ordinary tables (codesystem--0.1.0.sql); this file loads them into a per-backend cache and
// forgets the cache whenever one of the tables changes.
#include <postgres.h>
#include <fmgr.h>
#include <funcapi.h>
#include <miscadmin.h>
#include <executor/spi.h>
#include <commands/trigger.h>
#include <commands/extension.h>
#include <catalog/pg_extension.h>
#include <catalog/pg_type.h>
#include <access/htup_details.h>
#include <access/hash.h>
#include <libpq/pqformat.h>
#include <utils/array.h>
#include <lib/stringinfo.h>
#include <utils/builtins.h>
#include <utils/jsonb.h>
#include <utils/inval.h>
#include <utils/lsyscache.h>
#include <utils/memutils.h>
#include <utils/rel.h>
#include <utils/syscache.h>

#include "cs_pattern.h"

PG_MODULE_MAGIC;

#define CS_SYSTEM_SHIFT 48
#define CS_REV_SHIFT    40
#define CS_RANK_MASK    ((UINT64CONST(1) << CS_REV_SHIFT) - 1)
#define CS_NO_PARENT    0xFFFFFFFFu
#define CS_MAX_LEVELS   8

#define PG_GETARG_CODE(n)  ((int64) PG_GETARG_INT64(n))
#define PG_RETURN_CODE(x)  PG_RETURN_INT64(x)

static inline int64 pack_code (int sys, int rev, uint64 rank) {
   return ((int64) sys << CS_SYSTEM_SHIFT) | ((int64) rev << CS_REV_SHIFT) | (int64) rank;
}
static inline int    code_sys  (int64 v) { return (int) ((v >> CS_SYSTEM_SHIFT) & 0x7FFF); }
static inline int    code_rev  (int64 v) { return (int) ((v >> CS_REV_SHIFT) & 0xFF); }
static inline uint64 code_rank (int64 v) { return (uint64) v & CS_RANK_MASK; }

// ---- the cache -----------------------------------------------------------------------------------------------------
typedef struct {
   int      id;
   char     name[64];
   int32    hash;
   int      current;                 // its latest revision, 0 if none
} SysInfo;

typedef struct {
   int          sys, rev;
   char         name[64];
   cs_pattern  *pat;
   int          nlevels;
   char         level_name[CS_MAX_LEVELS][64];
   uint8       *level_of;             // [rank] -> 0-based index into level_name
   uint32      *parent;               // [rank] -> rank of the parent, CS_NO_PARENT at the top
   cs_parts    *parts;                // named parts, NULL if the pattern has none (and for every list system)
} Entry;
// For a pattern system level_of and parent are NULL: it has the one level, level_name[0], and no hierarchy.

static MemoryContext cache_cxt = NULL;
static SysInfo *systems = NULL;
static int      nsystems = 0;
static bool     systems_loaded = false;
static Entry  **entries = NULL;
static int      nentries = 0, entries_cap = 0;
static bool     stale = true;
static Oid      table_oids[4];
static int      ntable_oids = 0;

static void *cache_alloc (size_t n) { return MemoryContextAlloc(cache_cxt, n); }

static void registry_callback (Datum arg, Oid relid) {
   if (relid == InvalidOid) { stale = true; return; }
   for (int i = 0; i < ntable_oids; i++)
      if (table_oids[i] == relid) { stale = true; return; }
}

void _PG_init (void);
void _PG_init (void) {
   CacheRegisterRelcacheCallback(registry_callback, (Datum) 0);
}

// The trigger on the four tables: DML does not invalidate anything by itself, so say so.
PG_FUNCTION_INFO_V1(code_registry_changed);
Datum code_registry_changed (PG_FUNCTION_ARGS) {
   if (!CALLED_AS_TRIGGER(fcinfo))
      elog(ERROR, "code_registry_changed() must be called as a trigger");
   CacheInvalidateRelcacheByRelid(RelationGetRelid(((TriggerData *) fcinfo->context)->tg_relation));
   return PointerGetDatum(NULL);
}

static void spi_begin (void) {
   if (SPI_connect() != SPI_OK_CONNECT) elog(ERROR, "codesystem: SPI_connect failed");
}

// The extension's schema, from pg_extension (get_extension_schema() needs PostgreSQL 16; EXTENSIONOID is not in the syscache before 14).
static Oid extension_schema_oid (void) {
   Oid result = InvalidOid;
   spi_begin();
   if (SPI_execute("SELECT extnamespace FROM pg_catalog.pg_extension WHERE extname = 'codesystem'", true, 1) != SPI_OK_SELECT)
      elog(ERROR, "codesystem: cannot read pg_extension");
   if (SPI_processed == 1) {
      bool isnull;
      result = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
   }
   SPI_finish();
   if (!OidIsValid(result)) elog(ERROR, "codesystem: the extension is not installed");
   return result;
}

static const char *schema_prefix (void) {
   return psprintf("%s.", quote_identifier(get_namespace_name(extension_schema_oid())));
}

static void forget_cache (void) {
   if (cache_cxt == NULL)
      cache_cxt = AllocSetContextCreate(CacheMemoryContext, "codesystem cache", ALLOCSET_DEFAULT_SIZES);
   else
      MemoryContextReset(cache_cxt);
   systems = NULL; nsystems = 0; systems_loaded = false;
   entries = NULL; nentries = 0; entries_cap = 0;
   // from here a new invalidation sets stale again; one that arrived while loading just makes the next call reload
   stale = false;
   ntable_oids = 0;
   Oid nsp = extension_schema_oid();
   static const char *const tables[4] = { "codesystem_system", "codesystem_revision", "codesystem_level", "codesystem_code" };
   for (int i = 0; i < 4; i++) {
      Oid o = get_relname_relid(tables[i], nsp);
      if (OidIsValid(o)) table_oids[ntable_oids++] = o;
   }
}

static void check_fresh (void) {
   if (stale || cache_cxt == NULL) forget_cache();
}


static void load_systems (void) {
   check_fresh();
   if (systems_loaded) return;
   const char *sp = schema_prefix();
   char *sql = psprintf(
      "SELECT s.id, s.name, s.name_hash, coalesce((SELECT max(r.revision) FROM %scodesystem_revision r WHERE r.system_id = s.id), 0) "
      "FROM %scodesystem_system s ORDER BY s.id", sp, sp);
   spi_begin();
   if (SPI_execute(sql, true, 0) != SPI_OK_SELECT) elog(ERROR, "codesystem: cannot read the registry");
   uint64 n = SPI_processed;
   SysInfo *tmp = MemoryContextAllocZero(cache_cxt, sizeof(SysInfo) * (n ? n : 1));
   for (uint64 i = 0; i < n; i++) {
      bool isnull;
      HeapTuple t = SPI_tuptable->vals[i];
      TupleDesc d = SPI_tuptable->tupdesc;
      tmp[i].id = DatumGetInt16(SPI_getbinval(t, d, 1, &isnull));
      char *nm = text_to_cstring(DatumGetTextPP(SPI_getbinval(t, d, 2, &isnull)));
      strlcpy(tmp[i].name, nm, sizeof tmp[i].name);
      tmp[i].hash = DatumGetInt32(SPI_getbinval(t, d, 3, &isnull));
      tmp[i].current = (int) DatumGetInt64(SPI_getbinval(t, d, 4, &isnull)) ;
   }
   SPI_finish();
   systems = tmp; nsystems = (int) n; systems_loaded = true;
}

static SysInfo *find_system_by_id (int id) {
   load_systems();
   for (int i = 0; i < nsystems; i++) if (systems[i].id == id) return &systems[i];
   return NULL;
}
static SysInfo *find_system_by_name (const char *name) {
   load_systems();
   for (int i = 0; i < nsystems; i++) if (strcmp(systems[i].name, name) == 0) return &systems[i];
   return NULL;
}
static SysInfo *find_system_by_hash (int32 hash) {
   load_systems();
   for (int i = 0; i < nsystems; i++) if (systems[i].hash == hash) return &systems[i];
   return NULL;
}

static int32 name_hash (const char *s) {
   uint32 h = 2166136261u;
   for (; *s; s++) { h ^= (unsigned char) *s; h *= 16777619u; }
   return (int32) (h & 0x7FFFFFFF);
}

static Entry *load_entry (int sys, int rev, const char *sysname) {
   const char *sp = schema_prefix();
   char *err = palloc(256);
   Entry *e = MemoryContextAllocZero(cache_cxt, sizeof(Entry));
   e->sys = sys; e->rev = rev;
   strlcpy(e->name, sysname, sizeof e->name);

   spi_begin();
   Oid argt[2] = { INT2OID, INT2OID };
   Datum args[2] = { Int16GetDatum(sys), Int16GetDatum(rev) };
   char *lsql = psprintf("SELECT name FROM %scodesystem_level WHERE system_id = $1 AND revision = $2 ORDER BY ord", sp);
   if (SPI_execute_with_args(lsql, 2, argt, args, NULL, true, 0) != SPI_OK_SELECT) elog(ERROR, "codesystem: cannot read the levels");
   if (SPI_processed < 1 || SPI_processed > CS_MAX_LEVELS)
      ereport(ERROR, (errmsg("code system %s revision %d has no levels in the registry", sysname, rev)));
   e->nlevels = (int) SPI_processed;
   for (int i = 0; i < e->nlevels; i++) {
      bool isnull;
      char *nm = text_to_cstring(DatumGetTextPP(SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1, &isnull)));
      strlcpy(e->level_name[i], nm, sizeof e->level_name[i]);
   }
   SPI_freetuptable(SPI_tuptable);

   // a pattern system: the revision holds the regular expression, and there are no code rows
   // to_jsonb: the binary may be installed a moment before ALTER EXTENSION UPDATE adds the column
   char *psql = psprintf("SELECT to_jsonb(r)->>'pattern' FROM %scodesystem_revision r WHERE r.system_id = $1 AND r.revision = $2", sp);
   if (SPI_execute_with_args(psql, 2, argt, args, NULL, true, 0) != SPI_OK_SELECT) elog(ERROR, "codesystem: cannot read the revision");
   if (SPI_processed == 1) {
      bool pnull;
      Datum pd = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &pnull);
      if (!pnull) {
         char *regex = text_to_cstring(DatumGetTextPP(pd));
         e->pat = cs_pattern_compile(regex, cache_alloc, err, 256);
         if (e->pat == NULL)
            ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("code system %s revision %d: the stored pattern is not usable: %s", sysname, rev, err)));
         e->parts = cs_parts_compile(regex, cache_alloc, err, 256);
         if (e->parts != NULL && cs_parts_count(e->parts) == 0) e->parts = NULL;
         SPI_finish();
         return e;
      }
   }
   SPI_freetuptable(SPI_tuptable);

   char *csql = psprintf(
      "SELECT c.code, l.ord, c.parent FROM %scodesystem_code c JOIN %scodesystem_level l "
      "ON l.system_id = c.system_id AND l.revision = c.revision AND l.name = c.level "
      "WHERE c.system_id = $1 AND c.revision = $2 ORDER BY c.code COLLATE \"C\"", sp, sp);
   if (SPI_execute_with_args(csql, 2, argt, args, NULL, true, 0) != SPI_OK_SELECT) elog(ERROR, "codesystem: cannot read the codes");
   uint64 n = SPI_processed;
   if (n < 1) ereport(ERROR, (errmsg("code system %s revision %d has no codes in the registry", sysname, rev)));

   const char **codes = palloc(sizeof(char *) * n);
   char **parents = palloc(sizeof(char *) * n);
   e->level_of = MemoryContextAlloc(cache_cxt, n);
   e->parent = MemoryContextAlloc(cache_cxt, sizeof(uint32) * n);
   for (uint64 i = 0; i < n; i++) {
      bool isnull;
      HeapTuple t = SPI_tuptable->vals[i];
      TupleDesc d = SPI_tuptable->tupdesc;
      codes[i] = text_to_cstring(DatumGetTextPP(SPI_getbinval(t, d, 1, &isnull)));
      e->level_of[i] = (uint8) (DatumGetInt16(SPI_getbinval(t, d, 2, &isnull)) - 1);
      parents[i] = text_to_cstring(DatumGetTextPP(SPI_getbinval(t, d, 3, &isnull)));
   }
   e->pat = cs_pattern_from_list(codes, (size_t) n, cache_alloc, err, 256);
   if (e->pat == NULL)
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("code system %s revision %d: the stored codes are not usable: %s", sysname, rev, err)));
   for (uint64 i = 0; i < n; i++) {
      uint64 pr;
      if (parents[i][0] == '\0') e->parent[i] = CS_NO_PARENT;
      else if (cs_pattern_parse(e->pat, parents[i], &pr)) e->parent[i] = (uint32) pr;
      else ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                           errmsg("code system %s revision %d: the parent \"%s\" of \"%s\" is not a code", sysname, rev, parents[i], codes[i])));
   }
   SPI_finish();
   return e;
}

static Entry *get_entry (int sys, int rev) {
   check_fresh();
   for (int i = 0; i < nentries; i++)
      if (entries[i]->sys == sys && entries[i]->rev == rev) return entries[i];
   SysInfo *si = find_system_by_id(sys);
   if (si == NULL)
      ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("the code system with id %d is not defined here", sys),
                      errhint("a stored code can only be read where its code system is defined")));
   char name[64];
   strlcpy(name, si->name, sizeof name);
   Entry *e = load_entry(sys, rev, name);
   if (nentries == entries_cap) {
      int nc = entries_cap ? entries_cap * 2 : 8;
      Entry **ne = MemoryContextAlloc(cache_cxt, sizeof(Entry *) * nc);
      if (nentries) memcpy(ne, entries, sizeof(Entry *) * nentries);
      entries = ne; entries_cap = nc;
   }
   entries[nentries++] = e;
   return e;
}

static Entry *entry_of (int64 v) {
   Entry *e = get_entry(code_sys(v), code_rev(v));
   if (code_rank(v) >= e->pat->total)
      ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION), errmsg("invalid code: rank %llu is not in %s revision %d",
                      (unsigned long long) code_rank(v), e->name, e->rev)));
   return e;
}

// ---- reading and writing text ---------------------------------------------------------------------------------------
static bool is_name (const char *s, size_t n) {
   if (n == 0 || n > 63 || !(s[0] >= 'a' && s[0] <= 'z')) return false;
   for (size_t i = 1; i < n; i++)
      if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9') || s[i] == '_')) return false;
   return true;
}

// "system:CODE", or "CODE" where typmod names the system. force_sys (a name) overrides typmod.
static int64 parse_code (const char *s, int32 typmod, const char *force_sys) {
   const char *colon = strchr(s, ':');
   char qual[64] = "";
   const char *text = s;
   if (colon != NULL && is_name(s, (size_t) (colon - s))) {
      memcpy(qual, s, (size_t) (colon - s));
      qual[colon - s] = '\0';
      text = colon + 1;
   }
   SysInfo *si = NULL;
   if (force_sys != NULL) {
      si = find_system_by_name(force_sys);
      if (si == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system \"%s\" is not defined", force_sys),
                                      errhint("see the view code_systems")));
      if (qual[0] && strcmp(qual, force_sys) != 0)
         ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION), errmsg("\"%s\" is a code of %s, not %s", s, qual, force_sys)));
   } else if (typmod >= 0) {
      si = find_system_by_hash(typmod);
      if (si == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system of this column is not defined here"),
                                      errhint("restoring a dump? the codesystem_* tables must be restored before any table that has a code in it: use tools/restore.sh")));
      if (qual[0] && strcmp(qual, si->name) != 0)
         ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                         errmsg("\"%s\" is a code of %s, but this column is %s", s, qual, si->name)));
   } else {
      if (!qual[0])
         ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION), errmsg("invalid input for code: \"%s\"", s),
                         errhint("write the system with the code, 'isic_rev4:4711'; a bare code is read only from text (COPY, a text column, '4711'::text) into a column declared code('isic_rev4')")));
      si = find_system_by_name(qual);
      if (si == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system \"%s\" is not defined", qual),
                                      errhint("see the view code_systems")));
   }
   if (si->current < 1)
      ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system %s has no revision yet", si->name)));
   int sys = si->id, rev = si->current;
   char sysname[64];
   strlcpy(sysname, si->name, sizeof sysname);
   Entry *e = get_entry(sys, rev);
   uint64 rank;
   if (!cs_pattern_parse(e->pat, text, &rank))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg("\"%s\" is not a code of %s (revision %d)", text, sysname, rev)));
   return pack_code(sys, rev, rank);
}

PG_FUNCTION_INFO_V1(code_in);
Datum code_in (PG_FUNCTION_ARGS) {
   PG_RETURN_CODE(parse_code(PG_GETARG_CSTRING(0), PG_GETARG_INT32(2), NULL));
}

PG_FUNCTION_INFO_V1(code_out);
Datum code_out (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e = entry_of(v);
   char buf[CS_PAT_MAX_LEN + 1];
   cs_pattern_render(e->pat, code_rank(v), buf);
   PG_RETURN_CSTRING(psprintf("%s:%s", e->name, buf));
}

PG_FUNCTION_INFO_V1(code_text);
Datum code_text (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e = entry_of(v);
   char buf[CS_PAT_MAX_LEN + 1];
   cs_pattern_render(e->pat, code_rank(v), buf);
   PG_RETURN_TEXT_P(cstring_to_text(buf));
}

PG_FUNCTION_INFO_V1(code_recv);
Datum code_recv (PG_FUNCTION_ARGS) {
   StringInfo buf = (StringInfo) PG_GETARG_POINTER(0);
   int32 typmod = PG_GETARG_INT32(2);
   int64 v = pq_getmsgint64(buf);
   if (v < 0) ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION), errmsg("invalid code")));
   entry_of(v);
   if (typmod >= 0) {
      SysInfo *si = find_system_by_id(code_sys(v));
      if (si == NULL || si->hash != typmod)
         ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("the code is not of this column's code system")));
   }
   PG_RETURN_CODE(v);
}

PG_FUNCTION_INFO_V1(code_send);
Datum code_send (PG_FUNCTION_ARGS) {
   StringInfoData buf;
   pq_begintypsend(&buf);
   pq_sendint64(&buf, PG_GETARG_CODE(0));
   PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

// ---- the type modifier: code('isic_rev4') ---------------------------------------------------------------------------
// typmod_in holds only a hash of the name, so a restore can create the column before the registry tables are loaded.
PG_FUNCTION_INFO_V1(code_typmod_in);
Datum code_typmod_in (PG_FUNCTION_ARGS) {
   ArrayType *ta = PG_GETARG_ARRAYTYPE_P(0);
   Datum *elems;
   int n;
   deconstruct_array(ta, CSTRINGOID, -2, false, TYPALIGN_CHAR, &elems, NULL, &n);
   if (n != 1)
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("code takes one type modifier, the name of a code system"),
                      errhint("for example code('isic_rev4')")));
   char *nm = DatumGetCString(elems[0]);
   if (!is_name(nm, strlen(nm)))
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid type modifier \"%s\" for code: expected the name of a code system", nm),
                      errhint("lower case letters, digits and _, for example code('isic_rev4')")));
   PG_RETURN_INT32(name_hash(nm));
}

PG_FUNCTION_INFO_V1(code_typmod_out);
Datum code_typmod_out (PG_FUNCTION_ARGS) {
   int32 typmod = PG_GETARG_INT32(0);
   SysInfo *si = typmod >= 0 ? find_system_by_hash(typmod) : NULL;
   PG_RETURN_CSTRING(psprintf("(%s)", si ? si->name : "?"));
}

PG_FUNCTION_INFO_V1(code_name_hash);
Datum code_name_hash (PG_FUNCTION_ARGS) {
   PG_RETURN_INT32(name_hash(text_to_cstring(PG_GETARG_TEXT_PP(0))));
}

// The coercion PostgreSQL applies on the way into a column with a type modifier: the value must be of that column's system.
PG_FUNCTION_INFO_V1(code_enforce);
Datum code_enforce (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   int32 typmod = PG_GETARG_INT32(1);
   if (typmod >= 0) {
      SysInfo *si = find_system_by_id(code_sys(v));
      if (si == NULL || si->hash != typmod) {
         SysInfo *want = find_system_by_hash(typmod);
         ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH), errmsg("%s is not a code of %s",
                         DatumGetCString(DirectFunctionCall1(code_out, Int64GetDatum(v))), want ? want->name : "this column's code system")));
      }
   }
   PG_RETURN_CODE(v);
}

PG_FUNCTION_INFO_V1(code_cast_text);
Datum code_cast_text (PG_FUNCTION_ARGS) {
   PG_RETURN_CODE(parse_code(text_to_cstring(PG_GETARG_TEXT_PP(0)), PG_GETARG_INT32(1), NULL));
}

PG_FUNCTION_INFO_V1(code_from);
Datum code_from (PG_FUNCTION_ARGS) {
   PG_RETURN_CODE(parse_code(text_to_cstring(PG_GETARG_TEXT_PP(0)), -1, text_to_cstring(PG_GETARG_TEXT_PP(1))));
}

PG_FUNCTION_INFO_V1(code_is_valid);
Datum code_is_valid (PG_FUNCTION_ARGS) {
   if (PG_ARGISNULL(0) || PG_ARGISNULL(1)) PG_RETURN_BOOL(false);
   char *sysname = text_to_cstring(PG_GETARG_TEXT_PP(1));
   SysInfo *si = find_system_by_name(sysname);
   if (si == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system \"%s\" is not defined", sysname)));
   if (si->current < 1) PG_RETURN_BOOL(false);
   Entry *e = get_entry(si->id, si->current);
   uint64 rank;
   PG_RETURN_BOOL(cs_pattern_parse(e->pat, text_to_cstring(PG_GETARG_TEXT_PP(0)), &rank));
}

PG_FUNCTION_INFO_V1(code_list_check);
Datum code_list_check (PG_FUNCTION_ARGS) {
   ArrayType *a = PG_GETARG_ARRAYTYPE_P(0);
   Datum *elems; bool *nulls; int n;
   deconstruct_array(a, TEXTOID, -1, false, TYPALIGN_INT, &elems, &nulls, &n);
   if (n < 1) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("the list of codes is empty")));
   const char **codes = palloc(sizeof(char *) * n);
   for (int i = 0; i < n; i++) {
      if (nulls[i]) ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED), errmsg("a code is NULL")));
      codes[i] = text_to_cstring(DatumGetTextPP(elems[i]));
   }
   char err[256];
   cs_pattern *p = cs_pattern_from_list(codes, (size_t) n, (cs_alloc_fn) palloc, err, sizeof err);
   if (p == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("the list of codes cannot be used: %s", err)));
   PG_RETURN_INT32(p->nstates);
}

// ---- comparison ------------------------------------------------------------------------------------------------------
#define CMP_FN(NAME, OP) \
   PG_FUNCTION_INFO_V1(NAME); \
   Datum NAME (PG_FUNCTION_ARGS) { PG_RETURN_BOOL(PG_GETARG_CODE(0) OP PG_GETARG_CODE(1)); }
CMP_FN(code_eq, ==)
CMP_FN(code_ne, !=)
CMP_FN(code_lt, <)
CMP_FN(code_gt, >)
CMP_FN(code_le, <=)
CMP_FN(code_ge, >=)

PG_FUNCTION_INFO_V1(code_cmp);
Datum code_cmp (PG_FUNCTION_ARGS) {
   int64 a = PG_GETARG_CODE(0), b = PG_GETARG_CODE(1);
   PG_RETURN_INT32(a < b ? -1 : a > b ? 1 : 0);
}

PG_FUNCTION_INFO_V1(code_smaller);
Datum code_smaller (PG_FUNCTION_ARGS) {
   int64 a = PG_GETARG_CODE(0), b = PG_GETARG_CODE(1);
   PG_RETURN_CODE(a < b ? a : b);
}

PG_FUNCTION_INFO_V1(code_larger);
Datum code_larger (PG_FUNCTION_ARGS) {
   int64 a = PG_GETARG_CODE(0), b = PG_GETARG_CODE(1);
   PG_RETURN_CODE(a > b ? a : b);
}

PG_FUNCTION_INFO_V1(code_hash);
Datum code_hash (PG_FUNCTION_ARGS) {
   return DirectFunctionCall1(hashint8, Int64GetDatum(PG_GETARG_CODE(0)));
}

// ---- the hierarchy ---------------------------------------------------------------------------------------------------
PG_FUNCTION_INFO_V1(code_system);
Datum code_system (PG_FUNCTION_ARGS) {
   PG_RETURN_TEXT_P(cstring_to_text(entry_of(PG_GETARG_CODE(0))->name));
}

PG_FUNCTION_INFO_V1(code_revision);
Datum code_revision (PG_FUNCTION_ARGS) {
   PG_RETURN_INT32(code_rev(PG_GETARG_CODE(0)));
}

PG_FUNCTION_INFO_V1(code_level);
Datum code_level (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e = entry_of(v);
   PG_RETURN_TEXT_P(cstring_to_text(e->level_name[e->level_of ? e->level_of[code_rank(v)] : 0]));
}

PG_FUNCTION_INFO_V1(code_parent);
Datum code_parent (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e = entry_of(v);
   if (e->parent == NULL) PG_RETURN_NULL();
   uint32 p = e->parent[code_rank(v)];
   if (p == CS_NO_PARENT) PG_RETURN_NULL();
   PG_RETURN_CODE(pack_code(e->sys, e->rev, p));
}

PG_FUNCTION_INFO_V1(code_ancestor);
Datum code_ancestor (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   char *want = text_to_cstring(PG_GETARG_TEXT_PP(1));
   Entry *e = entry_of(v);
   int target = -1;
   for (int i = 0; i < e->nlevels; i++) if (strcmp(e->level_name[i], want) == 0) target = i;
   if (target < 0)
      ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("%s has no level \"%s\"", e->name, want)));
   uint64 r = code_rank(v);
   if (e->level_of == NULL) {              // a pattern system has the one level
      if (target == 0) PG_RETURN_CODE(v);
      PG_RETURN_NULL();
   }
   while (e->level_of[r] > target) {
      uint32 p = e->parent[r];
      if (p == CS_NO_PARENT) PG_RETURN_NULL();
      r = p;
   }
   if (e->level_of[r] != target) PG_RETURN_NULL();
   PG_RETURN_CODE(pack_code(e->sys, e->rev, r));
}

PG_FUNCTION_INFO_V1(code_children);
Datum code_children (PG_FUNCTION_ARGS) {
   FuncCallContext *fc;
   if (SRF_IS_FIRSTCALL()) {
      fc = SRF_FIRSTCALL_INIT();
      MemoryContext old = MemoryContextSwitchTo(fc->multi_call_memory_ctx);
      int64 v = PG_GETARG_CODE(0);
      Entry *e = entry_of(v);
      uint64 me = code_rank(v), total = e->parent ? e->pat->total : 0, n = 0;
      for (uint64 r = 0; r < total; r++) if (e->parent[r] == me) n++;
      int64 *out = palloc(sizeof(int64) * (n ? n : 1));
      n = 0;
      for (uint64 r = 0; r < total; r++) if (e->parent[r] == me) out[n++] = pack_code(e->sys, e->rev, r);
      fc->user_fctx = out;
      fc->max_calls = n;
      MemoryContextSwitchTo(old);
   }
   fc = SRF_PERCALL_SETUP();
   if (fc->call_cntr < fc->max_calls) {
      // computed first: SRF_RETURN_NEXT advances call_cntr before it evaluates its second argument
      Datum next = Int64GetDatum(((int64 *) fc->user_fctx)[fc->call_cntr]);
      SRF_RETURN_NEXT(fc, next);
   }
   SRF_RETURN_DONE(fc);
}

PG_FUNCTION_INFO_V1(code_label);
Datum code_label (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e = entry_of(v);
   char buf[CS_PAT_MAX_LEN + 1];
   cs_pattern_render(e->pat, code_rank(v), buf);
   char *sql = psprintf("SELECT label FROM %scodesystem_code WHERE system_id = $1 AND revision = $2 AND code = $3", schema_prefix());
   Oid argt[3] = { INT2OID, INT2OID, TEXTOID };
   Datum args[3] = { Int16GetDatum(e->sys), Int16GetDatum(e->rev), CStringGetTextDatum(buf) };
   MemoryContext caller = CurrentMemoryContext;
   spi_begin();
   if (SPI_execute_with_args(sql, 3, argt, args, NULL, true, 1) != SPI_OK_SELECT) elog(ERROR, "codesystem: cannot read the label");
   text *res = NULL;
   if (SPI_processed == 1) {
      bool isnull;
      Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
      if (!isnull) {
         MemoryContext old = MemoryContextSwitchTo(caller);
         res = cstring_to_text(text_to_cstring(DatumGetTextPP(d)));
         MemoryContextSwitchTo(old);
      }
   }
   SPI_finish();
   if (res == NULL) PG_RETURN_NULL();
   PG_RETURN_TEXT_P(res);
}

// ---- pattern systems -------------------------------------------------------------------------------------------------------
static char *alloc_msg (void) { return palloc(300); }

PG_FUNCTION_INFO_V1(code_pattern_resolve);
Datum code_pattern_resolve (PG_FUNCTION_ARGS) {
   char *spec = text_to_cstring(PG_GETARG_TEXT_PP(0));
   char regex[4096], err[300];
   if (!cs_pattern_resolve(spec, regex, sizeof regex, err, sizeof err))
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid pattern \"%s\": %s", spec, err),
                      errhint("a template (N digit, A letter, X either, [ ] optional) or a regular expression between slashes")));
   cs_pattern *p = cs_pattern_compile(regex, (cs_alloc_fn) palloc, err, sizeof err);
   if (p == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid pattern \"%s\": %s", spec, err)));
   if (p->total >= ((uint64) 1 << CS_REV_SHIFT))
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("the pattern allows %llu codes, more than the 2^40 a code can number", (unsigned long long) p->total)));
   cs_parts *parts = cs_parts_compile(regex, (cs_alloc_fn) palloc, err, sizeof err);
   if (parts == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid parts in pattern \"%s\": %s", spec, err)));
   if (cs_parts_count(parts) > 0) {
      char *msg = alloc_msg();
      int r = cs_parts_check(parts, p, msg, 300);
      if (r == CS_CHECK_AMBIGUOUS)
         ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("the parts of this pattern are ambiguous: for example %s can be split in more than one way", msg),
                         errhint("a code must split into its parts one way only")));
      if (r == CS_CHECK_PARTIAL) ereport(NOTICE, (errmsg("the parts could only be checked in part: %s", msg)));
      if (r == CS_CHECK_ERROR) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("the parts of this pattern cannot be checked: %s", msg)));
   }
   PG_RETURN_TEXT_P(cstring_to_text(regex));
}

static cs_pattern *compile_stored (text *t) {
   char err[300];
   cs_pattern *p = cs_pattern_compile(text_to_cstring(t), (cs_alloc_fn) palloc, err, sizeof err);
   if (p == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid pattern: %s", err)));
   return p;
}

PG_FUNCTION_INFO_V1(code_pattern_total);
Datum code_pattern_total (PG_FUNCTION_ARGS) { PG_RETURN_INT64((int64) compile_stored(PG_GETARG_TEXT_PP(0))->total); }

PG_FUNCTION_INFO_V1(code_pattern_maxlen);
Datum code_pattern_maxlen (PG_FUNCTION_ARGS) { PG_RETURN_INT32(compile_stored(PG_GETARG_TEXT_PP(0))->maxlen); }

PG_FUNCTION_INFO_V1(code_pattern_same);
Datum code_pattern_same (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(cs_pattern_same_codes(compile_stored(PG_GETARG_TEXT_PP(0)), compile_stored(PG_GETARG_TEXT_PP(1))));
}

PG_FUNCTION_INFO_V1(code_pattern_parts);
Datum code_pattern_parts (PG_FUNCTION_ARGS) {
   char err[300];
   cs_parts *parts = cs_parts_compile(text_to_cstring(PG_GETARG_TEXT_PP(0)), (cs_alloc_fn) palloc, err, sizeof err);
   if (parts == NULL) ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("invalid parts: %s", err)));
   int n = cs_parts_count(parts);
   Datum *d = palloc(sizeof(Datum) * (n ? n : 1));
   for (int i = 0; i < n; i++) d[i] = CStringGetTextDatum(cs_parts_name(parts, i));
   PG_RETURN_ARRAYTYPE_P(construct_array(d, n, TEXTOID, -1, false, TYPALIGN_INT));
}

// The parts of a code of a pattern system. start/end are -1 for a part this code does not have.
static int split_code (int64 v, Entry **ep, char *buf, int *start, int *end) {
   Entry *e = entry_of(v);
   *ep = e;
   if (e->parts == NULL)
      ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("%s has no named parts", e->name),
                      errhint("name them in the pattern: (?<prefix>SC|NI)\\d{6}")));
   cs_pattern_render(e->pat, code_rank(v), buf);
   int r = cs_parts_match(e->parts, buf, start, end);
   if (r < 0) ereport(ERROR, (errmsg("the parts of %s:%s are too complex to split", e->name, buf)));
   if (r == 0) ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED), errmsg("%s:%s does not match its own pattern", e->name, buf)));
   return r;
}

PG_FUNCTION_INFO_V1(code_part);
Datum code_part (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   char *want = text_to_cstring(PG_GETARG_TEXT_PP(1));
   Entry *e;
   char buf[CS_PAT_MAX_LEN + 1];
   int start[CS_PAT_MAX_NAMES], end[CS_PAT_MAX_NAMES];
   split_code(v, &e, buf, start, end);
   for (int i = 0; i < cs_parts_count(e->parts); i++) {
      if (strcmp(cs_parts_name(e->parts, i), want) != 0) continue;
      if (start[i] < 0) PG_RETURN_NULL();
      PG_RETURN_TEXT_P(cstring_to_text_with_len(buf + start[i], end[i] - start[i]));
   }
   ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("%s has no part \"%s\"", e->name, want)));
   PG_RETURN_NULL();
}

PG_FUNCTION_INFO_V1(code_parts);
Datum code_parts (PG_FUNCTION_ARGS) {
   int64 v = PG_GETARG_CODE(0);
   Entry *e;
   char buf[CS_PAT_MAX_LEN + 1];
   int start[CS_PAT_MAX_NAMES], end[CS_PAT_MAX_NAMES];
   split_code(v, &e, buf, start, end);
   StringInfoData js;
   initStringInfo(&js);
   appendStringInfoChar(&js, '{');
   bool first = true;
   for (int i = 0; i < cs_parts_count(e->parts); i++) {
      if (start[i] < 0) continue;
      if (!first) appendStringInfoChar(&js, ',');
      first = false;
      appendStringInfo(&js, "\"%s\":\"", cs_parts_name(e->parts, i));
      for (int k = start[i]; k < end[i]; k++) {
         if (buf[k] == '"' || buf[k] == '\\') appendStringInfoChar(&js, '\\');
         appendStringInfoChar(&js, buf[k]);
      }
      appendStringInfoChar(&js, '"');
   }
   appendStringInfoChar(&js, '}');
   return DirectFunctionCall1(jsonb_in, CStringGetDatum(js.data));
}

// ---- ranges: the codes that start with some text are consecutive ----------------------------------------------------------
static bool prefix_range (const char *prefix, const char *sysname, int *sys, int *rev, uint64 *lo, uint64 *hi) {
   SysInfo *si = find_system_by_name(sysname);
   if (si == NULL) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system \"%s\" is not defined", sysname)));
   if (si->current < 1) ereport(ERROR, (errcode(ERRCODE_UNDEFINED_OBJECT), errmsg("the code system %s has no revision yet", si->name)));
   *sys = si->id; *rev = si->current;
   Entry *e = get_entry(*sys, *rev);
   bool unbounded = false;
   uint64 h = 0;
   if (!cs_pattern_range(e->pat, prefix, lo, &h, &unbounded)) return false;
   *hi = unbounded ? e->pat->total : h;
   return true;
}

// The first and last code of a system that start with some text. BETWEEN the two is every such code, in any index:
//    WHERE crn BETWEEN code_first_with_prefix('SC', 'uk_crn') AND code_last_with_prefix('SC', 'uk_crn')
PG_FUNCTION_INFO_V1(code_first_with_prefix);
Datum code_first_with_prefix (PG_FUNCTION_ARGS) {
   int sys, rev; uint64 lo, hi;
   if (!prefix_range(text_to_cstring(PG_GETARG_TEXT_PP(0)), text_to_cstring(PG_GETARG_TEXT_PP(1)), &sys, &rev, &lo, &hi)) PG_RETURN_NULL();
   PG_RETURN_CODE(pack_code(sys, rev, lo));
}

PG_FUNCTION_INFO_V1(code_last_with_prefix);
Datum code_last_with_prefix (PG_FUNCTION_ARGS) {
   int sys, rev; uint64 lo, hi;
   if (!prefix_range(text_to_cstring(PG_GETARG_TEXT_PP(0)), text_to_cstring(PG_GETARG_TEXT_PP(1)), &sys, &rev, &lo, &hi)) PG_RETURN_NULL();
   PG_RETURN_CODE(pack_code(sys, rev, hi - 1));
}
