# Plant asset production workflow

Updated: 17 October 2026  
Companion: [forest_game_v1_spec.md](forest_game_v1_spec.md)  
Scope: approved adult 2D schematics → complete, consistent, game-ready species package.

## 1. Starting point and responsibilities

The user manually creates and refines the stage-4 adult schematics. Start this workflow with those approved images; generating new concept art is not a prerequisite. Produce the 3D models directly in Blender, through Blender MCP when available. Meshy is optional and is not part of the established oak pipeline.

Read the project-root spec and this guide at the beginning of a plant production session. Inspect existing source files and the live Blender scene before making changes. Continue from the latest approved source; do not rebuild from an older generator if that would erase manual refinements. Preserve unrelated live scenes and user work.

Separate what is already implemented from what is planned. This workflow produces assets and catalogue data, not the iOS storage UI, progression logic or runtime interaction effects.

For the existing Blender MCP setup, open Blender, enable the installed bridge add-on and use its viewport sidebar to connect/start the server on port 9876. The Codex-side `blender` MCP server is already configured for localhost. Test scene access before modeling; if it fails, check Blender is open, the bridge is running and both sides use the same port before reinstalling anything. Read the current scene and preserve unsaved work before switching sources. External generators and paid asset services are not needed for this workflow.

## 2. Deliverable and naming contract

Every species has these four stages, in this order:

| Display number | File/catalogue ID | Intended appearance |
| --- | --- | --- |
| 1 | `sprout` | Small emerging shoot; species-specific exposed seed fragment only where designed |
| 2 | `seedling` | Recognisable leaves and a small stem |
| 3 | `young` | Developing structural form and a smaller crown |
| 4 | `adult` | Mature design matching the approved schematics |

Every delivered stage/variant combination requires one animated USDZ and one transparent PNG thumbnail. Stage IDs, variant IDs, model names and catalogue paths must agree. All unboxed plants start at `sprout`; there is no separate seed stage, model or icon.

For S stages and V approved variants, the runtime package has **2×S×V + 1 files**, assuming each USDZ embeds its textures. Four stages and standard/blue/vined variants require exactly **25 files**: 12 USDZs, 12 PNGs and one catalogue.

Use the following layout, substituting the species ID and version:

```text
forest_game/
  forest_game_v1_spec.md
  PLANT_ASSET_WORKFLOW.md
  assets/
    oak/
      v1/
        models/
          oak-sprout-standard.usdz
          oak-sprout-blue.usdz
          oak-sprout-vined.usdz
          ...same three variants for seedling, young and adult
        ui/
          oak-sprout-standard.png
          oak-sprout-blue.png
          oak-sprout-vined.png
          ...same three variants for seedling, young and adult
        oak.json
    oak-v1.zip
  art/
    concepts/<species>/
      ...approved reference images
    <species>-production/
      <species>-master.blend
      ...generation/refinement/export/validation scripts
      ...source textures, source notes and review images
```

The ellipses explain the naming pattern; they are not files to create. Archive the runtime package with one species folder at its root, as in `oak/models/`, `oak/ui/` and `oak/oak.json`. The ZIP sits outside the package folder.

Keep sources, scripts, schematics, review images, turnarounds, reports, logs, backups and documentation under `art/`, outside the runtime package. Do not include duplicate GLB/FBX exports or loose copies of embedded textures unless a separately approved integration requires them.

## 3. Lock the visual reference

Use the approved adult schematics together with the approved oak collection as the style reference. The shared language is clean, smooth, engaging and calm, inspired by Abyssrium's miniature-world presentation.

- Readable silhouette and simplified botanical identity at garden scale.
- Matte surfaces, soft highlights, controlled colour variation and gentle shading.
- Sculpted/faceted masses where appropriate; clean curves and soft leaf lobes where appropriate.
- Restrained fine detail. Oak's early leaves use subtle midribs and secondary veins; its adult canopy uses grouped faceted foliage.
- Avoid noisy photorealistic textures, sharp glossy plastic, overly pale washed-out foliage or unrelated realism between stages.
- Leave enough space around foliage to read the trunk and characteristic branching. Check from the game's oblique camera, not just straight on.

