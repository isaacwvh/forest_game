# Native baseline conventions

Visual authority: the existing oak/Moonwillow assets and section 12.3 of the root
specification. Preserve their calm, stylized miniature-world appearance.

- Native SwiftUI lists, forms, sheets and navigation stacks; My plants / Garden / Edit / Activity bottom navigation. Edit enters a focused mode on the mounted Garden.
- F8.1 uses portrait-only play and a consistent light appearance, including native
  sheets. Dark Mode and landscape play are outside this release batch.
- System text styles, SF Symbols, semantic UI backgrounds and secondary text.
- Interactive tint is forest green: light RGB 0.20/0.39/0.25; dark RGB 0.56/0.80/0.59.
- Garden scene background RGB 0.90/0.93/0.89; temporary board RGB 0.45/0.57/0.36.
- Shared warm directional lighting with cooler fill; materials remain asset-authored.
- Actions use 44-point targets; browsing camera commands live in the Garden scene accessibility Actions menu. Edit retains its explicit camera controls.
- World ground is Y=0, assets retain metre scale and fixed ground anchors.
- Plant selection uses a small yellow marker, independent of gameplay clearance.
- Embedded wind respects Reduce Motion and inactive views. Scene changes preserve identity.
- My plants provides read-only owned-copy inspection without precise 3D touch selection. Sample Garden info retains an accessible sample plant list.
- Detailed inspection and synthetic fixtures are under developer tools in Debug and explicitly internal Release builds; public Release excludes their routes.
- Garden browsing fills the navigation-bounded viewport. Tokens, attraction and
  stored visits/capacity share one ordinary-size row. Garden info and outlined
  Collect sit beneath the first/last columns; accessibility text sizes reflow.
- Transparent forest-green outlines surround browsing actions, selection and
  exceptional notices. Reduce Transparency/increased contrast adds local backing.
  Only real overlay targets occlude visitor accessibility; empty space passes gestures.
- The bundled butterfly USDZ uses a shared template, embedded wing animation and
  board-relative flight with camera perspective. Projected 64-point touch targets
  preserve direct touch access. The rendered butterfly itself has a native
  accessibility element keyed by opportunity ID, with current projected bounds
  and the same welcome operation. There is no standalone Welcome button. A native
  fallback remains usable after artwork failure; loading feedback remains visible. Reduce Motion keeps
  flight stationary and wing animation paused; server expiry ends presentation.
- Visitor UI exposes pending/confirmed status and recovery without optimistically
  adding tokens. Development balance is labelled. B7 exchanges visitor tokens directly for packs.
- Browsing header/notices and the selected-copy popup overlay a stable full scene;
  their appearance never changes camera bounds or renderer identity. Tall overlays
  scroll within bounded areas. Edit retains geometry-reserved status/controls panels
  and its compact-height side panel on the same mounted scene bridge.
- Butterfly flight uses its own frame clock and retains its phase for each
  opportunity. A routine heartbeat keeps the visitor visible and accepts a saved
  tap; a read-only activity refresh does not end the foreground visitor session.

Evidence is source inspection only. Light appearance, Dynamic Type, portrait layout,
VoiceOver, touch interaction, lighting, imported orientation and performance need
native validation. No HTML/CSS detector or browser screenshot substitutes for it.

- Garden skills live under Garden info → Active skills.
  Preserve the mounted scene and fixed viewport while presenting secondary information. Show confirmed
  effective water, source/duplicate explanations and capped-state text; cached
  summaries are explicitly last confirmed. Pending placement never activates a
  skill. Owned/catalogue details explain adult activation and stored inactivity.

- A leading collection menu opens Exchange, Packs, Catalog and Milestones. Preserve the
  mounted garden/camera while browsing; the menu and collection routes pause
  active visitors. Browsing and settings retain their native navigation. Editing hides the bottom navigation and sidebar, with Storage and Done editing always clear.
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

- My plants combines confirmed Planted copies above paginated Stored copies. Rows
  open read-only copy details. Storage inside Edit opens the same details with a
  bottom Place action. Details resolve current copy identity from the account store.
- Selected planted copies appear in a compact outlined popup above bottom navigation.
  Close/empty ground dismisses it; explicit Plant details opens read-only current-copy
  inspection. Selection resolves by account-bound UUID and clears after storage/removal.
- Routine Garden success messages are classified explicitly and hidden without
  clearing service state. Pending, uncertain, offline and recovery notices remain
  actionable overlays. Confirmed rewards/request outcomes remain in local diagnostics.
  Visitor explanations and active skills remain in Garden info.
- Settings → Developer tools → Diagnostics shows the real connected state and
  live Garden renderer, plus bounded local events with manual copy/export. It does
  not create a renderer, own requests, upload logs or capture credentials/Health bodies.
