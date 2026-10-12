#!/usr/bin/env python3
"""UK SOC 2020, from the ONS "Extended SOC 2020 framework" (Extended_SOC_framework.csv) -> two prepared files.

The file has a title line, a header (Unique ID, Major Group, Sub-Major Group, Minor Group, Unit Group, Sub-Unit Group, Group Title)
and one row per group, the code in the column of its level and the other level columns empty. The first four levels are SOC 2020
itself (9, 26, 104 and 412 groups); the fifth, the sub-unit group (1111/01), is the ONS extension. They become two systems, so
that the standard is not mixed with the extension: uk_soc_2020 (four levels) and uk_soc_2020_extended (all five, refining it).

usage: prepare_soc.py SOURCE.csv OUT_SOC.csv OUT_EXTENDED.csv
"""
import csv
import sys
from csmodel import Level, Report, validate, write_csv, summary

BASE = "uk_soc_2020"
EXTENDED = "uk_soc_2020_extended"
LEVELS = [
    Level("major", 1, "[0-9]", "none", 9),
    Level("sub_major", 2, "[0-9]", "prefix", 26),
    Level("minor", 3, "[0-9]", "prefix", 104),
    Level("unit", 4, "[0-9]", "prefix", 412),
    Level("sub_unit", 7, "[0-9/]", "prefix", 1384),
]
HEADER = ["Unique ID", "Major Group", "Sub-Major Group", "Minor Group", "Unit Group", "Sub-Unit Group", "Group Title"]


def prepare(path):
    report = Report()
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        next(reader)                                  # the title line
        header = [h.strip() for h in next(reader)]
        if header != HEADER:
            raise SystemExit(f"{path}: expected the header {','.join(HEADER)}, found {header}")
        for n, rec in enumerate(reader, start=3):
            rec = (rec + [""] * 7)[:7]
            filled = [i for i in range(1, 6) if rec[i].strip()]
            if len(filled) != 1:
                raise SystemExit(f"{path} line {n}: expected exactly one group code, found {len(filled)}: {rec}")
            lv = LEVELS[filled[0] - 1]
            code = rec[filled[0]].strip()
            parent = "" if lv.link == "none" else code[:LEVELS[filled[0] - 2].width]
            rows.append({"code": code, "level": lv.name, "parent": parent, "label": rec[6].strip()})
    counts = validate(rows, LEVELS)
    report.notes.append("the sub-unit group code is nnnn/nn (7 characters, with a slash); its parent is the unit group before the slash")
    return rows, counts, report


def split(rows):
    base = [r for r in rows if r["level"] != "sub_unit"]
    return base, rows


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    rows, counts, report = prepare(sys.argv[1])
    base, ext = split(rows)
    write_csv(sys.argv[2], base)
    write_csv(sys.argv[3], ext)
    print(summary(EXTENDED, counts, report))
