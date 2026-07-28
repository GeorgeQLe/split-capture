# Session history

## 2026-07-27

- Added the stable local macOS code-signing workflow for Dual Capture qualification.
- Hardened fresh-user handoff so evidence roots stay within an administrator-owned, non-writable staging directory under `/Users/Shared`.
- Added append-only manual checks, strict evidence finalization, and exhaustive positive/negative fixtures.
- Updated the qualification runbook and build-helper index.
- Validation passed for Bash syntax, ShellCheck, the targeted warnings-as-errors logic-test build, and all three Dual Capture CTests.
- Accepted an existing cached-build linker warning: bundled Qt frameworks target macOS 13 while the cached test configuration targets macOS 12. The changed Dual Capture target builds without warnings.
