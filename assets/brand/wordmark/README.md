# Screenpunk wordmark asset pack

Approved **v1 / Modular** custom lettering in Screenpunk's dark and light colors.

## Formats and variants

| Variant | Lettering | Background |
| --- | --- | --- |
| dark-transparent | Soot #15191C | Transparent |
| light-transparent | Porcelain #F4EFE5 | Transparent |
| dark-on-light | Soot #15191C | Porcelain #F4EFE5 |
| light-on-dark | Porcelain #F4EFE5 | Soot #15191C |

- `svg/`: four true vector exports containing letter paths, without embedded raster images or font dependencies.
- `png/`: 28 PNG exports, including true alpha transparency in transparent variants.
- `webp/`: 28 lossless WebP exports with pixels identical to the corresponding PNGs.
- `screenpunk-wordmark-preview.png`: both brand color pairings.
- `palette.json`: exact sRGB color values.
- `manifest.json`: dimensions, source provenance, checksums, and validation results.

Raster widths: **128, 256, 512, 1024, 2048, 2560, 4096 px**. Heights are **26, 52, 104, 208, 416, 520, 832 px** respectively. All exports retain the same 64:13 canvas aspect ratio with a small consistent edge margin. Width is encoded in the filename.

## Usage

Use SVG for responsive interfaces and scalable layouts. Use transparent PNG or WebP when SVG is unsuitable or for placement over an existing surface. Use the solid-background files when the approved color pairing should be contained within the asset.

Keep the aspect ratio and existing spacing; do not retype the name in a substitute font. The wordmark is custom artwork, not the body/UI typeface. The 128px export is included for compact preview use; inspect the thin internal openings at the actual displayed size before using a small raster. No formal minimum-size or clear-space rule is established by this pack.

## Provenance

The user approved v1 / Modular, whose canonical raster reference is `../../Wordmark/screenpunk-wordmark-v1.png`. These vector outlines were traced from the approved grayscale silhouette at subpixel precision, with gently smoothed vector contours. This is a faithful vector conversion rather than original font outlines; small raster-edge differences remain. The raster source is preserved unchanged. All color variants share identical lettering geometry.

The earlier lockup SVGs in `../../Lockups/` use an embedded raster wordmark mask. This pack supplies true vector lettering for future fully vector lockup exports. It does not silently replace the existing lockup studies.

## Verification

All 60 assets were generated successfully. Every SVG has ten vector glyph paths and no embedded image. The source and vector silhouettes have 99.89% intersection-over-union at the reference resolution. Both color pairings were visually inspected, including the s and e openings and the p counter. Every lossless WebP decodes to the same pixels as its PNG. The manifest records file checksums and dimensions.
