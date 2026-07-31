#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly identity_name='Split Capture Local Development'
readonly expected_bundle_id='io.github.georgeqle.splitcapture'
script_directory="$(cd "$(dirname "$0")" && pwd)"
readonly script_directory
repository_root="$(cd "$script_directory/.." && pwd)"
readonly repository_root
readonly canonical_app="$repository_root/build_macos/frontend/Debug/Split Capture.app"
readonly support_directory="${HOME:?}/Library/Application Support/Split Capture Local Development"
readonly fingerprint_file="$support_directory/certificate.sha256"
readonly signing_lock_directory="$support_directory/signing.lock"
temporary_cleanup_directory=''
signing_lock_acquired=0

usage() {
  cat <<EOF
usage: $(basename "$0") COMMAND [APP]

Commands:
  setup       Create the five-year local code-signing identity, if absent
  doctor      Validate the single identity and pin its certificate fingerprint
  preflight   Sign and verify one disposable Mach-O before a full build
  build       Configure and build the canonical Debug app with the identity
  verify APP  Verify a stable, complete signature against the pinned identity

Local identity: $identity_name
Canonical app:  $canonical_app
Fingerprint:    $fingerprint_file
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_macos() {
  [[ "$(uname -s)" == Darwin ]] || die "this helper only supports macOS"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool '$1' was not found"
}

redact_routine_signing_output() {
  sed -E \
    -e 's/(--sign[[:space:]]+)[0-9A-Fa-f]{40}([[:space:]])/\1[certificate-redacted]\2/g' \
    -e 's/(-signing-cert[[:space:]]+)[0-9A-Fa-f]{40}([[:space:]])/\1[certificate-redacted]\2/g' \
    -e 's/(certificate leaf = H")[0-9A-Fa-f]{40}(")/\1[certificate-redacted]\2/g'
}

cleanup_temporary_directory() {
  [[ -z "$temporary_cleanup_directory" ]] || rm -rf -- "$temporary_cleanup_directory"
}

cleanup() {
  cleanup_temporary_directory
  if [[ "$signing_lock_acquired" -eq 1 ]]; then
    rmdir "$signing_lock_directory" 2>/dev/null || true
  fi
}

ensure_private_support_directory() {
  mkdir -p "$support_directory"
  chmod 700 "$support_directory"
}

acquire_signing_lock() {
  ensure_private_support_directory
  if ! mkdir "$signing_lock_directory" 2>/dev/null; then
    die "another signing operation may be active (lock: $signing_lock_directory)"
  fi
  signing_lock_acquired=1
}

login_keychain() {
  local keychain
  keychain="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  [[ -n "$keychain" && -f "$keychain" ]] || die "could not locate the user's login Keychain"
  printf '%s\n' "$keychain"
}

matching_identity_lines() {
  local keychain="$1"
  security find-identity -v -p codesigning "$keychain" 2>/dev/null |
    awk -v name="$identity_name" '
      {
        first_quote=index($0, "\"")
        if (first_quote == 0) next
        rest=substr($0, first_quote + 1)
        second_quote=index(rest, "\"")
        if (second_quote == 0) next
        if (substr(rest, 1, second_quote - 1) == name) print
      }
    '
}

identity_fingerprint() {
  local keychain="$1"
  { security find-certificate -c "$identity_name" -Z "$keychain" 2>/dev/null || true; } |
    awk -F': ' '/^SHA-256 hash: / { print toupper($2); exit }'
}

require_single_identity() {
  local keychain="$1"
  local lines count
  lines="$(matching_identity_lines "$keychain")"
  count="$(printf '%s\n' "$lines" | awk 'NF { count++ } END { print count+0 }')"
  [[ "$count" -eq 1 ]] ||
    die "expected exactly one valid '$identity_name' code-signing identity in the login Keychain; found $count (run setup or complete the documented rotation procedure)"
}

command_setup() {
  local keychain identity_count certificate_count temporary_directory certificate_file
  keychain="$(login_keychain)"
  identity_count="$(matching_identity_lines "$keychain" | awk 'NF { count++ } END { print count+0 }')"
  certificate_count="$(
    { security find-certificate -a -c "$identity_name" -Z "$keychain" 2>/dev/null || true; } |
      awk '/^SHA-256 hash: / { count++ } END { print count+0 }'
  )"

  if [[ "$identity_count" -eq 1 && "$certificate_count" -eq 1 ]]; then
    echo "The '$identity_name' identity already exists."
    command_doctor
    return
  fi
  [[ "$identity_count" -eq 0 && "$certificate_count" -le 1 ]] ||
    die "partial or duplicate '$identity_name' Keychain items exist; resolve them in Keychain Access before setup"

  if [[ "$certificate_count" -eq 0 ]]; then
    cat <<EOF
Keychain Access will open. Choose:
  Keychain Access > Certificate Assistant > Create a Certificate

Use these settings:
  Name:             $identity_name
  Identity Type:    Self Signed Root
  Certificate Type: Code Signing
  Override defaults: enabled
  Serial number:    any locally unique positive number
  Validity period:  1825 days (five years)
  Key pair:         RSA, 2048 bits
  Keychain:         login

Accept the remaining defaults. Do not export the certificate or private key.
EOF
    open -a 'Keychain Access'
    read -r -p "Press Return after Certificate Assistant has created the identity: " _

    certificate_count="$(
      { security find-certificate -a -c "$identity_name" -Z "$keychain" 2>/dev/null || true; } |
        awk '/^SHA-256 hash: / { count++ } END { print count+0 }'
    )"
    [[ "$certificate_count" -eq 1 ]] ||
      die "Certificate Assistant did not create exactly one '$identity_name' certificate"
  else
    echo "Found the new '$identity_name' certificate; finishing its code-signing trust setup."
  fi

  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/split-capture-cert.XXXXXX")"
  temporary_cleanup_directory="$temporary_directory"
  certificate_file="$temporary_directory/certificate.pem"
  security find-certificate -c "$identity_name" -p "$keychain" >"$certificate_file"
  [[ -s "$certificate_file" ]] || die "the new public certificate could not be read"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$certificate_file"
  rm -rf "$temporary_directory"
  temporary_cleanup_directory=''

  echo "Created a five-year identity trusted in the user domain only for code signing."
  command_doctor
}

