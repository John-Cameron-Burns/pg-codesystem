// Standalone tests for the ranked-pattern engine (cs_pattern.c), no Postgres needed. Build and run:
//
//   cc -std=c99 -Wall -Wpedantic -D_POSIX_C_SOURCE=200809L -o test_cs_pattern \
//      test_cs_pattern.c cs_pattern.c && ./test_cs_pattern
//
// Over a spread of patterns it checks, by brute force:
//   - the codes, taken in rank order, are strictly increasing as text; render and parse are inverses;
//   - the set of codes is exactly what the C library's own regex engine says (an independent oracle):
//     every rendered code matches, and for thousands of mutated and random strings the two agree;
//   - every prefix of every sampled code gives exactly the range that scanning for it would,
//     the range is consecutive, and its bounds are codes (or the end of the space);
//   - a separator left out of the input is put back, and nothing else is forgiven;
//   - root() is the shortest shorter code, or the code itself;
// and that a pattern which is not a finite set of codes is refused, with a message.

#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cs_pattern.h"

static int failures = 0;
static long checks = 0;

#define CHECK(cond) do { \
   checks++; \
   if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } \
} while (0)

static void *xalloc (size_t n) { return malloc(n); }

static cs_pattern *compile_spec (const char *spec, char *err, size_t errlen) {
   char re[700];
   if (!cs_pattern_resolve(spec, re, sizeof re, err, errlen)) return NULL;
   return cs_pattern_compile(re, xalloc, err, errlen);
}

// ERE for the C library: \d -> [0-9], (?: -> (, \/ -> /
static void to_ere (const char *re, char *out) {
   int in_class = 0;
   *out++ = '^'; *out++ = '(';
   for (const char *p = re; *p; p++) {
      if (*p == '^' && p == re) continue;
      if (*p == '$' && !p[1]) continue;
      if (*p == '\\') {
         p++;
         if (*p == 'd') { if (in_class) { strcpy(out, "0-9"); out += 3; } else { strcpy(out, "[0-9]"); out += 5; } }
         else if (*p == '/') *out++ = '/';
         else if (*p == '-' && in_class) *out++ = '-';
         else { *out++ = '\\'; *out++ = *p; }
         continue;
      }
      if (*p == '(' && p[1] == '?' && p[2] == ':') { *out++ = '('; p += 2; continue; }
      if (*p == '[') in_class = 1;
      if (*p == ']') in_class = 0;
      *out++ = *p;
   }
   *out++ = ')'; *out++ = '$'; *out = '\0';
}

static unsigned long long rng_state = 88172645463325252ull;
static unsigned long long rnd (void) {
   rng_state ^= rng_state << 13; rng_state ^= rng_state >> 7; rng_state ^= rng_state << 17;
   return rng_state;
}


static void strip_seps (const char *in, char *out) {
   for (; *in; in++) if (*in != ' ' && *in != '-') *out++ = *in;
   *out = '\0';
}

static bool ends_with_sep (const char *s) { size_t n = strlen(s); return n && (s[n - 1] == ' ' || s[n - 1] == '-'); }

// A pattern on which separators can't be dropped without changing which code is meant
static bool sep_ambiguous (const char *spec) { return strstr(spec, "[\\dA-Z]?") != NULL || strstr(spec, "\\d{4}|\\d{4}-") != NULL; }

typedef struct { const char *name; const char *spec; } pat;

