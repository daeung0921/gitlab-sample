#!/usr/bin/env bash
#
# scan-classes.sh
#
# Usage:
#   ./scan-classes.sh /path/to/classes
#

set -euo pipefail

TARGET_DIR="${1:-.}"
FILTER="/home/ec2-user/filter-class.sh"
MODE="aggressive"

TMP_ROOT="$(mktemp -d)"
OK_CNT=0
FAIL_CNT=0

echo "[INFO] scanning directory: $TARGET_DIR"
echo "[INFO] filter: $FILTER (mode=$MODE)"
echo "[INFO] temp dir: $TMP_ROOT"
echo

# --- safety guard: filter exists/executable
if [ ! -f "$FILTER" ]; then
  echo "[ERROR] filter not found: $FILTER" >&2
  exit 2
fi
if [ ! -x "$FILTER" ]; then
  echo "[ERROR] filter is not executable: $FILTER" >&2
  echo "        try: chmod +x $FILTER" >&2
  exit 2
fi

##############################################################################
check_normal_output() {
  local file="$1"

  # 1) 비어있으면 실패
  [ -s "$file" ] || return 1

  # 2) javap/awk/JVM 레벨 오류가 있으면 실패
  # 2) javap/awk/JVM 레벨 오류가 있으면 실패
  #    단, STRING CONSTANTS 섹션의 "Error:" 같은 문자열 상수는 제외해야 함
  if awk '
      BEGIN{in_str=0}
      /^=== STRING CONSTANTS ===$/ {in_str=1; next}
      /^=== / {in_str=0}
      in_str {next}
      {print}
    ' "$file" | grep -Eiq \
      "(^|[[:space:]])(ClassFormatError|VerifyError|UnsupportedClassVersionError|Truncated class file|Invalid constant pool|javap:|awk:|^Error:)"
  then
    return 1
  fi

  # 3) 필터 출력 계약(섹션 헤더) 확인
  grep -Fq "=== BASIC INFO ===" "$file" || return 1
  grep -Fq "=== METHODS ===" "$file" || return 1
  grep -Fq "=== BOOTSTRAP/INNER SAFETY SIGNALS ===" "$file" || return 1

  # 4) BASIC INFO 안에 최소 식별 정보 1개 이상 존재 확인
  #    (현재 filter는 Source/Class flags/Class file version을 항상 찍도록 되어 있음)
  grep -Eq \
    "^(Source[[:space:]]*:|Class flags[[:space:]]*:|Class file version[[:space:]]*:)" \
    "$file" || return 1

  return 0
}

##############################################################################

while IFS= read -r classfile; do
  rel="${classfile#$TARGET_DIR/}"
  out="$TMP_ROOT/${rel//\//__}.out"

  echo "[CHECK] $rel"

  # NOTE: -v -p: verbose + private, keep as before
  if ! javap -v -p "$classfile" 2>&1 | "$FILTER" --mode "$MODE" > "$out"; then
    echo "  ❌ javap/filter execution failed"
    echo "     saved to: $out"
    FAIL_CNT=$((FAIL_CNT+1))
    continue
  fi

  if check_normal_output "$out"; then
    echo "  ✅ OK"
    OK_CNT=$((OK_CNT+1))
  else
    echo "  ❌ ABNORMAL OUTPUT"
    echo "     saved to: $out"
    FAIL_CNT=$((FAIL_CNT+1))
  fi

done < <(find "$TARGET_DIR" -type f -name "*.class" | sort)

echo
echo "========================================"
echo "SUMMARY"
echo "  OK     : $OK_CNT"
echo "  FAILED : $FAIL_CNT"
echo "  OUTPUT : $TMP_ROOT"
echo "========================================"

[ "$FAIL_CNT" -eq 0 ]
