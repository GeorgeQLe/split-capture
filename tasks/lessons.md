# Lessons

## 2026-08-07: Re-archive after App Store validation fixes

- **What happened:** App Store validation rejected the first archive because
  `UIBackgroundModes` contained the unsupported `screen-capture` value and the
  1024px app icon retained an alpha channel. Re-uploading an older archive
  continued to report the same errors after the source was corrected.
- **Rule:** Before archiving an iOS submission, validate every background mode
  against the platform allowlist and verify the large app icon is fully opaque.
  After changing submission metadata or assets, create and upload a new archive;
  an existing archive does not refresh from later source changes.