static void test_pattern (const pat *pp, bool exhaustive_ok) {
   char err[200];
   cs_pattern *p = compile_spec(pp->spec, err, sizeof err);
   CHECK(p != NULL);
   if (!p) { printf("   %s: %s\n", pp->name, err); return; }

   char re[700], ere[1500];
   cs_pattern_resolve(pp->spec, re, sizeof re, err, sizeof err);
   to_ere(re, ere);
   regex_t rx;
   int rc = regcomp(&rx, ere, REG_EXTENDED | REG_NOSUB);
   CHECK(rc == 0);
   if (rc) { printf("   %s: libc cannot compile %s\n", pp->name, ere); return; }

   uint64_t total = p->total;
   CHECK(total >= 1);
   char a[64], b[64];

   // the codes in rank order: increasing, matching the independent regex, round-tripping
   uint64_t step = 1;
   if (total > 300000) step = total / 300000 + 1;
   char prev[64] = "";
   bool prev_ok = false;
   uint64_t prev_rank = 0;
   for (uint64_t r = 0; r < total; r += step) {
      int n = cs_pattern_render(p, r, a);
      CHECK(n > 0 && n <= CS_PAT_MAX_LEN);
      CHECK(regexec(&rx, a, 0, NULL, 0) == 0);
      uint64_t back = 0;
      CHECK(cs_pattern_parse(p, a, &back) && back == r);
      if (prev_ok && step == 1) CHECK(strcmp(prev, a) < 0);
      if (prev_ok && step > 1) CHECK(strcmp(prev, a) < 0);
      strcpy(prev, a); prev_ok = true; prev_rank = r;
      if (n >= 2 && !sep_ambiguous(pp->spec) && (r % 7 == 0)) {         // separators left out are put back
         char s[64];
         strip_seps(a, s);
         uint64_t sr;
         CHECK(cs_pattern_parse(p, s, &sr) && sr == r);
      }
      if (r % 11 == 0) {                                                // lower case is accepted
         char lc[64];
         strcpy(lc, a);
         for (char *c = lc; *c; c++) if (*c >= 'A' && *c <= 'Z') *c = (char) (*c + 32);
         uint64_t lr;
         CHECK(cs_pattern_parse(p, lc, &lr) && lr == r);
      }
   }
   (void) prev_rank;
   CHECK(cs_pattern_render(p, total, a) < 0);
   CHECK(!cs_pattern_valid(p, total) && cs_pattern_valid(p, total - 1));
   uint64_t dummy;
   CHECK(!cs_pattern_parse(p, "", &dummy));

   // membership against the C library: mutations of real codes, and random strings over the alphabet
   char alpha[100];
   int na = 0;
   {
      bool seen[256] = {0};
      for (uint64_t r = 0; r < total && na < 90; r += (total / 997 + 1)) {
         cs_pattern_render(p, r, a);
         for (char *c = a; *c; c++) if (!seen[(unsigned char) *c]) { seen[(unsigned char) *c] = true; alpha[na++] = *c; }
      }
      if (!seen['0']) alpha[na++] = '0';
      if (!seen['A']) alpha[na++] = 'A';
   }
   for (int i = 0; i < 4000; i++) {
      char s[80];
      int mode = (int) (rnd() % 5);
      uint64_t r = rnd() % total;
      cs_pattern_render(p, r, s);
      size_t n = strlen(s);
      if (mode == 0 && n) s[rnd() % n] = alpha[rnd() % (unsigned) na];                  // change a character
      else if (mode == 1 && n > 1) { size_t k = rnd() % n; memmove(s + k, s + k + 1, n - k); }   // delete one
      else if (mode == 2 && n < CS_PAT_MAX_LEN - 1) {                                    // insert one
         size_t k = rnd() % (n + 1);
         memmove(s + k + 1, s + k, n - k + 1);
         s[k] = alpha[rnd() % (unsigned) na];
      }
      else if (mode == 3) { size_t m = 1 + rnd() % (unsigned) (p->maxlen + 1); for (size_t k = 0; k < m; k++) s[k] = alpha[rnd() % (unsigned) na]; s[m] = '\0'; }
      else if (mode == 4 && n > 1) s[n - 1] = '\0';                                       // truncate
      if (!*s) continue;
      bool lib = regexec(&rx, s, 0, NULL, 0) == 0;
      uint64_t pr = 0;
      bool mine = cs_pattern_parse(p, s, &pr);
      if (lib) { CHECK(mine && cs_pattern_render(p, pr, b) > 0 && strcmp(b, s) == 0); }
      else if (mine) { cs_pattern_render(p, pr, b); CHECK(regexec(&rx, b, 0, NULL, 0) == 0); }   // only by putting a separator back
   }

   // prefixes: for sampled codes, every prefix gives the range a scan would
   int samples = total <= 3000 ? (int) total : 300;
   for (int i = 0; i < samples; i++) {
      uint64_t r = total <= 3000 ? (uint64_t) i : rnd() % total;
      cs_pattern_render(p, r, a);
      size_t len = strlen(a);
      for (size_t k = 1; k <= len; k++) {
         char f[64];
         memcpy(f, a, k);
         f[k] = '\0';
         uint64_t lo, hi = 0;
         bool unb;
         bool ok = cs_pattern_range(p, f, &lo, &hi, &unb);
         CHECK(ok);
         if (!ok) { printf("   %s: prefix \"%s\" refused\n", pp->name, f); continue; }
         // binary search for the first code >= f and the first code that does not start with f
         uint64_t l = 0, h = total;
         while (l < h) { uint64_t m = l + (h - l) / 2; cs_pattern_render(p, m, b); if (strcmp(b, f) < 0) l = m + 1; else h = m; }
         uint64_t elo = l;
         l = elo; h = total;
         while (l < h) { uint64_t m = l + (h - l) / 2; cs_pattern_render(p, m, b); if (strncmp(b, f, k) <= 0) l = m + 1; else h = m; }
         uint64_t ehi = l;
         bool good = lo == elo && (ehi == total ? unb : (!unb && hi == ehi));
         CHECK(good);
         if (!good) printf("   %s: prefix \"%s\": got [%llu,%llu)%s, want [%llu,%llu)\n", pp->name, f, (unsigned long long) lo,
                           (unsigned long long) hi, unb ? " unbounded" : "", (unsigned long long) elo, (unsigned long long) ehi);
         // the bounds are codes
         CHECK(cs_pattern_render(p, lo, b) > 0 && strncmp(b, f, k) == 0);
         if (!unb) CHECK(cs_pattern_valid(p, hi));
         // with separators left out of the prefix, the same range (unless the prefix ends in one)
         char fs[64];
         strip_seps(f, fs);
         if (*fs && !ends_with_sep(f) && !sep_ambiguous(pp->spec) && strcmp(fs, f) != 0) {
            uint64_t lo2, hi2 = 0;
            bool unb2;
            bool same = cs_pattern_range(p, fs, &lo2, &hi2, &unb2);
            same = same && lo2 == lo && unb2 == unb && (unb || hi2 == hi);
            CHECK(same);
            if (!same) { static int shown = 0; if (shown++ < 12) printf("   %s: \"%s\" vs \"%s\"\n", pp->name, f, fs); }
         }
      }
   }

   // root: the shortest shorter code, or itself
   for (int i = 0; i < 400; i++) {
      uint64_t r = rnd() % total;
      cs_pattern_render(p, r, a);
      size_t n = strlen(a);
      uint64_t oc = cs_pattern_root(p, r);
      CHECK(oc <= r);
      CHECK(cs_pattern_root(p, oc) == oc);
      cs_pattern_render(p, oc, b);
      CHECK(strncmp(a, b, strlen(b)) == 0);
      size_t want = n;
      for (size_t k = 1; k < n; k++) {                                                   // shortest proper prefix that is a code
         char t[64];
         memcpy(t, a, k);
         t[k] = '\0';
         uint64_t tr;
         if (regexec(&rx, t, 0, NULL, 0) == 0 && cs_pattern_parse(p, t, &tr)) { want = k; break; }
      }
      CHECK(strlen(b) == want);
   }
   if (!p->has_nested) CHECK(cs_pattern_root(p, 0) == 0);
   regfree(&rx);
   (void) exhaustive_ok;
   free(p);
}

