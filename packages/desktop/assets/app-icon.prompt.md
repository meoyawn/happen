# Happen macOS app icons

Generated with the built-in imagegen tool. Each icon set contains the 16–1024 px macOS sizes, with transparent exterior padding.

- Release and Profile: teal Möbius strip in `../macos/Runner/Assets.xcassets/AppIcon.appiconset/`.
- Debug: golden amber Möbius strip in `../macos/Runner/Assets.xcassets/AppIconDebug.appiconset/`.
- Easter egg: toilet-paper roll with a Möbius twist in `../macos/Runner/Assets.xcassets/AppIconToiletPaper.appiconset/`.

On macOS and Windows, Settings → Appearance → App icon switches between Default and Toilet paper at runtime. The selection is saved per device. Default restores the original native icon, including the amber icon in a macOS debug build. Windows uses the multi-resolution `app-icons/toilet-paper.ico` for its running window icons.

Release and debug use a wide flat sheet ribbon with one half-twist, a broad left arc, a softly oval outline and an open center. Face width and material thickness are separate: the faces are broad, while the sheet has a single fine cut edge without a bevel, rounded lip or extrusion. The debug icon is a recolor of the finished release icon to keep the geometry consistent.

Changes to the bundled native default icons require a rebuild and relaunch. Switching to the toilet-paper icon in Settings applies immediately.

## Release prompt

Use case: precise-object-edit
Asset type: Happen macOS release app icon, square 1024 x 1024.
Input image 1: current teal Möbius ribbon icon, exact edit target. Keep its paper-thin material and fine edge.
Input image 2: earlier wider teal ribbon, reference for FACE WIDTH and oval outline ONLY. Do not copy its rounded rim or bulky material.
Primary request: make the FLAT RIBBON FACE in image 1 about 45 percent WIDER, especially around the left arc. Combine the generous face width of image 2 with the ultra-thin sheet construction of image 1. WIDER PAPER, SAME PAPER THICKNESS. Do not make the band narrower.
Construction: one broad flat sheet strip with exactly one 180-degree Möbius half-twist. The material is still paper-thin: a single fine cut edge, at most one pixel at 1024px, with absolutely no visible extrusion, sidewall, bevel or rounded lip. Flat across its width, smoothly bending along its length. Broad visible face on the left, foreground and upper arc. The shading should show a sheet bending through space, not a rounded or inflated cross-section. Keep the twist traceable and the center clearly open.
Keep a softly oval overall silhouette. Preserve the existing teal around #18B9A8, restrained satin finish, mint highlights and petrol shadows. Preserve the charcoal rounded-square tile, size, position, subtle tile rim, lighting, square canvas and transparent exterior padding exactly.
One finished icon only. No tubes, chunky ceramic, solid bangle, inflated torus, pinched center, extra twists, text, badges or watermark. Genuine alpha transparency outside the opaque tile; clean antialiased perimeter without dust or fringe.

## Debug prompt

Use case: precise-object-edit
Asset type: Happen macOS debug app icon, square 1024 x 1024.
Input image 1: finished teal BROAD FLAT SHEET Möbius ribbon icon, exact edit target.
Input image 2: existing amber icon, COLOR REFERENCE ONLY.
Change ONLY the teal ribbon's hue in image 1 to warm golden amber matching image 2: faces near #F2A331, pale gold highlights, amber-copper shadows.
Preserve image 1's geometry EXACTLY: the WIDE FLAT FACE, especially its broad left arc, the broad foreground and upper sections, single smooth 180-degree Möbius half-twist, oval silhouette and generous open center. Keep the material paper-thin with a single fine cut edge at most one pixel at 1024px. WIDE FACE, THIN SHEET. Do not narrow the band. Do not thicken its material, round its cross-section or add a bevel, lip, extrusion or sidewall. Retain the flat satin surface, gentle shading, pose, size, placement and soft shadow.
Preserve the charcoal rounded-square tile, its size, position, subtle tile rim, lighting, square canvas, antialiased perimeter and transparent exterior padding exactly.
One finished icon only. No text, badges, sparkles, watermark, extra pieces or objects. Genuine alpha transparency outside the opaque tile, clean perimeter without dust or fringe.

## Toilet-paper easter egg prompt

Use case: precise-object-edit
Asset type: Happen macOS alternate easter egg app icon, square 1024 x 1024.
Input image 1: approved teal Möbius release icon, exact reference for the dark rounded-square tile, framing, soft lighting and polished sculptural style.
Primary request: replace the teal sculpture with the visual joke "a toilet paper roll with a Möbius twist." One small immaculate white toilet-paper roll with a visible warm tan cardboard core, and its unwound broad paper sheet curving forward into a generous oval loop with ONE plainly visible 180-degree half-twist, returning behind the roll as if the supply is endless. The compact roll sits at the back/upper left of the loop, its cardboard core angled toward the viewer. The wide white strip makes the main foreground silhouette, with a graceful readable Möbius roll-over along the upper/right arc. One coherent sculpted object, simple, charming and immediately recognizable as toilet paper.
Materials: clean soft white tissue with very subtle quilt embossing and a few fine crosswise perforation lines. The unwound strip is broad but physically paper-thin, a fine cut edge without a chunky bevel or inflated cross-section. Gentle ivory shadows, restrained white highlights, tan cardboard visible only within the small roll. No torn dirty edges. Keep the design minimal enough to read as an app icon at 16px.
Composition: center the complete roll-and-loop sculpture in the tile, approximately 68 percent of tile width, generous breathing room, softly elevated three-quarter view. Match the approved icon's soft upper-left light, shallow tactile 3D finish and clean negative space.
Preserve exactly: original charcoal rounded-square tile, its size and position, subtle raised tile rim, square canvas, transparent exterior padding and smooth antialiased perimeter.
Output: one finished production app icon only. No bathroom scene, toilet bowl, people, face, mascot, text, badge, sparkles, watermark or mockup. Opaque tile, genuine alpha transparency outside the tile, clean perimeter without dust or fringe.

