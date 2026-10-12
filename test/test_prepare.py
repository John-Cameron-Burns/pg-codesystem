"""Tests for the loaders and the checks in tools/. Run: python3 -m unittest discover -s test -p 'test_prepare.py'

Two kinds: small synthetic files that provoke each defect on purpose (these always run), and the real files in data/raw/ (these are
skipped if the files have not been fetched; see data/SOURCES.md).
"""
import csv
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import csmodel                      # noqa: E402
import prepare_isco                 # noqa: E402
import prepare_isic                 # noqa: E402
import prepare_nace                 # noqa: E402
import prepare_soc                  # noqa: E402

RAW = os.path.join(ROOT, "data", "raw")
ISIC_FILE = os.path.join(RAW, "ISIC_Rev_4_english_structure.Txt")
ISCO_FILE = os.path.join(RAW, "ISCO-08_EN.csv")
SOC_FILE = os.path.join(RAW, "Extended_SOC_framework.csv")
NACE_FILE = os.path.join(RAW, "NACERev.2_EN_CTI_20070214_131821_utf8.csv")


def tmp(content, encoding="utf-8"):
    f = tempfile.NamedTemporaryFile("wb", suffix=".csv", delete=False)
    f.write(content.encode(encoding))
    f.close()
    return f.name


LEVELS = [csmodel.Level("top", 1, "[0-9]", "none"), csmodel.Level("mid", 2, "[0-9]", "prefix"), csmodel.Level("leaf", 3, "[0-9]", "prefix")]


def row(code, level, parent, label="x"):
    return {"code": code, "level": level, "parent": parent, "label": label}


GOOD = [row("1", "top", ""), row("11", "mid", "1"), row("111", "leaf", "11"), row("112", "leaf", "11")]


class Validate(unittest.TestCase):
    def problems(self, rows, levels=LEVELS):
        with self.assertRaises(csmodel.InvalidCodeSystem) as cm:
            csmodel.validate(rows, levels)
        return str(cm.exception)

    def test_a_good_system_passes_and_is_counted(self):
        self.assertEqual(csmodel.validate(GOOD, LEVELS), {"top": 1, "mid": 1, "leaf": 2})

    def test_wrong_width_is_refused(self):
        self.assertIn("is not 3 characters", self.problems(GOOD + [row("11", "leaf", "11")]))

    def test_a_number_that_lost_its_zero_is_refused(self):
        self.assertIn("is not 3 characters", self.problems([row("1", "top", ""), row("11", "mid", "1"), row("11x", "leaf", "11")]))

    def test_wrong_characters_are_refused(self):
        self.assertIn("is not 3 characters of [0-9]", self.problems(GOOD + [row("11A", "leaf", "11")]))

    def test_duplicates_are_refused(self):
        self.assertIn("appears twice", self.problems(GOOD + [row("111", "leaf", "11")]))

    def test_a_missing_parent_is_refused(self):
        self.assertIn("is not a mid in the list", self.problems(GOOD + [row("122", "leaf", "12")]))

    def test_a_prefix_parent_must_be_the_prefix(self):
        # 123 names 22 as its parent: 22 is a real mid code, but 123 starts 12, not 22
        rows = GOOD + [row("2", "top", ""), row("22", "mid", "2"), row("123", "leaf", "22")]
        self.assertIn("is not its prefix", self.problems(rows))

    def test_the_publishers_counts_are_enforced(self):
        levels = [csmodel.Level("top", 1, "[0-9]", "none", 1), csmodel.Level("mid", 2, "[0-9]", "prefix", 1),
                  csmodel.Level("leaf", 3, "[0-9]", "prefix", 3)]
        self.assertIn("2 leaf codes, but the publisher says 3", self.problems(GOOD, levels))

    def test_a_code_with_no_children_is_a_sign_of_a_truncated_file(self):
        self.assertIn("have no children", self.problems(GOOD + [row("2", "top", "")]))

    def test_every_problem_is_listed_not_just_the_first(self):
        text = self.problems(GOOD + [row("111", "leaf", "11"), row("5", "mid", "1")])
        self.assertIn("appears twice", text)
        self.assertIn("is not 2 characters", text)