Ensure leaf, stem/trunk and flower textures and surface forms are well defined wherever those parts are present. Use the [approved oak adult trunk](art/oak01/renders/oak01-hero.png) as a reference for clear surface definition: readable sculpted planes, taper and branch junctions, with controlled colour variation and matte shading. Apply the same care to leaf blades, midribs, stems and petals using appropriate geometry, UVs and subtle texture detail. Keep surfaces smooth and refined without making them featureless or muddy; do not substitute noisy bark, random triangle colours or exaggerated veins for definition. Younger stages must receive the same material and texture quality as the mature plant. Review close-ups and garden-scale renders, and confirm that the definition survives USDZ export.

Useful schematic views are a front, side, top and three-quarter view. A back view helps with asymmetric designs. Align scale and identifiable branches between views; resolve conflicting shapes before detailed modeling. If only a single view exists, make restrained depth assumptions consistent with the design and review the resulting silhouette early.

For each species, record a short source note: approved reference paths, palette, adult proportions, distinguishing features and allowed variants. Do not invent rarity odds, growth thresholds or extra variant combinations.

## 4. Set the ground and scale before modeling

Use Blender's Z-up authoring convention and metres. Put the plant's placement origin at `(0, 0, 0)`, where it meets the garden surface. Choose and retain an adult size compatible with the garden, using oak as a relative scale reference. Store actual model bounds; the species' circular reserved-clearance radius remains game configuration, measured in garden units rather than pixels or cells. The spec proposes one garden unit per authoring metre after import unit conversion; keep the mapping consistent across species and stages.

Every stage and variant uses that same ground origin. Design visible geometry upward from Z=0. Keep intended relative sizes in the models; do not normalize every stage to adult height. Do not embed the garden plane, a soil island, a pedestal, studio lights or a camera in a plant export.

For a half-buried seed/acorn appearance, model only the visible portion and close the underside at ground level. Oak's sprout has the upper half of its acorn with a flat closed bottom at Z=0, plus the shoot emerging above it. Oak's seedling and later stages have no visible acorn. Never lower the ground plane or move the plant's placement anchor between stages.

Review the species' fixed circular clearance against adult ground/base geometry, exposed roots, substantial lower growth and a deliberate spacing allowance; check that it also accommodates all younger stages and variants. Reserve that same space from sprout through adult. Treat the larger visual crown/leaf envelope separately: moderate outer-foliage overlap is allowed, so the full adult bounding box is not automatically exclusive ground space. Low plants may sit under outer crowns where their ground clearances fit. Root/contact vertices should remain stationary during wind. Review a temporary thin ground plane and an oblique camera in the authoring scene to catch gaps or protrusion; exclude that plane from the export.

Validate mature mixed gardens of approximately 10–15 plants using shared ground, consistent lighting/contact shadows and readable height layers. Check neighbouring crowns, branches and wind at intended spacing, and tree-heavy/duplicate combinations. This is an aesthetic target, not an approved count cap. V1 placement uses circles on a continuous ground plane; model yaw does not change clearance. Clearance rings and adult placement previews are shared app presentation, not meshes baked into plant exports.

## 5. Build and approve the adult first

1. Place the schematics in Blender as authoring references. Match the front/side/top silhouettes with simple trunk, branch and foliage masses.
2. Refine the trunk taper, branch junctions, roots and crown spacing. Preserve the species' recognisable structure and intentional asymmetry.
3. Compare a neutral three-quarter render against the schematics and oak style reference. Make silhouette and palette corrections before adding detailed materials or variants.
4. Build only geometry visible or needed for deformation. Use closed geometry for newly constructed solid parts and avoid accidental loose faces, internal debris and excessive intersections.
5. Set up simple, export-compatible materials. Use textures/UVs or supported material inputs; bake any essential procedural Blender shading into textures rather than assuming nodes will transfer to USDZ.
6. Save the approved editable adult in the species master source before deriving younger stages.

One skinned mesh and one material per exported plant is the oak target and a useful mobile baseline. Combine compatible parts and use a compact atlas where that preserves appearance. Geometry count is a measured budget, not a reason to damage silhouette or animation. Oak's adult base is approximately 5,900 triangles; use that as a reference rather than a universal requirement.

Do not bake studio lighting, a ground shadow or a background into the plant's base-colour texture. The game supplies its lighting. Keep the adult approval render outside the runtime pack.

## 6. Design the younger stages

Derive sprout, seedling and young designs from the approved adult's botanical features, palette and material language. These are individually designed growth stages, not uniformly scaled adult copies.

