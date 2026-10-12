// Standalone tests for named parts, (?<name>...), in the ranked-pattern engine. No Postgres needed:
//
//   cc -std=c99 -Wall -Wpedantic -D_POSIX_C_SOURCE=200809L -o test_cs_parts \
//      test_cs_parts.c cs_pattern.c && ./test_cs_parts
//
// Over every code of several patterns it checks that
//   - a name changes nothing about WHICH codes exist, their order or their rank (named == stripped);
//   - the parts the engine finds are the ones the C library's own regex engine finds (an independent oracle),
//     whenever the pattern splits every code one way;
//   - a pattern that can split a code two ways is detected;
// and that malformed names are refused, with a message.

#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cs_pattern.h"

static int failures = 0;
static long checks = 0;

#define CHECK(cond) do { \
   checks++; \
   if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } \
} while (0)

static void *xalloc (size_t n) { return malloc(n); }

// The pattern as an ERE for the C library, every group capturing, and which capture is which name.
// \d -> [0-9]; (?<n> and (?: -> (
static void to_oracle (const char *re, char *out, int *capidx, int *ncap) {
   int idx = 0, n = 0;
   bool in_class = false;
   char *o = out;
   for (const char *r = re; *r; ) {
      if (*r == '\\' && r[1] == 'd') { strcpy(o, in_class ? "0-9" : "[0-9]"); o += strlen(o); r += 2; continue; }
      if (*r == '\\' && r[1]) { if (!in_class && strchr("/", r[1])) { *o++ = r[1]; r += 2; continue; } *o++ = *r++; *o++ = *r++; continue; }
      if (in_class) { if (*r == ']') in_class = false; *o++ = *r++; continue; }
      if (*r == '[') { in_class = true; *o++ = *r++; continue; }
      if (*r == '(') {
         idx++;
         *o++ = '(';
         if (r[1] == '?' && r[2] == '<') { capidx[n++] = idx; r = strchr(r, '>') + 1; continue; }
         if (r[1] == '?' && r[2] == ':') { r += 3; continue; }
         r++;
         continue;
      }
      *o++ = *r++;
   }
   *o = '\0';
   *ncap = n;
}

typedef struct { cs_pattern *pat; cs_parts *parts; regex_t rx; int capidx[CS_PAT_MAX_NAMES]; int ncap; uint64_t total; } fixture;


static bool setup (fixture *f, const char *re) {
   char err[200];
   f->pat = cs_pattern_compile(re, xalloc, err, sizeof err);
   f->parts = cs_parts_compile(re, xalloc, err, sizeof err);
   if (!f->pat || !f->parts) { printf("setup failed for %s: %s\n", re, err); failures++; return false; }
   char ere[2000];
   to_oracle(re, ere, f->capidx, &f->ncap);
   char full[2100];
   snprintf(full, sizeof full, "^(%s)$", ere);               // wrap: capture 0 is the whole, names shift by one
   for (int i = 0; i < f->ncap; i++) f->capidx[i]++;
   int rc = regcomp(&f->rx, full, REG_EXTENDED);
   if (rc) { printf("oracle regcomp failed for %s\n", re); failures++; return false; }
   f->total = f->pat->total;
   return true;
}

