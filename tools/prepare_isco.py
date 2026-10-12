#!/usr/bin/env python3
"""ISCO-08 (ILO, ISCO-08 EN.csv) -> the prepared form.

The file is not what its name says, and three things about it have to be dealt with:

  * it holds FOUR versions of the classification (ISCO-08, -88, -68, -58) in one table, told apart by `ISCO_version`;
  * it is Windows-1252, not UTF-8;
  * it was apparently passed through a spreadsheet: the Armed Forces group (major group 0) has lost its leading zeros, so sub-major
    group 01 is `1`, minor group 011 is `11` and unit group 0110 is `110`. A code is a string whose width belongs to its level, so
    each is padded back to the width of its level, and every repair is reported.

One wide row per unit group (major, sub_major, minor, unit with a label each); a code at an upper level repeats on every row below
it, and its label must be the same every time.

usage: prepare_isco.py SOURCE.csv OUT.csv [VERSION]      (VERSION defaults to ISCO-08)
"""
import csv
import sys
from csmodel import Level, Report, validate, write_csv, summary

LEVELS = [
    Level("major", 1, "[0-9]", "none", 10),
    Level("sub_major", 2, "[0-9]", "prefix", 43),
    Level("minor", 3, "[0-9]", "prefix", 130),
    Level("unit", 4, "[0-9]", "prefix", 436),
]
COLUMNS = {"major": "major_label", "sub_major": "sub_major_label", "minor": "minor_label", "unit": "description"}
EXPECTED = {"ISCO-08": [10, 43, 130, 436]}


def prepare(path, version="ISCO-08"):
    report = Report()
    with open(path, newline="", encoding="cp1252") as f:
        source = list(csv.DictReader(f))
    if not source or "ISCO_version" not in source[0]:
        raise SystemExit(f"{path}: expected a column ISCO_version")
    versions = sorted({r["ISCO_version"] for r in source})
    chosen = [r for r in source if r["ISCO_version"] == version]
    if not chosen:
        raise SystemExit(f"{path}: no rows for {version}; the file has {versions}")
    report.notes.append(f"kept {len(chosen)} of {len(source)} rows ({version}); the file also holds {[v for v in versions if v != version]}")

    levels = [Level(lv.name, lv.width, lv.charset, lv.link, e) for lv, e in zip(LEVELS, EXPECTED.get(version, [None] * 4))]
    rows, label_of, repaired = [], {}, {}
    for r in chosen:
        parent = ""
        for lv in levels:
            raw = r[lv.name].strip()
            code = raw.zfill(lv.width)            # the lost leading zeros
            if code != raw:
                repaired.setdefault(lv.name, {})[raw] = code
            label = r[COLUMNS[lv.name]].strip()
            if code in label_of:
                if label_of[code] != label:
                    raise SystemExit(f"{path}: {lv.name} {code!r} is called both {label_of[code]!r} and {label!r}")
            else:
                label_of[code] = label
                rows.append({"code": code, "level": lv.name, "parent": parent, "label": label})
            parent = code
    for name, pairs in repaired.items():
        shown = ", ".join(f"{a} -> {b}" for a, b in sorted(pairs.items()))
        report.repairs.append(f"{len(pairs)} {name} code(s) had lost leading zeros: {shown}")
    counts = validate(rows, levels)
    return rows, counts, report


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    version = sys.argv[3] if len(sys.argv) == 4 else "ISCO-08"
    rows, counts, report = prepare(sys.argv[1], version)
    write_csv(sys.argv[2], rows)
    print(summary(version.lower().replace("-", "_"), counts, report))
