#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────
# 간단한 로그 함수
# ───────────────────────────────────────────────
log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

# ───────────────────────────────────────────────
# 필수 명령 확인
# ───────────────────────────────────────────────
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "필수 명령을 찾을 수 없습니다: $1"
    exit 1
  fi
}

need_cmd java
need_cmd javac
need_cmd mvn

# ───────────────────────────────────────────────
# 1) JDK / javac 버전 (major, minor/patch, build)
# ───────────────────────────────────────────────
print_jdk_info() {
  log "1) JDK / javac 버전 정보"

  # java -version 전체 출력 (표준에러로 나와서 2>&1)
  java_version_raw="$(java -version 2>&1 || true)"
  javac_version_raw="$(javac -version 2>&1 || true)"

  echo "  [java -version]"
  echo "$java_version_raw" | sed 's/^/    /'

  echo
  echo "  [javac -version]"
  echo "    $javac_version_raw"

  # 대충 major/minor/patch & build 넘버 뽑기 (OpenJDK 계열 기준)
  # 예) openjdk version "17.0.9" 2023-10-17 LTS
  #     OpenJDK Runtime Environment (build 17.0.9+9-LTS)
  java_version="$(echo "$java_version_raw" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  java_build="$(echo "$java_version_raw" | grep -i 'Runtime Environment' | sed -E 's/.*build ([^)]*).*/\1/' || true)"

  echo
  echo "  [파싱된 JDK 버전]"
  echo "    java.version   = $java_version"
  [ -n "$java_build" ] && echo "    java.build     = $java_build"
  echo "    javac.version  = $javac_version_raw"
  echo
}

# ───────────────────────────────────────────────
# 4) Maven version
# ───────────────────────────────────────────────
print_maven_info() {
  log "4) Maven 버전 정보"

  mvn_ver_raw="$(mvn -version 2>&1 || true)"
  echo "$mvn_ver_raw" | sed 's/^/    /'
  echo
}

# ───────────────────────────────────────────────
# 5) maven-compiler-plugin 버전 / 6) 컴파일 옵션
#    effective-pom 기준으로 추출
# ───────────────────────────────────────────────
print_compiler_plugin_info() {
  log "5) maven-compiler-plugin 버전 / 6) 컴파일 옵션 (effective-pom 기준)"

  # effective-pom 생성 (임시 파일 사용)
  tmp_pom="$(mktemp)"
  trap 'rm -f "$tmp_pom"' EXIT

  log "  mvn help:effective-pom -Doutput=$tmp_pom 실행 중..."
  mvn -q help:effective-pom -Doutput="$tmp_pom"

  echo
  echo "  [maven-compiler-plugin 섹션 추출]"
  echo

  # maven-compiler-plugin 블록만 대략적으로 잘라내기
  # (복수 선언이 있으면 가장 먼저 나오는 것 기준)
  compiler_block="$(awk '
    /<artifactId>maven-compiler-plugin<\/artifactId>/ {
      in_block=1
    }
    in_block {
      print
      if ($0 ~ /<\/plugin>/) {
        exit
      }
    }
  ' "$tmp_pom" || true)"

  if [ -z "$compiler_block" ]; then
    warn "  effective-pom 에서 maven-compiler-plugin 을 찾지 못했습니다."
    echo
    return
  fi

  echo "$compiler_block" | sed 's/^/    /'
  echo

  # 버전 / source / target / release / debug / debuglevel 파싱
  plugin_version="$(echo "$compiler_block" | sed -n 's/.*<version>\(.*\)<\/version>.*/\1/p' | head -n1)"
  cfg_source="$(echo "$compiler_block" | sed -n 's/.*<source>\(.*\)<\/source>.*/\1/p' | head -n1)"
  cfg_target="$(echo "$compiler_block" | sed -n 's/.*<target>\(.*\)<\/target>.*/\1/p' | head -n1)"
  cfg_release="$(echo "$compiler_block" | sed -n 's/.*<release>\(.*\)<\/release>.*/\1/p' | head -n1)"
  cfg_debug="$(echo "$compiler_block" | sed -n 's/.*<debug>\(.*\)<\/debug>.*/\1/p' | head -n1)"
  cfg_debuglevel="$(echo "$compiler_block" | sed -n 's/.*<debuglevel>\(.*\)<\/debuglevel>.*/\1/p' | head -n1)"

  echo "  [파싱된 maven-compiler-plugin 설정 요약]"
  echo "    version     = ${plugin_version:-<not set>}"
  echo "    source      = ${cfg_source:-<not set>}"
  echo "    target      = ${cfg_target:-<not set>}"
  echo "    release     = ${cfg_release:-<not set>}"
  echo "    debug       = ${cfg_debug:-<maven default: true>}"
  echo "    debuglevel  = ${cfg_debuglevel:-<maven/javac default>}"
  echo
}

