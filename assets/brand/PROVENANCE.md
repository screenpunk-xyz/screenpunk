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
