// probe_pattern: how well does a pattern describe a list of real identifiers?
//
//    cc -O2 -std=c99 -D_POSIX_C_SOURCE=200809L -I engine -o probe tools/probe_pattern.c engine/cs_pattern.c
//    ./probe codes.txt '\d{8}|(SC|NI)\d{6}'      (codes.txt: one code per line, sorted in byte order; the pattern is a regex without slashes)
//
// Prints the size of the universe the pattern defines, the codes it rejects (the first 15), whether every code round-trips,
// whether the ranks come out in the same order as the text (they must), and the time per parse and render.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "cs_pattern.h"
static void *al(size_t n){ return malloc(n); }
int main(int argc, char **argv) {
   const char *pat = argv[2];
   char err[256];
   cs_pattern *p = cs_pattern_compile(pat, al, err, sizeof err);
   if (!p) { printf("compile failed: %s\n", err); return 1; }
   printf("universe %llu codes, %d states, maxlen %d, %.1f bits\n", (unsigned long long) p->total, p->nstates, p->maxlen, __builtin_log2((double) p->total));
   FILE *f = fopen(argv[1], "r"); char line[128]; char back[64];
   unsigned long long n = 0, bad = 0, notsorted = 0, rt = 0, prev = 0; int first = 1; int shown = 0;
   clock_t t0 = clock();
   while (fgets(line, sizeof line, f)) {
      line[strcspn(line, "\n")] = 0; n++;
      uint64_t r;
      if (!cs_pattern_parse(p, line, &r)) { bad++; if (shown++ < 15) printf("  rejected: %s\n", line); continue; }
      cs_pattern_render(p, r, back);
      if (strcmp(back, line)) rt++;
      if (!first && r <= prev) notsorted++;
      prev = r; first = 0;
   }
   double secs = (double) (clock() - t0) / CLOCKS_PER_SEC;
   printf("%llu codes: rejected %llu, round-trip differences %llu, rank order differs from byte order %llu; %.2f s (%.0f ns per parse+render)\n", n, bad, rt, notsorted, secs, secs * 1e9 / (double) n);
   return 0;
}
