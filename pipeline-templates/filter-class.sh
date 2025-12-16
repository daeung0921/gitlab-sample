#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# MODE PARSER
###############################################################################
MODE="safe"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-safe}"; shift 2 ;;
    --mode=*) MODE="${1#*=}"; shift ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

###############################################################################
# MODE → OPTION MAPPING
###############################################################################
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
    exit 1
    ;;
esac

tmp_in="$(mktemp)"
tmp_norm="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_norm"' EXIT

cat > "$tmp_in"

##############################################################################
# [PREPROCESS] ensure blank line before section headers
##############################################################################
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
' "$tmp_in" > "$tmp_norm"
mv "$tmp_norm" "$tmp_in"

##############################################################################
# [1] BASIC INFO
##############################################################################
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

##############################################################################
# [2] CLASS DECL & HIERARCHY (정확한 헤더 파싱)
##############################################################################
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
    # 예: "  interfaces: 0, fields: 3, methods: 3, attributes: 1"
    line=$0
    sub(/^  /,"",line)
    header=line

    # 콤마 제거 후 공백 split
    gsub(/,/, "", line)
    split(line, a, /[[:space:]]+/)

    # a: [1]=interfaces: [2]=0 [3]=fields: [4]=3 [5]=methods: [6]=3 [7]=attributes: [8]=1
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

##############################################################################
# [3] CLASS-LEVEL ANNOTATIONS (simple)
##############################################################################
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

##############################################################################
# [4] FIELDS
##############################################################################
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

##############################################################################
# [5] METHODS (Code normalize with mode + Exception table normalize)
##############################################################################
echo
echo "=== METHODS ==="

awk -v DROP_STACK="$DROP_STACK" \
    -v NORM_IFACE="$NORM_INVOKEINTERFACE" \
    -v NORM_LOCALS="$NORM_LOCALS" '
BEGIN {
  inBody=0; inMethod=0; inCode=0; inEx=0;
  printed=0;
  lastEx="";

  # meta blocks (per-method)
  inLVT=0; inLVTT=0; inSMT=0;
  smtCtx="";
}

function reset_meta() { inLVT=0; inLVTT=0; inSMT=0; smtCtx="" }

# class body enter/exit
/^\{/ { inBody=1; next }
/^\}/ { inBody=0; inMethod=0; inCode=0; inEx=0; reset_meta(); next }

# method signature
inBody && $0 ~ /\);$/ && $1 ~ /^(public|protected|private)/ {
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
  print "  Code:"
  inCode=1
  inEx=0
  reset_meta()
  next
}

# Exception table 시작
inCode && /Exception table:/ {
  print "  Exception table:"
  inEx=1
  next
}

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

# ---- LocalVariableTable (pretty keep: Name + Signature)
inMethod && /LocalVariableTable:/ {
  print "  LocalVariableTable:"
  inLVT=1; inLVTT=0; inSMT=0; smtCtx=""
  next
}

inLVT {
  if ($0 ~ /(LineNumberTable:|LocalVariableTypeTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) {
    inLVT=0
    # allow next rule to process current line
  } else {
    if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
    n = split($0, f, /[[:space:]]+/)
    if (n >= 6) {
      name = f[5]
      sig  = f[6]
      if (name != "" && sig != "") print "    " name "  " sig
    }
    next
  }
}

# ---- LocalVariableTypeTable (pretty keep: Name + Signature)
inMethod && /LocalVariableTypeTable:/ {
  print "  LocalVariableTypeTable:"
  inLVTT=1; inLVT=0; inSMT=0; smtCtx=""
  next
}

inLVTT {
  if ($0 ~ /(LineNumberTable:|LocalVariableTable:|StackMapTable:|MethodParameters:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:|Exception table:|Code:)/) {
    inLVTT=0
  } else {
    if ($0 ~ /Start[[:space:]]+Length[[:space:]]+Slot/) next
    n = split($0, f, /[[:space:]]+/)
    if (n >= 6) {
      name = f[5]
      sig  = f[6]
      if (name != "" && sig != "") print "    " name "  " sig
    }
    next
  }
}

# ---- StackMapTable (pretty keep: locals/stack types only)
inMethod && /StackMapTable:/ {
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

# bytecode 정규화 (Exception table이 아닌 Code 라인만)
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

  if (line ~ /^(if[a-z]*|goto|jsr|ifnull|ifnonnull)[[:space:]]+[0-9]+$/) {
    sub(/[[:space:]]+[0-9]+$/,"",line)
  }

  # 확장 branch 정규화: if*/goto/jsr 계열에서 모든 숫자 오프셋 제거
  #if (line ~ /^(if[a-z]*|if_icmp[a-z]*|ifnull|ifnonnull|goto|jsr)[[:space:]]+/) {
  #  gsub(/[[:space:]]+[0-9]+/, "", line)
  #}

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
' "$tmp_in"



##############################################################################
# [6] STRING CONSTANTS
##############################################################################
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


##############################################################################
# [7] SAFETY CHECK: BootstrapMethods / InnerClasses signal extraction
##############################################################################
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

  # 다른 섹션 헤더로 넘어가면 종료
  (inBoot || inInner) && /^[[:space:]]*(Constant pool:|\{|SourceFile:|Signature:|EnclosingMethod:|NestMembers:|PermittedSubclasses:|RuntimeVisibleAnnotations:|RuntimeInvisibleAnnotations:)/ {
    inBoot=0; inInner=0; inArgs=0
    next
  }

  ####################################################################
  # BootstrapMethods
  ####################################################################
  inBoot {
    line=$0
    sub(/^[[:space:]]+/,"",line)
    gsub(/#[0-9]+/,"",line)
    gsub(/[[:space:]]+/," ",line)
    sub(/^[[:space:]]+/,"",line)
    sub(/[[:space:]]+$/,"",line)

    # "0:" 같은 엔트리 시작을 만나면 args 컨텍스트 리셋
    if (line ~ /^[0-9]+:[[:space:]]*/) {
      inArgs=0
      sub(/^[0-9]+:[[:space:]]*/,"",line)   # ← 엔트리 번호(예: 0:) 제거
      print "  " line
      next
    }

    # Method arguments 시작
    if (line ~ /^Method arguments:/) {
      inArgs=1
      print "    Method arguments:"
      next
    }

    # REF_* 라인: args 내부면 더 깊게 들여쓰기
    if (line ~ /REF_[A-Za-z0-9][A-Za-z0-9]*/) {
      if (inArgs==1) print "      " line
      else          print "  " line
      next
    }

    # MethodType 라인: args 내부에서만 출력
    if (inArgs==1 && line ~ /^\(\).+;$/) {
      print "      " line
      next
    }

    next
  }

  ####################################################################
  # InnerClasses
  ####################################################################
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

  END {
    if (!saw) print "(no BootstrapMethods/InnerClasses found)"
  }
' "$tmp_in"