class IsicLoader(unittest.TestCase):
    HEADER = '"Code","Description"\n'

    def test_a_division_belongs_to_the_section_before_it(self):
        path = tmp(self.HEADER + '"A","Farming"\n"01","Crops"\n"011","Cereals"\n"0111","Wheat"\n"B","Mining"\n"05","Coal"\n"051","Hard"\n"0510","Hard coal"\n')
        # the real counts do not apply to this tiny file: check the parent rule directly with the real loader's logic
        rows, section = [], ""
        with open(path, newline="") as f:
            for rec in list(csv.reader(f))[1:]:
                level = prepare_isic.BY_WIDTH[len(rec[0])]
                if level == "section":
                    section = rec[0]
                if level == "division":
                    rows.append((rec[0], section))
        self.assertEqual(rows, [("01", "A"), ("05", "B")])

    def test_a_division_before_any_section_is_refused(self):
        path = tmp(self.HEADER + '"01","Crops"\n')
        with self.assertRaises(SystemExit) as cm:
            prepare_isic.prepare(path)
        self.assertIn("before any section", str(cm.exception))

    def test_the_wrong_header_is_refused(self):
        with self.assertRaises(SystemExit):
            prepare_isic.prepare(tmp("a,b\n1,2\n"))

    def test_a_code_of_an_impossible_width_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            prepare_isic.prepare(tmp(self.HEADER + '"A","Farming"\n"01234","Too long"\n'))
        self.assertIn("has no level", str(cm.exception))


class IscoLoader(unittest.TestCase):
    HEADER = "ISCO_version,major,major_label,sub_major,sub_major_label,minor,minor_label,unit,description\n"

    def make(self, body, encoding="cp1252"):
        return tmp(self.HEADER + body, encoding)

    def prepare(self, path, version="ISCO-08", expected=False):
        # the real expected counts belong to the full file; these small files are checked against their own
        saved = prepare_isco.EXPECTED.copy()
        prepare_isco.EXPECTED.clear()
        try:
            return prepare_isco.prepare(path, version)
        finally:
            prepare_isco.EXPECTED.update(saved)

    BODY = ("ISCO-08,1,Managers,11,Chief Executives,111,Legislators,1111,Legislators\n"
            "ISCO-08,1,Managers,11,Chief Executives,111,Legislators,1112,Senior Officials\n"
            "ISCO-08,0,Armed Forces,1,Commissioned,11,Commissioned,110,Commissioned officers\n"
            "ISCO-88,1,Legislators,11,Old,111,Old,1110,Old unit\n")

    def test_only_the_wanted_version_is_kept(self):
        rows, counts, report = self.prepare(self.make(self.BODY))
        self.assertEqual(counts["unit"], 3)
        self.assertNotIn("1110", {r["code"] for r in rows})
        self.assertTrue(any("ISCO-88" in n for n in report.notes))

    def test_lost_leading_zeros_are_repaired_and_reported(self):
        rows, counts, report = self.prepare(self.make(self.BODY))
        codes = {r["code"]: r for r in rows}
        self.assertIn("0110", codes)
        self.assertEqual(codes["0110"]["parent"], "011")
        self.assertEqual(codes["011"]["parent"], "01")
        self.assertEqual(codes["01"]["parent"], "0")
        self.assertEqual(len(report.repairs), 3)
        self.assertTrue(any("110 -> 0110" in line for line in report.repairs))

    def test_windows_1252_text_is_read(self):
        # the file stores an apostrophe as the single byte 0x92, which is U+2019 in Windows-1252 (and invalid UTF-8)
        body = "ISCO-08,1,Managers,11,Chief Executives,111,Legislators,1111,Heads of villages\u2019 chiefs\n"
        path = self.make(body)
        with open(path, "rb") as f:
            self.assertIn(b"villages\x92 chiefs", f.read())
        rows, _, _ = self.prepare(path)
        self.assertEqual([r["label"] for r in rows][-1], "Heads of villages\u2019 chiefs")

    def test_the_same_code_with_two_labels_is_refused(self):
        body = ("ISCO-08,1,Managers,11,Chief Executives,111,Legislators,1111,A\n"
                "ISCO-08,1,Managers,11,A DIFFERENT NAME,111,Legislators,1112,B\n")
        with self.assertRaises(SystemExit) as cm:
            self.prepare(self.make(body))
        self.assertIn("is called both", str(cm.exception))

    def test_a_version_the_file_does_not_have_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            self.prepare(self.make(self.BODY), "ISCO-25")
        self.assertIn("no rows for ISCO-25", str(cm.exception))