Every growth stage must have a noticeably different look from its neighbours. A change in size, colour or leaf count alone is insufficient: develop the silhouette, stem/trunk structure, branching, foliage arrangement or botanical maturity so the stages remain distinguishable when individually framed at the same thumbnail size. The seedling must already express age-appropriate qualities of the mature species rather than look like a larger sprout. For example, Moonwillow's seedling introduces a curved stem, small arching forks and its first hanging leafy shoots; its young and adult stages develop a stronger trunk and progressively fuller, more extensive weeping foliage. For flowering species, buds or blooms can mark maturity where consistent with the approved design. Record the intended visual differences between adjacent stages in the species source note.

| Stage | Modeling focus |
| --- | --- |
| Sprout | Clear small shoot, usually a few readable leaves; any exposed seed fragment shares the ground convention |
| Seedling | Longer stem and additional leaves; early botanical identity is easy to read |
| Young | Characteristic branching/structure begins to form, with a smaller and more open crown |
| Adult | Approved final proportions, full structure and mature crown |

Oak's sprout has two main leaves and its seedling has four; these are oak design choices, not mandatory counts for other species. Adapt the early form to the species while keeping the four-stage contract.

For visible early leaves, use a gently curved blade, coherent thickness/closed underside and a clean outline. Rounded lobes, a tapered raised midrib, subtle tonal gradients and faint secondary veins can add realism without changing the stylised theme. Review at thumbnail size: detail should support the shape rather than look like painted stripes. Avoid independent random colours on adjacent leaf triangles.

Oak uses a packed 512px atlas containing palette cells and a small detailed leaf region. This is an established example, not a requirement to give every species a larger texture. Use the smallest texture that looks clean on the target iPhone. Keep the palette and lighting consistent across stages.

Review the four standard stages together at both true relative scale and individually framed thumbnail scale. Verify a believable progression, clearly distinguishable adjacent stages, consistent surface quality and consistent ground contact before multiplying into variants. If two stages still look substantially alike when framed to the same size, revise their structure or foliage arrangement before exporting the collection.

## 7. Add shared wind animation

Use a lightweight skeletal rig so sway survives export and plays in the target viewer. Blender-only modifiers, drivers or simulations are insufficient unless their result is converted into supported exported animation.

1. Anchor the lower stem/trunk and ground-contact geometry to a stationary root/lowest bone.
2. Add a small structural bone chain with progressively greater motion higher up.
3. Use foliage/leaf bones where independent leaf or crown motion improves the result. Give each blade and its details consistent weights so veins and geometry move together.
4. Animate gentle, slightly offset oscillations. Keep trunks stable, foliage lively and the amplitude visible at garden scale without looking rubbery.
5. Make the first and final poses match exactly. Oak uses a five-second loop at 24 fps, frames 1–121 inclusive; retain this baseline unless a deliberate species change is justified.
6. Inspect several intermediate frames for gaps, root movement, leaf/stem separation and clipping.

Each stage can have its own rig/action because its structure changes. All variants of that same stage share the same rest rig, keyframes, duration and motion. In Blender they can reference one action; each delivered USDZ remains independently playable. Name actions predictably, for example `oak_seedling_sway`.

This is wind only. Do not bake future tap, placement, growth-transition or particle effects into every model.

## 8. Derive the approved variants

Build variants from the approved standard stage geometry and animation so revisions remain consistent.

- **Standard:** approved species palette and geometry.
- **Blue:** change foliage palette/texture tones while retaining the same shape, trunk treatment and wind. Make leaf veins compatible with the blue palette. Avoid accidentally recolouring the bark or sprout stem.
- **Vined:** add restrained clinging vines and small vine leaves. Fit them to the actual trunk/stem/acorn surface rather than a generic cylinder, and inspect from all sides for floating or buried sections. Weight them to the existing structural rig so they follow the same motion; do not introduce separate dangling-vine physics.

Scale vine density appropriately to each stage. Tiny sprouts need only a modest accent, while an adult can support a longer climbing vine. Preserve the primary plant silhouette and visible branching. Review variants together in the same light.

Rarity belongs in game configuration and can point to these visual variants. A rarity tier alone does not add more models, thumbnails or animation clips. Do not produce a combined blue-and-vined variant unless requested. Future runtime material overrides may reduce duplicated model data, but the current delivery is self-contained USDZs for straightforward iPhone use.

