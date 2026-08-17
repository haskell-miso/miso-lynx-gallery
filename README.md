# 📱 🛋️ miso-lynx-gallery

The LynxJS [**Product Gallery** tutorial](https://lynxjs.org/learn/gallery),
rebuilt in Haskell on [miso](https://github.com/dmjio/miso)'s **native
(LynxJS dual-thread)** backend.

<table>
<tr>
<td>

https://github.com/user-attachments/assets/db32d6b8-6a30-48d5-b92e-6f9be92387f2

</td>
<td>

https://github.com/user-attachments/assets/a9c5dfc2-2a53-42ef-83a8-ca8a8a363ba0

</td>
</tr>
</table>


A full-height black page with a two-column **waterfall** `<list>` of rounded
furniture cards, each with a tap-to-like heart (white → red, with a one-shot
ripple), and native **auto-scroll**. It compiles to a real `.lynx.bundle` via the
GHC JavaScript backend + [rspeedy](https://lynxjs.org), with the images embedded
inside the bundle — no asset server, fully offline.

<p align="center"><em>75 cards · MVU · runs on the LynxExplorer / any Lynx host app</em></p>

## Source

[Source](https://github.com/haskell-miso/miso-lynx-gallery/blob/product-detail/Main.hs)

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

## The `product-detail` branch

The `product-detail` branch is a second port from the same LynxJS tutorial
series — the [**Product Detail** tutorial](https://lynxjs.org/learn/product-detail),
a faithful reproduction of `lynx-family/lynx-examples/examples/swiper` (its final
`src/Swiper` stage). It replaces the gallery `Main.hs` with a hand-rolled,
high-performance **image swiper**: a horizontal track of full-width product
photos dragged with the finger and snapped to the nearest page on release, a live
page indicator that supports click-to-jump, over the product-detail chrome (price
card + order bar).

- **Dual-thread by construction.** All touch handling runs on the **main thread**
  (the sample's `main-thread:bindtouch*`) as `onTouch*Main` handlers; the only
  render-driving state (`Model`, just the highlighted page) lives on the
  **background thread**. The two are bridged explicitly: `Snapped`/`SetCurrent`
  cross MTS→BTS via `runOnBG`, and click-to-jump crosses BTS→MTS via `runOnMain`.
- **Main-thread scratch.** The drag state (offsets, velocity, cached track ref)
  is the sample's `useMainThreadRef`, here one `MainThreadRef Drag` touched only
  inside MTS handlers / rAF callbacks, so it never races the model.
- **vsync-coalesced follow loop.** `touchmove` only records where the finger
  wants the track; an `eachFrame` loop paints the latest offset once per frame
  (and samples velocity for flick detection), coalescing the device's bursty
  touch stream to one flush per frame. The snap on release is a native
  compositor `transition` (ease-out) — no per-frame JS during the tween.
- **`itemWidth`.** Page width is the sample's exact `SystemInfo.pixelWidth /
  SystemInfo.pixelRatio`, read from its true home `lynx.SystemInfo` (which is
  **MTS-only**), with a safe fallback so it never throws during render.

Same build flow as `main` — `nix build` → `result/main.lynx.bundle`. The assets
differ (`1.png`..`8.png`, `heart.png`, `star.png`, `back.png`); they're embedded
into the bundle the same way (see **How it works → Images** above).

## Credit

Port of the official LynxJS gallery tutorial; the furniture photos are the
tutorial's own sample images.
