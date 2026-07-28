#!/usr/bin/env bash

set -euo pipefail

runner="${1:?qualification runner path is required}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dual-capture-finalize.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

new_fixture() {
  local root="$1"
  mkdir -p "$root"/{output,logs,validators,resources,reports,state,stimulus}
  jq -n --arg root "$root" \
    '{app_executable:"/fixture/OBS",output_root:($root+"/output"),run_root:$root}' >"$root/config.json"
  : >"$root/events.jsonl"
  : >"$root/cases.jsonl"
  : >"$root/manual-checks.jsonl"
  : >"$root/stimulus/stimulus-results.jsonl"
}

add_case() {
  local root="$1" name="$2" expectation="$3" route="$4" desktop_audio="$5"
  local min="$6" max="$7" desktop_tracks="$8" camera_tracks="$9"
  jq -nc --arg case "$name" --arg expectation "$expectation" --arg route "$route" \
    --argjson desktop_audio "$desktop_audio" --argjson min "$min" --argjson max "$max" \
    --argjson desktop_tracks "$desktop_tracks" --argjson camera_tracks "$camera_tracks" '
    def tracks($count;$role):
      [range(1;$count+1) | {track:.,name:($role + " Track " + (.|tostring))}];
    {type:"case",case:$case,expectation:$expectation,result:"pass",
     duration_bounds:{min_seconds:$min,max_seconds:$max},
     expected_routing:{microphone_route:$route,desktop_audio:$desktop_audio,
       desktop_tracks:tracks($desktop_tracks;"Desktop"),
       camera_tracks:tracks($camera_tracks;"Camera")}}' >>"$root/cases.jsonl"
}

populate_complete() {
  local root="$1"
  new_fixture "$root"
  while IFS='|' read -r name route audio desktop camera; do
    add_case "$root" "$name" completed "$route" "$audio" 12 15 "$desktop" "$camera"
  done <<'EOF'
both_on|both|true|3|1
both_off|both|false|2|1
desktop_on|desktop|true|3|0
desktop_off|desktop|false|2|0
camera_on|camera|true|2|1
camera_off|camera|false|1|1
off_on|off|true|2|0
off_off|off|false|1|0
EOF
  add_case "$root" failpoint_preflight initialization-error off false 0 null 0 0
  add_case "$root" failpoint_desktop-start initialization-error off false 0 null 0 0
  add_case "$root" failpoint_camera-start initialization-error off false 0 null 0 0
  add_case "$root" stability_30m completed both true 1800 null 3 1
  add_case "$root" forced_termination interrupted both true 30 null 3 1

  {
    jq -nc '{type:"launch",pid:122,failpoint:"preflight"}'
    jq -nc '{type:"launch",pid:122,failpoint:"desktop-start"}'
    jq -nc '{type:"launch",pid:122,failpoint:"camera-start"}'
    jq -nc '{type:"launch",pid:123,failpoint:""}'
    jq -nc '{type:"monitor",pid:123,result:"pass",samples:31,rss_slope_kib_per_minute:100,
      ten_consecutive_post_warmup_rises:false}'
    jq -nc '{type:"kill-capture",signal:"SIGKILL",pid:123}'
  } >>"$root/events.jsonl"

  for check in \
    canonical_pregrant_blockers canonical_viewport_720x600 \
    signed_rebuild_permission_persistence portable_startup portable_config_containment \
    fresh_pregrant_blockers microphone_denied_routes output_path_missing \
    output_path_regular_file output_path_unwritable blocker_recording blocker_stream \
    blocker_replay_buffer blocker_virtual_camera controls_locked viewport_720x600 \
    settings_persistence manifest_ordering camera_release advanced_obs_handoff \
    stability_responsive stability_no_errors forced_termination_media_readable \
    forced_relaunch_recovery; do
    jq -nc --arg check "$check" '{check:$check,result:"pass",note:"fixture"}' \
      >>"$root/manual-checks.jsonl"
  done
  jq -nc '{check:"windows_workflow",result:"pass",note:"fixture",
    url:"https://github.com/example/split-obs/actions/runs/123456"}' >>"$root/manual-checks.jsonl"

  jq -c 'select(.case | test("^(both|desktop|camera|off)_(on|off)$")) |
    .case as $case |
    ["desktop","camera"][] as $role |
    .expected_routing[($role+"_tracks")][] |
    {case:$case,role:$role,track:.track,name:.name,result:"pass"}' "$root/cases.jsonl" \
    >"$root/stimulus/stimulus-results.jsonl"
}