## 9. Render all stage thumbnails

Render the final model for **every stage and variant**, after geometry, materials and wind have been approved. Use Blender renders rather than independently generated 2D images, so thumbnails match the delivered 3D assets.

- PNG, RGBA, transparent background, 384×448 pixels for the established oak baseline.
- Consistent camera direction, orthographic projection, lighting, colour management and neutral wind pose across the collection.
- Frame each stage for readability with a consistent margin; sprouts can occupy a similar image area to adults even though their world sizes differ. Record that thumbnails are not a physical scale comparison.
- Keep leaves, vines and roots inside the image, without clipping or a cut-off shadow/background.
- Check alpha edges against both light and dark UI backgrounds. Do not bake names, rarity badges, frames or selection states into the image.
- Name each PNG exactly like its corresponding model, for example `oak-seedling-blue.png` and `oak-seedling-blue.usdz`.

Storage looks up this shared PNG using species/stage/variant. It saves the owned plant's ID, species, variant and growth progress, not a new image or live 3D scene. A plant moved back from the garden retains its current-stage thumbnail. The game implements the drag-preview-to-3D handoff separately.

Keep additional contact sheets, turnarounds and close-ups under `art/<species>-production/review/`. Only the required transparent thumbnails enter `assets/`.

## 10. Export the game models

1. Export from the approved production scene at the correct scale and frame range. Verify applied transforms and rest poses rather than blindly applying transforms that could break skinning.
2. Select only that stage/variant's mesh and rig. Export animation and embedded textures; exclude all cameras, lights, reference images, preview grounds and other variants.
3. Write the corresponding self-contained USDZ to `models/<species>-<stage>-<variant>.usdz`.
4. Ensure the wind action, joint weights, UVs, base colours and roughness survive export. Do not rely on an external texture path on the author's PC.
5. Repeat for all stage/variant combinations, preferably with a deterministic script driven by the catalogue matrix.

Save the editable production source independently as `<species>-master.blend`, with necessary textures packed and clear stage/variant collections. Keep the preview studio in that source if useful. Save only the intended production scene and dependencies when exporting a master from a busy live Blender session; do not delete unrelated scenes to obtain a clean file.

## 11. Write the species catalogue

Use the current [oak catalogue](assets/oak/v1/oak.json) as the concrete schema example. Include:

- Schema version, species ID, asset version, format, units and authoring up axis.
- `initialStage: "sprout"`, ordered stage IDs and approved variant IDs.
- Ground-centred placement convention, ground height, adult bounds reference and fixed-footprint policy across stages/variants; document any half-seed construction. Actual model bounds describe the visual envelope. The game species catalogue separately owns the circular clearance radius; do not derive or duplicate a gameplay radius from the full crown bounds or thumbnail pixels.
- Wind duration, frame rate/range, loop behaviour, shared motion across variants and anchored roots.
- A stage/variant lookup for thumbnails.
- One record per model: stage, variant, model path, thumbnail path, actual model bounds, animation name, file byte size and SHA-256.

Keep paths relative to the package root. Generate byte counts/checksums after the final exports. Update them whenever a referenced model changes. Validate that catalogue lookups resolve to exactly the delivered files.

Do not invent growth thresholds, rarity probabilities, owned-plant IDs or user progress inside the art catalogue. Game configuration/state owns those values. `initialStage` describes the expected starting asset; it does not implement unboxing or progression by itself.

## 12. Validate before packaging

Use meaningful checks once the final revision is ready:

| Check | Required result |
| --- | --- |
| Coverage | All four stages × all approved variants have models and thumbnails |
| Fresh import | Every USDZ reimports into an isolated temporary scene without missing dependencies |
| Ground/scale | Same placement origin, intended relative sizes, no accidental below-ground geometry or floating bases |
| Geometry | New solid parts are closed; no new loose/boundary defects, broken normals or accidental studio objects |
| Materials | Embedded textures, expected colours/UVs, deliberate material count and no unsupported essential shading |
| Surface definition | Leaves, stems/trunks and flowers where present have clear, smooth, refined surface definition comparable in quality to the approved oak trunk; verify close-ups, garden scale and exported materials |
| Growth distinction | Every adjacent stage has a noticeably different silhouette, structure or botanical maturity at individually framed thumbnail scale; size, colour or leaf-count changes alone do not pass |
| Motion | Visible sway, stable ground vertices, first/final loop poses match, variant bone poses agree at sampled times |
| Thumbnails | Correct variant/stage, RGBA transparency, agreed size, clean silhouette and uncropped margins |
| Catalogue | Valid JSON, correct paths/bounds/animation metadata, matching byte sizes and hashes |
| Archive | Exact runtime file set, readable ZIP, no extraneous authoring files |