// Every code: engine parts == oracle parts (when the pattern is unambiguous), and the named pattern's codes
// are the stripped pattern's codes. Returns the number of codes the pattern splits two ways.
static uint64_t scan (const char *label, const char *re, bool expect_unambiguous, int show) {
   fixture f;
   if (!setup(&f, re)) return 0;
   char stripped[2000], err[200];
   cs_pattern_strip_names(re, stripped);
   cs_pattern *plain = cs_pattern_compile(stripped, xalloc, err, sizeof err);
   CHECK(plain != NULL);
   CHECK(plain && plain->total == f.total);
   CHECK(cs_parts_count(f.parts) == f.ncap);

   uint64_t ambiguous = 0, disagree = 0, shown = 0, nopart[CS_PAT_MAX_NAMES] = {0};
   char text[64], text2[64];
   for (uint64_t r = 0; r < f.total; r++) {
      int n = cs_pattern_render(f.pat, r, text);
      CHECK(n > 0);
      if (plain && r % 997 == 0) { cs_pattern_render(plain, r, text2); CHECK(strcmp(text, text2) == 0); }

      int s[CS_PAT_MAX_NAMES], e[CS_PAT_MAX_NAMES];
      int m = cs_parts_match(f.parts, text, s, e);
      CHECK(m == 1);
      if (m != 1) break;
      int amb = cs_parts_ambiguous(f.parts, text);
      CHECK(amb >= 0);
      if (amb == 1) ambiguous++;

      regmatch_t rm[CS_PAT_MAX_NAMES * 4 + 4];
      CHECK(regexec(&f.rx, text, (size_t) (f.capidx[f.ncap ? f.ncap - 1 : 0] + 2), rm, 0) == 0 || f.ncap == 0);
      bool same = true;
      for (int i = 0; i < f.ncap; i++) {
         int os = rm[f.capidx[i]].rm_so, oe = rm[f.capidx[i]].rm_eo;
         if (s[i] < 0) nopart[i]++;
         if (os != s[i] || (os >= 0 && oe != e[i])) same = false;
      }
      if (!same) {
         disagree++;
         if (shown < (uint64_t) show) {
            shown++;
            printf("      %-10s engine:", text);
            for (int i = 0; i < f.ncap; i++) printf(" %s=%.*s", cs_parts_name(f.parts, i), s[i] < 0 ? 0 : e[i] - s[i], s[i] < 0 ? "" : text + s[i]);
            printf("   posix:");
            for (int i = 0; i < f.ncap; i++) {
               int os = rm[f.capidx[i]].rm_so, oe = rm[f.capidx[i]].rm_eo;
               printf(" %s=%.*s", cs_parts_name(f.parts, i), os < 0 ? 0 : oe - os, os < 0 ? "" : text + os);
            }
            printf("\n");
         }
      }
   }
   printf("  %-34s %9llu codes, %2d parts, ambiguous=%llu, engine!=posix=%llu", label, (unsigned long long) f.total, f.ncap,
          (unsigned long long) ambiguous, (unsigned long long) disagree);
   for (int i = 0; i < f.ncap; i++) if (nopart[i]) printf("  [%s absent in %llu]", cs_parts_name(f.parts, i), (unsigned long long) nopart[i]);
   printf("\n");
   if (expect_unambiguous) { CHECK(ambiguous == 0); CHECK(disagree == 0); }
   regfree(&f.rx);
   return ambiguous;
}

static void refused (const char *re, const char *needle) {
   char err[300] = "";
   cs_parts *p = cs_parts_compile(re, xalloc, err, sizeof err);
   cs_pattern *q = cs_pattern_compile(re, xalloc, err, sizeof err);
   CHECK(p == NULL);
   CHECK(q == NULL);
   CHECK(strstr(err, needle) != NULL);
   if (!p && !strstr(err, needle)) printf("      wanted \"%s\" in: %s\n", needle, err);
}


// ---- the ambiguity check: three tiers, and the static analysis against brute force ------------------------

static unsigned long long rng = 88172645463325252ULL;
static int rnd (int n) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; return (int) ((rng >> 33) % (unsigned) n); }

static void gen_alt (char *out, int depth, int *nn);

static void gen_atom (char *out, int depth, int *nn, bool *named) {
   *named = false;
   int k = rnd(depth > 0 ? 9 : 6);
   switch (k) {
   case 0: strcat(out, "A"); break;
   case 1: strcat(out, "1"); break;
   case 2: strcat(out, "[AB]"); break;
   case 3: strcat(out, "[0-2]"); break;
   case 4: strcat(out, "\\d"); break;
   case 5: strcat(out, "[A-C]"); break;
   case 6: strcat(out, "(?:"); gen_alt(out, depth - 1, nn); strcat(out, ")"); break;
   default:
      if (*nn < 4) {
         char nm[16]; snprintf(nm, sizeof nm, "(?<p%d>", (*nn)++);
         strcat(out, nm); gen_alt(out, depth - 1, nn); strcat(out, ")"); *named = true;
      }
      else { strcat(out, "(?:"); gen_alt(out, depth - 1, nn); strcat(out, ")"); }
   }
}

