#!/usr/bin/env bash

set -u
set -o pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
validator="$script_directory/validate-session.sh"
repository_root="$(cd "$script_directory/../.." && pwd)"
macos_signing_helper="$repository_root/build-aux/split-obs-macos-dev.sh"
if [[ ! -x "$macos_signing_helper" && -x "$script_directory/split-obs-macos-dev.sh" ]]; then
  macos_signing_helper="$script_directory/split-obs-macos-dev.sh"
fi

usage() {
  cat <<'EOF'
usage: qualification-runner.sh COMMAND [OPTIONS]

Commands:
  init --app APP --output-root DIR --run-root DIR
  handoff --user USER --app APP --output-root DIR --run-root DIR
  launch [--failpoint NAME]
  capture --case NAME [--min-seconds N --max-seconds N]
  monitor --pid PID [--minutes 30 --interval 60]
  kill-capture --pid PID [--after 30]
  manual-check --check ID --result pass|fail|skip --note TEXT [--url URL]
  finalize
  validate
  report

Run `init` first. Later commands locate the run through
DUAL_CAPTURE_QUALIFICATION_RUN_ROOT, or through .qualification-run-root in the
current directory. Evidence files and the case ledger are append-only.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' was not found"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

unique_path() {
  local directory="$1"
  local stem="$2"
  local extension="$3"
  local candidate counter=0
  while true; do
    candidate="$directory/${stem}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    (( counter > 0 )) && candidate="${candidate}-${counter}"
    candidate="${candidate}${extension}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
    counter=$((counter + 1))
  done
}

resolve_run_root() {
  if [[ -n "${DUAL_CAPTURE_QUALIFICATION_RUN_ROOT:-}" ]]; then
    run_root="$DUAL_CAPTURE_QUALIFICATION_RUN_ROOT"
  elif [[ -f .qualification-run-root ]]; then
    IFS= read -r run_root <.qualification-run-root
  else
    die "set DUAL_CAPTURE_QUALIFICATION_RUN_ROOT or run from a directory containing .qualification-run-root"
  fi
  [[ -f "$run_root/config.json" ]] || die "run is not initialized: $run_root"
  config="$run_root/config.json"
  output_root="$(jq -r .output_root "$config")"
  app_executable="$(jq -r .app_executable "$config")"
  ledger="$run_root/cases.jsonl"
  events="$run_root/events.jsonl"
}

atomic_state() {
  local content="$1"
  local target="$run_root/state/current-launch.json"
  local temporary
  temporary="$(mktemp "$run_root/state/.current-launch.XXXXXX")" || exit 2
  printf '%s\n' "$content" >"$temporary"
  mv "$temporary" "$target"
}

record_event() {
  local kind="$1"
  local data='{}'
  local line
  (( $# >= 2 )) && data="$2"
  line="$(jq -nc --arg timestamp "$(utc_now)" --arg kind "$kind" --argjson data "$data" \
    '{timestamp:$timestamp,type:$kind} + $data')" ||
    die "could not encode '$kind' lifecycle event"
  printf '%s\n' "$line" >>"$events" || die "could not append '$kind' lifecycle event"
}

verify_recorded_pid() {
  local requested_pid="$1"
  [[ "$requested_pid" =~ ^[1-9][0-9]*$ ]] || die "PID must be a positive integer"
  local state="$run_root/state/current-launch.json"
  [[ -f "$state" ]] || die "no launch has been recorded"
  local recorded_pid
  recorded_pid="$(jq -r .pid "$state")"
  [[ "$requested_pid" == "$recorded_pid" ]] ||
    die "PID $requested_pid is not the exact recorded OBS PID $recorded_pid"
}

canonical_new_shared_path() {
  local candidate="$1"
  local label="$2"
  local parent base canonical_parent owner mode_text mode
  [[ "$candidate" == /* && "$candidate" != */ ]] ||
    die "$label must be an absolute path without a trailing slash"
  parent="$(dirname "$candidate")"
  base="$(basename "$candidate")"
  [[ "$base" != . && "$base" != .. && -d "$parent" ]] ||
    die "$label must have an existing parent directory"
  canonical_parent="$(cd -P "$parent" && pwd)" ||
    die "could not resolve the parent directory for $label"
  [[ "$canonical_parent" == /Users/Shared/* ]] ||
    die "$label must be below an administrator-owned staging directory in /Users/Shared"

  owner="$(stat -f %Su "$canonical_parent")" ||
    die "could not inspect the parent directory for $label"
  [[ "$owner" == "$(id -un)" ]] ||
    die "$label parent must be owned by the signing administrator"
  mode_text="$(stat -f %OLp "$canonical_parent")" ||
    die "could not inspect permissions for the parent directory of $label"
  mode=$((8#$mode_text))
  (( (mode & 0022) == 0 )) ||
    die "$label parent must not be group- or world-writable"

  printf '%s/%s\n' "$canonical_parent" "$base"
}

command_init() {
  local app=''
  local app_bundle=''
  local output=''
  local root=''
  local write_marker=1
  while (( $# > 0 )); do
    case "$1" in
      --app) app="${2:-}"; shift 2 ;;
      --output-root) output="${2:-}"; shift 2 ;;
      --run-root) root="${2:-}"; shift 2 ;;
      --no-marker) write_marker=0; shift ;;
      *) die "unknown or incomplete init argument '$1'" ;;
    esac
  done
  [[ -n "$app" && -n "$output" && -n "$root" ]] || die "init requires --app, --output-root, and --run-root"
  require_tool jq
  if [[ -d "$app" && "$app" == *.app ]]; then
    app_bundle="$app"
    app="$app/Contents/MacOS/OBS"
  elif [[ "$app" == */Contents/MacOS/* ]]; then
    app_bundle="${app%/Contents/MacOS/*}"
  fi
  [[ -x "$app" ]] || die "OBS executable is not executable: $app"
  if [[ "$(uname -s)" == Darwin ]]; then
    [[ -x "$macos_signing_helper" ]] ||
      die "macOS qualification requires the repository signing helper: $macos_signing_helper"
    [[ -n "$app_bundle" && -d "$app_bundle" ]] ||
      die "macOS qualification requires an OBS application bundle"
    "$macos_signing_helper" verify "$app_bundle" ||
      die "macOS qualification requires a stable app signed by the pinned local development identity"
  fi
  mkdir -p "$output" "$root" "$root/logs" "$root/validators" "$root/resources" \
    "$root/reports" "$root/state" "$root/stimulus"

  local app_absolute output_absolute root_absolute config_path
  app_absolute="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  output_absolute="$(cd "$output" && pwd)"
  root_absolute="$(cd "$root" && pwd)"
  config_path="$root_absolute/config.json"
  if [[ -e "$config_path" ]]; then
    jq -e --arg app "$app_absolute" --arg output "$output_absolute" --arg root "$root_absolute" \
      '.app_executable == $app and .output_root == $output and .run_root == $root' "$config_path" \
      >/dev/null || die "existing run configuration differs; choose a new run root"
  else
    jq -n --arg initialized_at "$(utc_now)" --arg app "$app_absolute" \
      --arg output "$output_absolute" --arg root "$root_absolute" \
      '{schema_version:1,initialized_at:$initialized_at,app_executable:$app,
        output_root:$output,run_root:$root}' >"$config_path"
  fi
  touch "$root_absolute/cases.jsonl" "$root_absolute/events.jsonl" \
    "$root_absolute/manual-checks.jsonl"
  if [[ "$write_marker" -eq 0 ]]; then
    :
  elif [[ -f .qualification-run-root ]]; then
    local recorded_root
    IFS= read -r recorded_root <.qualification-run-root
    [[ "$recorded_root" == "$root_absolute" ]] ||
      die ".qualification-run-root already points to preserved run '$recorded_root'; use the environment variable for this run"
  else
    printf '%s\n' "$root_absolute" >.qualification-run-root
  fi
  run_root="$root_absolute"
  events="$run_root/events.jsonl"
  record_event init "$(jq -nc --arg app "$app_absolute" --arg output "$output_absolute" \
    '{app_executable:$app,output_root:$output}')"
  echo "Initialized append-only qualification run: $root_absolute"
  echo "Configure the dashboard output root as: $output_absolute"
}

command_handoff() {
  [[ "$(uname -s)" == Darwin ]] || die "handoff is supported only on macOS"
  local user='' app='' output='' root=''
  while (( $# > 0 )); do
    case "$1" in
      --user) user="${2:-}"; shift 2 ;;
      --app) app="${2:-}"; shift 2 ;;
      --output-root) output="${2:-}"; shift 2 ;;
      --run-root) root="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete handoff argument '$1'" ;;
    esac
  done
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "handoff requires a valid --user short name"
  [[ -n "$app" && -n "$output" && -n "$root" ]] ||
    die "handoff requires --user, --app, --output-root, and --run-root"
  output="$(canonical_new_shared_path "$output" "output root")" || return
  root="$(canonical_new_shared_path "$root" "run root")" || return
  [[ "$output" != "$root" ]] || die "output and run roots must differ"
  [[ ! -e "$output" && ! -e "$root" ]] ||
    die "handoff refuses to reuse an existing output or run root"
  require_tool dscl
  require_tool dseditgroup
  require_tool sudo
  dscl . -read "/Users/$user" UniqueID >/dev/null 2>&1 ||
    die "standard user '$user' does not exist"
  if dseditgroup -o checkmember -m "$user" admin 2>/dev/null | grep -q 'yes'; then
    die "handoff target '$user' is an administrator, not a standard user"
  fi

  # Signature verification happens inside init before either evidence root exists.
  command_init --app "$app" --output-root "$output" --run-root "$root" --no-marker
  local administrator
  administrator="$(id -un)"
  [[ -d "$output" && ! -L "$output" && "$(stat -f %Su "$output")" == "$administrator" ]] ||
    die "output root changed unexpectedly before protected handoff"
  [[ -d "$root" && ! -L "$root" && "$(stat -f %Su "$root")" == "$administrator" ]] ||
    die "run root changed unexpectedly before protected handoff"
  echo "macOS may request the signing administrator's password to transfer only:"
  printf '  %s\n  %s\n' "$output" "$root"
  sudo chown -R "$user":staff "$output" "$root" ||
    die "could not transfer the initialized roots to '$user'"
  [[ "$(stat -f %Su "$output")" == "$user" && "$(stat -f %Su "$root")" == "$user" ]] ||
    die "handoff ownership verification failed"
  echo "Protected handoff complete. No signing identity material was transferred."
}

command_launch() {
  local failpoint=
  while (( $# > 0 )); do
    case "$1" in
      --failpoint) failpoint="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete launch argument '$1'" ;;
    esac
  done
  case "$failpoint" in ""|preflight|desktop-start|camera-start) ;; *) die "invalid failpoint '$failpoint'" ;; esac
  local existing_state="$run_root/state/current-launch.json"
  if [[ -f "$existing_state" ]]; then
    local existing_pid
    existing_pid="$(jq -r .pid "$existing_state")"
    if kill -0 "$existing_pid" 2>/dev/null; then
      die "recorded OBS PID $existing_pid is still running"
    fi
  fi

  local log pid started_at state
  log="$(unique_path "$run_root/logs" launch .log)"
  started_at="$(utc_now)"
  local -a args=(--portable --multi --only-bundled-plugins --disable-updater)
  [[ -n "$failpoint" ]] && args+=("--dual-capture-failpoint=$failpoint")
  (
    cd "$(dirname "$app_executable")" || exit 2
    exec "$app_executable" "${args[@]}"
  ) >"$log" 2>&1 &
  pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: OBS exited during launch; see $log" >&2
    return 1
  fi
  state="$(jq -nc --argjson pid "$pid" --arg started_at "$started_at" --arg log "$log" \
    --arg failpoint "$failpoint" --arg executable "$app_executable" \
    '{pid:$pid,started_at:$started_at,log:$log,failpoint:$failpoint,executable:$executable}')"
  atomic_state "$state"
  printf '%s\n' "$state" >>"$run_root/state/launches.jsonl"
  record_event launch "$state"
  echo "Launched exact OBS PID: $pid"
  echo "Launch log: $log"
}

command_capture() {
  local case_name=''
  local min_seconds=''
  local max_seconds=''
  while (( $# > 0 )); do
    case "$1" in
      --case) case_name="${2:-}"; shift 2 ;;
      --min-seconds) min_seconds="${2:-}"; shift 2 ;;
      --max-seconds) max_seconds="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete capture argument '$1'" ;;
    esac
  done
  [[ -n "$case_name" && "$case_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "--case is required and must use letters, numbers, dot, underscore, or dash"
  local before_file
  before_file="$(mktemp "$run_root/state/.sessions-before.XXXXXX")" || exit 2
  find "$output_root" -mindepth 1 -maxdepth 1 -type d -print | sort >"$before_file"
  echo "Waiting for operator to start case '$case_name' in OBS..."

  local timeout=600
  if [[ -n "$max_seconds" ]]; then
    timeout="$(awk -v max="$max_seconds" 'BEGIN { printf "%d", max + 180 }')"
  fi
  local deadline=$((SECONDS + timeout))
  local session=''
  local detected_at=''
  while (( SECONDS <= deadline )); do
    while IFS= read -r candidate; do
      if ! grep -Fqx "$candidate" "$before_file" && [[ -f "$candidate/session.json" ]]; then
        session="$candidate"
        detected_at="$(utc_now)"
        break 2
      fi
    done < <(find "$output_root" -mindepth 1 -maxdepth 1 -type d -print | sort)
    sleep 1
  done
  rm -f "$before_file"
  [[ -n "$session" ]] || { echo "error: no new session appeared within $timeout seconds" >&2; return 1; }
  echo "Associated '$case_name' with $session"

  local state=recording
  deadline=$((SECONDS + timeout))
  while (( SECONDS <= deadline )); do
    state="$(jq -r '
      if .completed == true then "completed"
      elif .stop_reason == "initialization_error" then "initialization-error"
      else "recording"
      end
    ' "$session/session.json" 2>/dev/null || echo recording)"
    [[ "$state" != recording ]] && break
    local launch_state="$run_root/state/current-launch.json"
    if [[ -f "$launch_state" ]]; then
      local launched_pid
      launched_pid="$(jq -r .pid "$launch_state")"
      if ! kill -0 "$launched_pid" 2>/dev/null; then
        state=interrupted
        sleep 2
        break
      fi
    fi
    sleep 1
  done
  [[ "$state" != recording ]] ||
    { echo "error: case did not settle within $timeout seconds" >&2; return 1; }

  local expected_state="$state"
  [[ "$expected_state" == interrupted ]] || [[ "$expected_state" == completed ]] ||
    expected_state=initialization-error
  local validator_log validator_result=pass
  validator_log="$(unique_path "$run_root/validators" "$case_name" .log)"
  local -a validator_args=(--expect "$expected_state")
  [[ -n "$min_seconds" ]] && validator_args+=(--min-seconds "$min_seconds")
  [[ -n "$max_seconds" ]] && validator_args+=(--max-seconds "$max_seconds")
  if ! "$validator" "${validator_args[@]}" "$session" >"$validator_log" 2>&1; then
    validator_result=fail
  fi

  local manifest="$session/session.json"
  local desktop_size=0 camera_size=0
  [[ -f "$session/desktop.mp4" ]] &&
    desktop_size="$(stat -f %z "$session/desktop.mp4" 2>/dev/null || stat -c %s "$session/desktop.mp4")"
  [[ -f "$session/camera.mp4" ]] &&
    camera_size="$(stat -f %z "$session/camera.mp4" 2>/dev/null || stat -c %s "$session/camera.mp4")"
  local entry
  entry="$(jq -nc --arg timestamp "$(utc_now)" --arg case "$case_name" --arg session "$session" \
    --arg expectation "$expected_state" --arg result "$validator_result" --arg validator "$validator_log" \
    --arg min_seconds "$min_seconds" --arg max_seconds "$max_seconds" \
    --argjson desktop_size "$desktop_size" --argjson camera_size "$camera_size" \
    --slurpfile manifest "$manifest" \
    --arg detected_at "$detected_at" \
    '{timestamp:$timestamp,detected_at:$detected_at,started_at:$manifest[0].started_at_utc,
      type:"case",case:$case,session:$session,expectation:$expectation,
      duration_bounds:{min_seconds:(if $min_seconds=="" then null else ($min_seconds|tonumber) end),
                       max_seconds:(if $max_seconds=="" then null else ($max_seconds|tonumber) end)},
      artifact_sizes:{desktop_mp4:$desktop_size,camera_mp4:$camera_size,session_json:null},
      expected_routing:{microphone_route:$manifest[0].audio.microphone_route,
                        desktop_audio:$manifest[0].audio.desktop_audio,
                        desktop_tracks:$manifest[0].audio.desktop_tracks,
                        camera_tracks:$manifest[0].audio.camera_tracks},
      manifest_summary:{completed:$manifest[0].completed,stop_reason:$manifest[0].stop_reason,
                        duration_ms:$manifest[0].duration_ms,output_errors:$manifest[0].output_errors},
      validator_log:$validator,result:$result}')"
  local manifest_size
  manifest_size="$(stat -f %z "$manifest" 2>/dev/null || stat -c %s "$manifest")"
  entry="$(jq -c --argjson size "$manifest_size" '.artifact_sizes.session_json=$size' <<<"$entry")"
  printf '%s\n' "$entry" >>"$ledger"
  record_event capture "$(jq -nc --arg case "$case_name" --arg session "$session" \
    --arg result "$validator_result" '{case:$case,session:$session,result:$result}')"
  echo "Validator result: $(printf '%s' "$validator_result" | tr '[:lower:]' '[:upper:]')"
  echo "Validator output: $validator_log"
  [[ "$validator_result" == pass ]]
}

command_monitor() {
  local pid=''
  local minutes=30
  local interval=60
  while (( $# > 0 )); do
    case "$1" in
      --pid) pid="${2:-}"; shift 2 ;;
      --minutes) minutes="${2:-}"; shift 2 ;;
      --interval) interval="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete monitor argument '$1'" ;;
    esac
  done
  verify_recorded_pid "$pid"
  [[ "$minutes" =~ ^[0-9]+$ && "$interval" =~ ^[1-9][0-9]*$ ]] ||
    die "minutes must be nonnegative and interval must be positive"
  local samples summary
  samples="$(unique_path "$run_root/resources" rss-cpu .csv)"
  summary="${samples%.csv}.json"
  echo "sample,timestamp,pid,rss_kib,cpu_percent" >"$samples"
  local count=$((minutes + 1))
  local index rss cpu
  for ((index = 0; index < count; index++)); do
    kill -0 "$pid" 2>/dev/null || { echo "error: PID $pid exited before sample $index" >&2; return 1; }
    read -r rss cpu < <(ps -o rss= -o %cpu= -p "$pid" | awk '{print $1, $2}')
    [[ -n "${rss:-}" && -n "${cpu:-}" ]] ||
      { echo "error: could not sample PID $pid" >&2; return 1; }
    printf '%d,%s,%s,%s,%s\n' "$index" "$(utc_now)" "$pid" "$rss" "$cpu" >>"$samples"
    (( index + 1 < count )) && sleep "$interval"
  done
  awk -F, -v interval="$interval" '
    NR == 1 { next }
    {
      n++
      x=(n-1)*interval/60
      y=$4
      if (n > 5) {
        rn++
        sx+=x; sy+=y; sxx+=x*x; sxy+=x*y
        if (y > previous) rising++; else rising=0
        if (rising >= 10) ten_rises=1
      }
      previous=y
    }
    END {
      denominator=rn*sxx-sx*sx
      slope=(denominator == 0 ? 0 : (rn*sxy-sx*sy)/denominator)
      printf "{\"samples\":%d,\"rss_slope_kib_per_minute\":%.3f,\"ten_consecutive_post_warmup_rises\":%s,\"result\":\"%s\"}\n",
        n,slope,(ten_rises?"true":"false"),((n==31 && slope<=1024 && !ten_rises)?"pass":"fail")
    }
  ' "$samples" >"$summary"
  record_event monitor "$(jq -c --arg pid "$pid" --arg samples "$samples" --arg summary "$summary" \
    '. + {pid:($pid|tonumber),samples_file:$samples,summary_file:$summary}' "$summary")"
  echo "Resource samples: $samples"
  echo "Resource result: $(jq -r .result "$summary")"
  [[ "$(jq -r .result "$summary")" == pass ]]
}

command_kill_capture() {
  local pid=''
  local after=30
  while (( $# > 0 )); do
    case "$1" in
      --pid) pid="${2:-}"; shift 2 ;;
      --after) after="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete kill-capture argument '$1'" ;;
    esac
  done
  verify_recorded_pid "$pid"
  [[ "$after" =~ ^[0-9]+$ ]] || die "--after must be a nonnegative integer"
  echo "Waiting $after seconds before sending SIGKILL only to recorded OBS PID $pid"
  sleep "$after"
  kill -0 "$pid" 2>/dev/null || { echo "error: PID $pid exited before SIGKILL" >&2; return 1; }
  kill -KILL "$pid"
  local data
  data="$(jq -nc --argjson pid "$pid" --argjson after "$after" '{pid:$pid,after_seconds:$after,signal:"SIGKILL"}')"
  record_event kill-capture "$data"
  echo "Sent SIGKILL to exact recorded OBS PID $pid"
}

command_manual_check() {
  local check='' result='' note='' url=''
  while (( $# > 0 )); do
    case "$1" in
      --check) check="${2:-}"; shift 2 ;;
      --result) result="${2:-}"; shift 2 ;;
      --note) note="${2:-}"; shift 2 ;;
      --url) url="${2:-}"; shift 2 ;;
      *) die "unknown or incomplete manual-check argument '$1'" ;;
    esac
  done
  [[ "$check" =~ ^[a-z][a-z0-9_]*$ ]] || die "manual-check requires a snake_case --check ID"
  case "$result" in pass|fail|skip) ;; *) die "--result must be pass, fail, or skip" ;; esac
  [[ -n "$note" ]] || die "manual-check requires a nonempty --note"
  if [[ "$check" == windows_workflow ]]; then
    [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/actions/runs/[0-9]+([/?#].*)?$ ]] ||
      die "windows_workflow requires a GitHub Actions run URL"
  elif [[ -n "$url" ]]; then
    die "--url is accepted only for windows_workflow"
  fi
  jq -nc --arg timestamp "$(utc_now)" --arg check "$check" --arg result "$result" \
    --arg note "$note" --arg url "$url" \
    '{timestamp:$timestamp,check:$check,result:$result,note:$note}
     + (if $url == "" then {} else {url:$url} end)' >>"$run_root/manual-checks.jsonl" ||
    die "could not append manual check"
  echo "Recorded manual check '$check': $result"
}

command_finalize() {
  local stimulus="$run_root/stimulus/stimulus-results.jsonl"
  [[ -f "$stimulus" ]] || stimulus=/dev/null
  local result_file
  result_file="$(unique_path "$run_root/state" finalization-candidate .json)"
  if ! jq -n \
    --slurpfile cases "$ledger" \
    --slurpfile events "$events" \
    --slurpfile manual "$run_root/manual-checks.jsonl" \
    --slurpfile stimulus "$stimulus" '
    def routing:
      [
        {case:"both_on",route:"both",desktop_audio:true,desktop_tracks:3,camera_tracks:1},
        {case:"both_off",route:"both",desktop_audio:false,desktop_tracks:2,camera_tracks:1},
        {case:"desktop_on",route:"desktop",desktop_audio:true,desktop_tracks:3,camera_tracks:0},
        {case:"desktop_off",route:"desktop",desktop_audio:false,desktop_tracks:2,camera_tracks:0},
        {case:"camera_on",route:"camera",desktop_audio:true,desktop_tracks:2,camera_tracks:1},
        {case:"camera_off",route:"camera",desktop_audio:false,desktop_tracks:1,camera_tracks:1},
        {case:"off_on",route:"off",desktop_audio:true,desktop_tracks:2,camera_tracks:0},
        {case:"off_off",route:"off",desktop_audio:false,desktop_tracks:1,camera_tracks:0}
      ];
    def failure_cases: ["failpoint_preflight","failpoint_desktop-start","failpoint_camera-start"];
    def required_manual:
      [
        "canonical_pregrant_blockers","canonical_viewport_720x600",
        "signed_rebuild_permission_persistence","portable_startup",
        "portable_config_containment","fresh_pregrant_blockers",
        "microphone_denied_routes","output_path_missing",
        "output_path_regular_file","output_path_unwritable",
        "blocker_recording","blocker_stream","blocker_replay_buffer",
        "blocker_virtual_camera","controls_locked","viewport_720x600",
        "settings_persistence","manifest_ordering","camera_release",
        "advanced_obs_handoff","stability_responsive","stability_no_errors",
        "forced_termination_media_readable","forced_relaunch_recovery",
        "windows_workflow"
      ];
    def case_by_name($name): [$cases[] | select(.case == $name)];
    def add_error($condition; $message): if $condition then . else . + [$message] end;
    def track_count($case; $role):
      (($case.expected_routing[($role + "_tracks")] // []) | length);
    def expected_audio:
      [routing[].case as $name
       | case_by_name($name)[0] as $case
       | ["desktop","camera"][] as $role
       | ($case.expected_routing[($role + "_tracks")] // [])[]
       | {case:$name,role:$role,track:.track,name:.name}];
    [] |
    add_error(($cases | length) == 13; "case inventory must contain exactly 13 entries") |
    reduce routing[] as $expected (.;
      case_by_name($expected.case) as $found |
      add_error(($found | length) == 1; "routing case \($expected.case) must occur exactly once") |
      if ($found | length) == 1 then
        $found[0] as $case |
        add_error($case.result == "pass"; "routing case \($expected.case) did not pass") |
        add_error($case.expectation == "completed"; "routing case \($expected.case) is not completed") |
        add_error(($case.duration_bounds.min_seconds // 0) >= 12; "routing case \($expected.case) lacks a 12-second minimum") |
        add_error(($case.duration_bounds.max_seconds // 999999) <= 15; "routing case \($expected.case) lacks a 15-second maximum") |
        add_error($case.expected_routing.microphone_route == $expected.route; "routing case \($expected.case) has the wrong microphone route") |
        add_error($case.expected_routing.desktop_audio == $expected.desktop_audio; "routing case \($expected.case) has the wrong Desktop-audio state") |
        add_error(track_count($case;"desktop") == $expected.desktop_tracks; "routing case \($expected.case) has the wrong Desktop track count") |
        add_error(track_count($case;"camera") == $expected.camera_tracks; "routing case \($expected.case) has the wrong Camera track count")
      else . end) |
    reduce failure_cases[] as $name (.;
      case_by_name($name) as $found |
      add_error(($found | length) == 1; "failure case \($name) must occur exactly once") |
      if ($found | length) == 1 then
        add_error($found[0].result == "pass"; "failure case \($name) did not pass") |
        add_error($found[0].expectation == "initialization-error"; "failure case \($name) has the wrong expectation")
      else . end) |
    reduce ["preflight","desktop-start","camera-start"][] as $failpoint (.;
      add_error(([$events[] | select(.type == "launch" and .failpoint == $failpoint)] | length) == 1;
                "failpoint launch \($failpoint) must occur exactly once")) |
    case_by_name("stability_30m") as $stability |
    add_error(($stability | length) == 1; "stability_30m must occur exactly once") |
    if ($stability | length) == 1 then
      add_error($stability[0].result == "pass" and $stability[0].expectation == "completed";
                "stability_30m did not complete successfully") |
      add_error(($stability[0].duration_bounds.min_seconds // 0) >= 1800;
                "stability_30m lacks a 1,800-second minimum")
    else . end |
    case_by_name("forced_termination") as $forced |
    add_error(($forced | length) == 1; "forced_termination must occur exactly once") |
    if ($forced | length) == 1 then
      add_error($forced[0].result == "pass" and $forced[0].expectation == "interrupted";
                "forced_termination did not validate as interrupted") |
      add_error(($forced[0].duration_bounds.min_seconds // 0) >= 30;
                "forced_termination lacks a 30-second minimum")
    else . end |
    [$events[] | select(.type == "monitor")] as $all_monitors |
    [$all_monitors[] | select(.result == "pass" and .samples == 31
      and .rss_slope_kib_per_minute <= 1024
      and .ten_consecutive_post_warmup_rises == false)] as $monitors |
    add_error(($all_monitors | length) == 1; "monitor inventory must contain exactly one event") |
    add_error(($monitors | length) == 1; "exactly one passing 31-sample stability monitor is required") |
    if ($monitors | length) == 1 then
      add_error(([$events[] | select(.type == "launch" and .pid == $monitors[0].pid)] | length) >= 1;
                "stability monitor PID is not a recorded OBS launch PID")
    else . end |
    [$events[] | select(.type == "kill-capture")] as $all_kills |
    [$all_kills[] | select(.signal == "SIGKILL")] as $kills |
    add_error(($all_kills | length) == 1; "forced-kill inventory must contain exactly one event") |
    add_error(($kills | length) == 1; "exactly one forced SIGKILL event is required") |
    if ($kills | length) == 1 then
      add_error(([$events[] | select(.type == "launch" and .pid == $kills[0].pid)] | length) >= 1;
                "forced SIGKILL PID is not a recorded OBS launch PID")
    else . end |
    add_error(($manual | all(.result == "pass")); "manual checks contain a failure or skip") |
    reduce required_manual[] as $name (.;
      add_error(([$manual[] | select(.check == $name)] | length) == 1;
                "manual check \($name) must occur exactly once")) |
    [$manual[] | select(.check == "windows_workflow")][0] as $windows |
    add_error(($windows.url // "") | test("^https://github[.]com/[^/]+/[^/]+/actions/runs/[0-9]+([/?#].*)?$");
              "Windows workflow result lacks a valid GitHub Actions run URL") |
    expected_audio as $expected_audio |
    add_error(($stimulus | all(.result == "pass")); "audio results contain a failure or skip") |
    add_error(($stimulus | length) == ($expected_audio | length);
              "audio result inventory does not exactly match the routing tracks") |
    reduce $expected_audio[] as $expected (.;
      add_error(([$stimulus[] | select(.case == $expected.case and .role == $expected.role
        and .track == $expected.track and .name == $expected.name)] | length) == 1;
        "audio result \($expected.case)/\($expected.role)/track\($expected.track) must occur exactly once")) |
    if length == 0 then
      {result:"pass",case_count:($cases|length),manual_check_count:($manual|length),
       audio_result_count:($stimulus|length),monitor_count:($monitors|length),
       forced_kill_count:($kills|length),windows_workflow_url:$windows.url}
    else {result:"fail",errors:.} end
  ' >"$result_file"; then
    rm -f "$result_file"
    die "could not evaluate final qualification inventory"
  fi

  if [[ "$(jq -r .result "$result_file")" != pass ]]; then
    jq -r '.errors[] | "incomplete: \(.)"' "$result_file" >&2
    rm -f "$result_file"
    return 1
  fi
  local finalization
  finalization="$(unique_path "$run_root/reports" finalization .json)"
  jq --arg finalized_at "$(utc_now)" '. + {finalized_at:$finalized_at}' "$result_file" >"$finalization"
  rm -f "$result_file"
  record_event finalize "$(jq -nc --arg finalization "$finalization" --arg result pass \
    '{result:$result,finalization:$finalization}')"
  echo "Strict completeness gate: PASS"
  echo "Finalization evidence: $finalization"
}

command_validate() {
  local aggregate
  aggregate="$(unique_path "$run_root/validators" all-cases .log)"
  local status=0 count=0
  while IFS=$'\t' read -r session expected min max case_name; do
    ((count += 1))
    local -a args=(--expect "$expected")
    [[ "$min" != null ]] && args+=(--min-seconds "$min")
    [[ "$max" != null ]] && args+=(--max-seconds "$max")
    {
      echo "Case: $case_name"
      "$validator" "${args[@]}" "$session"
    } >>"$aggregate" 2>&1 || status=1
  done < <(jq -r 'select(.type=="case") |
    [.session,.expectation,(.duration_bounds.min_seconds//"null"),
     (.duration_bounds.max_seconds//"null"),.case] | @tsv' "$ledger")
  (( count > 0 )) || { echo "error: no cases are recorded" >&2; return 1; }
  record_event validate "$(jq -nc --arg log "$aggregate" --argjson count "$count" \
    --arg result "$([[ $status == 0 ]] && echo pass || echo fail)" \
    '{log:$log,case_count:$count,result:$result}')"
  echo "Validated $count recorded cases: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
  echo "Aggregate output: $aggregate"
  return "$status"
}

command_report() {
  local report
  report="$(unique_path "$run_root/reports" qualification-report .md)"
  {
    echo "# Dual Capture Qualification Evidence"
    echo
    echo "- Generated: $(utc_now)"
    echo "- Run root: \`$run_root\`"
    echo "- Output root: \`$output_root\`"
    echo "- OBS executable: \`$app_executable\`"
    echo
    echo "## Strict finalization"
    echo
    if jq -e 'select(.type=="finalize" and .result=="pass")' "$events" >/dev/null; then
      jq -r 'select(.type=="finalize" and .result=="pass") |
        "- **PASS** — `\(.finalization)`"' "$events"
    else
      echo "No passing strict finalization has been recorded."
    fi
    echo
    echo "## Cases"
    echo
    echo "| Case | State | Result | Session | Desktop bytes | Camera bytes |"
    echo "|---|---|---|---|---:|---:|"
    jq -r 'select(.type=="case") |
      "| \(.case) | \(.expectation) | \(.result) | `\(.session)` | \(.artifact_sizes.desktop_mp4) | \(.artifact_sizes.camera_mp4) |"' \
      "$ledger"
    echo
    echo "## Validator and stimulus evidence"
    echo
    jq -r 'select(.type=="case") |
      "- **\(.case)**: validator `\(.validator_log)`; route `\(.expected_routing.microphone_route)`, desktop audio `\(.expected_routing.desktop_audio)`; manifest completed `\(.manifest_summary.completed)`, stop `\(.manifest_summary.stop_reason)`, errors `\(.manifest_summary.output_errors)`."' \
      "$ledger"
    if [[ -s "$run_root/stimulus/stimulus-results.jsonl" ]]; then
      echo
      echo "Listening results:"
      jq -r '"- \(.case) \(.role) track \(.track) (\(.name)): **\(.result)** — \(.note)"' \
        "$run_root/stimulus/stimulus-results.jsonl"
    else
      echo
      echo "No operator listening results have been recorded."
    fi
    echo
    echo "## Manual checks"
    echo
    if [[ -s "$run_root/manual-checks.jsonl" ]]; then
      jq -r '"- \(.check): **\(.result)** — \(.note // "")" +
        (if .url then " — [workflow run](\(.url))" else "" end)' "$run_root/manual-checks.jsonl"
    else
      echo "No manual checks have been appended to \`manual-checks.jsonl\`."
    fi
    echo
    echo "## Resource samples"
    echo
    find "$run_root/resources" -maxdepth 1 -type f -print | sort | sed 's/^/- `/' | sed 's/$/`/'
    echo
    echo "## Lifecycle events"
    echo
    jq -r '"- \(.timestamp) — \(.type)"' "$events"
    echo
    echo "## Artifact inventory"
    echo
    find "$run_root" "$output_root" -type f -print | sort | sed 's/^/- `/' | sed 's/$/`/'
  } >"$report"
  record_event report "$(jq -nc --arg report "$report" '{report:$report}')"
  echo "Wrote new report without replacing prior evidence: $report"
}

(( $# > 0 )) || { usage >&2; exit 2; }
command="$1"
shift
case "$command" in
  init) command_init "$@" ;;
  handoff) command_handoff "$@" ;;
  launch|capture|monitor|kill-capture|manual-check|finalize|validate|report)
    require_tool jq
    resolve_run_root
    "command_${command//-/_}" "$@"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown command '$command'" ;;
esac