Inspect the renders visually as well as checking files. A script cannot judge whether a crown hides the branches or a vein looks too strong. Check all stages together and view at least early-leaf detail, adult branching and vine contact. Keep validation reports outside the runtime pack.

Oak's existing approved adult trunk has 12 boundary edges; its validator records that inherited baseline. Its newly constructed sprout/seedling/young parts have no boundary edges. Do not copy this allowance blindly to another species or treat newly introduced holes as approved.

For iPhone review, transfer the USDZs through iCloud Drive or another file transfer and open them from Files in Quick Look. Check materials, transparency/visibility, scale and embedded sway. The earlier oak adult was approved on iPhone; later exports still need their own device review. Finally, test ground contact, stage swaps, lighting and a populated garden in the actual app on the chosen minimum device. Quick Look alone is not a game-performance test.

## 13. Package, refine and hand off

1. Put only the catalogue-declared USDZs, PNGs and one catalogue into `assets/<species>/<version>/`.
2. Remove explicitly superseded runtime files, such as old adult-only icons or a seed icon. Inspect the exact file list before removal; preserve authoring history outside the runtime pack.
3. Create `assets/<species>-<version>.zip` with the same runtime files and verify archive integrity and file contents.
4. Keep the latest editable master, scripts and a short source/rebuild note under `art/`. Reopen the master to verify its required objects, actions and textures are present before treating it as the editing handoff.
5. Supply the package link, one compact review sheet and a brief statement of validation and pending device checks. Do not include long repeated reports in the game package.

For revisions, update the approved source first and rebuild only affected outputs. A sprout geometry change affects its three models/thumbnails; a shared texture atlas change affects every export that embeds that atlas; a camera/lighting change requires the corresponding thumbnail set. Recalculate catalogue hashes and rebuild the ZIP after final changes. Avoid repeated full renders when a small preview can resolve a design question first.

Local v1 may be refined in place when authorised, as with oak. Once a version has been published to a CDN or relied on by released clients, publish a new immutable version rather than silently overwriting cached files.

## 14. Effects deferred to a later task

Current models contain wind sway. Stage transitions, tap/selection, dragging, placement, storage return and unboxing presentation are not implemented asset effects.

When that task resumes, build one shared runtime controller with a fixed placement parent and a separate animated visual child. Use a brief shared leaf/sparkle burst to conceal stage swaps, gentle selection/placement motion and shared reveal/return presentation. Preload the next model, preserve plant identity, avoid replaying celebrations on retries, cancel interrupted effects cleanly and limit concurrent particles. Validate reduced motion and the minimum supported iPhone.

Any small particle sprites or effect textures belong in a shared effects library, not duplicated in each species pack. Do not render transition videos, sprite sequences or additional per-plant effect models as part of this workflow unless explicitly requested later.

## 15. Existing oak implementation references

| Purpose | File |
| --- | --- |
| Final runtime directory | [assets/oak/v1/](assets/oak/v1/) |
| Downloadable package | [assets/oak-v1.zip](assets/oak-v1.zip) |
| Editable production source | [art/oak-production/oak-master.blend](art/oak-production/oak-master.blend) |
| Generator | [art/oak-production/build_oak_pack.py](art/oak-production/build_oak_pack.py) |
| Model import/motion validation | [art/oak-production/validate_oak_pack.py](art/oak-production/validate_oak_pack.py) |
| Runtime checks, review sheet and ZIP | [art/oak-production/package_oak.py](art/oak-production/package_oak.py) |
| Source/rebuild notes | [art/oak-production/SOURCE.md](art/oak-production/SOURCE.md) |
| Review sheet | [art/oak-production/review/oak-collection-review.jpg](art/oak-production/review/oak-collection-review.jpg) |

These scripts contain oak-specific paths, palette mappings and geometry assumptions. Adapt them deliberately for another species; do not execute them unchanged over a different plant. The oak builder expects the approved original adult source collection, so consult its source notes before rebuilding. This root guide and the current spec take precedence over older prototype workflow notes.
