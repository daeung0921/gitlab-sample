#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./render-classes.sh DIR OUT_DIR
#
# Env:
#   FILTER=/home/ec2-user/filter-class.sh
#   MODE=aggressive|safe
#   TIMEOUT_SEC=15        # per-class timeout (0이면 timeout 미사용)
#   PROGRESS_EVERY=50     # N개마다 진행 출력

DIR="${1:-}"
OUT_DIR="${2:-}"

FILTER="${FILTER:-/home/ec2-user/filter-class.sh}"
MODE="${MODE:-aggressive}"
TIMEOUT_SEC="${TIMEOUT_SEC:-15}"
PROGRESS_EVERY="${PROGRESS_EVERY:-50}"

if [ -z "${DIR:-}" ] || [ -z "${OUT_DIR:-}" ]; then
  echo "Usage: $0 <DIR> <OUT_DIR>" >&2
  exit 2
fi

if [ ! -d "$DIR" ]; then echo "[ERROR] DIR not found: $DIR" >&2; exit 2; fi
if ! command -v javap >/dev/null 2>&1; then echo "[ERROR] javap not found" >&2; exit 2; fi
if [ ! -f "$FILTER" ]; then echo "[ERROR] FILTER not found: $FILTER" >&2; exit 2; fi
if [ ! -x "$FILTER" ]; then echo "[ERROR] FILTER not executable: $FILTER" >&2; exit 2; fi

mkdir -p "$OUT_DIR"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REL_LIST="$TMP_ROOT/rel.list"
( cd "$DIR" && find . -type f -name "*.class" | sed 's|^\./||' | sort ) > "$REL_LIST"

safe_name() { echo "${1//\//__}"; }

run_pipe_to_file() {
  # args: base rel out
  local base="$1" rel="$2" out="$3"
  local src="$base/$rel"

  # 출력 파일을 먼저 만들고, 헤더(주석)를 선기록한 뒤 본문을 append
  {
    echo "# generated_by: javap -v -p \"$src\" | \"$FILTER\" --mode \"$MODE\""
    echo "# rel: $rel"
    echo "# mode: $MODE"
    echo "# timeout_sec: $TIMEOUT_SEC"
    echo "# ------------------------------------------------------------"
  } > "$out"

  if [ "$TIMEOUT_SEC" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SEC}s" bash -c \
      'javap -v -p "$1" 2>&1 | "$2" --mode "$3" >> "$4"' _ "$src" "$FILTER" "$MODE" "$out"
  else
    javap -v -p "$src" 2>&1 | "$FILTER" --mode "$MODE" >> "$out"
  fi
}

TOTAL="$(wc -l < "$REL_LIST" | tr -d ' ')"
echo "[INFO] DIR=$DIR"
echo "[INFO] OUT_DIR=$OUT_DIR"
echo "[INFO] FILTER=$FILTER MODE=$MODE TIMEOUT_SEC=$TIMEOUT_SEC"
echo "[INFO] files=$TOTAL"
echo

i=0
while IFS= read -r rel || [ -n "${rel:-}" ]; do
  [ -n "${rel:-}" ] || continue
  i=$((i+1))

  if [ "$PROGRESS_EVERY" -gt 0 ] && [ $((i % PROGRESS_EVERY)) -eq 0 ]; then
    echo "[PROG] ($i/$TOTAL) ..."
  fi

  class_path="$DIR/$rel"
  if [ ! -f "$class_path" ]; then
    # find 결과 기준으로는 보통 없을 수 없지만, 안전장치
    echo "[WARN] missing: $class_path"
    continue
  fi

  out_file="$OUT_DIR/$(safe_name "$rel").filtered.txt"

  echo "[RENDER] ($i/$TOTAL) $rel"
  if ! run_pipe_to_file "$DIR" "$rel" "$out_file"; then
    echo "  [ERR ] javap/filter failed: $rel"
    err_file="$OUT_DIR/$(safe_name "$rel").ERROR.txt"
    {
      echo "# RENDER FAILED"
      echo "# rel: $rel"
      echo "# src: $class_path"
      echo "# attempted: javap -v -p \"$class_path\" | \"$FILTER\" --mode \"$MODE\""
      echo "# mode=$MODE timeout_sec=$TIMEOUT_SEC"
    } > "$err_file"
    # 실패한 경우에도 다음 파일 계속
    continue
  fi
done < "$REL_LIST"

echo
echo "[DONE] rendered outputs saved to: $OUT_DIR"