static void gen_seq (char *out, int depth, int *nn) {
   int items = 1 + rnd(3);
   for (int i = 0; i < items; i++) {
      bool named;
      gen_atom(out, depth, nn, &named);
      int q = rnd(7);
      if (q == 0) strcat(out, "?");
      else if (!named && q == 1) strcat(out, "{1,2}");
      else if (!named && q == 2) strcat(out, "{0,2}");
   }
}

static void gen_alt (char *out, int depth, int *nn) {
   gen_seq(out, depth, nn);
   if (rnd(4) == 0) { strcat(out, "|"); gen_seq(out, depth, nn); }
}

static void tiers (void) {
   printf("\nthe ambiguity check\n");
   char err[200], msg[300];

   // tier 1 and 2 agree on a pattern both can do, and give an example
   {
      const char *re = "(?<a>\\d{1,2})(?<b>\\d{1,2})";
      cs_pattern *pat = cs_pattern_compile(re, xalloc, err, sizeof err);
      cs_parts *pp = cs_parts_compile(re, xalloc, err, sizeof err);
      CHECK(pat && pp);
      int r1 = cs_parts_check_exhaustive(pp, pat, msg, sizeof msg);
      char m2[300];
      int r2 = cs_parts_check_static(pp, m2, sizeof m2);
      CHECK(r1 == 1 && r2 == 1);
      printf("  ambiguous 1-2 digit pair:  exhaustive example '%s', static example '%s'\n", msg, m2);
      int s[CS_PAT_MAX_NAMES], e[CS_PAT_MAX_NAMES];
      CHECK(cs_parts_ambiguous(pp, m2) == 1 && cs_parts_match(pp, m2, s, e) == 1);   // the static example really is ambiguous
   }
   // tier 2 on a pattern too big for tier 1 (1.76 billion codes) -- unambiguous, exactly
   {
      const char *re = "(?<area>[A-Z]{1,2})(?<district>\\d[A-Z\\d]?)( (?<sector>\\d)(?<unit>[A-Z]{2}))?";
      cs_pattern *pat = cs_pattern_compile(re, xalloc, err, sizeof err);
      cs_parts *pp = cs_parts_compile(re, xalloc, err, sizeof err);
      clock_t t0 = clock();
      int r = cs_parts_check(pp, pat, msg, sizeof msg);
      printf("  UK-like, %llu codes:   result %d (0 = unambiguous, exact) in %.1f ms\n", (unsigned long long) pat->total, r, 1000.0 * (clock() - t0) / CLOCKS_PER_SEC);
      CHECK(r == CS_CHECK_UNAMBIGUOUS);
   }
   // tier 2 finds an ambiguity in a pattern of 111 million codes, without enumerating them
   {
      const char *re = "(?<a>\\d{1,4})(?<b>\\d{1,4})";
      cs_pattern *pat = cs_pattern_compile(re, xalloc, err, sizeof err);
      cs_parts *pp = cs_parts_compile(re, xalloc, err, sizeof err);
      clock_t t0 = clock();
      int r = cs_parts_check(pp, pat, msg, sizeof msg);
      printf("  1-4 digit pair, %llu codes: result %d, example '%s', in %.1f ms\n", (unsigned long long) pat->total, r, msg, 1000.0 * (clock() - t0) / CLOCKS_PER_SEC);
      CHECK(r == CS_CHECK_AMBIGUOUS);
   }
   // tier 3: many codes and a pattern with more than the allowed positions -> partial, and it says so
   {
      static char re[40000];
      strcpy(re, "(?<n>\\d{5})(?<w>(?:");
      int words = 0;
      for (int i = 0; i < 4096 && words < 500; i += 8, words++) {
         char w[8]; for (int k = 0; k < 6; k++) w[k] = (char) ('A' + ((i >> (2 * (5 - k))) & 3)); w[6] = 0;
         strcat(re, words ? "|" : ""); strcat(re, w);
      }
      strcat(re, "))");
      cs_pattern *pat = cs_pattern_compile(re, xalloc, err, sizeof err);
      cs_parts *pp = cs_parts_compile(re, xalloc, err, sizeof err);
      CHECK(pat && pp);
      if (pat && pp) {
         int r = cs_parts_check(pp, pat, msg, sizeof msg);
         printf("  %llu codes, large pattern:  result %d (2 = partial): %s\n", (unsigned long long) pat->total, r, msg);
         CHECK(r == CS_CHECK_PARTIAL);
      }
   }

   // the static analysis against brute force, over random patterns
   int tried = 0, valid = 0, amb = 0, same = 0, differ = 0, toobig = 0;
   for (int iter = 0; iter < 12000; iter++) {
      char re[400] = "";
      int nn = 0;
      gen_alt(re, 2, &nn);
      tried++;
      cs_pattern *pat = cs_pattern_compile(re, xalloc, err, sizeof err);
      cs_parts *pp = cs_parts_compile(re, xalloc, err, sizeof err);
      if (!pat || !pp || pat->total > 200000 || cs_parts_count(pp) == 0) continue;
      valid++;
      int r1 = cs_parts_check_exhaustive(pp, pat, msg, sizeof msg);
      char m2[300];
      int r2 = cs_parts_check_static(pp, m2, sizeof m2);
      if (r2 < 0) { toobig++; continue; }
      if (r1 == r2) same++;
      else { differ++; printf("  DIFFERENT for %s: exhaustive %d (%s), static %d (%s)\n", re, r1, msg, r2, m2); }
      if (r1 == 1) amb++;
      if (r2 == 1) { int sx[CS_PAT_MAX_NAMES], ex[CS_PAT_MAX_NAMES]; CHECK(cs_parts_match(pp, m2, sx, ex) == 1 && cs_parts_ambiguous(pp, m2) == 1); }
   }
   printf("  random patterns: %d tried, %d usable, %d ambiguous; static and brute force agree on %d, differ on %d (static declined %d)\n",
          tried, valid, amb, same, differ, toobig);
   CHECK(differ == 0);
   CHECK(valid > 500 && amb > 50);
}

