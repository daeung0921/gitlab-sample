      javap_filter_stream2() {
        local tmp_in
        tmp_in="$(mktemp)"
        cat > "$tmp_in"

        ############################################################
        # [1] BASIC INFO
        ############################################################
        echo "=== BASIC INFO ==="
        awk '
          BEGIN {
            major=""; minor=""; src=""; classfile="";
            flags_line="";
          }
          /^Classfile / {
            # 예: "Classfile /path/to/WelcomeController.class"
            # 2번째 토큰이 보통 파일 경로
            if (NF>=2) classfile=$2;
          }
          /Compiled from/ {
            # 예: "  Compiled from "WelcomeController.java""
            sub(/^  /, "", $0);
            src=$0;
          }
          /^  SourceFile: / {
            # 예: "  SourceFile: "WelcomeController.java""
            line=$0; sub(/^  /,"", line);
            src=line;
          }
          /^  flags:/ && !seen_flags {
            seen_flags=1;
            line=$0; sub(/^  /, "", line);
            flags_line=line;
          }
          /major version:/ { major=$3; }
          /minor version:/ { minor=$3; }

          END {
            if (classfile != "") printf("Classfile          : %s\n", classfile);
            if (src != "")       printf("Source             : %s\n", src);
            if (flags_line != "")printf("Class flags        : %s\n", flags_line);
            if (major != "")
              printf("Class file version : major=%s, minor=%s\n", major, minor);
          }
        ' "$tmp_in"

        ############################################################
        # [2] CLASS DECLARATION & HIERARCHY
        ############################################################
        echo
        echo "=== CLASS DECL & HIERARCHY ==="
        awk '
          BEGIN {
            decl=""; this_class=""; super_class="";
            iface_line=""; fields=0; methods=0;
          }

          /^  class / || /^  public class / {
            line=$0; sub(/^  /, "", line); decl=line;
          }
          /this_class:/ {
            line=$0; sub(/^  /, "", line);
            idx=index(line, "//");
            if (idx>0) {
              fqcn=substr(line, idx+2); gsub(/^ +/, "", fqcn);
              this_class=fqcn;
            }
          }
          /super_class:/ {
            line=$0; sub(/^  /, "", line);
            idx=index(line, "//");
            if (idx>0) {
              fqcn=substr(line, idx+2); gsub(/^ +/, "", fqcn);
              super_class=fqcn;
            }
          }
          /interfaces: / {
            line=$0; sub(/^  /, "", line);
            iface_line=line;
          }

          # 필드/메서드 개수 추정용 (본문에서 대략 카운트)
          #   - 필드: "  public int foo;"  (괄호 없음, 세미콜론 있음)
          #   - 메서드: "  public void bar(...);" (괄호 + 세미콜론)
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          inBody && $1 ~ /(public|protected|private|static|final)/ && $0 ~ /;/ {
            if ($0 ~ /\(/) methods++;
            else fields++;
          }

          END {
            if (decl != "")        printf("Declaration  : %s\n", decl);
            if (this_class != "")  printf("this_class   : %s\n", this_class);
            if (super_class != "") printf("super_class  : %s\n", super_class);
            if (iface_line != "")  printf("interfaces   : %s\n", iface_line);
            printf("fields       : %d\n", fields);
            printf("methods      : %d\n", methods);
          }
        ' "$tmp_in"

        ############################################################
        # [3] CLASS-LEVEL ANNOTATIONS
        ############################################################
        echo
        echo "=== CLASS-LEVEL ANNOTATIONS ==="
        awk '
          BEGIN { inClassAnn=0; inBody=0; printed=0 }

          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          /^  RuntimeVisibleAnnotations:/ && inBody==0 {
            inClassAnn=1;
            printed=1;
            print "(class)";
            next;
          }

          inClassAnn && NF==0 {
            inClassAnn=0;
            next;
          }

          inClassAnn {
            if ($1 ~ /^[0-9]+:/) next;
            sub(/^  /, "", $0);
            print "  " $0;
          }

          END {
            if (!printed) {
              print "(none)";
            }
          }
        ' "$tmp_in"

        ############################################################
        # [4] FIELDS (SIGNATURE + ANNOTATIONS)
        ############################################################
        echo
        echo "=== FIELDS ==="
        awk '
          BEGIN {
            inBody=0; inField=0; inFieldAnno=0;
            currentField="";
          }

          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          # 필드 선언: 본문 안에서 "public ... ;" 이면서 "(" 가 없는 라인
          inBody && $1 ~ /(public|protected|private|static|final|volatile|transient)/ && $0 ~ /;/ && $0 !~ /\(/ {
            sub(/^  /, "", $0);
            currentField=$0;
            print currentField;
            inField=1;
            inFieldAnno=0;
            next;
          }

          # 필드에 붙은 RuntimeVisibleAnnotations
          inField && /RuntimeVisibleAnnotations:/ {
            print "  Annotations:";
            inFieldAnno=1;
            next;
          }

          inFieldAnno && NF==0 {
            inFieldAnno=0;
            inField=0;
            next;
          }

          inFieldAnno {
            if ($1 ~ /^[0-9]+:/) next;
            sub(/^  /, "", $0);
            print "    " $0;
            next;
          }
        ' "$tmp_in"

        ############################################################
        # [5] METHODS (SIGNATURE + ANNOTATIONS + CODE)
        ############################################################
        echo
        echo "=== METHODS ==="
        awk '
          BEGIN {
            inBody=0; inMethod=0; inCode=0; inAnno=0;
            currentMet="";
          }

          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; inMethod=0; inCode=0; inAnno=0; next }

          # 메서드 시그니처 라인: "  public ... (...);"
          inBody && $1 ~ /(public|protected|private|static|final|synchronized|native|abstract)/ && $0 ~ /\);$/ {
            sub(/^  /, "", $0);
            if (currentMet != "") print "";
            currentMet=$0;
            print currentMet;
            inMethod=1;
            inCode=0;
            inAnno=0;
            next;
          }

          # 메서드 애노테이션 시작
          inMethod && /RuntimeVisibleAnnotations:/ {
            print "  Annotations:";
            inAnno=1;
            next;
          }

          # 애노테이션 블록 끝 (빈 줄)
          inAnno && NF==0 {
            inAnno=0;
            next;
          }

          # 애노테이션 내용: index 줄 제거
          inAnno {
            if ($1 ~ /^[0-9]+:/) next;
            sub(/^  /, "", $0);
            print "    " $0;
            next;
          }

          # Code: 섹션 시작
          inMethod && /Code:/ {
            print "  Code:";
            inCode=1;
            next;
          }

          # Code: 섹션 종료 조건
          inCode && /LineNumberTable:/      { inCode=0; next }
          inCode && /LocalVariableTable:/   { inCode=0; next }
          inCode && /StackMapTable:/        { inCode=0; next }
          inCode && /RuntimeVisibleAnnotations:/ { inCode=0; next }
          inCode && /MethodParameters:/     { inCode=0; next }

          # Code: 내부 인스트럭션 출력 (cp index 제거)
          inCode {
            line=$0;
            # " #숫자" 패턴 제거 (예: "ldc #7", "invokevirtual #11, 1")
            gsub(/ #[0-9]+/, "", line);
            sub(/^  /, "", line);
            # 앞뒤 공백 정규화
            sub(/[[:space:]]+$/, "", line);
            print "    " line;
            next;
          }
        ' "$tmp_in"

        ############################################################
        # [6] STRING CONSTANTS
        ############################################################
        echo
        echo "=== STRING CONSTANTS ==="
        awk '
          BEGIN { inCP=0 }
          /^Constant pool:/ { inCP=1; next }
          inCP && NF==0 { inCP=0 }

          # 예:   #7 = String             #8             // Gitlab
          inCP && $3=="String" {
            idx=index($0, "//");
            if (idx>0) {
              s=substr($0, idx+2);
              gsub(/^ +/, "", s);
              gsub(/[[:space:]]+$/, "", s);
              print s;
            }
          }
        ' "$tmp_in" | sort -u

        rm -f "$tmp_in"
      }


      # ───────────────────────────────────────────────
      # javap_filter_stream
      #  - stdin으로 들어온 "javap -v -p" 출력에서
      #    ConstantPool index, 디버그 테이블 등 노이즈 제거
      #  - 의미 있는 정보(시그니처/애노테이션/바이트코드/문자열만)만 출력
      # ───────────────────────────────────────────────
      javap_filter_stream() {
        local tmp_in
        tmp_in="$(mktemp)"
        cat > "$tmp_in"

        echo "=== BASIC INFO ==="
        awk '
          /Compiled from/ { sub(/^  /, "", $0); print $0; }
          /^  flags:/ && !seen_flags {
            seen_flags=1; sub(/^  /, "", $0); print $0;
          }
          /major version:/ { major=$3; }
          /minor version:/ { minor=$3; }
          END {
            if (major != "")
              printf("Java class file version : major=%s, minor=%s\n", major, minor);
          }
        ' "$tmp_in"

        echo
        echo "=== CLASS DECL & HIERARCHY ==="
        awk '
          /^  class / || /^  public class / {
            line=$0; sub(/^  /, "", line); print "Declaration: " line;
          }
          /this_class:/ {
            line=$0; sub(/^  /, "", line);
            idx=index(line, "//");
            if (idx>0) {
              fqcn=substr(line, idx+2); gsub(/^ +/, "", fqcn);
              print "this_class : " fqcn;
            }
          }
          /super_class:/ {
            line=$0; sub(/^  /, "", line);
            idx=index(line, "//");
            if (idx>0) {
              fqcn=substr(line, idx+2); gsub(/^ +/, "", fqcn);
              print "super_class: " fqcn;
            }
          }
        ' "$tmp_in"

        echo
        echo "=== CLASS-LEVEL ANNOTATIONS ==="
        awk '
          BEGIN { inClassAnn=0; inBody=0 }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }
          /^  RuntimeVisibleAnnotations:/ && inBody==0 {
            inClassAnn=1; print "(class)"; next;
          }
          inClassAnn && NF==0 { inClassAnn=0; next }
          inClassAnn {
            if ($1 ~ /^[0-9]+:/) next;
            sub(/^  /, "", $0); print "  " $0;
          }
        ' "$tmp_in"

        echo
        echo "=== METHODS ==="
        awk '
          BEGIN {
            inBody=0; inMethod=0; inCode=0; inAnno=0; currentMet="";
          }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; inMethod=0; inCode=0; inAnno=0; next }

          inBody && $1 ~ /(public|protected|private|static|final)/ && $0 ~ /\);$/ {
            sub(/^  /, "", $0);
            if (currentMet != "") print "";
            currentMet=$0; print currentMet;
            inMethod=1; inCode=0; inAnno=0; next;
          }

          inMethod && /RuntimeVisibleAnnotations:/ {
            print "  Annotations:"; inAnno=1; next;
          }
          inAnno && NF==0 { inAnno=0; next }
          inAnno {
            if ($1 ~ /^[0-9]+:/) next;
            sub(/^  /, "", $0); print "    " $0; next;
          }

          inMethod && /Code:/ {
            print "  Code:"; inCode=1; next;
          }
          inCode && /LineNumberTable:/      { inCode=0; next }
          inCode && /LocalVariableTable:/   { inCode=0; next }
          inCode && /StackMapTable:/        { inCode=0; next }
          inCode && /RuntimeVisibleAnnotations:/ { inCode=0; next }
          inCode && /MethodParameters:/     { inCode=0; next }

          inCode {
            line=$0;
            gsub(/ #[0-9]+/, "", line);
            sub(/^  /, "", line);
            print "    " line;
            next;
          }
        ' "$tmp_in"

        echo
        echo "=== STRING CONSTANTS ==="
        awk '
          BEGIN { inCP=0 }
          /^Constant pool:/ { inCP=1; next }
          inCP && NF==0 { inCP=0 }
          inCP && $3=="String" {
            idx=index($0, "//");
            if (idx>0) {
              s=substr($0, idx+2); gsub(/^ +/, "", s); print s;
            }
          }
        ' "$tmp_in" | sort -u

        rm -f "$tmp_in"
      }

      # ───────────────────────────────────────────────
      # refine_changed_classes_with_javap()
      #  - CHANGED_LIST 에서 .class 항목들에 대해
      #    BASE_DIR vs NEW_DIR javap semantic diff 수행
      #  - javap-filter 결과가 같으면 CHANGED_LIST 에서 제거
      #  - 실제 바이트코드 의미가 다른 .class 만 남김
      # ───────────────────────────────────────────────
      refine_changed_classes_with_javap() {
        # javap 없으면 그대로 통과
        if ! command -v javap >/dev/null 2>&1; then
          log "[javap] not found → class semantic refine 생략"
          return 0
        fi

        [ -f "$CHANGED_LIST" ] || return 0

        local tmp_keep tmp_ignored
        tmp_keep="$(mktemp)"
        tmp_ignored="$(mktemp)"

        # 소유권은 서비스 계정으로 맞춰줌
        sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$tmp_keep" "$tmp_ignored" || true

        while IFS= read -r rel || [ -n "${rel:-}" ]; do
          rel="$(printf '%s' "$rel" | sed -e 's/\r$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
          [ -z "$rel" ] && continue

          case "$rel" in
            *.class)
              old_class="${BASE_DIR%/}/$rel"
              new_class="${NEW_DIR%/}/$rel"

              # 신규 생성/삭제 등으로 한쪽만 존재하면 그대로 keep
              if ! sudo test -f "$old_class" || ! sudo test -f "$new_class"; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              old_tmp="$(mktemp)"
              new_tmp="$(mktemp)"

              # OLD semantic dump
              if ! sudo javap -v -p "$old_class" 2>/dev/null | javap_filter_stream > "$old_tmp"; then
                # javap 실패하면 보수적으로 keep
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                sudo rm -f "$old_tmp" "$new_tmp"
                continue
              fi

              # NEW semantic dump
              if ! sudo javap -v -p "$new_class" 2>/dev/null | javap_filter_stream > "$new_tmp"; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                sudo rm -f "$old_tmp" "$new_tmp"
                continue
              fi

              if sudo diff -q "$old_tmp" "$new_tmp" >/dev/null 2>&1; then
                # 의미적으로 동일 → 무시 목록에
                log "[javap] semantic same .class → ignore: $rel"
                echo "$rel" | sudo tee -a "$tmp_ignored" >/dev/null
              else
                # 진짜 바이트코드 의미가 바뀐 경우만 keep
                log "[javap] semantic changed .class → keep: $rel"
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
              fi

              sudo rm -f "$old_tmp" "$new_tmp"
              ;;
            *)
              # .class 가 아니면 그대로 유지
              echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
              ;;
          esac
        done < "$CHANGED_LIST"

        # 갱신
        sudo mv "$tmp_keep" "$CHANGED_LIST"
        sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$CHANGED_LIST" || true

        # 무시된 .class 목록은 로그로 남김
        if [ -s "$tmp_ignored" ]; then
          sudo mv "$tmp_ignored" "$LOG_DIR/ignored-class-semantic-same.txt"
          sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$LOG_DIR/ignored-class-semantic-same.txt" || true
          log "[javap] semantic 동일 .class 목록 기록: $LOG_DIR/ignored-class-semantic-same.txt"
        else
          sudo rm -f "$tmp_ignored"
        fi
      }

        compute_diff_lists
        compare_predicted_with_rsync               # [ADD 기존]
        refine_changed_classes_with_javap          # [ADD 새로 추가]
        apply_deletions "$TARGET" "$DELETE_LIST"
        apply_changes
