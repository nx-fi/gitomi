#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: integration.sh /path/to/gt" >&2
}

detect_jobs() {
  local jobs=1
  if command -v getconf >/dev/null 2>&1; then
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  elif command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc 2>/dev/null || printf '1')"
  fi

  [[ "$jobs" =~ ^[0-9]+$ ]] || jobs=1
  (( jobs < 1 )) && jobs=1
  (( jobs > 4 )) && jobs=4
  printf '%s\n' "$jobs"
}

case_name() {
  sed -n 's/^TEST_NAME="\(.*\)"/\1/p' "$1" | head -n 1
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

GT_BIN="$1"
GT_BIN="$(cd "$(dirname "$GT_BIN")" && pwd)/$(basename "$GT_BIN")"
export GT_BIN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$SCRIPT_DIR/cases"
FILTER="${GT_INTEGRATION_FILTER:-}"
JOBS="${GT_INTEGRATION_JOBS:-$(detect_jobs)}"
if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS < 1 )); then
  echo "GT_INTEGRATION_JOBS must be a positive integer" >&2
  exit 2
fi

RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitomi-cli-it-run.XXXXXX")"
FAILURES=0
cleanup() {
  local status=$?
  if [[ -n "${GT_INTEGRATION_KEEP_LOGS:-}" || "$status" -ne 0 ]]; then
    echo "integration: logs kept in $RUN_ROOT" >&2
  else
    rm -rf "$RUN_ROOT"
  fi
}
trap cleanup EXIT

mapfile -t ALL_CASES < <(find "$CASE_DIR" -maxdepth 1 -type f -name '*.sh' | sort)
CASES=()
for case_file in "${ALL_CASES[@]}"; do
  name="$(case_name "$case_file")"
  base="$(basename "$case_file")"
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* && "$base" != *"$FILTER"* ]]; then
    continue
  fi
  CASES+=("$case_file")
done

if (( ${#CASES[@]} == 0 )); then
  echo "integration: no test cases matched" >&2
  exit 1
fi

PIDS=()
NAMES=()
LOGS=()

start_case() {
  local case_file="$1"
  local name="$2"
  local slug log
  slug="$(basename "${case_file%.sh}")"
  log="$RUN_ROOT/$slug.log"
  echo "integration: start: $name"
  TEST_SLUG="$slug" bash "$case_file" >"$log" 2>&1 &
  PIDS+=("$!")
  NAMES+=("$name")
  LOGS+=("$log")
}

wait_oldest_case() {
  local pid="${PIDS[0]}"
  local name="${NAMES[0]}"
  local log="${LOGS[0]}"

  if wait "$pid"; then
    echo "integration: ok: $name"
  else
    echo "integration: FAIL: $name" >&2
    sed 's/^/  | /' "$log" >&2
    FAILURES=$((FAILURES + 1))
  fi

  PIDS=("${PIDS[@]:1}")
  NAMES=("${NAMES[@]:1}")
  LOGS=("${LOGS[@]:1}")
}

echo "integration: running ${#CASES[@]} case(s) with $JOBS job(s)"
for case_file in "${CASES[@]}"; do
  start_case "$case_file" "$(case_name "$case_file")"
  if (( ${#PIDS[@]} >= JOBS )); then
    wait_oldest_case
  fi
done

while (( ${#PIDS[@]} > 0 )); do
  wait_oldest_case
done

if (( FAILURES > 0 )); then
  echo "integration: $FAILURES case(s) failed" >&2
  exit 1
fi

echo "integration: ok"
