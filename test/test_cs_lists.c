// A long list of codes written out as one pattern must denote exactly those codes. No Postgres needed:
//
//   cc -std=c99 -Wall -Wpedantic -D_POSIX_C_SOURCE=200809L -o test_cs_lists test_cs_lists.c cs_pattern.c && ./test_cs_lists
//
// A list is the thing that makes the compiled automaton large (hundreds of states, against 17 for the largest built-in
// pattern). This test guards against the compiler keeping a pointer into an array it then grows: depending on the
// platform the freed memory could still hold the right data, or the pattern could come out with codes missing.
// Run it under the sanitizers too: -fsanitize=address,undefined.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cs_pattern.h"

static int failures = 0;
static long checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { if (failures < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void *xalloc (size_t n) { return malloc(n); }

static unsigned long long rng = 0x9E3779B97F4A7C15ULL;
static unsigned rnd (unsigned n) { rng = rng * 6364136223846793005ULL + 1442695040888963407ULL; return (unsigned) ((rng >> 33) % n); }

static int cmpstr (const void *a, const void *b) { return strcmp((const char *) a, (const char *) b); }

// n distinct codes of `len` characters from `alphabet`, sorted, written as one alternation
static void one_list (int n, int len, const char *alphabet, int clustered) {
   typedef char code[16];
   code *codes = malloc(sizeof(code) * (size_t) n);
   int m = 0;
   unsigned na = (unsigned) strlen(alphabet);
   while (m < n) {
      code c;
      for (int i = 0; i < len; i++) {
         // clustered: the first characters come from a few values, as in a real hierarchy
         unsigned span = clustered && i < 2 ? (i == 0 ? 4 : 9) : na;
         c[i] = alphabet[rnd(span < na ? span : na)];
      }
      c[len] = '\0';
      int dup = 0;
      for (int k = 0; k < m && !dup; k++) dup = strcmp(codes[k], c) == 0;
      if (!dup) { strcpy(codes[m++], c); }
   }
   qsort(codes, (size_t) n, sizeof(code), cmpstr);

   size_t cap = (size_t) n * ((size_t) len + 1) + 16;
   char *re = malloc(cap);
   strcpy(re, "(?:");
   for (int k = 0; k < n; k++) { if (k) strcat(re, "|"); strcat(re, codes[k]); }
   strcat(re, ")");

   char err[200], text[64];
   cs_pattern *p = cs_pattern_compile(re, xalloc, err, sizeof err);
   CHECK(p != NULL);
   if (p) {
      CHECK(p->total == (uint64_t) n);                                   // not one code lost or invented
      long wrong = 0;
      for (int k = 0; k < n; k++) {
         uint64_t rank = 0;
         if (cs_pattern_render(p, (uint64_t) k, text) < 0 || strcmp(text, codes[k]) != 0) wrong++;   // rank k is the k-th code
         if (!cs_pattern_parse(p, codes[k], &rank) || rank != (uint64_t) k) wrong++;
      }
      CHECK(wrong == 0);
   }
   free(codes); free(re);
}

int main (void) {
   int sizes[] = { 20, 60, 150, 300, 450 };
   for (int s = 0; s < 5; s++)
      for (int rep = 0; rep < 8; rep++) {
         one_list(sizes[s], 5, "0123456789", 0);
         one_list(sizes[s], 5, "0123456789", 1);
         one_list(sizes[s], 6, "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789", 0);
      }
   printf("%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