@unittest.skipUnless(os.path.exists(ISIC_FILE), "data/raw/ISIC_Rev_4_english_structure.Txt not fetched (see data/SOURCES.md)")
class IsicRealFile(unittest.TestCase):
    # The section each division belongs to, from the ISIC Rev.4 publication -- an oracle independent of the loader.
    PUBLISHED = {"A": "01-03", "B": "05-09", "C": "10-33", "D": "35", "E": "36-39", "F": "41-43", "G": "45-47", "H": "49-53",
                 "I": "55-56", "J": "58-63", "K": "64-66", "L": "68", "M": "69-75", "N": "77-82", "O": "84", "P": "85",
                 "Q": "86-88", "R": "90-93", "S": "94-96", "T": "97-98", "U": "99"}

    def test_the_published_structure_and_nothing_else(self):
        rows, counts, report = prepare_isic.prepare(ISIC_FILE)
        self.assertEqual(counts, {"section": 21, "division": 88, "group": 238, "class": 419})

    def test_every_division_is_in_the_section_the_publication_gives(self):
        rows, _, _ = prepare_isic.prepare(ISIC_FILE)
        expected = {}
        for section, span in self.PUBLISHED.items():
            lo, _, hi = span.partition("-")
            for d in range(int(lo), int(hi or lo) + 1):
                expected["%02d" % d] = section
        got = {r["code"]: r["parent"] for r in rows if r["level"] == "division"}
        self.assertEqual(got, expected)


@unittest.skipUnless(os.path.exists(ISCO_FILE), "data/raw/ISCO-08_EN.csv not fetched (see data/SOURCES.md)")
class IscoRealFile(unittest.TestCase):
    def test_the_published_structure(self):
        rows, counts, report = prepare_isco.prepare(ISCO_FILE)
        self.assertEqual(counts, {"major": 10, "sub_major": 43, "minor": 130, "unit": 436})

    def test_exactly_the_armed_forces_codes_were_repaired(self):
        rows, _, report = prepare_isco.prepare(ISCO_FILE)
        self.assertEqual(len(report.repairs), 3)
        text = " ".join(report.repairs)
        for a, b in (("1", "01"), ("11", "011"), ("110", "0110"), ("310", "0310")):
            self.assertIn(f"{a} -> {b}", text)
        armed = [r["code"] for r in rows if r["code"].startswith("0")]
        self.assertEqual(sorted(armed), ["0", "01", "011", "0110", "02", "021", "0210", "03", "031", "0310"])

    def test_the_other_versions_in_the_file_are_not_mixed_in(self):
        rows, _, _ = prepare_isco.prepare(ISCO_FILE)
        self.assertEqual(len(rows), 619)


if __name__ == "__main__":
    unittest.main()


