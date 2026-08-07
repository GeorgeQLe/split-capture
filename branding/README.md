# Split Capture Brand

Split Capture uses two offset capture frames opening into distinct outputs. The
mark is designed to remain recognizable at 16 px without text or reliance on
fine detail. Concept C was selected because its diagonal separation reads most
clearly at small sizes and adapts cleanly to macOS, Windows, and Linux.

## Identity

- Product: **Split Capture**
- Publisher: **GeorgeQLe**
- Application ID: `com.lexcorp.splitcapture`
- Homepage: <https://github.com/GeorgeQLe/split-capture>
- Description: Synchronized desktop and camera recording to separate,
  recoverable files.

## Palette

- Deep navy: `#071A2B`
- Navy highlight: `#0B2740`
- Bright cyan: `#2DD4F7`
- Pale cyan: `#B9F4FF`
- Recording coral: `#FF6B5E`

## Final generation prompt

> Design a distinctive split-frame capture mark: two synchronized rounded
> rectangular frames overlap briefly at center, then visibly peel apart into
> separate upper-left and lower-right outputs. Use a deep navy rounded-square
> app tile, bold cyan frame geometry, one restrained coral recording indicator,
> generous safe margins, and a strong silhouette that remains clear at 16 px.
> Keep it vector-friendly and subtly dimensional. No text, letters, camera
> lens, OBS swirl, watermark, photorealistic object, or play icon.

The three ImageGen explorations are retained in `branding/concepts/`. The
selected concept is design input only; shipped assets are rendered from the
deterministic `branding/split-capture-icon.svg` master.

## Regeneration

Run:

```sh
scripts/branding/generate-icons.sh
```

The script requires ImageMagick. On macOS it first asks `iconutil` to produce
the packaging ICNS and validates the result. If the host rejects the classic
iconset, the script uses the bundled deterministic PNG-backed ICNS packer and
validates that result with `iconutil`. It renders the 1024 px master PNG, all
ten macOS asset-catalog slots, the Windows multi-resolution ICO used by the
application and updater, and Linux 128/256/512 px PNGs plus the scalable SVG.
