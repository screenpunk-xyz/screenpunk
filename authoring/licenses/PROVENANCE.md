# Supplemental notices

The npm lockfile pins all redistributed package tarballs by integrity. Most packages
carry their own LICENSE/NOTICE; those are copied into authoring and screen notices.
Some upstream npm tarballs omit a root license. The following supplemental notices
were read from upstream through the GitHub System Plugin on 2026-09-21:

- react-remove-scroll-bar 2.3.8: theKashey/react-remove-scroll-bar LICENSE, blob
  7c08c3990396ecefd90f99ff5d9a34f26f5b5616 (MIT; package declares MIT).
- Embla packages 8.6.0: davidjerleke/embla-carousel LICENSE, blob
  2376624f527f4f1e53887552e42b004ab4056898 at the npm gitHead
  0fe65834136f1aa35e4c1a4a477e5ccb4bb5ee54 (MIT; packages declare MIT).
- victory-vendor 37.3.6: FormidableLabs/victory LICENSE.txt, blob
  4d33f1aba85636b665016cabb1b991209177c606 at v37.3.6 commit
  d9d9ca2d5038d6ef9de91f2cef39e6fb2733baa6; vendored D3/InternMap notices are
  also retained from the exact npm package's lib-vendor directory (MIT AND ISC).
- @esbuild/darwin-arm64 0.28.2: LICENSE.md from the matching esbuild 0.28.2 npm package.

The react-remove-scroll-bar npm gitHead b3b1287aad81def2e2ae707274b74531b61ddbaf
is no longer resolvable through GitHub. Its pinned npm package declares MIT and the
same author; the retained upstream MIT notice supplies the missing license text.
Recheck provenance and notices on any package upgrade. shadcn source provenance is in ui/NOTICE.txt. Lucide's full
notice (including retained third-party attribution) accompanies the SVG collection.
