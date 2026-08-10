# miso-lynx-gallery

The LynxJS [**Product Gallery** tutorial](https://lynxjs.org/learn/gallery),
rebuilt in Haskell on [miso](https://github.com/dmjio/miso)'s **native
(LynxJS dual-thread)** backend.

A full-height black page with a two-column **waterfall** `<list>` of rounded
furniture cards, each with a tap-to-like heart (white → red, with a one-shot
ripple), and native **auto-scroll**. It compiles to a real `.lynx.bundle` via the
GHC JavaScript backend + [rspeedy](https://lynxjs.org), with the images embedded
inside the bundle — no asset server, fully offline.

<p align="center"><em>75 cards · MVU · runs on the LynxExplorer / any Lynx host app</em></p>

## Layout

```
Main.hs                     -- the whole app (MVU: model, update, view)
styles.css                  -- class rules + @keyframes (compiled into the bundle, cssId 0)
assets/
  furnitures/0.png..14.png  -- the tutorial's 15 furniture photos (repeated x5 = 75 cards)
  redHeart.png whiteHeart.png
miso-lynx-gallery.cabal
flake.nix                   -- consumes miso.lib.${system}.{ ghcNative, mkLynxBundle }
cabal.project               -- only for the incremental cabal dev loop (see below)
```

## Build

Just [Nix](https://nixos.org) (flakes enabled) — the flake pulls miso (the
`dual-thread` branch) and its toolchain, so you don't need anything else:

```bash
nix build           # -> result/main.lynx.bundle
```

Serve it and point a Lynx host at the bundle:

```bash
nix develop -c http-server result -p 8080
# then open LynxExplorer at  http://<your-machine-ip>:8080/main.lynx.bundle
```

(Any static file server works — e.g. `python3 -m http.server 8080 -d result`.)

## Hacking on miso at the same time

`nix build` uses miso from GitHub (`github:dmjio/miso/dual-thread`). To build
against a **local** miso checkout with uncommitted changes, override the input —
use an **absolute** path (a relative `path:../miso` doesn't resolve from a git
flake):

```bash
nix build --override-input miso path:/absolute/path/to/miso
```

For a faster edit→bundle loop than a full `nix build`, work in the toolchain
shell and drive cabal directly. `cabal.project` points at a sibling `../miso`
checkout for this:

```bash
nix develop .#native
cabal build --with-compiler=javascript-unknown-ghcjs-ghc \
            --with-hc-pkg=javascript-unknown-ghcjs-ghc-pkg
# then bundle the resulting all.js with rspeedy (see mkLynxBundle in miso)
```

## How it works

- **MVU.** `model` is just the set of liked card indices. `update` toggles a
  like and, on mount, kicks off native `autoScroll` (rate 60). `view` builds the
  two-column waterfall from the 15 furniture images cycled to 75 cards.
- **CSS.** Lynx compiles CSS ahead of time under the global `cssId 0`, so
  `styles.css` is `import`ed by the rspeedy entry and `className "…"` resolves
  against it on device (runtime `document`-style injection doesn't work on Lynx).
  The like ripple is a `@keyframes ripple` in that stylesheet.
- **Images.** The Lynx `<image>` element can't resolve a relative `src` against
  the bundle, and rspeedy never sees the `src` strings the GHC JS backend emits.
  So miso's `mkLynxBundle` `import`s every PNG with `?inline` (rspeedy embeds each
  as a `data:` URI **in the bundle**) and registers them by name on
  `globalThis.__galleryAssets`; `Main.hs`'s `asset` reads that registry back.
- **Bundling.** The whole `all.js → .lynx.bundle` step (minify, compile in
  `styles.css`, inline the assets) is miso's reusable
  `miso.lib.${system}.mkLynxBundle`, consumed by `flake.nix`.

## Credit

Port of the official LynxJS gallery tutorial; the furniture photos are the
tutorial's own sample images.
