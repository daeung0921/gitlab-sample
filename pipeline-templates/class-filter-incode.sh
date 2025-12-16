.fn_tomcat_deploy_preview:


      javap_filter_stream() { 

        ###########################################################################
        # INPUT: JAVAP_TXT (positional) + options
        # USAGE: javap_filter_stream <JAVAP_TXT> [--mode safe|aggressive]
        ###########################################################################
        local JAVAP_TXT="${1:-}"
        shift || true

        if [ -z "$JAVAP_TXT" ]; then
          echo "[ERROR] JAVAP_TXT is required. Usage: javap_filter_stream <JAVAP_TXT> [--mode safe|aggressive]" >&2
          return 1
        fi
        if [ ! -f "$JAVAP_TXT" ]; then
          echo "[ERROR] JAVAP_TXT not found: $JAVAP_TXT" >&2
          return 1
        fi

        ###########################################################################
        # MODE PARSER
        ###########################################################################
        local MODE="safe"
        while [ $# -gt 0 ]; do
          case "$1" in
            --mode) MODE="${2:-safe}"; shift 2 ;;
            --mode=*) MODE="${1#*=}"; shift ;;
            *)
              echo "[ERROR] Unknown argument: $1" >&2
              return 1
              ;;
          esac
        done

        ###########################################################################
        # MODE → OPTION MAPPING
        ###########################################################################
        local DROP_STACK NORM_INVOKEINTERFACE NORM_LOCALS
        case "$MODE" in
          safe)
            DROP_STACK=1
            NORM_INVOKEINTERFACE=1
            NORM_LOCALS=0
            ;;
          aggressive)
            DROP_STACK=1
            NORM_INVOKEINTERFACE=1
            NORM_LOCALS=1
            ;;
          *)
            echo "[ERROR] Unknown mode: $MODE (use: safe | aggressive)" >&2
            return 1
            ;;
        esac

        ###########################################################################
        # TMP WORKDIR (trap으로 디렉터리 전체 삭제)
        ###########################################################################
        local workdir
        workdir="$(mktemp -d)"
        
        local prep_out tmp_in
        prep_out="$workdir/javap.prep.txt"

        ###########################################################################
        # [PREPROCESS] ensure blank line before section headers
        ###########################################################################
        awk '
          BEGIN { prev_empty=1 }
          function is_header(l) {
            return (l ~ /^Constant pool:/ ||
                    l ~ /^  (minor version:|major version:|flags:|this_class:|super_class:|interfaces:)/ ||
                    l ~ /^  (fields:|methods:|attributes:)/ ||
                    l ~ /^  (SourceFile:|Signature:|EnclosingMethod:|InnerClasses:|BootstrapMethods:|NestMembers:|PermittedSubclasses:)/ ||
                    l ~ /^\{/)
          }
          {
            if (is_header($0) && !prev_empty) print ""
            print
            prev_empty = (NF==0)
          }
        ' "$JAVAP_TXT" > "$prep_out"

        tmp_in="$prep_out"

        ###########################################################################
        # [1] BASIC INFO
        ###########################################################################
        echo "=== BASIC INFO ==="
        awk '
          BEGIN { major=""; minor=""; src=""; flags=""; seen=0 }
          /Compiled from/      { sub(/^  /,""); src=$0 }
          /^  SourceFile: /    { sub(/^  /,""); src=$0 }
          /^  flags:/ && !seen { seen=1; sub(/^  /,""); flags=$0 }
          /major version:/     { major=$3 }
          /minor version:/     { minor=$3 }
          END {
            if (src)   print "Source             : " src
            if (flags) print "Class flags        : " flags
            if (major) print "Class file version : major=" major ", minor=" minor
          }
        ' "$tmp_in"

        ###########################################################################
        # [2] CLASS DECL & HIERARCHY
        ###########################################################################
        echo
        echo "=== CLASS DECL & HIERARCHY ==="
        awk '
          BEGIN { thisc=""; superc=""; fieldsN=""; methodsN=""; header="" }

          /this_class:/ {
            line=$0; idx=index(line,"//")
            if (idx>0) { val=substr(line, idx+2); gsub(/^[[:space:]]+/,"",val); thisc=val }
          }
          /super_class:/ {
            line=$0; idx=index(line,"//")
            if (idx>0) { val=substr(line, idx+2); gsub(/^[[:space:]]+/,"",val); superc=val }
          }
          /^  interfaces:/ {
            line=$0; sub(/^  /,"",line); header=line
            gsub(/,/, "", line)
            split(line, a, /[[:space:]]+/)
            fieldsN=a[4]; methodsN=a[6]
          }

          END {
            if (thisc)  print "this_class   : " thisc
            if (superc) print "super_class  : " superc
            if (header) print header
            if (fieldsN!="")  print "fields       : " fieldsN
            if (methodsN!="") print "methods      : " methodsN
          }
        ' "$tmp_in"

        ###########################################################################
        # [3] CLASS-LEVEL ANNOTATIONS
        ###########################################################################
        echo
        echo "=== CLASS-LEVEL ANNOTATIONS ==="
        awk '
          BEGIN { inAnn=0; inBody=0; printed=0 }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          /^  RuntimeVisibleAnnotations:/ && inBody==0 { inAnn=1; printed=1; print "(class)"; next }

          inAnn {
            if (NF==0) { inAnn=0; next }
            if ($0 ~ /^Constant pool:/) { inAnn=0; next }
            if ($0 ~ /^\{/) { inAnn=0; next }
            if ($1 ~ /^[0-9]+:/) next
            sub(/^  /,"")
            print "  " $0
            next
          }
          END { if (!printed) print "(none)" }
        ' "$tmp_in"

        ###########################################################################
        # [4] FIELDS
        ###########################################################################
        echo
        echo "=== FIELDS ==="
        awk '
          BEGIN { inBody=0 }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          inBody && $1 ~ /(public|protected|private|static|final|volatile|transient)/ &&
          $0 ~ /;/ && $0 !~ /\(/ {
            sub(/^  /,"")
            print
          }
        ' "$tmp_in"

        ###########################################################################
        # [5] METHODS
        ###########################################################################
        echo
        echo "=== METHODS ==="
        awk -v DROP_STACK="$DROP_STACK" \
            -v NORM_IFACE="$NORM_INVOKEINTERFACE" \
            -v NORM_LOCALS="$NORM_LOCALS" '
        BEGIN {
          inBody=0; inMethod=0; inCode=0; inEx=0;
          printed=0; lastEx="";
          inLVT=0; inLVTT=0; inSMT=0; smtCtx="";
        }
        function reset_meta() { inLVT=0; inLVTT=0; inSMT=0; smtCtx="" }

        /^\{/ { inBody=1; next }
        /^\}/ { inBody=0; inMethod=0; inCode=0; inEx=0; reset_meta(); next }

        inBody && $0 ~ /\);$/ && $1 ~ /^(public|protected|private)/ {
          line=$0; sub(/^  /,"",line)
          if (printed) print ""
          printed=1
          print line
          inMethod=1; inCode=0; inEx=0; lastEx=""
          reset_meta()
          next
        }

        inMethod && /Code:/ { print "  Code:"; inCode=1; inEx=0; reset_meta(); next }
        inCode && /Exception table:/ { print "  Exception table:"; inEx=1; next }

        inEx && /LineNumberTable:/            { inEx=0 }
        inEx && /LocalVariableTable:/         { inEx=0 }
        inEx && /LocalVariableTypeTable:/     { inEx=0 }
        inEx && /StackMapTable:/              { inEx=0 }
        inEx && /MethodParameters:/           { inEx=0 }
        inEx && /RuntimeVisibleAnnotations:/  { inEx=0 }
        inEx && /RuntimeInvisibleAnnotations:/{ inEx=0 }
        inEx && /^[[:space:]]*\}/             { inEx=0 }

        inEx && /^[[:space:]]*from[[:space:]]+to[[:space:]]+target[[:space:]]+type/ { next }

        inEx {
          n = split($0, f, /[[:space:]]+/)
          for (i=1; i<=n; i++) {
            if (f[i] == "Class" && (i+1) <= n) {
              ex = f[i+1]
              if (ex != lastEx) { print "    Class " ex; lastEx = ex }
              break
            }
          }
          next
        }

        inMethod && /LocalVariableTable:/ { print "  LocalVariableTable:"; inLVT=1; inLVTT=0; inSMT=0; smtCtx=""; next }
        inLVT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTypeTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inLVT=0 }
          else {
            if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
            n=split($0,f,/[[:space:]]+/); if (n>=6) { name=f[5]; sig=f[6]; if (name!=""&&sig!="") print "    " name "  " sig }
            next
          }
        }

        inMethod && /LocalVariableTypeTable:/ { print "  LocalVariableTypeTable:"; inLVTT=1; inLVT=0; inSMT=0; smtCtx=""; next }
        inLVTT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inLVTT=0 }
          else {
            if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
            n=split($0,f,/[[:space:]]+/); if (n>=6) { name=f[5]; sig=f[6]; if (name!=""&&sig!="") print "    " name "  " sig }
            next
          }
        }

        inMethod && /StackMapTable:/ { print "  StackMapTable:"; inSMT=1; inLVT=0; inLVTT=0; smtCtx=""; next }
        inSMT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTable:|LocalVariableTypeTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inSMT=0; smtCtx="" }
          else {
            if ($0 ~ /^[[:space:]]*locals[[:space:]]*=/) smtCtx="locals"
            if ($0 ~ /^[[:space:]]*stack[[:space:]]*=/)  smtCtx="stack"

            if (smtCtx=="locals" || smtCtx=="stack") {
              line=$0; out=""
              while (match(line, /class[[:space:]]+[A-Za-z0-9_.$\/]+/)) {
                tok=substr(line, RSTART, RLENGTH)
                sub(/^class[[:space:]]+/, "", tok)
                gsub(/\//, ".", tok)
                out = (out=="" ? tok : out ", " tok)
                line = substr(line, RSTART+RLENGTH)
              }
              if (out != "") {
                if (smtCtx=="locals") print "    locals = [ " out " ]"
                else                  print "    stack  = [ " out " ]"
              }
            }
            next
          }
        }

        inCode && /(LineNumberTable|LocalVariableTable|LocalVariableTypeTable|StackMapTable|MethodParameters|RuntimeVisibleAnnotations|RuntimeInvisibleAnnotations):/ { inCode=0; next }

        inCode {
          line=$0
          gsub(/\r/,"",line)
          sub(/^[[:space:]]+/,"",line)
          sub(/[[:space:]]+$/,"",line)

          if (DROP_STACK==1 && line ~ /^stack=[0-9]+,[[:space:]]*locals=[0-9]+,[[:space:]]*args_size=[0-9]+$/) next

          sub(/^[0-9]+:[[:space:]]*/,"",line)
          gsub(/ldc_w/,"ldc",line)
          gsub(/#[0-9]+/,"",line)

          if (NORM_IFACE==1) { sub(/^invokeinterface([[:space:]]*,)?[[:space:]]*[0-9]+/,"invokeinterface",line) }

          if (line ~ /^(if[a-z]*|goto|jsr|ifnull|ifnonnull)[[:space:]]+[0-9]+$/) { sub(/[[:space:]]+[0-9]+$/,"",line) }

          if (NORM_LOCALS==1) {
            if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)_[0-9]+/) sub(/_[0-9]+/,"",line)
            if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)[[:space:]]+[0-9]+/) sub(/[[:space:]]+[0-9]+/,"",line)
          }

          gsub(/[[:space:]]+/," ",line)
          sub(/^[[:space:]]+/,"",line)
          sub(/[[:space:]]+$/,"",line)
          if (line != "") print "    " line
          next
        }
        ' "$tmp_in"

        ###########################################################################
        # [6] STRING CONSTANTS
        ###########################################################################
        echo
        echo "=== STRING CONSTANTS ==="
        awk '
          BEGIN { inCP=0; seen=0 }
          /^Constant pool:/ { if (!seen) { inCP=1; seen=1; next } inCP=0; next }
          inCP && NF==0 { inCP=0; next }
          inCP && $3=="String" {
            idx=index($0,"//")
            if (idx>0) {
              s=substr($0,idx+2)
              gsub(/^ +/,"",s)
              gsub(/[[:space:]]+$/,"",s)
              print s
            }
          }
        ' "$tmp_in" | sort -u

        ###########################################################################
        # [7] SAFETY CHECK: BootstrapMethods / InnerClasses signal extraction
        ###########################################################################
        echo
        echo "=== BOOTSTRAP/INNER SAFETY SIGNALS ==="
        awk '
          BEGIN { inBoot=0; inInner=0; inArgs=0; saw=0 }

          /^[[:space:]]*BootstrapMethods:/ {
            inBoot=1; inInner=0; inArgs=0; saw=1;
            print "BootstrapMethods:"
            next
          }
          /^[[:space:]]*InnerClasses:/ {
            inInner=1; inBoot=0; inArgs=0; saw=1;
            print "InnerClasses:"
            next
          }

          NF==0 { next }

          (inBoot || inInner) && /^[[:space:]]*(Constant pool:|\{|SourceFile:|Signature:|EnclosingMethod:|NestMembers:|PermittedSubclasses:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:)/ {
            inBoot=0; inInner=0; inArgs=0
            next
          }

          inBoot {
            line=$0
            sub(/^[[:space:]]+/,"",line)
            gsub(/#[0-9]+/,"",line)
            gsub(/[[:space:]]+/," ",line)
            sub(/^[[:space:]]+/,"",line)
            sub(/[[:space:]]+$/,"",line)

            if (line ~ /^[0-9]+:[[:space:]]*/) {
              inArgs=0
              sub(/^[0-9]+:[[:space:]]*/,"",line)
              print "  " line
              next
            }

            if (line ~ /^Method arguments:/) {
              inArgs=1
              print "    Method arguments:"
              next
            }

            if (line ~ /REF_[A-Za-z0-9][A-Za-z0-9]*/) {
              if (inArgs==1) print "      " line
              else          print "  " line
              next
            }

            if (inArgs==1 && line ~ /^\(\).+;$/) {
              print "      " line
              next
            }

            next
          }

          inInner {
            idx=index($0,"//")
            if (idx>0) {
              s=substr($0, idx+2)
              gsub(/^[[:space:]]+/,"",s)
              gsub(/[[:space:]]+$/,"",s)
              if (s != "") print "  " s
            }
            next
          }

          END { if (!saw) print "(no BootstrapMethods/InnerClasses found)" }
        ' "$tmp_in"

        sudo rm -rf "$workdir"
      }

      refine_changed_classes_with_javap() {
        if ! sudo command -v  ${JAVA_HOME}/bin/javap >/dev/null 2>&1; then
          log "[javap] not found → preview semantic refine 생략"
          return 0
        fi

        if [ -z "${BASE_DIR:-}" ] || ! sudo test -d "$BASE_DIR"; then
          log "[javap] BASE_DIR 없음 → preview refine 생략"
          return 0
        fi

        [ -f "$RSYNC_PATHS" ] || return 0

        local tmp_keep tmp_ignored
        tmp_keep="$(mktemp)"
        tmp_ignored="$(mktemp)"

        local diff_dir
        diff_dir="$ART_DIR/classdiff"
        mkdir -p "$diff_dir"

        while IFS= read -r rel || [ -n "${rel:-}" ]; do
          rel="$(printf '%s' "$rel" | sed -e 's/\r$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
          [ -z "$rel" ] && continue

          case "$rel" in
            *.class)
              local old_class new_class
              old_class="${BASE_DIR%/}/$rel"
              new_class="${PREVIEW_NEW_DIR%/}/$rel"

              if ! sudo test -f "$old_class" || ! test -f "$new_class"; then
                echo "$rel" >> "$tmp_keep"
                continue
              fi

              local old_tmp new_tmp tmp_diff
              old_tmp="$(mktemp)"
              new_tmp="$(mktemp)"
              tmp_diff="$(mktemp)"

              # javap 결과 파일로 저장
              local old_javap new_javap
              old_javap="$(mktemp)"
              new_javap="$(mktemp)"

              if ! sudo ${JAVA_HOME}/bin/javap -v -p "$old_class" > "$old_javap" 2>/dev/null; then
                echo "$rel" >> "$tmp_keep"
                rm -f "$old_tmp" "$new_tmp" "$tmp_diff" "$old_javap" "$new_javap"
                continue
              fi

              if ! sudo ${JAVA_HOME}/bin/javap -v -p "$new_class" > "$new_javap" 2>/dev/null; then
                echo "$rel" >> "$tmp_keep"
                rm -f "$old_tmp" "$new_tmp" "$tmp_diff" "$old_javap" "$new_javap"
                continue
              fi

              # 저장된 javap 텍스트 파일을 javap_filter_stream으로 파싱
              if ! javap_filter_stream "$old_javap" > "$old_tmp"; then
                echo "$rel" >> "$tmp_keep"
                rm -f "$old_tmp" "$new_tmp" "$tmp_diff" "$old_javap" "$new_javap"
                continue
              fi

              if ! javap_filter_stream "$new_javap" > "$new_tmp"; then
                echo "$rel" >> "$tmp_keep"
                rm -f "$old_tmp" "$new_tmp" "$tmp_diff" "$old_javap" "$new_javap"
                continue
              fi

              local safe_rel diff_file
              safe_rel="$(printf '%s' "$rel" | sed 's#/#__#g')"
              diff_file="$diff_dir/${safe_rel}.diff"

              if diff -u "$old_tmp" "$new_tmp" > "$tmp_diff" 2>/dev/null; then
                log "[javap] preview semantic same .class → ignore: $rel"
                echo "$rel" >> "$tmp_ignored"
                rm -f "$tmp_diff"
              else
                if [ -s "$tmp_diff" ]; then
                  mv "$tmp_diff" "$diff_file"
                  log "[javap] preview semantic changed .class → keep: $rel (diff: $diff_file)"
                else
                  rm -f "$tmp_diff"
                  log "[javap] preview semantic changed .class (empty diff?) → keep: $rel"
                fi
                echo "$rel" >> "$tmp_keep"
              fi

              rm -f "$old_tmp" "$new_tmp" "$old_javap" "$new_javap"
              ;;
            *)
              echo "$rel" >> "$tmp_keep"
              ;;
          esac
        done < "$RSYNC_PATHS"

        mv "$tmp_keep" "$RSYNC_PATHS"

        if [ -s "$tmp_ignored" ]; then
          mv "$tmp_ignored" "$ART_DIR/ignored-class-semantic-same.txt"
          log "[javap] preview semantic 동일 .class 목록 기록: $ART_DIR/ignored-class-semantic-same.txt"
        else
          rm -f "$tmp_ignored"
        fi
      }

