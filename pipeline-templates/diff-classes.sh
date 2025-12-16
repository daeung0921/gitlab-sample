#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./diff-classes.sh DIR_A DIR_B OUT_DIR
#
# Env:
#   FILTER=/home/ec2-user/filter-class.sh
#   MODE=aggressive|safe
#   TIMEOUT_SEC=15        # per-class timeout (0이면 timeout 미사용)
#   PROGRESS_EVERY=50     # N개마다 진행 출력

A_DIR="${1:-}"
B_DIR="${2:-}"
OUT_DIR="${3:-}"

FILTER="${FILTER:-/home/ec2-user/filter-class.sh}"
MODE="${MODE:-aggressive}"
TIMEOUT_SEC="${TIMEOUT_SEC:-15}"
PROGRESS_EVERY="${PROGRESS_EVERY:-50}"

if [ -z "$A_DIR" ] || [ -z "$B_DIR" ] || [ -z "$OUT_DIR" ]; then
  echo "Usage: $0 <DIR_A> <DIR_B> <OUT_DIR>" >&2
  exit 2
fi

if [ ! -d "$A_DIR" ]; then echo "[ERROR] DIR_A not found: $A_DIR" >&2; exit 2; fi
if [ ! -d "$B_DIR" ]; then echo "[ERROR] DIR_B not found: $B_DIR" >&2; exit 2; fi
if ! command -v javap >/dev/null 2>&1; then echo "[ERROR] javap not found" >&2; exit 2; fi
if [ ! -f "$FILTER" ]; then echo "[ERROR] FILTER not found: $FILTER" >&2; exit 2; fi
if [ ! -x "$FILTER" ]; then echo "[ERROR] FILTER not executable: $FILTER" >&2; exit 2; fi

mkdir -p "$OUT_DIR"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
A_TMP="$TMP_ROOT/A"
B_TMP="$TMP_ROOT/B"
mkdir -p "$A_TMP" "$B_TMP"

REL_LIST="$TMP_ROOT/rel.list"
{
  (cd "$A_DIR" && find . -type f -name "*.class" | sed 's|^\./||')
  (cd "$B_DIR" && find . -type f -name "*.class" | sed 's|^\./||')
} | sort -u > "$REL_LIST"

safe_name() { echo "${1//\//__}"; }

run_pipe() {
  # args: base rel out
  local base="$1" rel="$2" out="$3"
  local src="$base/$rel"

  if [ "$TIMEOUT_SEC" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SEC}s" bash -c \
      'javap -v -p "$1" 2>&1 | "$2" --mode "$3" > "$4"' _ "$src" "$FILTER" "$MODE" "$out"
  else
    javap -v -p "$src" 2>&1 | "$FILTER" --mode "$MODE" > "$out"
  fi
}

TOTAL="$(wc -l < "$REL_LIST" | tr -d ' ')"
echo "[INFO] A_DIR=$A_DIR"
echo "[INFO] B_DIR=$B_DIR"
echo "[INFO] OUT_DIR=$OUT_DIR"
echo "[INFO] FILTER=$FILTER MODE=$MODE TIMEOUT_SEC=$TIMEOUT_SEC"
echo "[INFO] files=$TOTAL"
echo

i=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  i=$((i+1))

  echo "[CHECK] ($i/$TOTAL) $rel"

  a_class="$A_DIR/$rel"
  b_class="$B_DIR/$rel"

  # 한쪽만 있으면 기록
  if [ ! -f "$a_class" ] || [ ! -f "$b_class" ]; then
    echo "  [WARN] only one side exists"
    diff_file="$OUT_DIR/$(safe_name "$rel").diff"
    {
      echo "ONLY ONE SIDE:"
      [ -f "$a_class" ] && echo "  A: $rel"
      [ -f "$b_class" ] && echo "  B: $rel"
    } > "$diff_file"
    continue
  fi

  a_out="$A_TMP/$(safe_name "$rel").out"
  b_out="$B_TMP/$(safe_name "$rel").out"

  echo "  [STEP] javap(A) + filter"
  if ! run_pipe "$A_DIR" "$rel" "$a_out"; then
    echo "  [ERR ] javap/filter failed (A)"
    diff_file="$OUT_DIR/$(safe_name "$rel").diff"
    {
      echo "RENDER FAILED (A)"
      echo "rel=$rel"
      echo "src=$a_class"
      echo "mode=$MODE timeout=$TIMEOUT_SEC"
    } > "$diff_file"
    continue
  fi

  echo "  [STEP] javap(B) + filter"
  if ! run_pipe "$B_DIR" "$rel" "$b_out"; then
    echo "  [ERR ] javap/filter failed (B)"
    diff_file="$OUT_DIR/$(safe_name "$rel").diff"
    {
      echo "RENDER FAILED (B)"
      echo "rel=$rel"
      echo "src=$b_class"
      echo "mode=$MODE timeout=$TIMEOUT_SEC"
    } > "$diff_file"
    continue
  fi

  echo "  [STEP] compare normalized output"
  if cmp -s "$a_out" "$b_out"; then
    echo "  [OK  ] semantic SAME → skip"
    continue
  fi

  echo "  [DIFF] semantic DIFFERENT → diff saved"
  diff_file="$OUT_DIR/$(safe_name "$rel").diff"
  diff -u "$a_out" "$b_out" > "$diff_file" || true

done < "$REL_LIST"


echo
echo "[DONE] diff files saved to: $OUT_DIR"
