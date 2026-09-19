# Brand provenance

Brand artwork is **not** Apache 2.0. Tokens are copied from the Codex guide.

| Field | Value |
| --- | --- |
| Brand repository | `screenpunk-xyz/Brand` |
| Brand commit | `4b01c13400622b726ac429373d075301a35779ef` |
| Style source | `Style-Guide/` (`dist/` site; `.openai/hosting.json` project `appgprj_6aa593debf9881918aba9a1f77ba8e00`) |
| Public Codex URL | https://screenpunk-style-guide.gsuter.chatgpt.site |
| Copied | 2026-09-12 |

## Identity assets

| Bundle | Brand path | Copied |
| --- | --- | --- |
| Logomark (v8 bevel) | `Exports/Screenpunk-Logomark/` | 4 SVG masters; PNG 32/128/256/512/1024 × 4 variants; README; palette |
| Wordmark (v1 Modular) | `Exports/Screenpunk-Wordmark/` | 4 SVG masters; PNG 256/512/1024 × 4 variants; README; palette |
| Lockups (v1) | `Lockups/` | horizontal/stacked × light/dark SVG+PNG; `APPROVED-V1.md` |
| Tokens | `Style-Guide/dist/data.js` | `assets/brand/style/tokens.json` |

Omitted: WebP duplicates, 2560/4096 rasters, v2 / Upright lockups, wordmark studies, GitHub avatar, under-review marks.

## Settled style contract

- Use published tokens, palette, and layout. If impractical, update `Brand/Style-Guide/`.
- Default lockup: **stacked**. Horizontal is an approved alternate.
- Offline ring and danger/error: `semanticTokens.*.danger` (`#A52C42` / `#FF8BA0`).
- Apple controls: iOS 27 / guide studies by default; older-OS-safe fallbacks. Targets iOS 16+ / macOS 26+. iOS 27 is not required to run.

Integrity: `scripts/verify-brand.mjs`.

## App icon — Raspberry Liquid Glass (2026-09-19)

The operator approved the pink-canvas B v8 character, then selected the closer
100% crop in Icon Composer and explicitly requested integration into both apps
and a GitHub PR. Decision recorded in Planning-Files,
`Icon-Composer/Screenpunk-Raspberry-v1/APPROVAL.md`.

- Source: approved `02h-dark-screen-raspberry-canvas-v8.png` from the Brand app-icon studies.
- Composer delivery: `Planning-Files/Icon-Composer/Screenpunk-Raspberry-v1/Screenpunk.icon`.
- Repository master: `assets/brand/app-icon/Screenpunk.icon`, shared by both app targets.
- Character RGB preserved exactly; operator authorized deterministic background alpha removal.
- Exact Raspberry #E66596 native fill; dark lenses; native specular, 20% shadow, no blur/translucency.
- Raster layer SHA-256: `8abbbd5d7b6b6e68e61c3ce4421900f9b959799bd4ca4d265d8467aea8b1a89f`.
- Brand artwork remains subject to the separate brand terms, not Apache 2.0.
