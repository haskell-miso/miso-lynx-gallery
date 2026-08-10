{
  description = "miso-lynx-gallery — the LynxJS Product Gallery, in Haskell (miso-native)";

  inputs = {
    miso.url = "github:dmjio/miso/dual-thread";
  };
  # For local miso development (with uncommitted changes), override the input to
  # a local checkout — note the ABSOLUTE path (relative `path:../miso` doesn't
  # resolve correctly from a git flake):
  #
  #   nix build --override-input miso path:/absolute/path/to/miso

  outputs = inputs:
    let miso = inputs.miso;
    in miso.inputs.flake-utils.lib.eachDefaultSystem (system:
      let
        inherit (miso.inputs.nixpkgs) lib;   # for lib.cleanSource

        # miso's GHC-JS (LynxJS) package set, with miso-native — exposed by miso's
        # flake, so we don't re-import nixpkgs + the overlay here.
        ghcNative = miso.lib.${system}.ghcNative;

        # The gallery app, compiled with the GHC JavaScript backend against
        # miso's native (-fnative) build.
        miso-lynx-gallery =
          ghcNative.callCabal2nix "miso-lynx-gallery" (lib.cleanSource ./.) {
            miso = ghcNative.miso-native;
          };

        # The Lynx bundle, via miso's shared helper: minifies all.js, compiles in
        # styles.css, and inlines the furniture/heart PNGs as data: URIs.
        bundle = miso.lib.${system}.mkLynxBundle {
          name = "miso-lynx-gallery-bundle";
          jsDrv = miso-lynx-gallery;
          exeName = "miso-lynx-gallery";
          assets = ./assets;
          styles = ./styles.css;
        };
      in
      {
        # `nix build` -> result/main.lynx.bundle
        packages = {
          default = bundle;
          inherit bundle;
          app = miso-lynx-gallery;
        };

        # Inherit miso's dev shells (toolchain: GHC JS backend, bun, rspeedy).
        devShells = {
          default = miso.devShells.${system}.default;
          native = miso.devShells.${system}.native;
          wasm = miso.devShells.${system}.wasm;
        };
      });
}
