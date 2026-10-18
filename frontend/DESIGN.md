# Native baseline conventions

Visual authority: the existing oak/Moonwillow assets and section 12.3 of the root
specification. Preserve their calm, stylized miniature-world appearance.

- Native SwiftUI Garden/Activity tabs, navigation stacks, lists, forms and sheets.
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

Evidence is source inspection only. Dark Mode, Dynamic Type, landscape layout,
VoiceOver, touch interaction, lighting, imported orientation and performance need
native validation. No HTML/CSS detector or browser screenshot substitutes for it.
