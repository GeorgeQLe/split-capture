# Session history

## 2026-07-31

- Suppressed the upstream first-run setup wizard in Split OBS builds.
- Added idempotent Dual Capture shutdown that waits up to five seconds for active outputs to finalize.
- Marked successful application-exit finalization complete and retained incomplete manifests with `shutdown_timeout` when cleanup exceeds the deadline.
- Added shutdown lifecycle and manifest-completion logic coverage, and documented the application-exit behavior.
- Validation passed for the Debug `obs-studio` and `dual-capture-logic-test` build, all three Dual Capture CTests, and Git whitespace checks.
- Accepted cached-build warnings: bundled Qt frameworks target macOS 13 while the cache targets macOS 12, and generated Xcode copy/script phases report duplicate or always-run notices.
- Formatting validation was skipped because `clang-format` is not installed or available in the current environment.

## 2026-07-27

- Added the stable local macOS code-signing workflow for Dual Capture qualification.
- Hardened fresh-user handoff so evidence roots stay within an administrator-owned, non-writable staging directory under `/Users/Shared`.
- Added append-only manual checks, strict evidence finalization, and exhaustive positive/negative fixtures.
- Updated the qualification runbook and build-helper index.
- Validation passed for Bash syntax, ShellCheck, the targeted warnings-as-errors logic-test build, and all three Dual Capture CTests.
- Accepted an existing cached-build linker warning: bundled Qt frameworks target macOS 13 while the cached test configuration targets macOS 12. The changed Dual Capture target builds without warnings.