# ───────────────────────────────────────────────
# 7) annotation processor / lombok 검사
#   - dependency:list 기반 lombok 존재 여부
#   - compiler plugin 의 annotationProcessorPaths 존재 여부
# ───────────────────────────────────────────────
print_annotation_processor_info() {
  log "7) Annotation Processor / Lombok 검사"

  echo
  log "  (1) mvn dependency:list 로 lombok 의존성 확인"

  tmp_dep="$(mktemp)"
  trap 'rm -f "$tmp_dep"' EXIT

  # dependency:list 출력
  mvn -q dependency:list -DincludeScope=compile -DoutputFile="$tmp_dep" -DappendOutput=true >/dev/null 2>&1 || true

  if grep -qi 'lombok' "$tmp_dep"; then
    echo "    → Lombok 의존성이 감지되었습니다."
    grep -i 'lombok' "$tmp_dep" | sed 's/^/      /'
  else
    echo "    → Lombok 의존성은 감지되지 않았습니다."
  fi

  echo
  log "  (2) maven-compiler-plugin 의 annotationProcessorPaths 확인 (effective-pom)"

  tmp_pom2="$(mktemp)"
  trap 'rm -f "$tmp_pom2"' EXIT
  mvn -q help:effective-pom -Doutput="$tmp_pom2"

  anno_block="$(awk '
    /<artifactId>maven-compiler-plugin<\/artifactId>/ { in_plugin=1 }
    in_plugin && /<annotationProcessorPaths>/ { in_anno=1 }
    in_anno {
      print
      if ($0 ~ /<\/annotationProcessorPaths>/) {
        exit
      }
    }
  ' "$tmp_pom2" || true)"

  if [ -n "$anno_block" ]; then
    echo
    echo "    [annotationProcessorPaths 섹션]"
    echo "$anno_block" | sed 's/^/      /'
  else
    echo "    → annotationProcessorPaths 설정이 없습니다."
  fi

  echo
}

# ───────────────────────────────────────────────
# 3) javac implementation build number
#    (사실상 java -version / javac -version 에서 이미 노출)
# ───────────────────────────────────────────────
print_javac_build_note() {
  log "3) javac implementation build number 메모"
  echo "    위의 [java -version] 출력의 Runtime Environment (build ...) 라인,"
  echo "    그리고 [javac -version] 출력이 사실상 javac implementation build 를 나타냅니다."
  echo "    두 빌드 환경에서 이 문자열(특히 build 번호)이 다르면, synthetic method,"
  echo "    StackMapTable, LVT 생성 방식이 달라질 수 있습니다."
  echo
}

# ───────────────────────────────────────────────
# 메인
# ───────────────────────────────────────────────
main() {
  echo "============================================================"
  echo " Java/Maven 빌드 환경 조사 스크립트"
  echo "  - JDK/Javac 버전 (1,2,3)"
  echo "  - Maven / maven-compiler-plugin 정보 (4,5,6)"
  echo "  - Annotation Processor / Lombok (7)"
  echo "============================================================"
  echo

  print_jdk_info           # 1,2,3
  print_javac_build_note   # 3 설명
  print_maven_info         # 4
  print_compiler_plugin_info  # 5,6
  print_annotation_processor_info # 7

  echo "============================================================"
  echo " 빌드 환경 비교 시에는 이 스크립트 출력을 두 환경에서 각각 실행해"
  echo " diff 하시면 됩니다."
  echo "============================================================"
}

main "$@"