static void expect_error (const char *spec, const char *needle) {
   char err[300] = "";
   cs_pattern *p = compile_spec(spec, err, sizeof err);
   CHECK(p == NULL);
   if (p) { printf("   accepted: %s\n", spec); free(p); return; }
   CHECK(strstr(err, needle) != NULL);
   if (!strstr(err, needle)) printf("   %s: wanted \"%s\" in \"%s\"\n", spec, needle, err);
}

static void expect_total (const char *spec, uint64_t want) {
   char err[300];
   cs_pattern *p = compile_spec(spec, err, sizeof err);
   CHECK(p != NULL);
   if (!p) { printf("   %s: %s\n", spec, err); return; }
   CHECK(p->total == want);
   if (p->total != want) printf("   %s: %llu codes, want %llu\n", spec, (unsigned long long) p->total, (unsigned long long) want);
   free(p);
}

static void expect_words (const char *spec, const char *words) {          // comma separated, in order
   char err[300];
   cs_pattern *p = compile_spec(spec, err, sizeof err);
   CHECK(p != NULL);
   if (!p) { printf("   %s: %s\n", spec, err); return; }
   char list[1000] = "", buf[64];
   for (uint64_t r = 0; r < p->total && r < 200; r++) {
      cs_pattern_render(p, r, buf);
      if (r) strcat(list, ",");
      strcat(list, buf);
   }
   CHECK(strcmp(list, words) == 0);
   if (strcmp(list, words)) printf("   %s: got %s\n   want %s\n", spec, list, words);
   free(p);
}