// ---- do two patterns denote the same codes? ---------------------------------------------------------------

static bool brute_same (const cs_pattern *a, const cs_pattern *b) {
   if (a->total != b->total) return false;
   char ta[CS_PAT_MAX_LEN + 1], tb[CS_PAT_MAX_LEN + 1];
   for (uint64_t r = 0; r < a->total; r++) {
      cs_pattern_render(a, r, ta);
      cs_pattern_render(b, r, tb);
      if (strcmp(ta, tb)) return false;
   }
   return true;
}

static void same_codes_tests (void) {
   printf("\nsame codes: two patterns, one set\n");
   char err[200];
   struct { const char *a, *b; bool same; } known[] = {
      { "\\d{2}-\\d{3}", "\\d\\d-\\d\\d\\d", true },
      { "(?<a>\\d{2})-(?<b>\\d{3})", "\\d{2}-\\d{3}", true },
      { "(?<a>\\d{2})-(?<b>\\d{3})", "(?<x>\\d{2})-(?<y>\\d{3})", true },
      { "\\d{2}|[A-C]", "[A-C]|\\d{2}", true },
      { "\\d{2}", "[0-9]{2}", true },
      { "A(B|C)", "AB|AC", true },
      { "\\d{2}-\\d{3}", "\\d{2}-\\d{4}", false },
      { "\\d{2}(-\\d{3})?", "\\d{2}-\\d{3}", false },
      { "\\d{2}", "\\d{3}", false },
      { "[A-C]\\d", "[A-D]\\d", false },
      { "A\\d", "B\\d", false },
      { "\\d{1,2}", "\\d|\\d\\d", true },
      { "\\d{1,2}", "\\d{2}", false },
   };
   for (size_t i = 0; i < sizeof known / sizeof *known; i++) {
      cs_pattern *a = cs_pattern_compile(known[i].a, xalloc, err, sizeof err);
      cs_pattern *b = cs_pattern_compile(known[i].b, xalloc, err, sizeof err);
      CHECK(a && b);
      if (a && b) {
         CHECK(cs_pattern_same_codes(a, b) == known[i].same);
         CHECK(cs_pattern_same_codes(b, a) == known[i].same);
         CHECK(cs_pattern_same_codes(a, a));
         CHECK(brute_same(a, b) == known[i].same);
      }
   }

   // random pairs, against brute force: a pattern and set-preserving rewrites of it, and unrelated patterns
   int pairs = 0, equal = 0, wrong = 0;
   for (int iter = 0; iter < 8000; iter++) {
      char re[400] = "", w1[420], w2[420], w3[420];
      int nn = 0;
      gen_alt(re, 2, &nn);
      cs_pattern *a = cs_pattern_compile(re, xalloc, err, sizeof err);
      if (!a || a->total > 100000) continue;

      snprintf(w1, sizeof w1, "(?:%s)", re);                       // wrapped
      char *o = w2;                                                // \d written as a class
      for (const char *r = re; *r; r++) { if (r[0] == '\\' && r[1] == 'd') { strcpy(o, "[0-9]"); o += 5; r++; } else *o++ = *r; }
      *o = '\0';
      cs_pattern_strip_names(re, w3);                               // names removed
      char other[400] = ""; int nn2 = 0;
      gen_alt(other, 2, &nn2);
      const char *variants[] = { w1, w2, w3, other };
      for (int v = 0; v < 4; v++) {
         cs_pattern *b = cs_pattern_compile(variants[v], xalloc, err, sizeof err);
         if (!b || b->total > 100000) continue;
         pairs++;
         bool truth = brute_same(a, b);
         if (truth) equal++;
         if (cs_pattern_same_codes(a, b) != truth) { wrong++; printf("  WRONG for %s vs %s (truth %d)\n", re, variants[v], truth); }
      }
   }
   printf("  random pairs: %d compared (%d with the same codes), %d wrong\n", pairs, equal, wrong);
   CHECK(wrong == 0);
   CHECK(pairs > 3000 && equal > 1500);
}

