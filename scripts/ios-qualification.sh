#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
short_sha="$(git -C "$repo_root" rev-parse --short HEAD)"
revision="${SPLIT_CAPTURE_QUALIFICATION_REVISION:-r1}"
evidence_root="${SPLIT_CAPTURE_EVIDENCE_ROOT:-/Users/Shared/split-capture-ios-qualification-${short_sha}-${revision}}"
manifest="$evidence_root/manifest.log"
results="$evidence_root/manual-results.tsv"

usage() {
  print "Usage:"
  print "  $0 init"
  print "  $0 build [destination]"
  print "  $0 result <scenario> <PASS|FAIL|BLOCKED> <notes>"
  print "  $0 import <scenario> <path>"
  print "  $0 verify <path-to-mp4>"
  print "  $0 console <device-identifier> [seconds]"
  print "  $0 report"
}

append_manifest() {
  print -- "$(date -u +%Y-%m-%dT%H:%M:%SZ)\t$*" >> "$manifest"
}

require_initialized() {
  if [[ ! -d "$evidence_root" || ! -f "$manifest" ]]; then
    print -u2 "Run '$0 init' first."
    exit 2
  fi
}

case "${1:-}" in
  init)
    mkdir -p "$evidence_root"/{build,console,exports,ffprobe,screenshots}
    touch "$manifest" "$results"
    append_manifest "INIT	repository=$repo_root	sha=$short_sha	revision=$revision"
    {
      print "=== xcodebuild -version ==="
      xcodebuild -version
      print "=== iPhoneOS SDK ==="
      xcrun --sdk iphoneos --show-sdk-version
      print "=== paired devices ==="
      xcrun devicectl list devices
    } 2>&1 | tee -a "$evidence_root/toolchain.log"
    append_manifest "SNAPSHOT	toolchain=$evidence_root/toolchain.log"
    print "$evidence_root"
    ;;
  build)
    require_initialized
    destination="${2:-generic/platform=iOS}"
    log="$evidence_root/build/build-$(date -u +%Y%m%dT%H%M%SZ).log"
    set +e
    xcodebuild \
      -project "$repo_root/ios/SplitCapture.xcodeproj" \
      -scheme SplitCapture \
      -configuration Debug \
      -destination "$destination" \
      -derivedDataPath "$evidence_root/build/DerivedData" \
      build 2>&1 | tee -a "$log"
    status=${pipestatus[1]}
    set -e
    append_manifest "BUILD	status=$status	destination=$destination	log=$log"
    exit "$status"
    ;;
  result)
    require_initialized
    [[ $# -ge 4 ]] || { usage; exit 2; }
    scenario="$2"
    status="$3"
    notes="$4"
    [[ "$status" == PASS || "$status" == FAIL || "$status" == BLOCKED ]] || {
      print -u2 "Status must be PASS, FAIL, or BLOCKED."
      exit 2
    }
    print -- "$(date -u +%Y-%m-%dT%H:%M:%SZ)\t$scenario\t$status\t$notes" >> "$results"
    append_manifest "RESULT	scenario=$scenario	status=$status"
    ;;
  import)
    require_initialized
    [[ $# -eq 3 ]] || { usage; exit 2; }
    scenario="$2"
    source_path="$3"
    [[ -f "$source_path" ]] || { print -u2 "No file: $source_path"; exit 2; }
    extension="${source_path##*.}"
    destination="$evidence_root/exports/${scenario}-$(date -u +%Y%m%dT%H%M%SZ).${extension}"
    cp -n "$source_path" "$destination"
    shasum -a 256 "$destination" | tee -a "$evidence_root/checksums.sha256"
    append_manifest "IMPORT	scenario=$scenario	file=$destination"
    print "$destination"
    ;;
  verify)
    require_initialized
    [[ $# -eq 2 ]] || { usage; exit 2; }
    source_path="$2"
    [[ -f "$source_path" ]] || { print -u2 "No file: $source_path"; exit 2; }
    command -v ffprobe >/dev/null || { print -u2 "ffprobe is required."; exit 2; }
    output="$evidence_root/ffprobe/$(basename "$source_path").json"
    ffprobe -v error \
      -show_format \
      -show_streams \
      -of json \
      "$source_path" 2>&1 | tee -a "$output"
    append_manifest "FFPROBE	file=$source_path	output=$output"
    ;;
  console)
    require_initialized
    [[ $# -ge 2 ]] || { usage; exit 2; }
    device="$2"
    seconds="${3:-60}"
    log="$evidence_root/console/console-$(date -u +%Y%m%dT%H%M%SZ).log"
    append_manifest "CONSOLE_BEGIN	device=$device	seconds=$seconds	log=$log"
    xcrun devicectl device info processes --device "$device" > /dev/null
    print "Collect device console in Xcode’s Devices and Simulators window for ${seconds}s." | tee -a "$log"
    append_manifest "CONSOLE_END	device=$device	log=$log"
    ;;
  report)
    require_initialized
    report="$repo_root/test-reports/ios-screen-capture-qualification-$(date +%Y-%m-%d).md"
    if [[ -e "$report" ]]; then
      print -u2 "Refusing to overwrite existing report: $report"
      exit 3
    fi
    mkdir -p "$(dirname "$report")"
    {
      print "# iOS Screen Capture Qualification"
      print
      print "- Repository SHA: \`$short_sha\`"
      print "- Evidence: \`$evidence_root\`"
      print "- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      print
      print "## Manual results"
      print
      print "| Time (UTC) | Scenario | Result | Notes |"
      print "|---|---|---|---|"
      while IFS=$'\t' read -r timestamp scenario status notes; do
        [[ -n "$timestamp" ]] || continue
        print "| $timestamp | $scenario | $status | $notes |"
      done < "$results"
      print
      print "## Evidence manifest"
      print
      print '```text'
      sed -n '1,240p' "$manifest"
      print '```'
    } > "$report"
    append_manifest "REPORT	file=$report"
    print "$report"
    ;;
  *)
    usage
    exit 2
    ;;
esac
