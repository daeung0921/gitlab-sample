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
  local MODE="aggressive"
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
    BEGIN {
      thisc=""; superc="";
      ifaceN=""; fieldsN=""; methodsN=""; attrsN="";
      header=""
    }

    /this_class:/ {
      line=$0
      idx=index(line,"//")
      if (idx>0) {
        val=substr(line, idx+2)
        gsub(/^[[:space:]]+/,"",val)
        thisc=val
      }
    }

    /super_class:/ {
      line=$0
      idx=index(line,"//")
      if (idx>0) {
        val=substr(line, idx+2)
        gsub(/^[[:space:]]+/,"",val)
        superc=val
      }
    }

    /^  interfaces:/ {
      line=$0
      sub(/^  /,"",line)
      header=line

      gsub(/,/, "", line)
      split(line, a, /[[:space:]]+/)

      ifaceN=a[2]; fieldsN=a[4]; methodsN=a[6]; attrsN=a[8]
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

    /^  RuntimeVisibleAnnotations:/ && inBody==0 {
      inAnn=1; printed=1; print "(class)"; next
    }

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
    printed=0;
    lastEx="";

    inLVT=0; inLVTT=0; inSMT=0;
    smtCtx="";

    tmpseq=0;
    srand();
  }

  function reset_meta() { inLVT=0; inLVTT=0; inSMT=0; smtCtx="" }

  function tmpdir(   d) {
    d = ENVIRON["TMPDIR"]
    if (d == "") d = "/tmp"
    return d
  }

  function tmpfile(tag,    id) {
    id = systime() "_" int(rand()*1000000000) "_" (++tmpseq)
    return tmpdir() "/javapf_" tag "_" id ".txt"
  }

  function flush_sorted(file, indent,    cmd) {
    if (file == "") return
    if (indent == "") indent = "    "
    cmd = "sort -u " file " | awk -v pfx='\''" indent "'\'' '\''{print pfx $0}'\''"
    system(cmd)
    system("rm -f " file)
  }

  /^\{/ { inBody=1; next }

  /^\}/ {
    if (inLVT)  { flush_sorted(lvt_file, "    ");  inLVT=0 }
    if (inLVTT) { flush_sorted(lvtt_file, "    "); inLVTT=0 }

    inBody=0; inMethod=0; inCode=0; inEx=0;
    reset_meta()
    next
  }

  # method signature
  inBody && $0 ~ /\);$/ && $1 ~ /^(public|protected|private)/ {
    if (inLVT)  { flush_sorted(lvt_file, "    ");  inLVT=0 }
    if (inLVTT) { flush_sorted(lvtt_file, "    "); inLVTT=0 }

    line=$0
    sub(/^  /,"",line)

    if (printed) print ""
    printed=1

    print line
    inMethod=1
    inCode=0
    inEx=0
    lastEx=""
    reset_meta()
    next
  }

  # Code 시작
  inMethod && /Code:/ {
    if (inLVT)  { flush_sorted(lvt_file, "    ");  inLVT=0 }
    if (inLVTT) { flush_sorted(lvtt_file, "    "); inLVTT=0 }

    print "  Code:"
    inCode=1
    inEx=0
    reset_meta()
    next
  }

  # Exception table 시작
  inCode && /Exception table:/ { print "  Exception table:"; inEx=1; next }

  # Exception table 종료 조건들
  inEx && /LineNumberTable:/            { inEx=0 }
  inEx && /LocalVariableTable:/         { inEx=0 }
  inEx && /LocalVariableTypeTable:/     { inEx=0 }
  inEx && /StackMapTable:/              { inEx=0 }
  inEx && /MethodParameters:/           { inEx=0 }
  inEx && /RuntimeVisibleAnnotations:/  { inEx=0 }
  inEx && /RuntimeInvisibleAnnotations:/{ inEx=0 }
  inEx && /^[[:space:]]*\}/             { inEx=0 }

  # Exception table 헤더 라인 제거
  inEx && /^[[:space:]]*from[[:space:]]+to[[:space:]]+target[[:space:]]+type/ { next }

  # Exception table 본문: "Class xxx"만 뽑아서 중복 제거 출력
  inEx {
    n = split($0, f, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      if (f[i] == "Class" && (i+1) <= n) {
        ex = f[i+1]
        if (ex != lastEx) {
          print "    Class " ex
          lastEx = ex
        }
        break
      }
    }
    next
  }

  # ---- LocalVariableTable (collect -> sort -u -> print)
  inMethod && /LocalVariableTable:/ {
    if (inLVTT) { flush_sorted(lvtt_file, "    "); inLVTT=0 }

    print "  LocalVariableTable:"
    inLVT=1; inLVTT=0; inSMT=0; smtCtx=""
    lvt_file = tmpfile("lvt")
    next
  }

  inLVT {
    if ($0 ~ /(LineNumberTable:|LocalVariableTypeTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) {
      flush_sorted(lvt_file, "    ")
      inLVT=0
      # fall-through
    } else {
      if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
      n = split($0, f, /[[:space:]]+/)
      if (n >= 6) {
        name = f[5]
        sig  = f[6]
        if (name != "" && sig != "") print name "  " sig >> lvt_file
      }
      next
    }
  }

  # ---- LocalVariableTypeTable (collect -> sort -u -> print)
  inMethod && /LocalVariableTypeTable:/ {
    if (inLVT) { flush_sorted(lvt_file, "    "); inLVT=0 }

    print "  LocalVariableTypeTable:"
    inLVTT=1; inLVT=0; inSMT=0; smtCtx=""
    lvtt_file = tmpfile("lvtt")
    next
  }

  inLVTT {
    if ($0 ~ /(LineNumberTable:|LocalVariableTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) {
      flush_sorted(lvtt_file, "    ")
      inLVTT=0
      # fall-through
    } else {
      if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
      n = split($0, f, /[[:space:]]+/)
      if (n >= 6) {
        name = f[5]
        sig  = f[6]
        if (name != "" && sig != "") print name "  " sig >> lvtt_file
      }
      next
    }
  }

  # ---- StackMapTable (pretty keep: locals/stack types only)
  inMethod && /StackMapTable:/ {
    if (inLVT)  { flush_sorted(lvt_file, "    ");  inLVT=0 }
    if (inLVTT) { flush_sorted(lvtt_file, "    "); inLVTT=0 }

    print "  StackMapTable:"
    inSMT=1; inLVT=0; inLVTT=0; smtCtx=""
    next
  }

  inSMT {
    if ($0 ~ /(LineNumberTable:|LocalVariableTable:|LocalVariableTypeTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) {
      inSMT=0
      smtCtx=""
    } else {
      if ($0 ~ /^[[:space:]]*locals[[:space:]]*=/) smtCtx="locals"
      if ($0 ~ /^[[:space:]]*stack[[:space:]]*=/)  smtCtx="stack"

      if (smtCtx=="locals" || smtCtx=="stack") {
        line=$0
        out=""
        while (match(line, /class[[:space:]]+[A-Za-z0-9_.$\/]+/)) {
          tok = substr(line, RSTART, RLENGTH)
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

  # Code 종료(메타데이터 시작) 조건 확장
  inCode && /(LineNumberTable|LocalVariableTable|LocalVariableTypeTable|StackMapTable|MethodParameters|RuntimeVisibleAnnotations|RuntimeInvisibleAnnotations):/ {
    inCode=0
    next
  }

  # bytecode 정규화
  inCode {
    line=$0
    gsub(/\r/,"",line)
    sub(/^[[:space:]]+/,"",line)
    sub(/[[:space:]]+$/,"",line)

    if (DROP_STACK==1 && line ~ /^stack=[0-9]+,[[:space:]]*locals=[0-9]+,[[:space:]]*args_size=[0-9]+$/) next

    sub(/^[0-9]+:[[:space:]]*/,"",line)
    gsub(/ldc_w/,"ldc",line)
    gsub(/#[0-9]+/,"",line)

    if (NORM_IFACE==1) {
      sub(/^invokeinterface([[:space:]]*,)?[[:space:]]*[0-9]+/,"invokeinterface",line)
    }

    # invokedynamic 정규화 (형식 무관)
    if (line ~ /^invokedynamic/) {
      cpos = index(line, "//")
      if (cpos > 0) {
        pre  = substr(line, 1, cpos-1)
        post = substr(line, cpos)
        sub(/^[[:space:]]+/, "", pre)
        pre = "invokedynamic"
        line = pre " " post
      } else {
        line = "invokedynamic"
      }
    }

    if (line ~ /^(if[a-z]*|goto|jsr|ifnull|ifnonnull)[[:space:]]+[0-9]+$/) {
      sub(/[[:space:]]+[0-9]+$/,"",line)
    }

    # 확장 branch 정규화
    if (line ~ /^(if[a-z]*|if_icmp[a-z]*|ifnull|ifnonnull|goto|jsr)[[:space:]]+/) {
      gsub(/[[:space:]]+[0-9]+/, "", line)
    }

    if (NORM_LOCALS==1) {
      if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)_[0-9]+/) {
        sub(/_[0-9]+/,"",line)
      }
      if (line ~ /^(aload|astore|iload|istore|lload|lstore|fload|fstore|dload|dstore)[[:space:]]+[0-9]+/) {
        sub(/[[:space:]]+[0-9]+/,"",line)
      }
    }

    gsub(/[[:space:]]+/," ",line)
    sub(/^[[:space:]]+/,"",line)
    sub(/[[:space:]]+$/,"",line)

    if (line != "") print "    " line
    next
  }

  END {
    if (inLVT)  flush_sorted(lvt_file, "    ")
    if (inLVTT) flush_sorted(lvtt_file, "    ")
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
  # [7] SAFETY CHECK: BootstrapMethods / InnerClasses 
  ###########################################################################
  echo
  echo "=== BOOTSTRAP/INNER SAFETY SIGNALS ==="
  awk '
    BEGIN {
      inBoot=0; inInner=0; inArgs=0;
      sawBoot=0; sawInner=0;
      tmpseq=0;
      srand();
    }

    function tmpdir(   d) {
      d = ENVIRON["TMPDIR"]
      if (d == "") d = "/tmp"
      return d
    }

    function tmpfile(tag,    id) {
      id = systime() "_" int(rand()*1000000000) "_" (++tmpseq)
      return tmpdir() "/javapf_" tag "_" id ".txt"
    }

    function flush_inner(file,    cmd) {
      if (file == "") return
      cmd = "sort -u " file " | awk '\''{print \"  \" $0}'\''"
      system(cmd)
      system("rm -f " file)
    }

    /^[[:space:]]*BootstrapMethods:/ {
      if (inInner) { flush_inner(inner_file); inInner=0 }
      inBoot=1; inInner=0; inArgs=0; sawBoot=1;
      print "BootstrapMethods:"
      next
    }

    /^[[:space:]]*InnerClasses:/ {
      if (inInner) { flush_inner(inner_file) }
      inInner=1; inBoot=0; inArgs=0; sawInner=1;
      inner_file = tmpfile("inner")
      print "InnerClasses:"
      next
    }

    NF==0 { next }

    (inBoot || inInner) && /^[[:space:]]*(Constant pool:|\{|SourceFile:|Signature:|EnclosingMethod:|NestMembers:|PermittedSubclasses:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:)/ {
      if (inInner) { flush_inner(inner_file); inInner=0 }
      inBoot=0; inArgs=0
      next
    }

    # BootstrapMethods (streaming)
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

    # InnerClasses (collect -> sort -u -> print)
    inInner {
      idx=index($0,"//")
      if (idx>0) {
        s=substr($0, idx+2)
        gsub(/^[[:space:]]+/,"",s)
        gsub(/[[:space:]]+$/,"",s)
        if (s != "") print s >> inner_file
      }
      next
    }

    END {
      if (inInner) flush_inner(inner_file)
      if (!sawBoot && !sawInner) print "(no BootstrapMethods/InnerClasses found)"
    }
  ' "$tmp_in"
  
   sudo rm -rf "$workdir"
}