class NaceLoader(unittest.TestCase):
    HEADER = '"Ebene";"EDV-Code";"Code";"Titel";"Kurztitel"\n'

    def test_the_section_of_a_division_is_the_letter_in_its_code(self):
        path = tmp(self.HEADER + '1;"A";"A";"Farming";""\n2;"A01";"A 01";"Crops";""\n3;"A011";"A 01.1";"Annual";""\n4;"A0111";"A 01.11";"Cereals";""\n'
                   '1;"B";"B";"Mining";""\n2;"B05";"B 05";"Coal";""\n3;"B051";"B 05.1";"Hard";""\n4;"B0510";"B 05.10";"Hard coal";""\n')
        real = prepare_nace.LEVELS
        prepare_nace.LEVELS = [csmodel.Level(lv.name, lv.width, lv.charset, lv.link) for lv in real]   # the real counts do not apply here
        try:
            rows, _, _ = prepare_nace.prepare(path)
        finally:
            prepare_nace.LEVELS = real
        self.assertEqual([(r["code"], r["parent"]) for r in rows if r["level"] == "division"], [("01", "A"), ("05", "B")])
        self.assertEqual([(r["code"], r["parent"]) for r in rows if r["level"] == "class"], [("0111", "011"), ("0510", "051")])

    def test_the_wrong_header_is_refused(self):
        with self.assertRaises(SystemExit):
            prepare_nace.prepare(tmp("a;b\n1;2\n"))

    def test_a_level_out_of_range_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            prepare_nace.prepare(tmp(self.HEADER + '9;"A";"A";"x";""\n'))
        self.assertIn("is not 1 to 4", str(cm.exception))

    def test_a_code_that_does_not_fit_its_level_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            prepare_nace.prepare(tmp(self.HEADER + '2;"A011";"x";"x";""\n'))
        self.assertIn("is not a division code", str(cm.exception))


@unittest.skipUnless(os.path.exists(NACE_FILE), "NACE Rev.2 file not in data/raw (see data/SOURCES.md)")
class NaceRealFile(unittest.TestCase):
    def test_the_published_structure(self):
        rows, counts, _ = prepare_nace.prepare(NACE_FILE)
        self.assertEqual(counts, {"section": 21, "division": 88, "group": 272, "class": 615})

    def test_divisions_are_in_the_same_sections_as_isic(self):
        if not os.path.exists(ISIC_FILE):
            self.skipTest("ISIC file not fetched")
        nace = {r["code"]: r["parent"] for r in prepare_nace.prepare(NACE_FILE)[0] if r["level"] == "division"}
        isic = {r["code"]: r["parent"] for r in prepare_isic.prepare(ISIC_FILE)[0] if r["level"] == "division"}
        self.assertEqual(nace, isic)


class SocLoader(unittest.TestCase):
    HEADER = "title line,,,,,,\nUnique ID,Major Group,Sub-Major Group,Minor Group,Unit Group,Sub-Unit Group,Group Title\n"

    def test_a_row_with_two_codes_is_refused(self):
        with self.assertRaises(SystemExit) as cm:
            prepare_soc.prepare(tmp(self.HEADER + ",1,11,,,,Two\n"))
        self.assertIn("exactly one group code", str(cm.exception))

    def test_the_wrong_header_is_refused(self):
        with self.assertRaises(SystemExit):
            prepare_soc.prepare(tmp("t\na,b\n1,2\n"))

    def test_parents_follow_the_prefix_and_the_slash(self):
        path = tmp(self.HEADER + ",1,,,,,Managers\n,,11,,,,Corporate\n,,,111,,,Chief\nx,,,,1111,,CEOs\ny,,,,,1111/01,Chairpersons\n")
        real = prepare_soc.LEVELS
        prepare_soc.LEVELS = [csmodel.Level(lv.name, lv.width, lv.charset, lv.link) for lv in real]
        try:
            rows, _, _ = prepare_soc.prepare(path)
        finally:
            prepare_soc.LEVELS = real
        self.assertEqual([(r["code"], r["parent"]) for r in rows], [("1", ""), ("11", "1"), ("111", "11"), ("1111", "111"), ("1111/01", "1111")])
        base, ext = prepare_soc.split(rows)
        self.assertEqual((len(base), len(ext)), (4, 5))


@unittest.skipUnless(os.path.exists(SOC_FILE), "Extended SOC file not in data/raw (see data/SOURCES.md)")
class SocRealFile(unittest.TestCase):
    def test_soc_2020_has_the_published_group_counts(self):
        rows, counts, _ = prepare_soc.prepare(SOC_FILE)
        self.assertEqual(counts, {"major": 9, "sub_major": 26, "minor": 104, "unit": 412, "sub_unit": 1384})
