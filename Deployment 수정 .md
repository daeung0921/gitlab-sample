# Deployment 수정

1. `/opt/tomcat/releases` 정리
2. `/opt/tomcat/artifacts` 정리 
3. nexus 스냅샷 릴리즈 정리
4. 신규 넥서스 서버로 연결하도록 변경
5. 함수 변경
    
    ```ruby
    GREEN="\033[1;32m"
    BLUE="\033[1;34m"
    YELLOW="\033[1;33m"
    RED="\033[1;31m"
    NC="\033[0m"  # no color
    
    log() {
      local msg="$1"
      printf "${BLUE}[INFO]${NC} %s\n" "$msg"
      printf "[INFO] %s\n" "$msg" >> "$LOG_FILE"
    }
    
    ok() {
      local msg="$1"
      printf "${GREEN}[OK]${NC} %s\n" "$msg"
      printf "[OK] %s\n" "$msg" >> "$LOG_FILE"
    }
    
    err() {
      local msg="$1"
      printf "${RED}[ERROR]${NC} %s\n" "$msg" >&2
      printf "[ERROR] %s\n" "$msg" >> "$LOG_FILE"
    }
    
    fail() {
      local msg="$1"
      printf "${RED}[FAIL]${NC} %s\n" "$msg" >&2
      printf "[FAIL] %s\n" "$msg" >> "$LOG_FILE"
      exit 1
    }
    ```
    
6. common.yml 수정
    
    ```ruby
    mkdir gitlab_ci_jobs
    chmod 777 gitlab_ci_jobs/
     
    REMOTE_DIR: "/gitlab_ci_jobs/gitlab-ci-${CI_PIPELINE_ID}-${CI_JOB_ID}"
    ```
    
7. 함수 추가 (모든 deployment 수정)
    - setup_acl ⇒ setup_context 이후에 호출
        
        ```ruby
        setup_acl() {
          uid="$(id -u)"; gid="$(id -g)"
          sudo setfacl -R -m u:$uid:rwx $RELEASES_BASE
          sudo setfacl -R -m d:u:$uid:rwx $RELEASES_BASE
          sudo setfacl -R -m m:rwx $RELEASES_BASE
          sudo setfacl -R -m d:m:rwx $RELEASES_BASE
        
          sudo setfacl -R -m u:$ARTIFACT_USER:rwx $REMOTE_DIR
          sudo setfacl -R -m d:u:$ARTIFACT_USER:rwx $REMOTE_DIR
          sudo setfacl -R -m m:rwx $REMOTE_DIR
          sudo setfacl -R -m d:m:rwx $REMOTE_DIR
        }
        ```
        
    - change_chown_path ⇒ chown_path 대체 및 chown 코드 대체
        
        ```ruby
        log()  { printf '[INFO] %s\n' "$*"; }
        change_chown_path() {
            local path="$1"
            local user="$2"
            local group="$3"
         
            if [ -z "$path" ] || [ ! -e "$path" ]; then
                log "ERROR: path does not exist: '$path'" >&2
                return 1
            fi
        
            # 위험한 경로는 금지
            case "$path" in
                /|/etc|/usr|/bin|/sbin|/lib*|/var*)
                    echo "ERROR: unsafe path: '$path'" >&2
                    return 1
                    ;;
            esac
        
            # 소유권 변경
            sudo chown -R "$user:$group" "$path"
        
            # 권한 변경 (파일/디렉터리 구분)
            if [ -d "$path" ]; then
                sudo find "$path" -type d -exec chmod 0755 {} +
                sudo find "$path" -type f -exec chmod 0644 {} +
            elif [ -f "$path" ]; then
                sudo chmod 0644 "$path"
            else
                echo "WARNING: '$path' is neither file nor directory" >&2
            fi
        }
        ```
        
8. fn_tomcat_symbolic_deploy ⇒ 일단 수정은 하되 rpt 도 diff 로 변경하고 partial deploy 만 끄기 
    
    ```ruby
    # 함수 수정
    setup_context() {
      APP_NAME="${CONTEXT_PATH#/}"                       # "/devops" → "devops"
      LIVE_LINK="${WEBAPPS_ROOT%/}/${APP_NAME}"
      APP_RELEASES_DIR="${RELEASES_BASE%/}/${APP_NAME}"
      ART_DIR="$REMOTE_DIR/artifacts"
      LOG="$ART_DIR/$DEPLOY_LOG_NAME"
      OUT_ZIP="$ART_DIR/symlink-deploy-artifacts.zip"
    
      NEW_VERSION="${COMMIT_TAG#v}"
      BASE_URL="${RELEASE_REPO_URL%/}/${GROUP_ID//.//}/${ARTIFACT_ID}"
      NEW_WAR="${ARTIFACT_ID}-${NEW_VERSION}.war"
      NEW_URL="${BASE_URL}/${NEW_VERSION}/${NEW_WAR}"
    
      uid="$(id -u)"; gid="$(id -g)"
      sudo mkdir -p "$REMOTE_DIR" "$ART_DIR"
      sudo chown -R "$uid:$gid" "$REMOTE_DIR" "$ART_DIR"
    
      sudo mkdir -p "$RELEASES_BASE" "$APP_RELEASES_DIR"
      sudo chown "$ARTIFACT_USER:$ARTIFACT_GROUP" "$RELEASES_BASE" "$APP_RELEASES_DIR"
      sudo chmod 2775 "$RELEASES_BASE" "$APP_RELEASES_DIR"
    
      sudo touch "$LOG"
      sudo chmod 777 "$LOG"
    }
    
    # chown_path 변경
    chown_path "$tmp_dir" => change_chown_path "$tmp_dir" "$ARTIFACT_USER" "$ARTIFACT_GROUP"
    
    # ensure_owned_dir 함수 삭제 및 ensure_owned_dir 사용 부분 아래로 변경
    sudo mkdir -p  "$tmp_dir"
    change_chown_path "$tmp_dir" "$ARTIFACT_USER" "$ARTIFACT_GROUP"
    ```