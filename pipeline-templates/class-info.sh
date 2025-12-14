#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# javap 기반 .class/FQCN 분석 스크립트
#   - 사람이 읽기 좋은 요약 뷰 제공
#   - 기본값: 중요 정보만 출력 (헤더/시그니처/애노테이션/문자열 상수)
#
# 옵션:
#   --cp <classpath>   : javap -classpath 에 전달
#   --show-debug       : LineNumberTable / LocalVariableTable도 출력
#   --show-code        : 메서드 Code: 섹션도 출력
#
# 입력:
#   1) FQCN  예) com.example.devops.web.WelcomeController
#   2) 절대경로 .class
#      예) /opt/.../WEB-INF/classes/com/example/devops/web/WelcomeController.class
# ──────────────────────────────────────────────────────────────

JAVAP_BIN="${JAVAP_BIN:-javap}"

CLASSPATH=""
SHOW_DEBUG=0
SHOW_CODE=0
TARGET_CLASS=""

print_usage() {
  cat <<EOF
Usage: $0 [--cp <classpath>] [--show-debug] [--show-code] <class-or-fqcn-or-.class>

  --cp <classpath>   javap -classpath 에 전달할 값
  --show-debug       LineNumberTable / LocalVariableTable 도 출력
  --show-code        메서드의 Code: (바이트코드) 섹션도 출력

예시:
  $0 com.example.devops.web.WelcomeController
  $0 --cp ./WEB-INF/classes com.example.devops.web.WelcomeController
  $0 /opt/tomcat/.../WEB-INF/classes/com/example/devops/web/WelcomeController.class
EOF
}

