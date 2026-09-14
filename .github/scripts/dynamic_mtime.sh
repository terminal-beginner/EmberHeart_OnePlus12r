#!/usr/bin/env bash
# dynamic_mtime.sh — mtime-based incremental-build hinting across shallow clones.
# Copyright (c) 2026  nullptr_t <nullptr.oss@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>
#
# Usage:
#   dynamic_mtime.sh -t -d <dir> [-k <key>]   # track: call after clone, before patches
#   dynamic_mtime.sh -u -d <dir> [-k <key>]   # untrack: call after patches, before build
#
# Requires: DYNAMIC_CACHE_DIR env var (e.g. ${OUT_DIR}/dynamic_cache)
#
# FIXES:
#   - Parallel hashing now uses per-process temp files (no interleaved
#     writes to a shared stdout). The previous `xargs -P | sha256sum > file`
#     could interleave partial lines when output exceeded PIPE_BUF,
#     producing malformed "<hash>  <path>" pairs and downstream
#     `touch: '<workspace>/<hash>  <path>': No such file` errors.
#   - Validate hash format before parsing (skip malformed lines).
#   - Force absolute paths (defensive against relative sha256sum output).
#   - Skip files that vanished between find and touch.
#   - touch -c to avoid creating missing files.
#   - Fixed duplicate "--" typo in changed-list touch invocation.
#   - Non-fatal on transient fs races (|| true on xargs touch).
#
# NOTE on dates: _freeze is a fixed date safely in the past (never
# decays). "Changed" files are stamped with the REAL current time, not a
# fixed constant — a fixed future constant would eventually be overtaken
# by real build-output timestamps and silently break.

set -euo pipefail

red="\033[38;2;236;1;1m"
blue="\033[38;2;39;127;255m"
green="\e[38;2;71;212;185m"
yellow="\e[38;2;254;164;76m"
end="\e[0m"

_name="[${yellow}$(basename "$0")${end}]"
_freeze="200712220000"

mode=""
dir=""
key=""
while getopts ":tud:k:" opt; do
  case "${opt}" in
    t) mode="track" ;;
    u) mode="untrack" ;;
    d) dir="${OPTARG}" ;;
    k) key="${OPTARG}" ;;
    \?) echo -e "${_name} unknown flag: ${red}-${OPTARG}${end}" >&2; exit 1 ;;
    :)  echo -e "${_name} ${red}-${OPTARG} requires an argument${end}" >&2; exit 1 ;;
  esac
done

[[ -n "${mode}" ]] || { echo -e "Usage: $(basename "$0") -t|-u -d <dir> [-k <key>]" >&2; exit 1; }
[[ -n "${dir}"  ]] || { echo -e "${_name} -d <dir> is required" >&2; exit 1; }
[[ -d "${dir}"  ]] || { echo -e "${_name} ${dir} is not a directory" >&2; exit 1; }
[[ -n "${DYNAMIC_CACHE_DIR:-}" ]] || { echo -e "${_name} ${red}DYNAMIC_CACHE_DIR is not set${end}" >&2; exit 1; }

root="$(cd "${dir}" && pwd)"
if [[ -z "${key}" ]]; then
  key="$(basename "${root}")-$(printf '%s' "${root}" | sha256sum | cut -c1-8)"
fi

cache_dir="${DYNAMIC_CACHE_DIR}/${key}"
hash="${cache_dir}/hashes.tsv"
mkdir -p "${cache_dir}"

echo -e "${_name} [${blue}${key}${end}] dir=${root} mode=${mode}"

if [[ "${mode}" == "track" ]]; then
  find "${root}" -type f -not -path '*/.git/*' -exec touch -t "${_freeze}" {} +
  echo -e "${_name} [${blue}${key}${end}] flattened to fallback — ready for patches"
  exit 0
fi

# --- untrack ---
declare -A BASELINE=()
if [[ -f "${hash}" ]]; then
  while IFS=$'\t' read -r rel h; do
    [[ -z "${rel}" ]] && continue
    BASELINE["${rel}"]="${h}"
  done < "${hash}"
fi

