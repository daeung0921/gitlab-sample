#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./rsync-bidir-report.sh DIR_A DIR_B OUT_DIR
#
# Example:
#   ./rsync-bidir-report.sh devops-1.0.0 devops-ops _rsync_bidir

A_DIR="${1:-}"
B_DIR="${2:-}"
OUT_DIR="${3:-./_rsync_bidir_report}"

if [ -z "$A_DIR" ] || [ -z "$B_DIR" ]; then
  echo "Usage: $0 <DIR_A> <DIR_B> [OUT_DIR]" >&2
  exit 2
fi
[ -d "$A_DIR" ] || { echo "[ERR] DIR_A not found: $A_DIR" >&2; exit 2; }
[ -d "$B_DIR" ] || { echo "[ERR] DIR_B not found: $B_DIR" >&2; exit 2; }

# Normalize trailing slashes for directory copy semantics
case "$A_DIR" in */) :;; *) A_DIR="$A_DIR/";; esac
case "$B_DIR" in */) :;; *) B_DIR="$B_DIR/";; esac

mkdir -p "$OUT_DIR"

log(){ printf '[INFO] %s\n' "$*" >&2; }
ok(){  printf '[OK]   %s\n' "$*" >&2; }

# Run one direction and parse into ADDED/DELETED/CHANGED
run_one() {
  local SRC="$1" DST="$2" PREFIX="$3" BASE="$4"

  local RAW="$BASE/${PREFIX}.rsync.raw.txt"
  local ADDED="$BASE/${PREFIX}.ADDED.list"
  local DELETED="$BASE/${PREFIX}.DELETED.list"
  local CHANGED="$BASE/${PREFIX}.CHANGED.list"
  local SUMMARY="$BASE/${PREFIX}.SUMMARY.txt"

  : > "$RAW"; : > "$ADDED"; : > "$DELETED"; : > "$CHANGED"; : > "$SUMMARY"

  log "rsync dry-run ($PREFIX): SRC=$SRC  DST=$DST"
  # -r l D c n i + --delete
  # --out-format: "<itemize> <path>"
  rsync -rlDcni --delete --out-format='%i %n%L' "$SRC" "$DST" | tee "$RAW" >/dev/null

  awk -v added="$ADDED" -v deleted="$DELETED" -v changed="$CHANGED" '
    function trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }

    /^\*deleting[ \t]+/ {
      sub(/^\*deleting[ \t]+/, "", $0)
      print trim($0) >> deleted
      next
    }

    {
      code=$1
      line=$0
      sub(/^[^ \t]+[ \t]+/, "", line)
      path=trim(line)

      # Added: ends with 9 plus signs (+++++++++)
      if (code ~ /\+\+\+\+\+\+\+\+\+$/) { print path >> added; next }

      # Changed: any non-dot itemize line (rsync prints only changes with -i)
      if (code !~ /^\.+$/) { print path >> changed; next }
    }
  ' "$RAW"

  sort -u -o "$ADDED" "$ADDED"
  sort -u -o "$DELETED" "$DELETED"
  sort -u -o "$CHANGED" "$CHANGED"

  local a d c
  a="$(wc -l < "$ADDED" | tr -d ' ')"
  d="$(wc -l < "$DELETED" | tr -d ' ')"
  c="$(wc -l < "$CHANGED" | tr -d ' ')"

  {
    echo "PREFIX: $PREFIX"
    echo "SRC   : $SRC"
    echo "DST   : $DST"
    echo "CMD   : rsync -rlDcni --delete (checksum compare, dry-run)"
    echo
    echo "ADDED  : $a"
    echo "DELETED: $d"
    echo "CHANGED: $c"
    echo
    echo "Files:"
    echo "  RAW    : $RAW"
    echo "  ADDED  : $ADDED"
    echo "  DELETED: $DELETED"
    echo "  CHANGED: $CHANGED"
  } > "$SUMMARY"

  ok "done ($PREFIX): added=$a deleted=$d changed=$c"
}

# Prepare subdirs
A2B_DIR="$OUT_DIR/A_to_B"
B2A_DIR="$OUT_DIR/B_to_A"
X_DIR="$OUT_DIR/cross"
mkdir -p "$A2B_DIR" "$B2A_DIR" "$X_DIR"

