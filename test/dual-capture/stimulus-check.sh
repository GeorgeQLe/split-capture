#!/usr/bin/env bash

set -u
set -o pipefail

usage() {
  cat <<'EOF'
usage: stimulus-check.sh --case NAME --session DIR --output-dir DIR

Extracts every AAC stream to a case-labelled WAV, prints the expected source,
and interactively appends the operator's listening result to stimulus-results.jsonl.
Existing WAVs and results are never overwritten.
EOF
}

case_name=
session_directory=
output_directory=
while (( $# > 0 )); do
  case "$1" in
    --case) case_name="${2:-}"; shift 2 ;;
    --session) session_directory="${2:-}"; shift 2 ;;
    --output-dir) output_directory="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown or incomplete argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$case_name" && "$case_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
  { echo "error: --case must contain only letters, numbers, dot, underscore, or dash" >&2; exit 2; }
[[ -f "$session_directory/session.json" ]] ||
  { echo "error: session.json was not found" >&2; exit 2; }
mkdir -p "$output_directory" || exit 2
for tool in jq ffprobe ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 ||
    { echo "error: required tool '$tool' was not found" >&2; exit 2; }
done

results_file="$output_directory/stimulus-results.jsonl"
microphone_route="$(jq -r .audio.microphone_route "$session_directory/session.json")"
desktop_audio="$(jq -r .audio.desktop_audio "$session_directory/session.json")"
for role in desktop camera; do
  media="$session_directory/$role.mp4"
  [[ -f "$media" ]] || { echo "error: missing $media" >&2; exit 1; }
  # shellcheck disable=SC2016 # $role is a jq variable.
  mapfile_command=(jq -r --arg role "$role" '
    .audio[($role + "_tracks")][] | [.track, .name] | @tsv
  ' "$session_directory/session.json")
  while IFS=$'\t' read -r track name; do
    [[ -n "$track" ]] || continue
    stream_index=$((track - 1))
    wav="$output_directory/${case_name}-${role}-track${track}.wav"
    if [[ -e "$wav" ]]; then
      echo "error: refusing to overwrite existing extraction: $wav" >&2
      exit 1
    fi
    ffmpeg -nostdin -v error -i "$media" -map "0:a:${stream_index}" -vn -c:a pcm_s16le "$wav" ||
      exit 1
    case "$name" in
      "Desktop Playback Mix")
        expected="playback mix:"
        if [[ "$desktop_audio" == true ]]; then
          expected="$expected continuous system tone"
        else
          expected="$expected no system tone"
        fi
        if [[ "$microphone_route" == both || "$microphone_route" == desktop ]]; then
          expected="$expected; spoken/clap microphone markers"
        else
          expected="$expected; no microphone markers"
        fi
        ;;
      "Microphone Isolated") expected="spoken/clap microphone markers; no system tone" ;;
      "System Audio Isolated") expected="continuous distinctive system tone; no microphone markers" ;;
      "Camera Microphone") expected="spoken/clap microphone markers; no system tone" ;;
      *) expected="source described by track name: $name" ;;
    esac
    printf '%s\n  WAV: %s\n  Expected: %s\n' "$role track $track — $name" "$wav" "$expected"
    while true; do
      read -r -p "Listening result [pass/fail/skip]: " result
      case "$result" in pass|fail|skip) break ;; *) echo "Enter pass, fail, or skip." ;; esac
    done
    read -r -p "Optional note: " note
    jq -nc \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg case "$case_name" --arg session "$session_directory" --arg role "$role" \
      --argjson track "$track" --arg name "$name" --arg expected "$expected" \
      --arg wav "$wav" --arg result "$result" --arg note "$note" \
      '{timestamp:$timestamp,case:$case,session:$session,role:$role,track:$track,
        name:$name,expected:$expected,wav:$wav,result:$result,note:$note}' >>"$results_file"
  done < <("${mapfile_command[@]}")
done

echo "Appended listening results to $results_file"