int main (void) {
   printf("named parts: every code against the C library's regex engine\n");

   // a small UK-shaped pattern, optional incode
   scan("UK-like (area district sector unit)",
        "(?<area>[A-C]{1,2})(?<district>\\d[A-D\\d]?)( (?<sector>\\d)(?<unit>[A-B]{2}))?", true, 3);
   // SIC-like: a hierarchy as sequential parts
   scan("SIC-like (division..subclass)",
        "(?<division>\\d{2})(?<group>\\d)(?<class>\\d)(?<subclass>\\d)", true, 3);
   // alternation: exactly one branch's part is present
   scan("alternation (numeric | alnum)",
        "(?<numeric>\\d{4})|(?<alnum>[A-C]\\d[A-C]\\d)", true, 3);
   // nesting: the parent part includes its children
   scan("nested (code > major, minor)",
        "(?<code>(?<major>\\d{2})(?<minor>\\d{2})?)", true, 3);
   // an optional part between fixed text
   scan("optional (nl-like: digits, letters)",
        "(?<digits>[1-3]\\d{3})( (?<letters>[A-C]{2}))?", true, 3);

   printf("\nambiguity: a pattern that can split one code two ways\n");
   uint64_t a1 = scan("(?<a>[A-C]{1,2})(?<b>[A-C]?\\d)", "(?<a>[A-C]{1,2})(?<b>[A-C]?\\d)", false, 4);
   uint64_t a2 = scan("(?<a>\\d{1,2})(?<b>\\d{1,2})", "(?<a>\\d{1,2})(?<b>\\d{1,2})", false, 4);
   uint64_t a3 = scan("(?<a>\\d{2})(?<b>\\d{1,2})", "(?<a>\\d{2})(?<b>\\d{1,2})", false, 4);
   CHECK(a1 > 0); CHECK(a2 > 0); CHECK(a3 == 0);

   printf("\nbadly formed names are refused\n");
   refused("(?<a>\\d)(?<a>\\d)", "used twice");
   refused("(?<a>\\d){2}", "cannot be repeated");
   refused("(?<a>\\d){1,3}", "cannot be repeated");
   refused("(?<a>\\d?)", "can match nothing");
   refused("(?<a>(\\d)?)", "can match nothing");
   refused("(?<=a)\\d", "lookbehind");
   refused("(?<Name>\\d)", "lower case");
   refused("(?<1a>\\d)", "lower case");
   refused("(?<>\\d)", "needs a name");
   refused("(?<a\\d)", "lower case");
   refused("(?<abcdefghijklmnopqrstuvwxyzabcdefg>\\d)", "at most 32");
   refused("(?!a)\\d", "named parts");
   {
      char re[600] = "";
      for (int i = 0; i < 17; i++) { char t[20]; snprintf(t, sizeof t, "(?<p%d>\\d)", i); strcat(re, t); }
      refused(re, "at most 16");
   }
   {  // ? is allowed on a part, and a part inside an alternation, and an unnamed repeat around nothing named
      char err[200];
      CHECK(cs_parts_compile("(?<a>\\d)?\\d", xalloc, err, sizeof err) != NULL);
      CHECK(cs_parts_compile("(?<a>\\d{2})|(?<b>\\d{3})", xalloc, err, sizeof err) != NULL);
      CHECK(cs_parts_compile("\\d{2,3}(?<a>\\d)", xalloc, err, sizeof err) != NULL);
   }

   printf("\nstrip_names leaves everything else alone\n");
   {
      char out[200];
      cs_pattern_strip_names("(?<a>\\d)(?:x)([(?<q>])(\\()", out);   CHECK(strcmp(out, "(?:\\d)(?:x)([(?<q>])(\\()") == 0);
      cs_pattern_strip_names("(?<area>[A-Z]{1,2})(?<d>\\d)", out);   CHECK(strcmp(out, "(?:[A-Z]{1,2})(?:\\d)") == 0);
      cs_pattern_strip_names("\\(?<a>\\d", out);                      CHECK(strcmp(out, "\\(?<a>\\d") == 0);
   }

   printf("\nnot a code, and text case\n");
   {
      char err[200]; int s[CS_PAT_MAX_NAMES], e[CS_PAT_MAX_NAMES];
      cs_parts *p = cs_parts_compile("(?<l>[A-C]{2})(?<d>\\d{2})", xalloc, err, sizeof err);
      CHECK(p && cs_parts_match(p, "AB12", s, e) == 1 && s[0] == 0 && e[0] == 2 && s[1] == 2 && e[1] == 4);
      CHECK(p && cs_parts_match(p, "ab12", s, e) == 1);                    // letters in either case
      CHECK(p && cs_parts_match(p, "AB1", s, e) == 0);
      CHECK(p && cs_parts_match(p, "AB123", s, e) == 0);
      CHECK(p && cs_parts_match(p, "", s, e) == 0);
   }

   printf("\nspeed: split every code of a 6.2M-code pattern\n");
   {
      fixture f;
      if (setup(&f, "(?<division>\\d{2})(?<group>\\d)(?<class>\\d)(?<subclass>\\d)( (?<tail>[A-B]\\d{2}))?")) {
         char text[64]; int s[CS_PAT_MAX_NAMES], e[CS_PAT_MAX_NAMES];
         clock_t t0 = clock();
         uint64_t n = 0;
         for (uint64_t r = 0; r < f.total; r += 3) { cs_pattern_render(f.pat, r, text); n++; }
         clock_t t1 = clock();
         for (uint64_t r = 0; r < f.total; r += 3) { cs_pattern_render(f.pat, r, text); cs_parts_match(f.parts, text, s, e); }
         clock_t t2 = clock();
         printf("  %llu codes: render %.0f ns each, render + split %.0f ns each (split adds %.0f ns)\n",
                (unsigned long long) n, 1e9 * (t1 - t0) / CLOCKS_PER_SEC / (double) n, 1e9 * (t2 - t1) / CLOCKS_PER_SEC / (double) n,
                1e9 * ((t2 - t1) - (t1 - t0)) / CLOCKS_PER_SEC / (double) n);
         regfree(&f.rx);
      }
   }

   tiers();
   same_codes_tests();

   printf("\n%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
