# Screenpunk logomark asset pack

Approved bottom bevel mark, supplied in the Screenpunk dark and light colors.

## Colors

| Color | Hex | RGB |
| --- | --- | --- |
| Dark | #15191C | 21, 25, 28 |
| Light | #F4EFE5 | 244, 239, 229 |

## Variants

| Filename variant | Positive space | Background |
| --- | --- | --- |
| dark-transparent | #15191C | Transparent |
| light-transparent | #F4EFE5 | Transparent |
| dark-on-light | #15191C | #F4EFE5 |
| light-on-dark | #F4EFE5 | #15191C |

## Contents

- `svg/`: four scalable vector masters, one for each variant. Each contains the actual logo paths; no embedded raster images.
- `png/`: each variant at 32, 64, 128, 256, 512, 1024 and 2560 pixels square.
- `webp/`: the same variants and sizes, encoded losslessly.
- `screenpunk-logomark-preview.png`: the two solid color pairings.
- `palette.json`: the exact palette values.
- `manifest.json`: file dimensions, checksums, color assignments and source provenance.

The pack includes 60 logo assets: 4 SVG, 28 PNG and 28 WebP files. Raster exports use the sRGB color profile.

## Use

Use the dark mark on light backgrounds and the light mark on dark backgrounds. Transparent files retain the circular lens openings, goggle gaps and bottom bevel as true transparency. Solid versions fill the square canvas and the negative spaces with the complementary brand color.

SVG is the scalable master for interfaces, documents and other layouts. Use PNG for applications needing a raster file and lossless WebP for web use. All files share the same square canvas and positioning. Keep the proportions intact.

## Design provenance

These exports use the approved revision 8 bottom bevel design. The dark version retains the existing black variant's optical adjustments; the light version retains the approved white variant's geometry. The narrow bevel has rounded corners and a slightly higher right end, while the foreground remains one connected shape.

Only the colors and export formats change in this pack. The original SVG path data and PNG alpha shapes are preserved. Source files remain in `Brand/Logomark`.

## Verification

Verified the requested color values, raster sizes, transparent holes, native SVG paths, and unchanged source geometry. Every decoded WebP matches its PNG counterpart exactly. All source files are unchanged. The two color pairings were reviewed visually.
