#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 두 개의 .class/FQCN 을 비교해서 "의미 있는 차이"만 출력하는 스크립트
#
#   - 내부적으로 javap -v -p 결과를 사람이 읽기 좋은 요약 형태로 정규화
#   - 정규화된 요약을 diff -u로 비교
#   - FQCN 또는 절대 경로 .class 모두 지원
#
# 사용 예:
#   ./class-diff.sh com.example.devops.web.WelcomeController \
#                   /path/to/other/WelcomeController.class
#
#   ./class-diff.sh --cp1 ./old/WEB-INF/classes \
#                   --cp2 ./new/WEB-INF/classes \
#                   com.example.devops.web.WelcomeController \
#                   com.example.devops.web.WelcomeController
#
#   ./class-diff.sh \
#     /old/WEB-INF/classes/com/example/devops/web/WelcomeController.class \
#     /new/WEB-INF/classes/com/example/devops/web/WelcomeController.class
# ──────────────────────────────────────────────────────────────

JAVAP_BIN="${JAVAP_BIN:-javap}"

CP1=""
CP2=""
CLASS1=""
CLASS2=""

print_usage() {
  cat <<EOF
Usage: $0 [--cp1 <classpath1>] [--cp2 <classpath2>] <class1> <class2>

  --cp1 <classpath1>   첫 번째 클래스에 사용할 classpath (javap -classpath)
  --cp2 <classpath2>   두 번째 클래스에 사용할 classpath

<classN> 는 아래 중 하나:
  - FQCN (예: com.example.devops.web.WelcomeController)
  - 절대 경로 .class
    (예: /opt/.../WEB-INF/classes/com/example/devops/web/WelcomeController.class)

예시:
  $0 com.example.devops.web.WelcomeController \
     /path/to/other/WelcomeController.class

  $0 --cp1 ./old/WEB-INF/classes --cp2 ./new/WEB-INF/classes \
     com.example.devops.web.WelcomeController \
     com.example.devops.web.WelcomeController

  $0 \
    /old/WEB-INF/classes/com/example/devops/web/WelcomeController.class \
    /new/WEB-INF/classes/com/example/devops/web/WelcomeController.class
EOF
}