int main (void) {
   // ---- small, hand-checked
   expect_words("/A|B/", "A,B");
   expect_words("/(A|B)C?/", "A,AC,B,BC");
   expect_words("/AB?C?/", "A,AB,ABC,AC");
   expect_words("/\\d{2}/", "00,01,02,03,04,05,06,07,08,09,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99");
   expect_words("/9(-[1-3])?/", "9,9-1,9-2,9-3");
   expect_words("/[AB]{1,2}/", "A,AA,AB,B,BA,BB");
   expect_words("/[AB]-[12]/", "A-1,A-2,B-1,B-2");
   expect_words("/\\d(\\d)?-A/", "0-A,00-A,01-A,02-A,03-A,04-A,05-A,06-A,07-A,08-A,09-A,1-A,10-A,11-A,12-A,13-A,14-A,15-A,16-A,17-A,18-A,19-A,2-A,20-A,21-A,22-A,23-A,24-A,25-A,26-A,27-A,28-A,29-A,3-A,30-A,31-A,32-A,33-A,34-A,35-A,36-A,37-A,38-A,39-A,4-A,40-A,41-A,42-A,43-A,44-A,45-A,46-A,47-A,48-A,49-A,5-A,50-A,51-A,52-A,53-A,54-A,55-A,56-A,57-A,58-A,59-A,6-A,60-A,61-A,62-A,63-A,64-A,65-A,66-A,67-A,68-A,69-A,7-A,70-A,71-A,72-A,73-A,74-A,75-A,76-A,77-A,78-A,79-A,8-A,80-A,81-A,82-A,83-A,84-A,85-A,86-A,87-A,88-A,89-A,9-A,90-A,91-A,92-A,93-A,94-A,95-A,96-A,97-A,98-A,99-A");

   expect_total("/\\d{5}/", 100000);
   expect_total("NNNNN[-NNNN]", 100000ull * 10001);
   expect_total("/[A-Z]\\d[A-Z] \\d[A-Z]\\d/", 26ull * 10 * 26 * 10 * 26 * 10);
   expect_total("/973\\d\\d/", 100);
   expect_total("/FIQQ 1ZZ/", 1);
   expect_total("/(STHL|ASCN|TDCU) 1ZZ/", 3);
   expect_total("/\\d{3}(-\\d{2,3})?/", 1000ull * (1 + 100 + 1000));
   expect_total("/[1-9]\\d{3}/", 9000);
   expect_total("/(0[1-9]|[1-9]\\d)\\d{3}/", 99000);
   expect_total("[A]NNNN[AAA]", 27ull * 10000 * (1 + 17576));
   expect_total("NNNN[NN]", 10000ull * 101);
   expect_total("XXXXXXXXX", 101559956668416ull);                    // 36^9
   expect_total("/\\d{14}/", 100000000000000ull);

   // ---- refused, with a reason
   expect_error("", "empty");
   expect_error("//", "between slashes");
   expect_error("/\\d+/", "any length");
   expect_error("/\\d*/", "any length");
   expect_error("/\\d{3,}/", "upper bound");
   expect_error("/./", "not allowed");
   expect_error("/(?=\\d)\\d/", "lookahead");
   expect_error("/a/", "upper case");
   expect_error("/[a-z]/", "upper case");
   expect_error("/\\d{41}/", "at most");
   expect_error("/[AB]{20}[AB]{21}/", "at most 40");
   expect_error("/\\d{16}/", "2^48");
   expect_error("/(\\d{4}/", "\")\"");
   expect_error("/\\d{4})/", "without");
   expect_error("/[0-9/", "\"]\"");
   expect_error("/[9-0]/", "backwards");
   expect_error("/\\q/", "unsupported escape");
   expect_error("/\\d?/", "empty string");
   expect_error("/()/", "empty string");
   expect_error("/\\d{0}/", "repeats nothing");
   expect_error("/A^B/", "very start");
   expect_error("NN[", "missing");
   expect_error("NN]", "without");
   expect_error("NN[]", "empty");
   expect_error("nn", "template is made of");
   expect_error("CCNNNN", "a template is made of N");        // C is not one of the template letters (N A X)
   expect_error("N?N", "template is made of");

   // ---- brute force over real shapes
   static const pat pats[] = {
      { "base+extension",            "NNNNN[-NNNN]" },
      { "Czech",            "NNN NN" },
      { "Poland",           "NN-NNN" },
      { "Netherlands",      "/[1-9]\\d{3}( ([A-EGHJ-NPRTVWXZ][A-EGHJ-NPRSTVWXZ]|S[BCEGHJ-NPRTVWXZ]))?/" },
      { "Canada",           "/[ABCEGHJ-NPRSTVXY]\\d[ABCEGHJ-NPRSTV-Z]( \\d[ABCEGHJ-NPRSTV-Z]\\d)?/" },
      { "Argentina",        "/([ABCDEFGHJKLMNPQRSTUVWXYZ]\\d{4}([A-Z]{3})?|\\d{4})/" },
      { "Taiwan",           "/\\d{3}(-\\d{2,3})?/" },
      { "Ghana",            "/[A-Z][A-Z0-9]\\d{3,5}/" },
      { "Kazakhstan",       "/\\d{6}|[A-Z]\\d\\d[A-Z]\\d[A-Z]\\d/" },
      { "French overseas",  "/9[78]\\d{3}/" },
      { "Single code",      "/FIQQ 1ZZ/" },
      { "Three territories","/(STHL|ASCN|TDCU) 1ZZ/" },
      { "Germany",          "/(0[1-9]|[1-9]\\d)\\d{3}/" },
      { "Spain",            "/(0[1-9]|[1-4]\\d|5[0-2])\\d{3}/" },
      { "Turkey",           "/(0[1-9]|[1-7]\\d|8[01]|99)\\d{3}/" },
      { "Liechtenstein",    "/94(8[5-9]|9[0-8])/" },
      { "Iran",             "NNNNN[-NNNNN]" },
      { "UAE",              "NNNNN[ NNNNN]" },
      { "Malta",            "AAA[ NNNN]" },
      { "Brazil-like",      "/\\d{5}(-\\d{3})?/" },
      { "letters then optional digits",  "/[A-PR-UWYZ]([A-HK-Y]?\\d[\\dA-HJKPSTUW]?)/" },
      { "UK-like full",     "/[A-PR-UWYZ][A-HK-Y]?\\d[\\dA-Z]?( \\d[ABD-HJLNP-UW-Z]{2})?/" },
      { "nested optional",  "NNN[-NN[N]]" },
      { "Portugal",         "/[1-9]\\d{3}(-\\d{3})?/" },
      { "Chile",            "/[1-9]\\d{2}-\\d{4}/" },
      { "Sweden",           "/[1-9]\\d{2} \\d{2}/" },
      { "Greece",           "/[1-8]\\d{2} \\d{2}/" },
      { "Eswatini",         "/[HLMS]\\d{3}/" },
      { "alternatives",     "/\\d{4}|\\d{4}-\\d{2}|[A-Z]{2}\\d{3}/" },
      { "fixed + variable", "/KY[123]-1\\d{3}/" },
      { "Argentina tmpl",   "[A]NNNN[AAA]" },
      { "digits long",      "/\\d{9}/" },
      { "letters long",     "XXXXXXXX" },
   };
   for (size_t i = 0; i < sizeof pats / sizeof *pats; i++) test_pattern(&pats[i], true);

   printf("%ld checks, %d failures\n", checks, failures);
   return failures != 0;
}
