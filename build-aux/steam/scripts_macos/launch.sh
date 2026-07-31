#!/bin/zsh
 
arch_name="${CPUTYPE}"
is_translated="$(sysctl -in sysctl.proc_translated)"

if (( is_translated )) arch_name="arm64"
if [[ ${@} == *'--intel'* ]] arch_name="x86_64"
if [[ -d 'Split Capture.app' ]] exec open 'Split Capture.app' -W --args "${@}"

case ${arch_name} {
    x86_64) exec open 'x86_64/Split Capture.app' -W --args "${@}" ;;
    arm64) exec open 'arm64/Split Capture.app' -W --args "${@}" ;;
    *) echo "Unknown architecture: ${arch_name}"; exit 2 ;;
}