command_doctor() {
  local keychain fingerprint pinned temporary_directory certificate_file
  keychain="$(login_keychain)"
  require_single_identity "$keychain"
  fingerprint="$(identity_fingerprint "$keychain")"
  [[ "$fingerprint" =~ ^[0-9A-F]{64}$ ]] || die "could not read the identity's SHA-256 certificate fingerprint"

  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/split-capture-trust.XXXXXX")"
  temporary_cleanup_directory="$temporary_directory"
  certificate_file="$temporary_directory/certificate.pem"
  security find-certificate -c "$identity_name" -p "$keychain" >"$certificate_file"
  [[ -s "$certificate_file" ]] || die "the pinned public certificate could not be read"
  security verify-cert -c "$certificate_file" -p codeSign -L >/dev/null 2>&1 ||
    die "the '$identity_name' certificate is not trusted for code signing in the user domain"
  rm -rf "$temporary_directory"
  temporary_cleanup_directory=''

  ensure_private_support_directory
  if [[ -f "$fingerprint_file" ]]; then
    IFS= read -r pinned <"$fingerprint_file"
    [[ "$pinned" == "$fingerprint" ]] ||
      die "the '$identity_name' certificate differs from the pinned identity; follow the documented rotation procedure"
  else
    printf '%s\n' "$fingerprint" >"$fingerprint_file"
    echo "Pinned the local certificate fingerprint at: $fingerprint_file"
  fi
  chmod 600 "$fingerprint_file"
  echo "Identity check passed: $identity_name"
}

