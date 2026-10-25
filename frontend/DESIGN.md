# Native baseline conventions

Visual authority: the existing oak/Moonwillow assets and section 12.3 of the root
specification. Preserve their calm, stylized miniature-world appearance.

- Native SwiftUI Garden/Activity tabs, navigation stacks, lists, forms and sheets.
- F8.1 uses portrait-only play and a consistent light appearance, including native
  sheets. Dark Mode and landscape play are outside this release batch.
- System text styles, SF Symbols, semantic UI backgrounds and secondary text.
- Interactive tint is forest green: light RGB 0.20/0.39/0.25; dark RGB 0.56/0.80/0.59.
- Garden scene background RGB 0.90/0.93/0.89; temporary board RGB 0.45/0.57/0.36.
- Shared warm directional lighting with cooler fill; materials remain asset-authored.
- Explicit camera buttons use 44-point targets; ordinary content uses native spacing.
- World ground is Y=0, assets retain metre scale and fixed ground anchors.
- Plant selection uses a small yellow marker, independent of gameplay clearance.
- Embedded wind respects Reduce Motion and inactive views. Scene changes preserve identity.
- A native Plants list provides access to details without precise 3D touch selection.
- Detailed inspection and synthetic fixtures are under Debug-only developer tools.
- Visitor controls extend the existing native garden status area with confirmed
  tokens, stored visits, one collection action and a collapsed explanation.
- The bundled butterfly USDZ uses a shared template, embedded wing animation and
  board-relative flight with camera perspective. Projected 64-point touch targets
  and a separate accessible Welcome action preserve access. A temporary native
  fallback remains usable during missing/loading artwork. Reduce Motion keeps
  flight stationary and wing animation paused; server expiry ends presentation.
- Visitor UI exposes pending/confirmed status and recovery without optimistically
  adding tokens. Development balance is labelled. B7 exchanges visitor tokens directly for packs.
- Garden panel regions depend on available screen size and orientation. Status,
  progress and validation text scroll within those regions; they never resize the
  camera viewport. Compact height places status and controls beside the scene.
- Butterfly flight uses its own frame clock and retains its phase for each
  opportunity. A routine heartbeat keeps the visitor visible and accepts a saved
  tap; a read-only activity refresh does not end the foreground visitor session.

Evidence is source inspection only. Light appearance, Dynamic Type, portrait layout,
VoiceOver, touch interaction, lighting, imported orientation and performance need
native validation. No HTML/CSS detector or browser screenshot substitutes for it.

- Garden skills use a native inline DisclosureGroup in the existing status panel.
  Preserve the mounted scene and fixed viewport when expanding it. Show confirmed
  effective water, source/duplicate explanations and capped-state text; cached
  summaries are explicitly last confirmed. Pending placement never activates a
  skill. Owned/catalogue details explain adult activation and stored inactivity.

- A leading collection menu opens Exchange, Catalog and Packs. Preserve the
  mounted garden/camera while browsing; the menu and collection routes pause
  active visitors. Garden/Activity and settings retain their native navigation.
- Exchange separates read-only contents from explicit purchase confirmation,
  with inline pending/success/recovery feedback and a route to Packs. Packs
  separates unopened packs, the persisted confirmed result and history.
  Catalogue inspection is independent of ownership. Use native lists, text
  styles, SF Symbols, 44-point actions and explicit pending/error/empty states.
- Wallet presentation accepts newer server economy versions only. A durable
  opening result never depends on a reveal animation. Add artwork via the bundled
  asset index; remote asset delivery remains a later milestone.

- Catalogue navigation is one row per species. Variants live in a selector inside
  species detail, alongside current-pack conditional and overall draw odds. Rarity
  belongs to the species; legacy variant rarity is not used for new catalogue UI.
- Pack contents distinguish schema-2 rarity → equal species → weighted variant
  from legacy flat outcomes. Stage artwork remains visible; silhouettes and
  permanent account-scoped discovery are deferred polish in IMPLEMENTATION_PLAN.

- An app-entry sheet shows a frozen batch of saved growth per owned copy,
  including actual skill water and stage advances. Current skills are labelled
  separately. It appears on launch/login or a real background return, including
  a quiet no-new-growth state. Ordinary sync never presents it. Dismissal
  acknowledges only displayed receipts and never claims visits or grants growth.
- Pack opening uses a dimmed full-screen presentation, explicit confirmation,
  tear tap, reveal tap and Continue. The Woodland layers are bundled separately
  from plant packages and downsampled for display. Other themes use a generic
  wrapper. Rarity comes from the saved receipt. Recovery uses the durable result
  and history; it does not automatically replay the two taps.
