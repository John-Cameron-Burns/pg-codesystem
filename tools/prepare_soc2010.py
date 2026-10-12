#!/usr/bin/env python3
"""ONS SOC 2010 -> ISCO-08 correspondence (ug201002soc2010toisco08v2.xls) -> the prepared form.

NOTE: this is SOC 2010, not SOC 2020. The spreadsheet's mapping sheets were exported to CSV one by one (Numbers: File > Export To >
CSV) into data/raw/soc2010_isco08/. Each mapping sheet lists a SOC 2010 unit group on the first line of a block and leaves the code
blank on the continuation lines, where a unit group maps to more than one ISCO-08 unit group:

    1to1s-Table 1.csv, "1to2 50-50-Table 1.csv", "1to2 40-60-Table 1.csv"      SOC2010, title, ISCO08, title
    Unmapped ISCO08-Table 1.csv      ISCO-08 unit groups that no SOC 2010 group maps to: used here only to check our own count

Writes uk_soc_2010.csv (a flat system of the 4-digit unit groups that appear: the file has no higher levels) and the pairs for
define_crosswalk(). The 50/50 and 40/60 splits are not kept: a pair says only that the groups correspond.

usage: prepare_soc2010.py DIR OUT_SYSTEM.csv OUT_PAIRS.csv
"""
import csv
import glob
import os
import re
import sys

SHEETS = ["1to1s-Table 1.csv", "1to2 50-50-Table 1.csv", "1to2 40-60-Table 1.csv"]
UNMAPPED = "Unmapped ISCO08-Table 1.csv"
CODE = re.compile(r"^[0-9]{4}$")


def prepare(directory):
    titles, pairs = {}, set()
    for sheet in SHEETS:
        path = os.path.join(directory, sheet)
        with open(path, newline="", encoding="utf-8-sig") as f:
            reader = csv.reader(f)
            next(reader)                                          # the header (its first cell has a line break)
            soc = None
            for n, rec in enumerate(reader, start=2):
                rec = (rec + [""] * 4)[:4]
                if not any(c.strip() for c in rec):
                    continue
                if rec[0].strip():
                    soc = rec[0].strip()
                    if not CODE.match(soc):
                        raise SystemExit(f"{path} line {n}: {soc!r} is not a SOC 2010 unit group")
                    titles[soc] = rec[1].strip()
                isco = rec[2].strip()
                if soc is None or not CODE.match(isco):
                    raise SystemExit(f"{path} line {n}: expected a SOC code before an ISCO-08 code, got {rec}")
                pairs.add((soc, isco))
    unmapped = set()
    with open(os.path.join(directory, UNMAPPED), newline="", encoding="utf-8-sig") as f:
        for rec in list(csv.reader(f))[2:]:
            if rec and CODE.match(rec[0].strip()):
                unmapped.add(rec[0].strip())
    return titles, sorted(pairs), unmapped


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    titles, pairs, unmapped = prepare(sys.argv[1])
    with open(sys.argv[2], "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["code", "level", "parent", "label"])
        for code in sorted(titles):
            w.writerow([code, "unit", "", titles[code]])
    with open(sys.argv[3], "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["from_code", "to_code"])
        w.writerows(pairs)
    iscos = {i for _, i in pairs}
    print(f"uk_soc_2010: {len(titles)} unit groups; {len(pairs)} pairs onto {len(iscos)} ISCO-08 unit groups; "
          f"the file's own unmapped list has {len(unmapped)}, overlapping the mapped ones in {len(unmapped & iscos)}")