# ──────────────────────────────────────────────────────────────
# 인자 파싱
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp1)
      CP1="$2"
      shift 2
      ;;
    --cp2)
      CP2="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      if [[ -z "$CLASS1" ]]; then
        CLASS1="$1"
      elif [[ -z "$CLASS2" ]]; then
        CLASS2="$1"
      else
        echo "ERROR: too many arguments" >&2
        print_usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$CLASS1" || -z "$CLASS2" ]]; then
  echo "ERROR: both <class1> and <class2> are required" >&2
  print_usage
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 절대 경로 .class → FQCN + CPx 변환 (WEB-INF/classes 기준)
# ──────────────────────────────────────────────────────────────
if [[ "$CLASS1" == /* && -f "$CLASS1" ]]; then
  CLASS_PATH_FILE="$CLASS1"
  CLASS_DIR="$(echo "$CLASS_PATH_FILE" | sed -n 's#^\(.*WEB-INF/classes\)/.*#\1#p')"
  if [[ -z "$CLASS_DIR" ]]; then
    echo "ERROR: CLASS1 파일이 WEB-INF/classes 하위에 있어야 FQCN 변환 가능: $CLASS_PATH_FILE" >&2
    exit 1
  fi
  REL_PATH="${CLASS_PATH_FILE#$CLASS_DIR/}"
  REL_PATH="${REL_PATH%.class}"
  CLASS1="${REL_PATH//\//.}"
  if [[ -z "$CP1" ]]; then
    CP1="$CLASS_DIR"
  fi
  echo "[INFO] CLASS1 absolute .class path detected" >&2
  echo "       FQCN1     = $CLASS1" >&2
  echo "       classpath1= $CP1" >&2
fi

if [[ "$CLASS2" == /* && -f "$CLASS2" ]]; then
  CLASS_PATH_FILE="$CLASS2"
  CLASS_DIR="$(echo "$CLASS_PATH_FILE" | sed -n 's#^\(.*WEB-INF/classes\)/.*#\1#p')"
  if [[ -z "$CLASS_DIR" ]]; then
    echo "ERROR: CLASS2 파일이 WEB-INF/classes 하위에 있어야 FQCN 변환 가능: $CLASS_PATH_FILE" >&2
    exit 1
  fi
  REL_PATH="${CLASS_PATH_FILE#$CLASS_DIR/}"
  REL_PATH="${REL_PATH%.class}"
  CLASS2="${REL_PATH//\//.}"
  if [[ -z "$CP2" ]]; then
    CP2="$CLASS_DIR"
  fi
  echo "[INFO] CLASS2 absolute .class path detected" >&2
  echo "       FQCN2     = $CLASS2" >&2
  echo "       classpath2= $CP2" >&2
fi

# ──────────────────────────────────────────────────────────────
# 요약 함수: javap -v -p 출력 → 사람이 읽기 좋은 요약 텍스트
#   (test3.sh 과 동일 구조, 단 Classfile 경로는 출력/비교하지 않음)
# ──────────────────────────────────────────────────────────────
summarize_class() {
  local cp="$1"
  local target="$2"

  local tmp_out
  tmp_out="$(mktemp)"

  # javap 실행
  local args=(-v -p)
  if [[ -n "$cp" ]]; then
    args+=("-classpath" "$cp")
  fi
  args+=("$target")

  if ! "$JAVAP_BIN" "${args[@]}" >"$tmp_out" 2>&1; then
    echo "### ERROR: javap 실행 실패: $target" >&2
    cat "$tmp_out" >&2
    rm -f "$tmp_out"
    return 1
  fi

  # 섹션 1: BASIC INFO (Classfile 경로는 비교에서 제외)
  echo "============================================================"
  echo "  [1] BASIC INFO"
  echo "============================================================"
  awk '
    # Classfile 라인은 경로만 달라서 비교에서 제외
    /Classfile / { next }

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
  ' "$tmp_out"

  echo

  # 섹션 2: CLASS DECLARATION & HIERARCHY
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
  ' "$tmp_out"

  echo

  # 섹션 3: CLASS-LEVEL ANNOTATIONS
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
  ' "$tmp_out"

  echo

  # 섹션 4: METHODS (SIGNATURES)
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
  ' "$tmp_out"

  echo

  # 섹션 5: METHOD-LEVEL ANNOTATIONS
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
  ' "$tmp_out"

  echo

  # 섹션 6: STRING CONSTANTS
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
  ' "$tmp_out"

  echo

  rm -f "$tmp_out"
}

# ──────────────────────────────────────────────────────────────
# CLASS1, CLASS2 요약 생성
# ──────────────────────────────────────────────────────────────
TMP_SUM1="$(mktemp)"
TMP_SUM2="$(mktemp)"
trap 'rm -f "$TMP_SUM1" "$TMP_SUM2"' EXIT

summarize_class "$CP1" "$CLASS1" > "$TMP_SUM1"
summarize_class "$CP2" "$CLASS2" > "$TMP_SUM2"

# ──────────────────────────────────────────────────────────────
# diff 수행
# ──────────────────────────────────────────────────────────────
TMP_DIFF="$(mktemp)"
if diff -u "$TMP_SUM1" "$TMP_SUM2" > "$TMP_DIFF"; then
  echo "### NO MEANINGFUL DIFFERENCES (after javap-summary normalization)"
else
  echo "### MEANINGFUL DIFFERENCES FOUND"
  echo
  cat "$TMP_DIFF"
fi

rm -f "$TMP_DIFF"

#./class-diff.sh \
#  --cp1 /opt/tomcat/releases/devops/devops-legacy/WEB-INF/classes \
#  --cp2 /opt/tomcat/releases/devops/devops-new/WEB-INF/classes \
#  com.example.devops.web.WelcomeController \
#  com.example.devops.web.WelcomeController

#./class-diff.sh \
#  /opt/tomcat/releases/devops/devops-1.0.0/WEB-INF/classes/com/example/devops/web/WelcomeController.class \
#  /opt/tomcat/releases/devops/devops-legacy-20251129023645/WEB-INF/classes/com/example/devops/web/WelcomeController.class
