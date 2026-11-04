# Sale and Edit storage follow-up

Source implemented 5 November 2026. This refines the existing inventory feature;
there is no schema migration, valuation change or capacity-rule change.

- Confirmation says “Sell this plant?” with “This move cannot be undone.”
- The plant inspector shows the token amount without valuation/calculation detail.
- A confirmed sale dismisses the current inspector, including recovered sales.
  Confirmation is observed before the inventory-refresh callback can remove the
  copy; the missing-copy fallback also dismisses a confirmed sold copy.
- Edit shows compact global Plants/Planted/Stored counts and limits, and Storage
  repeats the existing summary. Counts use confirmed placement state; previews
  never alter them. Existing receipt/refresh paths update counts after place,
  store and sale.
- Edit Storage inspection puts Sell next to Place, stacking at accessibility text
  sizes. Protected/unavailable copies retain Place. Pending economic operations
  disable Place; existing edit, cache and activity guards still apply.
- Planted-copy inspection shows the current resale amount and store-first note
  without a Sell button. The backend read-only quote now permits planted copies;
  the sale transaction still rejects them before changing ownership or currency.
  Original starter protection remains in place.

Executed locally: **100 backend tests passed** in 64.82 seconds, covering inventory,
placement and frontend wire contracts. The planted-copy regression verifies a
readable price, rejected sale while planted and successful sale after storage.
Frontend project/resource/contrast/contracts validation, all 78 Swift syntax
parses, Ruff lint/format and diff checks passed. The Impeccable source detector
returned no findings for the three changed views.

Added native coverage for Edit counts across preview, confirmed placement and
storage. Xcode/Apple SDK compilation, XCTest execution and actual device visual
acceptance were unavailable on Windows and remain Mac checks:

1. Sell from My plants; check the short confirmation and automatic return.
2. Enter Edit, place/store copies and verify counts update after confirmation.
3. Open Edit Storage details; check Place/Sell side by side and confirm that sale
   returns to Storage with the sold tile removed and counts refreshed.
4. Inspect a planted non-starter; verify the value is visible with no Sell button.
5. Repeat with Dynamic Type/VoiceOver, lost response, recovery and failed refresh.

Rebuild/restart the backend for planted-copy quotes; the schema remains
`0012_inventory_management`. The personal game database was not changed by tests.
