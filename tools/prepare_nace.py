#!/usr/bin/env python3
"""NACE Rev.2 (Eurostat RAMON, NACERev.2_EN_CTI_*_utf8.csv, the structure with titles) -> the prepared form.

The file is `;`-separated with a German header (Ebene;EDV-Code;Code;Titel;Kurztitel): the level 1-4, the code without punctuation
("A", "A01", "A011", "A0111": the section letter, then the digits of the division, group and class), the printed code ("A 01.1") and
the title. A division's section is the letter in its own code, a grouping and not a prefix of the digits; the digits of the others
extend their parent's.

usage: prepare_nace.py SOURCE.csv OUT.csv
"""
import csv
import sys
from csmodel import Level, Report, validate, write_csv, summary

SYSTEM = "nace_rev2"
LEVELS = [
    Level("section", 1, "[A-Z]", "none", 21),
    Level("division", 2, "[0-9]", "grouping", 88),
    Level("group", 3, "[0-9]", "prefix", 272),
    Level("class", 4, "[0-9]", "prefix", 615),
]
HEADER = ["Ebene", "EDV-Code", "Code", "Titel", "Kurztitel"]


def prepare(path):
    report = Report()
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f, delimiter=";")
        header = next(reader)
        if [h.strip() for h in header] != HEADER:
            raise SystemExit(f"{path}: expected the header {';'.join(HEADER)}, found {header}")
        for n, rec in enumerate(reader, start=2):
            if not rec:
                continue
            ebene, edv, label = rec[0].strip(), rec[1].strip(), rec[3].strip()
            if not ebene.isdigit() or not 1 <= int(ebene) <= len(LEVELS):
                raise SystemExit(f"{path} line {n}: level {ebene!r} is not 1 to {len(LEVELS)}")
            lv = LEVELS[int(ebene) - 1]
            if len(edv) != lv.width + (0 if lv.name == "section" else 1) or not edv[0].isalpha():
                raise SystemExit(f"{path} line {n}: {edv!r} is not a {lv.name} code")
            if lv.name == "section":
                code, parent = edv, ""
            elif lv.name == "division":
                code, parent = edv[1:], edv[0]
            else:
                code, parent = edv[1:], edv[1:-1]
            rows.append({"code": code, "level": lv.name, "parent": parent, "label": label})
    counts = validate(rows, LEVELS)
    report.notes.append("a division's section is the letter in the source's own code, not a prefix of the digits")
    return rows, counts, report


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    rows, counts, report = prepare(sys.argv[1])
    write_csv(sys.argv[2], rows)
    print(summary(SYSTEM, counts, report))
