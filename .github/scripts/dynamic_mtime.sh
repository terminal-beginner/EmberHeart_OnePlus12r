#!/bin/bash
# nullptr-style mtime hack: sha256-based change detection
# Goal: restore old mtimes for UNCHANGED files so ccache hits survive re-patching
#
# Usage:
#   dynamic_mtime.sh -u -d <dir> -k <key>   # update cache (hash all files, save hash+mtime+path)
#   dynamic_mtime.sh -t -d <dir> -k <key>   # restore mtimes for files whose hash is unchanged
#
# Cache format: <sha256>|<mtime_epoch>|<absolute_path>
# Cache file:   $DYNAMIC_CACHE_DIR/<key>.cache

set -euo pipefail

MODE=""
DIR=""
KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|-u) MODE="$1"; shift ;;
    -d) DIR="${2:-}"; shift 2 ;;
    -k) KEY="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "${MODE}" ] || [ -z "${DIR}" ]; then
  echo "[mtime] usage: -t|-u -d <dir> -k <key>" >&2
  exit 0
fi

if [ ! -d "${DIR}" ]; then
  echo "[mtime] dir not found: ${DIR}, skipping" >&2
  exit 0
fi

DIR="$(cd "${DIR}" && pwd)"

CACHE_DIR="${DYNAMIC_CACHE_DIR:-/tmp/mtime_cache}"
mkdir -p "${CACHE_DIR}"
CACHE_FILE="${CACHE_DIR}/${KEY:-default}.cache"

list_files() {
  find "${DIR}" \
    \( -path "*/.git" -o -path "*/out" -o -path "*/build" -o -path "*/.tmp_versions" \) -prune -o \
    -type f -print0 2>/dev/null
}

file_signature() {
  local f="$1"
  local h m
  h=$(sha256sum -- "${f}" 2>/dev/null | awk '{print $1}') || return 1
  m=$(stat -c %Y -- "${f}" 2>/dev/null) || return 1
  [ -n "${h}" ] && [ -n "${m}" ] || return 1
  printf '%s|%s|%s\n' "${h}" "${m}" "${f}"
}

case "${MODE}" in
  -u)
    echo "[mtime] ${KEY}: updating cache for ${DIR}"
    NEW_CACHE="${CACHE_FILE}.new.$$"
    : > "${NEW_CACHE}"

    while IFS= read -r -d '' file; do
      sig=$(file_signature "${file}") || continue
      printf '%s\n' "${sig}" >> "${NEW_CACHE}"
    done < <(list_files)

    mv -f "${NEW_CACHE}" "${CACHE_FILE}"
    total=$(wc -l < "${CACHE_FILE}" || echo 0)
    echo "[mtime] ${KEY}: cached ${total} files"
    ;;

  -t)
    if [ ! -f "${CACHE_FILE}" ]; then
      echo "[mtime] ${KEY}: no cache yet, skipping restore"
      exit 0
    fi

    echo "[mtime] ${KEY}: restoring mtimes from cache"
    restored=0
    skipped=0
    missing=0

    while IFS='|' read -r old_hash old_mtime path; do
      [ -z "${path:-}" ] && continue

      if [ ! -f "${path}" ]; then
        missing=$((missing + 1))
        continue
      fi

      cur_hash=$(sha256sum -- "${path}" 2>/dev/null | awk '{print $1}') || { skipped=$((skipped + 1)); continue; }

      if [ "${cur_hash}" = "${old_hash}" ]; then
        touch -d "@${old_mtime}" -- "${path}" 2>/dev/null && restored=$((restored + 1)) || skipped=$((skipped + 1))
      else
        skipped=$((skipped + 1))
      fi
    done < "${CACHE_FILE}"

    echo "[mtime] ${KEY}: restored=${restored} changed_or_skipped=${skipped} missing=${missing}"
    ;;
esac

exit 0