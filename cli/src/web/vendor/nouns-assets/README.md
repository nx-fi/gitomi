# Nouns Assets

Vendored from `nounsDAO/nouns-monorepo`, `packages/nouns-assets`.

- Source: https://github.com/nounsDAO/nouns-monorepo/tree/master/packages/nouns-assets
- Package: `@nouns/assets`
- License: GPL-3.0, copied in `LICENSE`

`image-data.json` is the official run-length encoded Nouns image data. `image_data.zig` is generated from that JSON so the Zig web renderer can build avatars without parsing JSON on every request.
