#!/usr/bin/env python3
"""SOC 2020 -> ISCO-08, derived from the ONS SOC 2020 coding index (volume 2, Excel; needs openpyxl).

The ONS says there is no simple mapping at unit-group level, so it dual-coded every job title of the index to both
classifications (the sheet "SOC2020 coding index": SOC_2020, SOC_2020_ext, and "ISCO-08 code based on SOC2020"). A pair here
means: at least one indexed job title is coded to both. That is the ONS's own coding, but the pairs are derived, not a table the
ONS publishes, and a pair says nothing about how many titles or people it covers.

Skipped, and reported: the cross-reference entries ("see Adviser"), which carry the placeholder }}}} in all three columns, and
index records whose ISCO-08 cell is the placeholder or empty.

usage: prepare_soc2020_isco.py INDEX.xlsx OUT_UNIT_PAIRS.csv OUT_SUBUNIT_PAIRS.csv
"""
import csv
import re
import sys

SHEET = "SOC2020 coding index"
COLUMNS = ["SOC_2020", "SOC_2020_ext", "ISCO-08 code based on SOC2020"]
PLACEHOLDER = "}}}}"


def prepare(path):
    import openpyxl
    ws = openpyxl.load_workbook(path, read_only=True)[SHEET]
    rows = ws.iter_rows(values_only=True)
    header = next(rows)
    missing = [c for c in COLUMNS if c not in header]
    if missing:
        raise SystemExit(f"{path}: the sheet {SHEET!r} has no column {missing}")
    ix = {h: i for i, h in enumerate(header)}
    unit_pairs, sub_pairs = set(), set()
    skipped = {"cross-references": 0, "no ISCO-08 code": 0}
    for n, r in enumerate(rows, start=2):
        u, e, i = (r[ix[c]] for c in COLUMNS)
        if str(u) == PLACEHOLDER and str(e).startswith(PLACEHOLDER) and str(i) == PLACEHOLDER:
            skipped["cross-references"] += 1
            continue
        if i is None or str(i).strip() in ("", PLACEHOLDER):
            skipped["no ISCO-08 code"] += 1
            continue
        u, e, i = str(u).strip().zfill(4), str(e).strip(), str(i).strip().zfill(4)
        if not re.fullmatch(r"[0-9]{4}", u) or not re.fullmatch(r"[0-9]{4}/[0-9]{2}", e) or not re.fullmatch(r"[0-9]{4}", i) or e[:4] != u:
            raise SystemExit(f"{path} row {n}: unexpected codes SOC_2020={u!r} SOC_2020_ext={e!r} ISCO={i!r}")
        unit_pairs.add((u, i))
        sub_pairs.add((e, i))
    return sorted(unit_pairs), sorted(sub_pairs), skipped


def write(path, pairs):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["from_code", "to_code"])
        w.writerows(pairs)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    units, subs, skipped = prepare(sys.argv[1])
    write(sys.argv[2], units)
    write(sys.argv[3], subs)
    print(f"{len(units)} unit-group pairs, {len(subs)} sub-unit pairs; skipped {skipped}")