expect_pass() {
  DUAL_CAPTURE_QUALIFICATION_RUN_ROOT="$1" "$runner" finalize >/dev/null
}

expect_fail() {
  if DUAL_CAPTURE_QUALIFICATION_RUN_ROOT="$1" "$runner" finalize >/dev/null 2>&1; then
    echo "expected finalize rejection for $1" >&2
    exit 1
  fi
}

complete="$fixture_root/complete"
populate_complete "$complete"
expect_pass "$complete"

for index in $(seq 0 12); do
  partial="$fixture_root/missing-case-$index"
  populate_complete "$partial"
  jq -c --argjson index "$index" 'select(input_line_number != ($index + 1))' \
    "$partial/cases.jsonl" >"$partial/cases.filtered"
  mv "$partial/cases.filtered" "$partial/cases.jsonl"
  expect_fail "$partial"
done

manual_count="$(wc -l <"$complete/manual-checks.jsonl" | tr -d ' ')"
for index in $(seq 0 $((manual_count - 1))); do
  partial="$fixture_root/missing-manual-$index"
  populate_complete "$partial"
  jq -c --argjson index "$index" 'select(input_line_number != ($index + 1))' \
    "$partial/manual-checks.jsonl" >"$partial/manual.filtered"
  mv "$partial/manual.filtered" "$partial/manual-checks.jsonl"
  expect_fail "$partial"
done

audio_count="$(wc -l <"$complete/stimulus/stimulus-results.jsonl" | tr -d ' ')"
for index in $(seq 0 $((audio_count - 1))); do
  partial="$fixture_root/missing-audio-$index"
  populate_complete "$partial"
  jq -c --argjson index "$index" 'select(input_line_number != ($index + 1))' \
    "$partial/stimulus/stimulus-results.jsonl" >"$partial/audio.filtered"
  mv "$partial/audio.filtered" "$partial/stimulus/stimulus-results.jsonl"
  expect_fail "$partial"
done

for event in monitor kill-capture; do
  partial="$fixture_root/missing-$event"
  populate_complete "$partial"
  jq -c --arg event "$event" 'select(.type != $event)' "$partial/events.jsonl" \
    >"$partial/events.filtered"
  mv "$partial/events.filtered" "$partial/events.jsonl"
  expect_fail "$partial"
done

for failpoint in preflight desktop-start camera-start; do
  partial="$fixture_root/missing-launch-$failpoint"
  populate_complete "$partial"
  jq -c --arg failpoint "$failpoint" \
    'select(.type != "launch" or .failpoint != $failpoint)' "$partial/events.jsonl" \
    >"$partial/events.filtered"
  mv "$partial/events.filtered" "$partial/events.jsonl"
  expect_fail "$partial"
done

for result_file in manual-checks.jsonl stimulus/stimulus-results.jsonl; do
  partial="$fixture_root/nonpassing-${result_file//\//-}"
  populate_complete "$partial"
  jq -c 'if input_line_number == 1 then .result="skip" else . end' "$partial/$result_file" \
    >"$partial/result.filtered"
  mv "$partial/result.filtered" "$partial/$result_file"
  expect_fail "$partial"
done

partial="$fixture_root/bad-windows-url"
populate_complete "$partial"
jq -c 'if .check == "windows_workflow" then .url="https://example.com/not-a-run" else . end' \
  "$partial/manual-checks.jsonl" >"$partial/manual.filtered"
mv "$partial/manual.filtered" "$partial/manual-checks.jsonl"
expect_fail "$partial"

if [[ "$(uname -s)" == Darwin ]]; then
  if handoff_error="$(
    "$runner" handoff \
      --user nobody \
      --app /private/tmp/nonexistent/OBS.app \
      --output-root /Users/Shared/../../unsafe-output \
      --run-root /Users/Shared/../../unsafe-run 2>&1
  )"; then
    echo "expected handoff to reject paths that escape /Users/Shared" >&2
    exit 1
  fi
  grep -Fq \
    "must be below an administrator-owned staging directory in /Users/Shared" \
    <<<"$handoff_error" || {
      echo "handoff rejected the traversal path for an unexpected reason" >&2
      printf '%s\n' "$handoff_error" >&2
      exit 1
    }
fi

echo "qualification finalize fixtures: PASS"