--------------------------------------------------------------------------------------------------------------
.fn_tomcat_diff_deploy:

       javap_filter_stream() { 

        ###########################################################################
        # INPUT: JAVAP_TXT (positional) + options
        # USAGE: javap_filter_stream <JAVAP_TXT> [--mode safe|aggressive]
        ###########################################################################
        local JAVAP_TXT="${1:-}"
        shift || true

        if [ -z "$JAVAP_TXT" ]; then
          echo "[ERROR] JAVAP_TXT is required. Usage: javap_filter_stream <JAVAP_TXT> [--mode safe|aggressive]" >&2
          return 1
        fi
        if [ ! -f "$JAVAP_TXT" ]; then
          echo "[ERROR] JAVAP_TXT not found: $JAVAP_TXT" >&2
          return 1
        fi

        ###########################################################################
        # MODE PARSER
        ###########################################################################
        local MODE="safe"
        while [ $# -gt 0 ]; do
          case "$1" in
            --mode) MODE="${2:-safe}"; shift 2 ;;
            --mode=*) MODE="${1#*=}"; shift ;;
            *)
              echo "[ERROR] Unknown argument: $1" >&2
              return 1
              ;;
          esac
        done

        ###########################################################################
        # MODE → OPTION MAPPING
        ###########################################################################
        local DROP_STACK NORM_INVOKEINTERFACE NORM_LOCALS
        case "$MODE" in
          safe)
            DROP_STACK=1
            NORM_INVOKEINTERFACE=1
            NORM_LOCALS=0
            ;;
          aggressive)
            DROP_STACK=1
            NORM_INVOKEINTERFACE=1
            NORM_LOCALS=1
            ;;
          *)
            echo "[ERROR] Unknown mode: $MODE (use: safe | aggressive)" >&2
            return 1
            ;;
        esac

        ###########################################################################
        # TMP WORKDIR (trap으로 디렉터리 전체 삭제)
        ###########################################################################
        local workdir
        workdir="$(mktemp -d)"

        local prep_out tmp_in
        prep_out="$workdir/javap.prep.txt"

        ###########################################################################
        # [PREPROCESS] ensure blank line before section headers
        ###########################################################################
        awk '
          BEGIN { prev_empty=1 }
          function is_header(l) {
            return (l ~ /^Constant pool:/ ||
                    l ~ /^  (minor version:|major version:|flags:|this_class:|super_class:|interfaces:)/ ||
                    l ~ /^  (fields:|methods:|attributes:)/ ||
                    l ~ /^  (SourceFile:|Signature:|EnclosingMethod:|InnerClasses:|BootstrapMethods:|NestMembers:|PermittedSubclasses:)/ ||
                    l ~ /^\{/)
          }
          {
            if (is_header($0) && !prev_empty) print ""
            print
            prev_empty = (NF==0)
          }
        ' "$JAVAP_TXT" > "$prep_out"

        tmp_in="$prep_out"

        ###########################################################################
        # [1] BASIC INFO
        ###########################################################################
        echo "=== BASIC INFO ==="
        awk '
          BEGIN { major=""; minor=""; src=""; flags=""; seen=0 }
          /Compiled from/      { sub(/^  /,""); src=$0 }
          /^  SourceFile: /    { sub(/^  /,""); src=$0 }
          /^  flags:/ && !seen { seen=1; sub(/^  /,""); flags=$0 }
          /major version:/     { major=$3 }
          /minor version:/     { minor=$3 }
          END {
            if (src)   print "Source             : " src
            if (flags) print "Class flags        : " flags
            if (major) print "Class file version : major=" major ", minor=" minor
          }
        ' "$tmp_in"

        ###########################################################################
        # [2] CLASS DECL & HIERARCHY
        ###########################################################################
        echo
        echo "=== CLASS DECL & HIERARCHY ==="
        awk '
          BEGIN { thisc=""; superc=""; fieldsN=""; methodsN=""; header="" }

          /this_class:/ {
            line=$0; idx=index(line,"//")
            if (idx>0) { val=substr(line, idx+2); gsub(/^[[:space:]]+/,"",val); thisc=val }
          }
          /super_class:/ {
            line=$0; idx=index(line,"//")
            if (idx>0) { val=substr(line, idx+2); gsub(/^[[:space:]]+/,"",val); superc=val }
          }
          /^  interfaces:/ {
            line=$0; sub(/^  /,"",line); header=line
            gsub(/,/, "", line)
            split(line, a, /[[:space:]]+/)
            fieldsN=a[4]; methodsN=a[6]
          }

          END {
            if (thisc)  print "this_class   : " thisc
            if (superc) print "super_class  : " superc
            if (header) print header
            if (fieldsN!="")  print "fields       : " fieldsN
            if (methodsN!="") print "methods      : " methodsN
          }
        ' "$tmp_in"

        ###########################################################################
        # [3] CLASS-LEVEL ANNOTATIONS
        ###########################################################################
        echo
        echo "=== CLASS-LEVEL ANNOTATIONS ==="
        awk '
          BEGIN { inAnn=0; inBody=0; printed=0 }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          /^  RuntimeVisibleAnnotations:/ && inBody==0 { inAnn=1; printed=1; print "(class)"; next }

          inAnn {
            if (NF==0) { inAnn=0; next }
            if ($0 ~ /^Constant pool:/) { inAnn=0; next }
            if ($0 ~ /^\{/) { inAnn=0; next }
            if ($1 ~ /^[0-9]+:/) next
            sub(/^  /,"")
            print "  " $0
            next
          }
          END { if (!printed) print "(none)" }
        ' "$tmp_in"

        ###########################################################################
        # [4] FIELDS
        ###########################################################################
        echo
        echo "=== FIELDS ==="
        awk '
          BEGIN { inBody=0 }
          /^\{/ { inBody=1; next }
          /^\}/ { inBody=0; next }

          inBody && $1 ~ /(public|protected|private|static|final|volatile|transient)/ &&
          $0 ~ /;/ && $0 !~ /\(/ {
            sub(/^  /,"")
            print
          }
        ' "$tmp_in"

        ###########################################################################
        # [5] METHODS
        ###########################################################################
        echo
        echo "=== METHODS ==="
        awk -v DROP_STACK="$DROP_STACK" \
            -v NORM_IFACE="$NORM_INVOKEINTERFACE" \
            -v NORM_LOCALS="$NORM_LOCALS" '
        BEGIN {
          inBody=0; inMethod=0; inCode=0; inEx=0;
          printed=0; lastEx="";
          inLVT=0; inLVTT=0; inSMT=0; smtCtx="";
        }
        function reset_meta() { inLVT=0; inLVTT=0; inSMT=0; smtCtx="" }

        /^\{/ { inBody=1; next }
        /^\}/ { inBody=0; inMethod=0; inCode=0; inEx=0; reset_meta(); next }

        inBody && $0 ~ /\);$/ && $1 ~ /^(public|protected|private)/ {
          line=$0; sub(/^  /,"",line)
          if (printed) print ""
          printed=1
          print line
          inMethod=1; inCode=0; inEx=0; lastEx=""
          reset_meta()
          next
        }

        inMethod && /Code:/ { print "  Code:"; inCode=1; inEx=0; reset_meta(); next }
        inCode && /Exception table:/ { print "  Exception table:"; inEx=1; next }

        inEx && /LineNumberTable:/            { inEx=0 }
        inEx && /LocalVariableTable:/         { inEx=0 }
        inEx && /LocalVariableTypeTable:/     { inEx=0 }
        inEx && /StackMapTable:/              { inEx=0 }
        inEx && /MethodParameters:/           { inEx=0 }
        inEx && /RuntimeVisibleAnnotations:/  { inEx=0 }
        inEx && /RuntimeInvisibleAnnotations:/{ inEx=0 }
        inEx && /^[[:space:]]*\}/             { inEx=0 }

        inEx && /^[[:space:]]*from[[:space:]]+to[[:space:]]+target[[:space:]]+type/ { next }

        inEx {
          n = split($0, f, /[[:space:]]+/)
          for (i=1; i<=n; i++) {
            if (f[i] == "Class" && (i+1) <= n) {
              ex = f[i+1]
              if (ex != lastEx) { print "    Class " ex; lastEx = ex }
              break
            }
          }
          next
        }

        inMethod && /LocalVariableTable:/ { print "  LocalVariableTable:"; inLVT=1; inLVTT=0; inSMT=0; smtCtx=""; next }
        inLVT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTypeTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inLVT=0 }
          else {
            if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
            n=split($0,f,/[[:space:]]+/); if (n>=6) { name=f[5]; sig=f[6]; if (name!=""&&sig!="") print "    " name "  " sig }
            next
          }
        }

        inMethod && /LocalVariableTypeTable:/ { print "  LocalVariableTypeTable:"; inLVTT=1; inLVT=0; inSMT=0; smtCtx=""; next }
        inLVTT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inLVTT=0 }
          else {
            if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
            n=split($0,f,/[[:space:]]+/); if (n>=6) { name=f[5]; sig=f[6]; if (name!=""&&sig!="") print "    " name "  " sig }
            next
          }
        }

        inMethod && /StackMapTable:/ { print "  StackMapTable:"; inSMT=1; inLVT=0; inLVTT=0; smtCtx=""; next }
        inSMT {
          if ($0 ~ /(LineNumberTable:|LocalVariableTable:|LocalVariableTypeTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) { inSMT=0; smtCtx="" }
          else {
            if ($0 ~ /^[[:space:]]*locals[[:space:]]*=/) smtCtx="locals"
            if ($0 ~ /^[[:space:]]*stack[[:space:]]*=/)  smtCtx="stack"

            if (smtCtx=="locals" || smtCtx=="stack") {
              line=$0; out=""
              while (match(line, /class[[:space:]]+[A-Za-z0-9_.$\/]+/)) {
                tok=substr(line, RSTART, RLENGTH)
                sub(/^class[[:space:]]+/, "", tok)
                gsub(/\//, ".", tok)
                out = (out=="" ? tok : out ", " tok)
                line = substr(line, RSTART+RLENGTH)
              }
              if (out != "") {
                if (smtCtx=="locals") print "    locals = [ " out " ]"
                else                  print "    stack  = [ " out " ]"
              }
            }
            next
          }
        }

        inCode && /(LineNumberTable|LocalVariableTable|LocalVariableTypeTable|StackMapTable|MethodParameters|RuntimeVisibleAnnotations|RuntimeInvisibleAnnotations):/ { inCode=0; next }

        inCode {
          line=$0
          gsub(/\r/,"",line)
          sub(/^[[:space:]]+/,"",line)
          sub(/[[:space:]]+$/,"",line)

          if (DROP_STACK==1 && line ~ /^stack=[0-9]+,[[:space:]]*locals=[0-9]+,[[:space:]]*args_size=[0-9]+$/) next

          sub(/^[0-9]+:[[:space:]]*/,"",line)
          gsub(/ldc_w/,"ldc",line)
          gsub(/#[0-9]+/,"",line)

          if (NORM_IFACE==1) { sub(/^invokeinterface([[:space:]]*,)?[[:space:]]*[0-9]+/,"invokeinterface",line) }

          if (line ~ /^(if[a-z]*|goto|jsr|ifnull|ifnonnull)[[:space:]]+[0-9]+$/) { sub(/[[:space:]]+[0-9]+$/,"",line) }

          if (NORM_LOCALS==1) {
            if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)_[0-9]+/) sub(/_[0-9]+/,"",line)
            if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)[[:space:]]+[0-9]+/) sub(/[[:space:]]+[0-9]+/,"",line)
          }

          gsub(/[[:space:]]+/," ",line)
          sub(/^[[:space:]]+/,"",line)
          sub(/[[:space:]]+$/,"",line)
          if (line != "") print "    " line
          next
        }
        ' "$tmp_in"

        ###########################################################################
        # [6] STRING CONSTANTS
        ###########################################################################
        echo
        echo "=== STRING CONSTANTS ==="
        awk '
          BEGIN { inCP=0; seen=0 }
          /^Constant pool:/ { if (!seen) { inCP=1; seen=1; next } inCP=0; next }
          inCP && NF==0 { inCP=0; next }
          inCP && $3=="String" {
            idx=index($0,"//")
            if (idx>0) {
              s=substr($0,idx+2)
              gsub(/^ +/,"",s)
              gsub(/[[:space:]]+$/,"",s)
              print s
            }
          }
        ' "$tmp_in" | sort -u

        ###########################################################################
        # [7] SAFETY CHECK: BootstrapMethods / InnerClasses signal extraction
        ###########################################################################
        echo
        echo "=== BOOTSTRAP/INNER SAFETY SIGNALS ==="
        awk '
          BEGIN { inBoot=0; inInner=0; inArgs=0; saw=0 }

          /^[[:space:]]*BootstrapMethods:/ {
            inBoot=1; inInner=0; inArgs=0; saw=1;
            print "BootstrapMethods:"
            next
          }
          /^[[:space:]]*InnerClasses:/ {
            inInner=1; inBoot=0; inArgs=0; saw=1;
            print "InnerClasses:"
            next
          }

          NF==0 { next }

          (inBoot || inInner) && /^[[:space:]]*(Constant pool:|\{|SourceFile:|Signature:|EnclosingMethod:|NestMembers:|PermittedSubclasses:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:)/ {
            inBoot=0; inInner=0; inArgs=0
            next
          }

          inBoot {
            line=$0
            sub(/^[[:space:]]+/,"",line)
            gsub(/#[0-9]+/,"",line)
            gsub(/[[:space:]]+/," ",line)
            sub(/^[[:space:]]+/,"",line)
            sub(/[[:space:]]+$/,"",line)

            if (line ~ /^[0-9]+:[[:space:]]*/) {
              inArgs=0
              sub(/^[0-9]+:[[:space:]]*/,"",line)
              print "  " line
              next
            }

            if (line ~ /^Method arguments:/) {
              inArgs=1
              print "    Method arguments:"
              next
            }

            if (line ~ /REF_[A-Za-z0-9][A-Za-z0-9]*/) {
              if (inArgs==1) print "      " line
              else          print "  " line
              next
            }

            if (inArgs==1 && line ~ /^\(\).+;$/) {
              print "      " line
              next
            }

            next
          }

          inInner {
            idx=index($0,"//")
            if (idx>0) {
              s=substr($0, idx+2)
              gsub(/^[[:space:]]+/,"",s)
              gsub(/[[:space:]]+$/,"",s)
              if (s != "") print "  " s
            }
            next
          }

          END { if (!saw) print "(no BootstrapMethods/InnerClasses found)" }
        ' "$tmp_in"

        sudo rm -rf "$workdir"
      }

      refine_changed_classes_with_javap() {
        # javap 없으면 그대로 통과
        if ! sudo command -v  ${JAVA_HOME}/bin/javap >/dev/null 2>&1; then
          log "[javap] not found → class semantic refine 생략"
          return 0
        fi

        [ -f "$CHANGED_LIST" ] || return 0

        ###########################################################################
        # TMP WORKDIR (trap으로 디렉터리 전체 삭제)
        ###########################################################################
        local workdir
        workdir="$(mktemp -d)"

        local tmp_keep tmp_ignored
        tmp_keep="$workdir/keep.txt"
        tmp_ignored="$workdir/ignored.txt"
        : > "$tmp_keep"
        : > "$tmp_ignored"

        # 소유권은 서비스 계정으로 맞춰줌
        sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$tmp_keep" "$tmp_ignored" || true

        # classdiff 디렉토리 준비 (_logs/classdiff)
        local diff_dir
        diff_dir="$LOG_DIR/classdiff"
        sudo mkdir -p "$diff_dir"
        sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$diff_dir" || true

        ###########################################################################
        # MAIN LOOP
        ###########################################################################
        while IFS= read -r rel || [ -n "${rel:-}" ]; do
          rel="$(printf '%s' "$rel" | sed -e 's/\r$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
          [ -z "$rel" ] && continue

          case "$rel" in
            *.class)
              local old_class new_class
              old_class="${BASE_DIR%/}/$rel"
              new_class="${NEW_DIR%/}/$rel"

              # 신규 생성/삭제 등으로 한쪽만 존재하면 그대로 keep
              if ! sudo test -f "$old_class" || ! sudo test -f "$new_class"; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              #####################################################################
              # per-class temp files (all under workdir)
              #####################################################################
              local safe_rel
              safe_rel="$(printf '%s' "$rel" | sed 's#/#__#g')"

              local old_javap new_javap old_sem new_sem tmp_diff
              old_javap="$workdir/${safe_rel}.old.javap.txt"
              new_javap="$workdir/${safe_rel}.new.javap.txt"
              old_sem="$workdir/${safe_rel}.old.semantic.txt"
              new_sem="$workdir/${safe_rel}.new.semantic.txt"
              tmp_diff="$workdir/${safe_rel}.semantic.diff"

              # 서비스 계정이 후속 처리/디버깅에 접근 가능하도록 소유권 조정(선제)
              sudo touch "$old_javap" "$new_javap" "$old_sem" "$new_sem" "$tmp_diff" 2>/dev/null || true
              sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$old_javap" "$new_javap" "$old_sem" "$new_sem" "$tmp_diff" 2>/dev/null || true

              #####################################################################
              # [1] javap output -> file
              #####################################################################
              if ! sudo ${JAVA_HOME}/bin/javap -v -p "$old_class" > "$old_javap" 2>/dev/null; then
                # 보수적으로 keep
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              if ! sudo ${JAVA_HOME}/bin/javap -v -p "$new_class" > "$new_javap" 2>/dev/null; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              #####################################################################
              # [2] semantic dump (javap_filter_stream reads file)
              #####################################################################
              if ! javap_filter_stream "$old_javap" > "$old_sem"; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              if ! javap_filter_stream "$new_javap" > "$new_sem"; then
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
                continue
              fi

              # 소유권 맞춤
              sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$old_sem" "$new_sem" 2>/dev/null || true

              #####################################################################
              # [3] semantic diff 저장 (_logs/classdiff/....diff)
              #####################################################################
              local diff_file
              diff_file="$diff_dir/${safe_rel}.diff"

              # unified diff (semantic dump 기준)
              if sudo diff -u "$old_sem" "$new_sem" > "$tmp_diff" 2>/dev/null; then
                # 동일
                log "[javap] semantic same .class → ignore: $rel"
                echo "$rel" | sudo tee -a "$tmp_ignored" >/dev/null
                sudo rm -f "$tmp_diff" 2>/dev/null || true
              else
                # diff exit 1 => 변경
                if [ -s "$tmp_diff" ]; then
                  sudo mv -f "$tmp_diff" "$diff_file"
                  sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$diff_file" 2>/dev/null || true
                  log "[javap] semantic changed .class → keep: $rel (diff: $diff_file)"
                else
                  sudo rm -f "$tmp_diff" 2>/dev/null || true
                  log "[javap] semantic changed .class (empty diff?) → keep: $rel"
                fi
                echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
              fi
              ;;
            *)
              # .class 가 아니면 그대로 유지
              echo "$rel" | sudo tee -a "$tmp_keep" >/dev/null
              ;;
          esac
        done < "$CHANGED_LIST"

        ###########################################################################
        # CHANGED_LIST 갱신
        ###########################################################################
        sudo mv -f "$tmp_keep" "$CHANGED_LIST"
        sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$CHANGED_LIST" 2>/dev/null || true

        ###########################################################################
        # ignored 목록 기록
        ###########################################################################
        if [ -s "$tmp_ignored" ]; then
          sudo mv -f "$tmp_ignored" "$LOG_DIR/ignored-class-semantic-same.txt"
          sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$LOG_DIR/ignored-class-semantic-same.txt" 2>/dev/null || true
          log "[javap] semantic 동일 .class 목록 기록: $LOG_DIR/ignored-class-semantic-same.txt"
        else
          sudo rm -f "$tmp_ignored" 2>/dev/null || true
        fi

         sudo rm -rf "$workdir"
      }
