#!/usr/bin/env bash

set -u
set -o pipefail

usage() {
  cat <<'EOF'
usage: validate-session.sh [OPTIONS] SESSION_DIRECTORY [SESSION_DIRECTORY ...]

Options:
  --expect STATE       auto, completed, initialization-error, or interrupted
  --min-seconds N      require each media file to be at least N seconds
  --max-seconds N      require each media file to be at most N seconds
  -h, --help           show this help

With no options, the original one-or-more-directory interface is preserved and
the expected state is inferred from each manifest.
EOF
}

expectation=auto
min_seconds=
max_seconds=
declare -a session_directories=()

while (( $# > 0 )); do
  case "$1" in
    --expect)
      (( $# >= 2 )) || { echo "error: --expect requires a value" >&2; exit 2; }
      expectation="$2"
      shift 2
      ;;
    --min-seconds)
      (( $# >= 2 )) || { echo "error: --min-seconds requires a value" >&2; exit 2; }
      min_seconds="$2"
      shift 2
      ;;
    --max-seconds)
      (( $# >= 2 )) || { echo "error: --max-seconds requires a value" >&2; exit 2; }
      max_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      session_directories+=("$@")
      break
      ;;
    -*)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      session_directories+=("$1")
      shift
      ;;
  esac
done

case "$expectation" in
  auto|completed|initialization-error|interrupted) ;;
  *) echo "error: invalid expectation '$expectation'" >&2; exit 2 ;;
esac

number_pattern='^[0-9]+([.][0-9]+)?$'
if [[ -n "$min_seconds" && ! "$min_seconds" =~ $number_pattern ]]; then
  echo "error: --min-seconds must be a nonnegative number" >&2
  exit 2
fi
if [[ -n "$max_seconds" && ! "$max_seconds" =~ $number_pattern ]]; then
  echo "error: --max-seconds must be a nonnegative number" >&2
  exit 2
fi
if [[ -n "$min_seconds" && -n "$max_seconds" ]] &&
  ! awk -v min="$min_seconds" -v max="$max_seconds" 'BEGIN { exit !(min <= max) }'; then
  echo "error: --min-seconds cannot exceed --max-seconds" >&2
  exit 2
fi
if (( ${#session_directories[@]} == 0 )); then
  usage >&2
  exit 2
fi

for tool in jq ffprobe awk find; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' was not found" >&2
    exit 2
  fi
done

scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/dual-capture-validator.XXXXXX")" || exit 2
trap 'rm -rf "$scratch_directory"' EXIT

overall_status=0

validate_session() {
  local session_directory="$1"
  local manifest="$session_directory/session.json"
  local session_status=0
  local expected_state="$expectation"

  pass() {
    printf '  PASS  %s\n' "$1"
  }

  fail() {
    printf '  FAIL  %s\n' "$1"
    session_status=1
  }

  check_jq() {
    local description="$1"
    local expression="$2"
    if jq -e "$expression" "$manifest" >/dev/null 2>&1; then
      pass "$description"
    else
      fail "$description"
    fi
  }

  printf 'Session: %s\n' "$session_directory"
  if [[ ! -d "$session_directory" ]]; then
    fail "session directory exists"
    return "$session_status"
  fi
  if [[ ! -f "$manifest" ]]; then
    fail "session.json exists"
    return "$session_status"
  fi

  check_jq "manifest JSON parses" '. | type == "object"'
  if [[ "$expected_state" == auto ]]; then
    expected_state="$(jq -r '
      if .completed == true then "completed"
      elif .stop_reason == "initialization_error" then "initialization-error"
      else "interrupted"
      end
    ' "$manifest" 2>/dev/null)"
  fi
  printf '  INFO  expected state: %s\n' "$expected_state"

  check_jq "schema_version is 1" '.schema_version == 1'
  check_jq "completion state is boolean" '.completed | type == "boolean"'
  case "$expected_state" in
    completed)
      check_jq "manifest is a completed user stop" \
        '.completed == true and .stop_reason == "user" and .output_errors == ""'
      ;;
    initialization-error)
      check_jq "manifest is an initialization error" \
        '.completed == false and .stop_reason == "initialization_error" and
         (.output_errors | type == "string" and test("^(Desktop|Camera): .+"))'
      ;;
    interrupted)
      check_jq "manifest is an interrupted recording" \
        '.completed == false and .stop_reason == "recording" and .output_errors == ""'
      ;;
  esac
  check_jq "media filenames are canonical" \
    '.video.desktop.filename == "desktop.mp4" and .video.camera.filename == "camera.mp4"'
  check_jq "manifest video format is H.264 at 30 fps" \
    '.video.codec == "h264" and .video.fps_numerator == 30 and .video.fps_denominator == 1'
  check_jq "manifest Camera dimensions are 1920x1080" \
    '.video.camera.width == 1920 and .video.camera.height == 1080'
  check_jq "manifest Desktop dimensions are positive" \
    '(.video.desktop.width | type == "number" and . > 0) and
     (.video.desktop.height | type == "number" and . > 0)'
  check_jq "manifest audio format is AAC/48 kHz" \
    '.audio.codec == "aac" and .audio.sample_rate == 48000'
  # shellcheck disable=SC2016 # $route and $system are jq variables.
  check_jq "manifest track layout matches requested routing" '
    (.audio.microphone_route as $route |
     .audio.desktop_audio as $system |
     .audio.desktop_tracks
       == ([{"track":1,"name":"Desktop Playback Mix"}]
           + (if $route == "both" or $route == "desktop"
              then [{"track":2,"name":"Microphone Isolated"}] else [] end)
           + (if $system
              then [{"track":(if $route == "both" or $route == "desktop" then 3 else 2 end),
                     "name":"System Audio Isolated"}] else [] end))
     and
     .audio.camera_tracks
       == (if $route == "both" or $route == "camera"
           then [{"track":1,"name":"Camera Microphone"}] else [] end))'
  check_jq "dropped-frame counts are zero" \
    '.dropped_frames.desktop == 0 and .dropped_frames.camera == 0'

  if [[ "$expected_state" == initialization-error ]]; then
    local file_count
    file_count="$(find "$session_directory" -mindepth 1 -maxdepth 1 | wc -l | awk '{print $1}')"
    if [[ "$file_count" == "1" && -f "$manifest" && ! -e "$session_directory/desktop.mp4" &&
          ! -e "$session_directory/camera.mp4" ]]; then
      pass "initialization failure retains only session.json"
    else
      fail "initialization failure retains only session.json"
    fi
    return "$session_status"
  fi

  local role media probe expected_width expected_height expected_names
  local desktop_first="" camera_first=""
  local desktop_duration="" camera_duration=""
  for role in desktop camera; do
    media="$session_directory/$role.mp4"
    probe="$(mktemp "$scratch_directory/probe.XXXXXX")" || exit 2
    if [[ -f "$media" && -s "$media" ]]; then
      pass "$role.mp4 exists and is nonzero"
    else
      fail "$role.mp4 exists and is nonzero"
      continue
    fi
    if ffprobe -v error -show_streams -show_format -of json "$media" >"$probe"; then
      pass "$role.mp4 is readable by ffprobe"
    else
      fail "$role.mp4 is readable by ffprobe"
      continue
    fi

    expected_width="$(jq -r ".video.$role.width" "$manifest")"
    expected_height="$(jq -r ".video.$role.height" "$manifest")"
    expected_names="$(jq -c ".audio.${role}_tracks | map(.name)" "$manifest")"
    if jq -e --argjson width "$expected_width" --argjson height "$expected_height" '
      [.streams[] | select(.codec_type == "video")] as $video |
      ($video | length) == 1 and
      $video[0].codec_name == "h264" and
      $video[0].width == $width and $video[0].height == $height and
      ($video[0].avg_frame_rate == "30/1" or $video[0].r_frame_rate == "30/1")
    ' "$probe" >/dev/null; then
      pass "$role video codec, dimensions, and frame rate"
    else
      fail "$role video codec, dimensions, and frame rate"
    fi

    if jq -e --argjson names "$expected_names" '
      [.streams[] | select(.codec_type == "audio")] as $audio |
      ($audio | length) == ($names | length) and
      ([$audio[] | .codec_name] | all(. == "aac")) and
      ([$audio[] | (.tags.handler_name // .tags.title // "")] == $names)
    ' "$probe" >/dev/null; then
      pass "$role AAC track count and names"
    else
      fail "$role AAC track count and names"
    fi

    local packet_times first last duration
    packet_times="$(mktemp "$scratch_directory/packets.XXXXXX")" || exit 2
    if ffprobe -v error -select_streams v:0 -show_packets \
      -show_entries packet=dts_time -of csv=p=0 "$media" >"$packet_times"; then
      read -r first last < <(
        awk -F, '
          {
            value = $1
            if (value != "N/A" && value != "") {
              if (seen && value <= previous) bad = 1
              if (!seen) first = value
              previous = value
              last = value
              seen = 1
            }
          }
          END { if (seen && !bad && last > first) print first, last }
        ' "$packet_times"
      )
      if [[ -n "${first:-}" && -n "${last:-}" ]]; then
        pass "$role video packet timestamps increase"
      else
        fail "$role video packet timestamps increase"
      fi
    else
      fail "$role video packets are readable"
      first=""
      last=""
    fi
    duration="$(jq -r '
      ([.streams[] | select(.codec_type == "video") | .duration,
         .format.duration] | map(select(. != null and . != "N/A")) | .[0]) // ""
    ' "$probe")"
    if [[ -n "$duration" ]] && awk -v duration="$duration" 'BEGIN { exit !(duration > 0) }'; then
      pass "$role duration is positive"
    else
      fail "$role duration is positive"
    fi
    if [[ -n "$duration" && -n "$min_seconds" ]] &&
      awk -v duration="$duration" -v min="$min_seconds" 'BEGIN { exit !(duration >= min) }'; then
      pass "$role duration is at least $min_seconds seconds"
    elif [[ -n "$min_seconds" ]]; then
      fail "$role duration is at least $min_seconds seconds"
    fi
    if [[ -n "$duration" && -n "$max_seconds" ]] &&
      awk -v duration="$duration" -v max="$max_seconds" 'BEGIN { exit !(duration <= max) }'; then
      pass "$role duration is at most $max_seconds seconds"
    elif [[ -n "$max_seconds" ]]; then
      fail "$role duration is at most $max_seconds seconds"
    fi

    if [[ "$role" == desktop ]]; then
      desktop_first="${first:-}"
      desktop_duration="$duration"
    else
      camera_first="${first:-}"
      camera_duration="$duration"
    fi
  done

  if [[ -n "$desktop_first" && -n "$camera_first" ]] &&
    awk -v a="$desktop_first" -v b="$camera_first" \
      'BEGIN { difference = a - b; if (difference < 0) difference = -difference; exit !(difference <= 0.03333) }'; then
    pass "cross-file video starts differ by at most 33.33 ms"
  else
    fail "cross-file video starts differ by at most 33.33 ms"
  fi
  if [[ -n "$desktop_duration" && -n "$camera_duration" ]] &&
    awk -v a="$desktop_duration" -v b="$camera_duration" \
      'BEGIN { difference = a - b; if (difference < 0) difference = -difference; exit !(difference <= 0.03333) }'; then
    pass "cross-file durations differ by at most 33.33 ms"
  else
    fail "cross-file durations differ by at most 33.33 ms"
  fi

  if [[ "$expected_state" == completed ]]; then
    local manifest_mtime desktop_mtime camera_mtime
    manifest_mtime="$(stat -f %m "$manifest" 2>/dev/null || stat -c %Y "$manifest")"
    desktop_mtime="$(stat -f %m "$session_directory/desktop.mp4" 2>/dev/null ||
      stat -c %Y "$session_directory/desktop.mp4")"
    camera_mtime="$(stat -f %m "$session_directory/camera.mp4" 2>/dev/null ||
      stat -c %Y "$session_directory/camera.mp4")"
    if (( manifest_mtime >= desktop_mtime && manifest_mtime >= camera_mtime )); then
      pass "completed manifest is not older than either finalized media file"
    else
      fail "completed manifest is not older than either finalized media file"
    fi
  fi

  return "$session_status"
}

for session_directory in "${session_directories[@]}"; do
  if validate_session "$session_directory"; then
    printf 'Result: PASS\n\n'
  else
    printf 'Result: FAIL\n\n'
    overall_status=1
  fi
done

exit "$overall_status"