# Run both directions
run_one "$A_DIR" "$B_DIR" "A2B" "$A2B_DIR"
run_one "$B_DIR" "$A_DIR" "B2A" "$B2A_DIR"

# Cross analysis helpers (set operations on sorted unique lists)
cross_sets() {
  local left="$1"
  local right="$2"
  local out_prefix="$3"
  local out_dir="$4"

  mkdir -p "$out_dir"

  local L_SORT="$out_dir/.left.sorted"
  local R_SORT="$out_dir/.right.sorted"

  # 입력 파일 없으면 빈 파일로 대체
  if [ -s "$left" ]; then
    sort -u "$left" > "$L_SORT"
  else
    : > "$L_SORT"
  fi

  if [ -s "$right" ]; then
    sort -u "$right" > "$R_SORT"
  else
    : > "$R_SORT"
  fi

  comm -12 "$L_SORT" "$R_SORT" > "$out_dir/${out_prefix}.BOTH.list"
  comm -23 "$L_SORT" "$R_SORT" > "$out_dir/${out_prefix}.ONLY_LEFT.list"
  comm -13 "$L_SORT" "$R_SORT" > "$out_dir/${out_prefix}.ONLY_RIGHT.list"

  rm -f "$L_SORT" "$R_SORT"
}


# Load lists
A2B_ADDED="$A2B_DIR/A2B.ADDED.list"
A2B_DELETED="$A2B_DIR/A2B.DELETED.list"
A2B_CHANGED="$A2B_DIR/A2B.CHANGED.list"

B2A_ADDED="$B2A_DIR/B2A.ADDED.list"
B2A_DELETED="$B2A_DIR/B2A.DELETED.list"
B2A_CHANGED="$B2A_DIR/B2A.CHANGED.list"

# Cross comparisons for each category
# Interpretations:
# - A2B.ADDED  == "A에는 있고 B에는 없음"
# - B2A.ADDED  == "B에는 있고 A에는 없음"
# These should mirror each other, but due to rsync semantics/filters they may not be identical.
cross_sets "$A2B_ADDED"   "$B2A_ADDED"   "ADDED"   "$X_DIR"
cross_sets "$A2B_DELETED" "$B2A_DELETED" "DELETED" "$X_DIR"
cross_sets "$A2B_CHANGED" "$B2A_CHANGED" "CHANGED" "$X_DIR"

# Also useful: "missing on each side" derived cleanly
# A_only == A2B.ADDED (exists only in A)
# B_only == B2A.ADDED (exists only in B)
cp -a "$A2B_ADDED" "$X_DIR/ONLY_IN_A.list"
cp -a "$B2A_ADDED" "$X_DIR/ONLY_IN_B.list"

# Overall summary
SUMMARY="$OUT_DIR/SUMMARY.txt"
{
  echo "A_DIR: $A_DIR"
  echo "B_DIR: $B_DIR"
  echo "Mode : rsync -rlDcni --delete (checksum compare, dry-run) both directions"
  echo

  echo "[A -> B]"
  cat "$A2B_DIR/A2B.SUMMARY.txt"
  echo
  echo "[B -> A]"
  cat "$B2A_DIR/B2A.SUMMARY.txt"
  echo

  echo "[Cross]"
  echo "ONLY_IN_A (A has, B missing): $X_DIR/ONLY_IN_A.list ($(wc -l < "$X_DIR/ONLY_IN_A.list" | tr -d ' '))"
  echo "ONLY_IN_B (B has, A missing): $X_DIR/ONLY_IN_B.list ($(wc -l < "$X_DIR/ONLY_IN_B.list" | tr -d ' '))"
  echo
  echo "ADDED intersection (both runs report as added): $X_DIR/ADDED.BOTH.list ($(wc -l < "$X_DIR/ADDED.BOTH.list" | tr -d ' '))"
  echo "CHANGED intersection: $X_DIR/CHANGED.BOTH.list ($(wc -l < "$X_DIR/CHANGED.BOTH.list" | tr -d ' '))"
  echo "DELETED intersection: $X_DIR/DELETED.BOTH.list ($(wc -l < "$X_DIR/DELETED.BOTH.list" | tr -d ' '))"
  echo
  echo "Output root: $OUT_DIR"
} > "$SUMMARY"

ok "All reports generated: $SUMMARY"
echo "$SUMMARY"