# ──────────────────────────────────────────────────────────────
# 인자 파싱
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp)
      CLASSPATH="$2"
      shift 2
      ;;
    --show-debug)
      SHOW_DEBUG=1
      shift
      ;;
    --show-code)
      SHOW_CODE=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_CLASS" ]]; then
        TARGET_CLASS="$1"
        shift
      else
        echo "ERROR: too many arguments" >&2
        print_usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$TARGET_CLASS" ]]; then
  echo "ERROR: class or FQCN or .class path is required" >&2
  print_usage
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 절대 경로 .class → FQCN + CLASSPATH 자동 변환
#   - WEB-INF/classes 기준으로만 변환
# ──────────────────────────────────────────────────────────────
if [[ "$TARGET_CLASS" == /* && -f "$TARGET_CLASS" ]]; then
  CLASS_PATH_FILE="$TARGET_CLASS"

  # WEB-INF/classes 기준 root 경로 추출
  CLASS_DIR="$(echo "$CLASS_PATH_FILE" | sed -n 's#^\(.*WEB-INF/classes\)/.*#\1#p')"

  if [[ -z "$CLASS_DIR" ]]; then
    echo "ERROR: 대상 파일이 WEB-INF/classes 하위에 있어야 FQCN 변환이 가능합니다: $CLASS_PATH_FILE" >&2
    exit 1
  fi

  # WEB-INF/classes 이후의 상대 경로 → FQCN
  REL_PATH="${CLASS_PATH_FILE#$CLASS_DIR/}"
  REL_PATH="${REL_PATH%.class}"
  TARGET_CLASS="${REL_PATH//\//.}"

  # --cp 옵션이 없었다면 WEB-INF/classes 를 classpath 로 사용
  if [[ -z "$CLASSPATH" ]]; then
    CLASSPATH="$CLASS_DIR"
  fi

  echo "[INFO] absolute .class path detected"
  echo "       FQCN      = $TARGET_CLASS"
  echo "       classpath = $CLASSPATH"
  echo
fi

# ──────────────────────────────────────────────────────────────
# javap 실행
# ──────────────────────────────────────────────────────────────
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

JAVAP_ARGS=(-v -p)
if [[ -n "$CLASSPATH" ]]; then
  JAVAP_ARGS+=("-classpath" "$CLASSPATH")
fi
JAVAP_ARGS+=("$TARGET_CLASS")

if ! "$JAVAP_BIN" "${JAVAP_ARGS[@]}" >"$TMP_OUT" 2>&1; then
  echo "ERROR: javap 실행 실패" >&2
  cat "$TMP_OUT" >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 1. BASIC INFO
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [1] BASIC INFO"
echo "============================================================"
awk '
  /Classfile / {
    printf("Classfile : %s\n", $2);
  }
  /Compiled from/ {
    sub(/^  /, "", $0);
    print $0;
  }
  /major version:/ {
    major=$3;
  }
  /minor version:/ {
    minor=$3;
  }
  # 클래스 플래그(ACC_SUPER 포함된 라인만)
  /flags:/ && /ACC_SUPER/ {
    sub(/^  /, "", $0);
    print $0;
  }
  END {
    if (major != "") {
      printf("Java class file version : major=%s, minor=%s\n", major, minor);
    }
  }
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 2. CLASS DECLARATION & HIERARCHY
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [2] CLASS DECLARATION & HIERARCHY"
echo "============================================================"
awk '
  /^public class / || /^class / {
    sub(/^  /, "", $0);
    print "Declaration: " $0;
  }
  /this_class:/ {
    sub(/^  /, "", $0);
    print "this_class : " $0;
  }
  /super_class:/ {
    sub(/^  /, "", $0);
    print "super_class: " $0;
  }
  /interfaces: / {
    sub(/^  /, "", $0);
    print "interfaces : " $0;
  }
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 3. CLASS-LEVEL ANNOTATIONS
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [3] CLASS-LEVEL ANNOTATIONS"
echo "============================================================"
awk '
  BEGIN { inClassAnn=0; inBody=0 }

  /^\{/ { inBody=1; next }
  /^\}/ { inBody=0; next }

  # inBody==0 인 상태에서 나오는 RuntimeVisibleAnnotations 는 클래스 레벨
  /^RuntimeVisibleAnnotations:/ && inBody==0 {
    inClassAnn=1;
    print "(class)";
    next;
  }

  inClassAnn && NF==0 { inClassAnn=0; next }

  inClassAnn {
    print "  " $0;
  }
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 4. METHODS (SIGNATURES)
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [4] METHODS (SIGNATURES)"
echo "============================================================"
awk '
  BEGIN { inBody=0 }

  /^\{/ { inBody=1; next }
  /^\}/ { inBody=0; next }

  inBody && $1 ~ /(public|protected|private)/ && $0 ~ /\);$/ {
    sub(/^  /, "", $0);
    print "- " $0;
  }
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 5. METHOD-LEVEL ANNOTATIONS
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [5] METHOD-LEVEL ANNOTATIONS"
echo "============================================================"
awk '
  BEGIN {
    inBody = 0;
    inMethod = 0;
    inAnn = 0;
    currentMethod = "";
  }

  # 클래스 바디 시작/끝
  /^\{/ { inBody = 1; next }
  /^\}/ { inBody = 0; inMethod = 0; inAnn = 0; next }

  # 메서드 시그니처 캡처 (public/protected/private ... );
  inBody && $1 ~ /(public|protected|private)/ && $0 ~ /\);$/ {
    sub(/^  /, "", $0);
    currentMethod = $0;
    inMethod = 1;
    inAnn = 0;
    next;
  }

  # 메서드 내부의 RuntimeVisibleAnnotations 시작
  inMethod && /RuntimeVisibleAnnotations:/ {
    if (currentMethod != "") {
      print currentMethod;
    }
    inAnn = 1;
    next;
  }

  # 애노테이션 블록 종료: 빈 줄 나오면 끝
  inAnn && NF == 0 {
    inAnn = 0;
    inMethod = 0;   # 한 메서드 처리 끝
    print "";
    next;
  }

  # 애노테이션 내용 출력
  inAnn {
    print "  " $0;
    next;
  }

  # 나머지는 아무것도 출력하지 않음
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 6. STRING CONSTANTS (from Constant Pool)
# ──────────────────────────────────────────────────────────────
echo "============================================================"
echo "  [6] STRING CONSTANTS (from Constant Pool)"
echo "============================================================"
awk '
  BEGIN { inCP=0 }
  /^Constant pool:/ { inCP=1; next }
  inCP && NF==0 { inCP=0 }
  # 예:   #7 = String             #8             // Gitlab
  inCP && $3=="String" {
    sub(/^  /, "", $0);
    print $0;
  }
' "$TMP_OUT"

echo

# ──────────────────────────────────────────────────────────────
# 7. DEBUG INFO (옵션)
# ──────────────────────────────────────────────────────────────
if [[ "$SHOW_DEBUG" -eq 1 ]]; then
  echo "============================================================"
  echo "  [7] DEBUG INFO (LineNumberTable / LocalVariableTable)"
  echo "============================================================"
  awk '
    BEGIN { show=0 }
    /LineNumberTable:/     { show=1; print; next }
    /LocalVariableTable:/  { show=1; print; next }

    show && NF==0 { print ""; show=0; next }

    show { print }
  ' "$TMP_OUT"
  echo
fi

# ──────────────────────────────────────────────────────────────
# 8. METHOD BYTECODE (옵션)
# ──────────────────────────────────────────────────────────────
if [[ "$SHOW_CODE" -eq 1 ]]; then
  echo "============================================================"
  echo "  [8] METHOD BYTECODE (Code: sections)"
  echo "============================================================"
  awk '
    BEGIN { inBody=0; inCode=0; currentMethod="" }

    /^\{/ { inBody=1; next }
    /^\}/ { inBody=0; next }

    inBody && $1 ~ /(public|protected|private)/ && $0 ~ /\);$/ {
      sub(/^  /, "", $0);
      currentMethod=$0;
    }

    inBody && /Code:/ {
      if (currentMethod != "") {
        print "----------------------------------------";
        print currentMethod;
      }
      print "Code:";
      inCode=1;
      next;
    }

    inCode && NF==0 {
      inCode=0;
      print "";
      next;
    }

    inCode { print }
  ' "$TMP_OUT"
  echo
fi

# ./class-info.sh \
#  /opt/tomcat/releases/devops/devops-legacy/WEB-INF/classes/com/example/devops/web/WelcomeController.class

#./class-info.sh \
#   --cp /opt/tomcat/releases/devops/devops-1.0.0/WEB-INF/classes \
#        com.example.devops.web.WelcomeController