is_fresh_cache=false
[[ ${#BASELINE[@]} -eq 0 ]] && is_fresh_cache=true

tmp_hash="$(mktemp)"
raw_hash="$(mktemp)"
err_log="$(mktemp)"
changed_list="$(mktemp)"
unchanged_list="$(mktemp)"
parts_dir="$(mktemp -d)"
cleanup() {
  rm -f "${tmp_hash}" "${raw_hash}" "${err_log}" "${changed_list}" "${unchanged_list}"
  rm -rf "${parts_dir}"
}
trap cleanup EXIT

# --- Parallel + safe hashing ---
# Each worker writes to its own temp file (guaranteed unique via mktemp),
# so concurrent sha256sum outputs never interleave. We concatenate after.
export PARTS_DIR="${parts_dir}"

set +o pipefail
find "${root}" -type f -not -path '*/.git/*' -print0 | \
  xargs -0 -P "$(nproc)" -n 64 bash -c '
    part="$(mktemp "${PARTS_DIR}/part.XXXXXXXX")"
    sha256sum "$@" > "${part}" 2>>"${PARTS_DIR}/.errors" || true
  ' _
xargs_status=$?
set -o pipefail

# Concatenate worker output. Order does not matter for our diff logic.
if compgen -G "${PARTS_DIR}/part.*" > /dev/null; then
  cat "${PARTS_DIR}"/part.* > "${raw_hash}"
else
  : > "${raw_hash}"
fi

if [[ -s "${PARTS_DIR}/.errors" ]]; then
  echo -e "${_name} [${blue}${key}${end}]   ${yellow}warning: some files could not be hashed:${end}"
  sed "s/^/${_name}   /" "${PARTS_DIR}/.errors"
fi

if [[ "${xargs_status}" -gt 1 ]]; then
  echo -e "${_name} [${blue}${key}${end}]   ${red}xargs exited abnormally (status ${xargs_status})${end}"
fi

if ${is_fresh_cache}; then
  echo -e "${_name} [${blue}${key}${end}]   ${yellow}fresh cache — hashing all files, per-file diff suppressed${end}"
fi

# --- Diff + touch ---
changed=0
unchanged=0
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue

  h="${line%%  *}"
  f="${line#*  }"

  # Skip malformed lines (no two-space separator, or invalid hash)
  [[ "${h}" =~ ^[0-9a-fA-F]{64}$ ]] || continue
  [[ -n "${f}" && "${f}" != "${line}" ]] || continue

  # Force absolute path (defensive)
  if [[ "${f}" != /* ]]; then
    f="${root}/${f}"
  fi

  # Skip if the file vanished between find and now
  [[ -e "${f}" ]] || continue

  rel="${f#"${root}"/}"
  printf '%s\t%s\n' "${rel}" "${h}" >> "${tmp_hash}"

  prev="${BASELINE[${rel}]:-}"
  if [[ "${h}" == "${prev}" ]]; then
    printf '%s\0' "${f}" >> "${unchanged_list}"
    unchanged=$((unchanged + 1))
  else
    printf '%s\0' "${f}" >> "${changed_list}"
    changed=$((changed + 1))
    if ! ${is_fresh_cache}; then
      if [[ -z "${prev}" ]]; then
        echo -e "${_name} [${blue}${key}${end}]   ${green}+ ${rel} (null -> ${h:0:8})${end}"
      else
        echo -e "${_name} [${blue}${key}${end}]   ${red}~ ${rel} (${prev:0:8} -> ${h:0:8})${end}"
      fi
    fi
  fi
done < "${raw_hash}"

# touch -c: do not create missing files. "--" ends option parsing.
# || true: don't fail the whole script on transient fs races.
[[ -s "${unchanged_list}" ]] && xargs -0 -P "$(nproc)" -n 200 touch -c -t "${_freeze}" -- < "${unchanged_list}" || true
[[ -s "${changed_list}"   ]] && xargs -0 -P "$(nproc)" -n 200 touch -c -- < "${changed_list}" || true

mv -f "${tmp_hash}" "${hash}"
trap - EXIT
cleanup

echo -e "${_name} [${blue}${key}${end}] ${red}${changed}${end} file(s) changed, ${green}${unchanged}${end} unchanged"