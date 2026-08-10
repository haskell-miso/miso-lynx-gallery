# miso-lynx-gallery

The LynxJS [**Product Gallery** tutorial](https://lynxjs.org/learn/gallery),
rebuilt in Haskell on [miso](https://github.com/dmjio/miso)'s **native
(LynxJS dual-thread)** backend.

A full-height black page with a two-column **waterfall** `<list>` of rounded
furniture cards, each with a tap-to-like heart (white → red, with a one-shot
ripple), and native **auto-scroll**. It compiles to a real `.lynx.bundle` via
the GHC JavaScript backend + [rspeedy](https://lynxjs.org).

<p align="center"><em>75 cards · MVU · runs on the Lynx explorer / a Lynx host app</em></p>

## Layout

```
Main.hs                   -- the whole app (MVU: model, update, view)
styles.css                -- class rules + @keyframes (compiled into the bundle, cssId 0)
assets/
  furnitures/0.png..14.png -- the tutorial's 15 furniture photos (repeated x5 = 75 cards)
  redHeart.png whiteHeart.png
miso-lynx-gallery.cabal
cabal.project             -- builds against ../miso (a sibling checkout)
flake.nix                 -- inherits miso's dev shells + mkLynxBundle
```

## Prerequisites

- [Nix](https://nixos.org) with flakes enabled.
- A **miso checkout beside this repo** at `../miso` (that's where `cabal.project`
  finds the `miso` library). If you'd rather not vendor it, replace the
  `../miso` line in `cabal.project` with a `source-repository-package` pointing
  at `github.com/dmjio/miso`.

## Build & run

Enter the native toolchain shell (inherited from miso's flake — GHC JS backend,
`bun`, `rspeedy`) and build the bundle:

```bash
nix develop .#native
just bundle          # -> build/dist/main.lynx.bundle
just serve           # http://<host>:8080/main.lynx.bundle
```

Then point the **Lynx Explorer** app (or your Lynx host app) at
`http://<your-machine-ip>:8080/main.lynx.bundle`. `just rebuild` recompiles and
re-bundles; the explorer re-fetches on reload.

## How it works (notes)

- **MVU.** `model` is just the set of liked card indices. `update` toggles likes
  and kicks off native `autoScroll` on mount. `view` builds the waterfall.
- **CSS.** Lynx compiles CSS ahead-of-time under the global `cssId 0`, so
  `styles.css` is `import`ed by the rspeedy entry and `className "..."` resolves
  against it on device. Runtime `document`-style injection does **not** work on
  Lynx — hence the class-based approach and the `@keyframes ripple` in the CSS.
- **Images.** The Lynx `<image>` element can't resolve a relative `src` against
  the bundle, and rspeedy never sees the `src` strings the GHC JS backend
  generates. So `justfile`'s `bundle` recipe `import`s every PNG with `?inline`
  (rspeedy embeds each as a `data:` URI **in the bundle** — fully offline) and
  registers them by name on `globalThis.__galleryAssets`; `Main.hs`'s `asset`
  reads that registry back.

## Credit

Port of the official LynxJS gallery tutorial; furniture photos are the tutorial's
own sample images.
