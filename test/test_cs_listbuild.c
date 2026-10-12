// Patterns built straight from a list of codes (cs_pattern_from_list). No Postgres needed:
//
//   cc -std=c99 -Wall -Wpedantic -D_POSIX_C_SOURCE=200809L -o test_cs_listbuild test_cs_listbuild.c cs_pattern.c && ./test_cs_listbuild
//
// A list-built pattern must be the same pattern as a regular expression for the same codes, only smaller:
//   - against cs_pattern_compile on the codes written as one alternation: the same codes in the same ranks (render and
//     parse), the same range for every prefix, the same root, and cs_pattern_same_codes says so;
//   - it is the SMALLEST automaton: its number of states is the number of distinct sets of endings, counted here by an
//     independent method that knows nothing about automata;
//   - a long list (tens of thousands of codes, far beyond what a pattern can hold) ranks, parses and gives prefix
//     ranges exactly as the list says, checked against the list itself;
//   - a list that is not sorted, has a duplicate, or has a code that cannot be one is refused, saying where.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cs_pattern.h"

static int failures = 0;
static long checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { if (failures < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void *xalloc (size_t n) { return malloc(n); }

static unsigned long long rng = 0x9E3779B97F4A7C15ULL;
static unsigned rnd (unsigned n) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; return (unsigned) ((rng >> 33) % n); }

static int cmp_ptr (const void *a, const void *b) { return strcmp(*(char *const *) a, *(char *const *) b); }

// sorts and drops duplicates; returns the new length
static size_t sort_unique (char **v, size_t n) {
   qsort(v, n, sizeof *v, cmp_ptr);
   size_t m = 0;
   for (size_t i = 0; i < n; i++) {
      if (m && strcmp(v[m - 1], v[i]) == 0) { free(v[i]); continue; }
      v[m++] = v[i];
   }
   return m;
}

static char *dup (const char *s) { char *d = malloc(strlen(s) + 1); strcpy(d, s); return d; }

enum { SHAPE_DIGITS, SHAPE_CLUSTERED, SHAPE_MIXED, SHAPE_ICD };

// n codes of the shape wanted (fewer if some were drawn twice), sorted
static char **make_list (size_t *np, int shape) {
   size_t n = *np;
   char **v = malloc(sizeof *v * n);
   char buf[48];
   for (size_t k = 0; k < n; k++) {
      switch (shape) {
      case SHAPE_DIGITS:
         for (int i = 0; i < 5; i++) buf[i] = (char) ('0' + rnd(10));
         buf[5] = 0; break;
      case SHAPE_CLUSTERED:                                   // a hierarchy: a few values in front, any at the end
         buf[0] = (char) ('0' + rnd(4)); buf[1] = (char) ('0' + rnd(9));
         for (int i = 2; i < 5; i++) buf[i] = (char) ('0' + rnd(10));
         buf[5] = 0; break;
      case SHAPE_MIXED: {                                     // different lengths from a small alphabet: many codes are prefixes of others
         static const char alpha[] = "AB1- ";
         int len = 1 + (int) rnd(5);
         for (int i = 0; i < len; i++) buf[i] = alpha[rnd(5)];
         buf[len] = 0; break; }
      default: {                                              // ICD-10-like: a letter, two digits, then optionally a point and one or two more
         buf[0] = (char) ('A' + rnd(26)); buf[1] = (char) ('0' + rnd(10)); buf[2] = (char) ('0' + rnd(10));
         int len = 3;
         if (rnd(6)) {
            buf[len++] = '.'; buf[len++] = (char) ('0' + rnd(10));
            if (rnd(2)) buf[len++] = rnd(5) ? (char) ('0' + rnd(10)) : 'X';
         }
         buf[len] = 0; break; }
      }
      v[k] = dup(buf);
   }
   *np = sort_unique(v, n);
   return v;
}

static void free_list (char **v, size_t n) { for (size_t i = 0; i < n; i++) free(v[i]); free(v); }

// the codes written as one alternation, for cs_pattern_compile (no code here contains a character that needs escaping)
static char *as_alternation (char **v, size_t n) {
   size_t cap = 8;
   for (size_t i = 0; i < n; i++) cap += strlen(v[i]) + 1;
   char *re = malloc(cap);
   strcpy(re, "(?:");
   for (size_t i = 0; i < n; i++) { if (i) strcat(re, "|"); strcat(re, v[i]); }
   strcat(re, ")");
   return re;
}

// The number of states in the smallest automaton for the list, by counting distinct sets of endings: for each prefix of
// each code, the set of what can follow it (the empty ending standing for "the code may stop here"); two prefixes with
// the same set are one state. Slow and obvious, which is the point.
static size_t distinct_endings (char **v, size_t n) {
   size_t maxp = 1;
   for (size_t i = 0; i < n; i++) maxp += strlen(v[i]) + 1;
   char **sets = malloc(sizeof *sets * maxp);
   size_t ns = 0;
   for (size_t i = 0; i < n; i++)
      for (size_t l = 0; l <= strlen(v[i]); l++) {
         // the endings after the prefix v[i][0..l)
         size_t cap = 16;
         for (size_t k = 0; k < n; k++) cap += strlen(v[k]) + 2;
         char *s = malloc(cap);
         size_t len = 0;
         for (size_t k = 0; k < n; k++)
            if (strncmp(v[k], v[i], l) == 0) { len += (size_t) sprintf(s + len, "%s\x01", v[k] + l); }
         s[len] = 0;
         sets[ns++] = s;
      }
   qsort(sets, ns, sizeof *sets, cmp_ptr);
   size_t distinct = 0;
   for (size_t i = 0; i < ns; i++) if (i == 0 || strcmp(sets[i], sets[i - 1]) != 0) distinct++;
   for (size_t i = 0; i < ns; i++) free(sets[i]);                   // only now: the loop above compares neighbours
   free(sets);
   return distinct;
}

// the range of the codes starting with `prefix`, from the list itself: [first index, one past the last]
static void brute_range (char **v, size_t n, const char *prefix, size_t *lo, size_t *hi) {
   size_t pl = strlen(prefix), a = 0;
   while (a < n && strncmp(v[a], prefix, pl) < 0) a++;      // first code >= prefix, in prefix order
   size_t b = a;
   while (b < n && strncmp(v[b], prefix, pl) == 0) b++;
   *lo = a; *hi = b;
}

static void equivalence (int shape, size_t want) {
   size_t n = want;
   char **v = make_list(&n, shape);
   char *re = as_alternation(v, n);
   char err[300], t1[64], t2[64];
   cs_pattern *a = cs_pattern_compile(re, xalloc, err, sizeof err);
   cs_pattern *b = cs_pattern_from_list((const char *const *) v, n, xalloc, err, sizeof err);
   CHECK(a != NULL && b != NULL);
   if (!a || !b) { if (!b) printf("  from_list: %s\n", err); free(re); free_list(v, n); return; }

   CHECK(a->total == n && b->total == n);
   CHECK(b->maxlen == a->maxlen);
   CHECK(b->has_nested == a->has_nested);
   CHECK(cs_pattern_same_codes(a, b) && cs_pattern_same_codes(b, a));
   CHECK((size_t) b->nstates <= (size_t) a->nstates);
   CHECK((size_t) b->nstates == distinct_endings(v, n));              // the smallest there can be

   long bad = 0;
   for (size_t k = 0; k < n; k++) {
      uint64_t ra = 0, rb = 0;
      if (cs_pattern_render(b, k, t1) < 0 || strcmp(t1, v[k]) != 0) bad++;           // rank k is the k-th code
      if (cs_pattern_render(a, k, t2) < 0 || strcmp(t1, t2) != 0) bad++;
      if (!cs_pattern_parse(b, v[k], &rb) || rb != k) bad++;
      if (!cs_pattern_parse(a, v[k], &ra) || ra != k) bad++;
      if (cs_pattern_root(a, k) != cs_pattern_root(b, k)) bad++;
      // every prefix of the code: the same range from both, and the one the list says
      for (size_t l = 1; l <= strlen(v[k]); l++) {
         char pre[48];
         memcpy(pre, v[k], l); pre[l] = 0;
         uint64_t loa, hia, lob, hib; bool ua, ub;
         bool oka = cs_pattern_range(a, pre, &loa, &hia, &ua), okb = cs_pattern_range(b, pre, &lob, &hib, &ub);
         if (oka != okb || loa != lob || ua != ub || (!ua && hia != hib)) bad++;
         size_t blo, bhi;
         brute_range(v, n, pre, &blo, &bhi);
         if (!okb || lob != blo || (ub ? bhi != n : hib != bhi)) bad++;
      }
   }
   CHECK(bad == 0);
   free(re); free_list(v, n);
}

static void large (size_t want) {
   size_t n = want;
   clock_t t0 = clock();
   char **v = make_list(&n, SHAPE_ICD);
   char err[300], t[64];
   clock_t t1 = clock();
   cs_pattern *b = cs_pattern_from_list((const char *const *) v, n, xalloc, err, sizeof err);
   clock_t t2 = clock();
   CHECK(b != NULL);
   if (!b) { printf("  %zu codes: %s\n", n, err); free_list(v, n); return; }
   CHECK(b->total == n);
   long bad = 0;
   for (size_t k = 0; k < n; k++) {
      uint64_t r = 0;
      if (cs_pattern_render(b, k, t) < 0 || strcmp(t, v[k]) != 0) bad++;
      if (!cs_pattern_parse(b, v[k], &r) || r != k) bad++;
   }
   CHECK(bad == 0);
   // prefix ranges for a spread of prefixes, against the list
   long rbad = 0, rchecked = 0;
   for (size_t k = 0; k < n; k += 7) {
      for (size_t l = 1; l <= strlen(v[k]); l++) {
         char pre[48];
         memcpy(pre, v[k], l); pre[l] = 0;
         uint64_t lo, hi; bool unb;
         size_t blo, bhi;
         brute_range(v, n, pre, &blo, &bhi);
         rchecked++;
         if (!cs_pattern_range(b, pre, &lo, &hi, &unb) || lo != blo || (unb ? bhi != n : hi != bhi)) rbad++;
      }
   }
   CHECK(rbad == 0);
   // what is not in the list is not a code
   long notcodes = 0;
   for (int k = 0; k < 2000; k++) {
      char junk[48];
      snprintf(junk, sizeof junk, "%c%02u.%u%u", 'A' + rnd(26), rnd(100), rnd(10), rnd(10));
      uint64_t r;
      size_t lo = 0, hi = n;
      while (lo < hi) { size_t mid = (lo + hi) / 2; if (strcmp(v[mid], junk) < 0) lo = mid + 1; else hi = mid; }
      bool inlist = lo < n && strcmp(v[lo], junk) == 0;
      if (cs_pattern_parse(b, junk, &r) != inlist) notcodes++;
   }
   CHECK(notcodes == 0);
   double mb = (double) b->nstates * (95 * 2 + 96 * 8 + 9) / 1048576.0;
   printf("  %6zu ICD-like codes: %5d states, %.1f MB, built in %.0f ms; ranks, parses, %ld prefix ranges and 2000 non-codes agree with the list\n",
          n, b->nstates, mb, 1000.0 * (t2 - t1) / CLOCKS_PER_SEC, rchecked);
   (void) t0;
   free_list(v, n);
}

static void refused (const char *const *codes, size_t n, const char *needle) {
   char err[300] = "";
   cs_pattern *p = cs_pattern_from_list(codes, n, xalloc, err, sizeof err);
   CHECK(p == NULL);
   CHECK(strstr(err, needle) != NULL);
   if (p || !strstr(err, needle)) printf("  wanted \"%s\" in: %s\n", needle, err);
}

int main (void) {
   printf("cs_pattern_from_list\n");

   // the same pattern as a regular expression, and the smallest
   int shapes[] = { SHAPE_DIGITS, SHAPE_CLUSTERED, SHAPE_MIXED };
   size_t sizes[] = { 1, 2, 5, 20, 60, 150 };
   for (int s = 0; s < 3; s++)
      for (int z = 0; z < 6; z++)
         for (int rep = 0; rep < 6; rep++)
            equivalence(shapes[s], sizes[z]);
   printf("  equivalence with the regular expression path and minimality: done\n");

   // far more than a pattern can hold
   large(5000);
   large(40000);
   large(120000);

   // the single-code and prefix-code edge cases
   {
      const char *one[] = { "A" };
      char err[200];
      cs_pattern *p = cs_pattern_from_list(one, 1, xalloc, err, sizeof err);
      CHECK(p && p->total == 1 && p->nstates == 2 && p->maxlen == 1);
      const char *pre[] = { "A", "AB", "ABC" };
      p = cs_pattern_from_list(pre, 3, xalloc, err, sizeof err);
      CHECK(p && p->total == 3 && p->has_nested);
      uint64_t r;
      CHECK(p && cs_pattern_parse(p, "ab", &r) && r == 1);                // either case, as for any pattern
   }

   // refused, with a reason
   {
      const char *unsorted[] = { "B", "A" };           refused(unsorted, 2, "does not come after");
      const char *dup2[] = { "A", "A" };               refused(dup2, 2, "without duplicates");
      const char *empty[] = { "" };                    refused(empty, 1, "is empty");
      const char *lower[] = { "ab" };                  refused(lower, 1, "upper case");
      const char *nonascii[] = { "A\xC3\xA9" };        refused(nonascii, 1, "printable ASCII");
      const char *ctrl[] = { "A\tB" };                 refused(ctrl, 1, "printable ASCII");
      const char *longc[] = { "01234567890123456789012345678901234567890" };   refused(longc, 1, "at most 40");
      refused(NULL, 0, "at least one");
   }
   {  // too many states: a list of random 8-digit codes needs more than the 16-bit transitions can number
      size_t n = 150000;
      char **v = malloc(sizeof *v * n);
      for (size_t k = 0; k < n; k++) {
         char buf[16];
         for (int i = 0; i < 8; i++) buf[i] = (char) ('0' + rnd(10));
         buf[8] = 0;
         v[k] = dup(buf);
      }
      n = sort_unique(v, n);
      refused((const char *const *) v, n, "more than 32767 states");
      free_list(v, n);
   }

   printf("\n%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
