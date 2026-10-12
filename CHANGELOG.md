# Changes

## 0.2.1

The extension itself is unchanged from 0.2.0 (the same `codesystem--0.2.0.sql`, nothing to upgrade). This release is the package around it.

* **ONS GSS geography codes:** `gss` (a pattern system for codes like `E06000001`, with country, type and area parts) and `gss_entity`
  (the 206 entity types of the Register of Geographic Codes), loaded by `tools/load_gss.sql`. `gss_update_entity_types()`
  (`tools/gss_update.sql`) brings `gss_entity` up to the latest edition from the ONS.
* **ISIC Rev.4 and ISCO-08 are installed from their publishers:** `codesystem_install_isic_rev4()` and `codesystem_install_isco_08()`
  (`tools/install_isic_isco.sql`) download them from the UN and the ILO, check them against the published counts and define them.
  They are not distributed with the package. `tools/load_nace.sql` loads NACE, which needs ISIC first.
* **Prepared data comes with the package** for NACE Rev.2, UK SIC 2007 and 2003 and the GSS entity types, with their attributions in `NOTICE`.
* Documentation rewritten around defining your own code system, with the included systems as worked examples.
