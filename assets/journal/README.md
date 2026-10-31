# Botanical journal runtime package

Stage 1 presentation resources, 31 October 2026.

The v1 folder contains four 240×240 RGBA vine corners, one 768×96 RGBA divider,
catalog-descriptions.json, and an integrity manifest. The five ornaments total
60,170 bytes. They were exported from the previously reviewed SVG kit. Source
masters and screen mockups remain in the local ignored art workspace and are
not bundled.

The Xcode project copies the journal folder. UI code uses constant-size corner
ornaments, native scalable rarity outlines and existing plant PNGs. Ornaments do
not intercept touch or appear in the accessibility tree. No model, silhouette,
gameplay radius, rarity assignment or per-copy artwork is stored in this package.

The catalog copy file is a presentation fallback for empty/legacy server
descriptions, never used by owned inspection. Portable validation checks it
against the server's approved text metadata. New authored server descriptions
take precedence. Neither copy updates nor these resources change game mechanics.
