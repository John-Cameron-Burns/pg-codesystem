# The UK Companies House company number (CRN) as a code

`tools/load_crn.sql` defines `uk_crn`, a *pattern system*: a system defined by the syntax of its codes, not by a list.

```sql
\i tools/load_crn.sql
SELECT code_part('uk_crn:SC123456', 'prefix');          -- SC
SELECT code_from_padded('1234567', 'uk_crn');           -- uk_crn:01234567
WHERE crn BETWEEN code_first_with_prefix('SC','uk_crn') AND code_last_with_prefix('SC','uk_crn')   -- every Scottish number
```

The pattern was checked against all 13,549,728 company numbers in the Companies House Bulk Downloads (live and dissolved
companies, and the update feed). Every one casts to `code`, text and code agree on the way back, the codes sort as the text
does, the prefix counts match, and `code_first_with_prefix('SC','uk_crn')` .. `code_last_with_prefix` finds the 659,559 SC
numbers by an index-only scan. The system defines 407,291,360 codes. Its parts are `prefix` and `number`; the older society
numbers have `legacy_prefix` and `legacy_number`, because a part name can be used only once in a pattern.

## What a company number looks like

All are 8 characters, upper case, no spaces.

| shape | numbers | what it is |
|---|---|---|
| `99999999` | 12,393,857 | England & Wales: 8 digits, zero padded (1.5 million of the live ones start with 0); highest seen 17,429,089 |
| `AA999999` | 1,149,885 | a 2-character prefix and 6 digits, 35 prefixes: SC (660 thousand), NI, OC, CE, SL, OE, LP, FC, CS, SO, RS, NC, IP, NL, RC, AC, IC, NF, BR, GE ... |
| `A9999999` | 153 | `R0` and 6 digits (the prefix contains a digit) |
| older society numbers | 5,833 (0.043 %) | IP, SP, RS and a few SL: `IP00002C`, `SP1000RS`, `RS0001FI`, `SP001CUS`, and four one-offs (`IPIP2960`, `IPIP316C`, `SP3COLLS`, `SP01BENS`): a number with a one- to three-letter suffix |

A company number is not a classification code: the set is open (it grows daily, and the England & Wales numbers are allocated in
sequence), has no list to be checked against, and has no hierarchy. Its only structure is the prefix, which says the kind of body
and the jurisdiction.

## Why a pattern

A pattern defines the set of syntactically possible numbers, and a code's value is its rank in that set, so adding companies
changes nothing and no revisions are needed.

* `\d{8}|(35 prefixes)\d{6}` allows 135,000,000 codes (27.0 bits) and compiles to 28 states. It rejects exactly the 5,833 older
  society numbers.
* The same with the older forms (`(IP|RS|SP|SL)\d{5}[A-Z]`, `(IP|RS|SP)\d{4}[A-Z]{2}`, `(IP|RS|SP)\d{3}[A-Z]{3}`, `SP\d{2}[A-Z]{4}`,
  `SP\d[A-Z]{5}`, `IPIP\d{4}`, `IPIP\d{3}[A-Z]`) allows 382,955,360 codes (28.5 bits) and compiles to 58 states. All 13,549,728
  real numbers parse, every one renders back to the same text, ranks come out in byte order, and a parse plus render takes about
  150 ns.

## What it does not do

* **Check that a company exists.** The set of possible numbers is about 28 times the number ever issued (England & Wales: 100
  million possible, 17.4 million issued). The type catches a typo in the prefix, a wrong length, lower case or a stray letter,
  but not a number nobody was issued. That is a join to the Companies House table.
* **Make the column smaller.** A code is 8 bytes; the text is 9.
* **Cap the England & Wales digits at what has been issued.** The cap would catch more typos, but it grows every year, so every
  extension would be a new revision and values written earlier would need `code_current()`. Not capping is the stable choice.

## Practical points

* Spreadsheets drop the leading zeros of England & Wales numbers (`01234567` becomes `1234567`). `code_from_padded` pads a
  digits-only input shorter than 8; the type itself does not accept it, because a short digit string is not a company number
  and accepting it silently hides a bad load.
* The prefix is the only part. An England & Wales number has no prefix, so the part is optional.
* The revision of a pattern system stores the regular expression, not millions of rows. The system is flat and may name parts.
* The same shape suits other identifiers with a syntax and no list, such as charity numbers. It does not suit identifiers with check
  digits, or ones that need a list (those are list systems).