resolve_app() {
  local candidate="$1"
  if [[ -d "$candidate" && "$candidate" == *.app ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  if [[ -x "$candidate" && "$candidate" == */Contents/MacOS/* ]]; then
    printf '%s\n' "${candidate%/Contents/MacOS/*}"
    return
  fi
  die "APP must be an application bundle or its Contents/MacOS executable: $candidate"
}

command_verify() {
  [[ $# -eq 1 ]] || die "verify requires exactly one APP argument"
  local app details requirement bundle_id temporary_directory leaf_certificate
  local app_fingerprint pinned
  app="$(resolve_app "$1")"
  [[ -d "$app" ]] || die "application bundle does not exist: $app"

  command_doctor
  bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == "$expected_bundle_id" ]] ||
    die "unexpected bundle identifier '$bundle_id' (expected '$expected_bundle_id')"

  details="$(codesign -dvvv "$app" 2>&1)" || die "could not inspect the app signature"
  if grep -Eqi 'Signature=adhoc|flags=.*adhoc' <<<"$details"; then
    die "the app uses an ad-hoc signature"
  fi
  codesign --verify --deep --strict --verbose=2 "$app"

  requirement="$(codesign -d -r- "$app" 2>&1)" || die "could not read the designated requirement"
  grep -Eqi 'designated[[:space:]]*=>' <<<"$requirement" ||
    die "the app has no designated requirement"
  if grep -Eqi 'designated[[:space:]]*=>[[:space:]]*cdhash|(^|[^[:alnum:]_])cdhash[[:space:]]' <<<"$requirement"; then
    die "the app has a CDHash-only or CDHash-dependent designated requirement"
  fi
  grep -Eqi '(^|[[:space:](])(anchor|certificate)([[:space:])]|$)' <<<"$requirement" ||
    die "the designated requirement is not certificate-based"

  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/split-capture-signature.XXXXXX")"
  temporary_cleanup_directory="$temporary_directory"
  codesign -d --extract-certificates="$temporary_directory/certificate" "$app" >/dev/null 2>&1 ||
    die "could not extract the app's signing certificate"
  leaf_certificate="$temporary_directory/certificate0"
  [[ -s "$leaf_certificate" ]] || die "the app signature has no leaf certificate"
  app_fingerprint="$(shasum -a 256 "$leaf_certificate" | awk '{ print toupper($1) }')"
  IFS= read -r pinned <"$fingerprint_file"
  [[ "$app_fingerprint" == "$pinned" ]] ||
    die "the app was not signed by the pinned identity"
  rm -rf "$temporary_directory"
  temporary_cleanup_directory=''

  echo "Signature verification passed: $app"
  echo "Designated requirement check passed: certificate-based and independent of CDHash."
}

command_preflight() {
  local keychain source_binary temporary_directory signed_binary details requirement
  local leaf_certificate signed_fingerprint pinned
  command_doctor
  acquire_signing_lock
  keychain="$(login_keychain)"
  require_single_identity "$keychain"

  source_binary=/usr/bin/true
  [[ -x "$source_binary" ]] || die "preflight source Mach-O is unavailable: $source_binary"
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/split-capture-preflight.XXXXXX")"
  chmod 700 "$temporary_directory"
  temporary_cleanup_directory="$temporary_directory"
  signed_binary="$temporary_directory/true"
  cp "$source_binary" "$signed_binary"
  chmod 700 "$signed_binary"

  echo "Signing one disposable Mach-O. Approve at most this single codesign access request."
  codesign --force --sign "$identity_name" --timestamp=none "$signed_binary" ||
    die "single-signature preflight failed; do not start the full build or broaden Keychain access"
  codesign --verify --strict --verbose=2 "$signed_binary"
  details="$(codesign -dvvv "$signed_binary" 2>&1)" ||
    die "could not inspect the disposable signature"
  if grep -Eqi 'Signature=adhoc|flags=.*adhoc' <<<"$details"; then
    die "the disposable Mach-O received an ad-hoc signature"
  fi
  requirement="$(codesign -d -r- "$signed_binary" 2>&1)" ||
    die "could not read the disposable designated requirement"
  grep -Eqi '(^|[[:space:](])(anchor|certificate)([[:space:])]|$)' <<<"$requirement" ||
    die "the disposable designated requirement is not certificate-based"
  if grep -Eqi 'designated[[:space:]]*=>[[:space:]]*cdhash|(^|[^[:alnum:]_])cdhash[[:space:]]' <<<"$requirement"; then
    die "the disposable designated requirement depends on a CDHash"
  fi

  codesign -d --extract-certificates="$temporary_directory/certificate" "$signed_binary" \
    >/dev/null 2>&1 || die "could not extract the disposable signing certificate"
  leaf_certificate="$temporary_directory/certificate0"
  [[ -s "$leaf_certificate" ]] || die "the disposable signature has no leaf certificate"
  signed_fingerprint="$(shasum -a 256 "$leaf_certificate" | awk '{ print toupper($1) }')"
  IFS= read -r pinned <"$fingerprint_file"
  [[ "$signed_fingerprint" == "$pinned" ]] ||
    die "the disposable Mach-O was not signed by the pinned identity"

  rm -rf "$temporary_directory"
  temporary_cleanup_directory=''
  rmdir "$signing_lock_directory"
  signing_lock_acquired=0
  echo "Single-signature preflight passed."
}

command_build() {
  command_preflight
  acquire_signing_lock
  (
    cd "$repository_root"
    CODESIGN_IDENT="$identity_name" cmake --preset macos \
      -DCMAKE_COMPILE_WARNING_AS_ERROR=ON \
      -DOBS_COMPILE_DEPRECATION_AS_WARNING=ON \
      -DENABLE_PORTABLE_CONFIG=ON \
      -DENABLE_DUAL_CAPTURE_TEST_HOOKS=ON \
      -DENABLE_DUAL_CAPTURE_TESTS=ON \
      -DENABLE_VIRTUALCAM=ON \
      -DSPLIT_CAPTURE_ENABLE_CUSTOM_UPDATER=OFF
    require_qualification_configuration
    CODESIGN_IDENT="$identity_name" cmake --build build_macos --config Debug -- -jobs 1 2>&1 |
      redact_routine_signing_output
  )
  command_verify "$canonical_app"
  rmdir "$signing_lock_directory"
  signing_lock_acquired=0
}

require_qualification_configuration() {
  local cache="$repository_root/build_macos/CMakeCache.txt"
  [[ -f "$cache" ]] || die "canonical build cache is missing: $cache"
  local option expected actual
  while IFS='=' read -r option expected; do
    actual="$(sed -n "s/^${option}:[^=]*=//p" "$cache" | tail -n 1)"
    [[ "$actual" == "$expected" ]] ||
      die "qualification configuration mismatch: $option is '${actual:-unset}', expected '$expected'"
  done <<'EOF'
CMAKE_COMPILE_WARNING_AS_ERROR=ON
OBS_COMPILE_DEPRECATION_AS_WARNING=ON
ENABLE_PORTABLE_CONFIG=ON
ENABLE_DUAL_CAPTURE_TEST_HOOKS=ON
ENABLE_DUAL_CAPTURE_TESTS=ON
ENABLE_VIRTUALCAM=ON
SPLIT_CAPTURE_ENABLE_CUSTOM_UPDATER=OFF
EOF
  echo "Qualification CMake configuration check passed."
}

require_macos
require_tool security
require_tool codesign
require_tool plutil
trap cleanup EXIT

command="${1:-}"
case "$command" in
  setup)
    [[ $# -eq 1 ]] || die "setup takes no arguments"
    command_setup
    ;;
  doctor)
    [[ $# -eq 1 ]] || die "doctor takes no arguments"
    command_doctor
    ;;
  preflight)
    [[ $# -eq 1 ]] || die "preflight takes no arguments"
    command_preflight
    ;;
  build)
    [[ $# -eq 1 ]] || die "build takes no arguments"
    require_tool cmake
    command_build
    ;;
  verify)
    shift
    command_verify "$@"
    ;;
  -h|--help|help|'')
    usage
    ;;
  *)
    usage >&2
    die "unknown command '$command'"
    ;;
esac
