-- The Companies House company number as a pattern system, derived from the 13,549,728 company numbers in the Companies House
-- Bulk Downloads (live and dissolved companies, and the update feed): see docs/CRN.md. The prefixes are the ones found in that
-- data, not Companies House's published list, which should be checked before relying on this to refuse a new prefix.
--
--   an 8-digit number                      England and Wales
--   a prefix and 6 digits                  the other jurisdictions and body types (SC Scotland, NI Northern Ireland, OC LLP, ...)
--   IP, RS, SP, SL and a few one-offs      the older society numbers: a number with a one- to three-letter suffix (IP00002C, SP1000RS)
--
-- Parts: prefix and number for the first two kinds. A part name can be used once in a pattern, so the older society numbers
-- have their own, legacy_prefix and legacy_number (the number with its letters), NULL for the other part names and the reverse.
-- Four one-off forms (SP01BENS, SP3COLLS, IPIP2960, IPIP316C: 8 numbers in all) are allowed and have no parts.
-- The pattern allows SL and the other legacy prefixes a few more suffix shapes than were seen: a little looser, never tighter.
\set ON_ERROR_STOP on
SELECT define_code_system_pattern('uk_crn',
   '/\d{8}'
   '|(?<prefix>AC|BR|CE|CS|FC|FE|GE|GS|IC|IP|LP|NC|NF|NI|NL|NO|NP|OC|OE|PC|R0|RC|RS|SA|SC|SE|SF|SG|SI|SL|SO|SP|SR|SZ|ZC)(?<number>\d{6})'
   '|(?<legacy_prefix>IP|RS|SP|SL)(?<legacy_number>\d{5}[A-Z]|\d{4}[A-Z]{2}|\d{3}[A-Z]{3})'
   '|SP\d{2}[A-Z]{4}|SP\d[A-Z]{5}|IPIP\d{4}|IPIP\d{3}[A-Z]/',
   'number', 'UK company registration number', 'Companies House') AS uk_crn_revision;
SELECT name, kind, ncodes, levels FROM code_systems WHERE name = 'uk_crn';
