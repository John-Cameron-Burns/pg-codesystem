#!/usr/bin/env python3
"""ISIC Rev.4 (UN Statistics Division, ISIC_Rev_4_english_structure.Txt) -> the prepared form.

The file is `Code,Description`, UTF-8, one row per code, sections first and in order: a section letter, then its divisions,
groups and classes. Sections are a grouping of divisions, not a prefix of them, so a division's section is the section row it
follows. That is checked by the tests against the ranges the publication gives.

usage: prepare_isic.py SOURCE.Txt OUT.csv
"""
import csv
import sys
from csmodel import Level, Report, validate, write_csv, summary

SYSTEM = "isic_rev4"
LEVELS = [
    Level("section", 1, "[A-Z]", "none", 21),
    Level("division", 2, "[0-9]", "grouping", 88),
    Level("group", 3, "[0-9]", "prefix", 238),
    Level("class", 4, "[0-9]", "prefix", 419),
]
BY_WIDTH = {lv.width: lv.name for lv in LEVELS}


def prepare(path):
    report = Report()
    rows, section = [], ""
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        header = next(reader)
        if [h.strip() for h in header] != ["Code", "Description"]:
            raise SystemExit(f"{path}: expected the header Code,Description, found {header}")
        for n, rec in enumerate(reader, start=2):
            code, label = rec[0].strip(), rec[1].strip()
            level = BY_WIDTH.get(len(code))
            if level is None:
                raise SystemExit(f"{path} line {n}: {code!r} has no level (a code is 1 to 4 characters)")
            if level == "section":
                section = code
                parent = ""
            elif level == "division":
                if not section:
                    raise SystemExit(f"{path} line {n}: division {code!r} comes before any section")
                parent = section
            else:
                parent = code[:-1]
            rows.append({"code": code, "level": level, "parent": parent, "label": label})
    counts = validate(rows, LEVELS)
    report.notes.append("a section is a grouping of divisions (taken from the file's order), not a prefix of them")
    return rows, counts, report


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    rows, counts, report = prepare(sys.argv[1])
    write_csv(sys.argv[2], rows)
    print(summary(SYSTEM, counts, report))
