"""The shape every loader produces, and the checks every loader must pass.

A prepared code system is a list of rows (code, level, parent, label):

  code    the code as a string. Its width belongs to its level, so it is never a number ("0110", not 110).
  level   the name of its level ("division", "unit").
  parent  the code one level up, or "" at the top level.
  label   the title the publisher gives it.

Nothing is repaired silently. A loader may repair a known defect of a source file, but it says so in `report.repairs`, and
`validate()` refuses a system that does not satisfy its spec: every code the right width and characters, no duplicates, every
parent present, a prefix parent really a prefix, and the number of codes at every level what the publisher says there are.
"""
import csv
import re
from dataclasses import dataclass, field


@dataclass
class Level:
    name: str
    width: int                 # characters in a code at this level
    charset: str               # a regular-expression class: "[0-9]", "[A-Z]"
    link: str = "prefix"       # how a code finds its parent: "none" (top), "prefix" (code[:parent width]) or "grouping" (given)
    expected: int | None = None  # how many codes the publisher says there are at this level


@dataclass
class Report:
    repairs: list = field(default_factory=list)   # what the loader had to put right in the source, one line each
    notes: list = field(default_factory=list)


class InvalidCodeSystem(Exception):
    pass


def validate(rows, levels):
    """rows: list of dicts with code, level, parent, label. Raises InvalidCodeSystem listing every problem found."""
    problems = []
    by_name = {lv.name: lv for lv in levels}
    order = {lv.name: i for i, lv in enumerate(levels)}
    seen = {}
    for r in rows:
        lv = by_name.get(r["level"])
        if lv is None:
            problems.append(f"{r['code']!r}: unknown level {r['level']!r}")
            continue
        if r["code"] in seen:
            problems.append(f"{r['code']!r} appears twice (levels {seen[r['code']]!r} and {r['level']!r})")
        seen[r["code"]] = r["level"]
        if len(r["code"]) != lv.width or not re.fullmatch(lv.charset + "{%d}" % lv.width, r["code"]):
            problems.append(f"{r['code']!r} is not {lv.width} characters of {lv.charset} as a {lv.name} code must be")
    for r in rows:
        lv = by_name.get(r["level"])
        if lv is None:
            continue
        i = order[lv.name]
        if lv.link == "none":
            if r["parent"]:
                problems.append(f"{r['code']!r}: a {lv.name} has no parent but names {r['parent']!r}")
            continue
        parent_level = levels[i - 1]
        if r["parent"] not in seen or seen[r["parent"]] != parent_level.name:
            problems.append(f"{r['code']!r}: parent {r['parent']!r} is not a {parent_level.name} in the list")
        elif lv.link == "prefix" and r["parent"] != r["code"][:parent_level.width]:
            problems.append(f"{r['code']!r}: parent {r['parent']!r} is not its prefix {r['code'][:parent_level.width]!r}")
    counts = {lv.name: sum(1 for r in rows if r["level"] == lv.name) for lv in levels}
    for lv in levels:
        if lv.expected is not None and counts[lv.name] != lv.expected:
            problems.append(f"{counts[lv.name]} {lv.name} codes, but the publisher says {lv.expected}")
    # a level above the last must have a child in every code (a division with no groups is a sign of a truncated file)
    children = {r["parent"] for r in rows}
    for lv in levels[:-1]:
        empty = [r["code"] for r in rows if r["level"] == lv.name and r["code"] not in children]
        if empty:
            problems.append(f"{len(empty)} {lv.name} codes have no children, e.g. {empty[:3]}")
    if problems:
        raise InvalidCodeSystem("\n  ".join([f"{len(problems)} problem(s):"] + problems[:40] + (["..."] if len(problems) > 40 else [])))
    return counts


def write_csv(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["code", "level", "parent", "label"], lineterminator="\n")
        w.writeheader()
        w.writerows(rows)


def read_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def summary(system, counts, report):
    out = [f"{system}: " + ", ".join(f"{n} {k}" for k, n in counts.items())]
    out += [f"  repaired: {line}" for line in report.repairs]
    out += [f"  note: {line}" for line in report.notes]
    return "\n".join(out)
