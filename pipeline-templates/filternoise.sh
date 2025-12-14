      # ───────────────────────────────────────────────
      # filter_class_noise()
      # CHANGED_LIST 중 .class 파일에 대해 javap 결과가 동일하면
      # rsync 대상에서 제외하는 노이즈 필터
      #  - 대상: WEB-INF/classes/*.class
      #  - 방식: BASE_DIR / NEW_DIR 각각에서 javap 출력 비교
      # ───────────────────────────────────────────────
      filter_class_noise() {
        log "[class-diff] .class 노이즈 필터링 시작"

        # javap 없으면 그냥 통과
        if ! need javap; then
          log "[class-diff] javap 미존재 → 필터링 생략"
          return 0
        fi

        local orig="$CHANGED_LIST"
        local filtered="${CHANGED_LIST%.txt}.filtered.txt"
        local rel class_rel fqcn
        local old_class new_class tmp1 tmp2
        local total=0 kept=0 skipped=0

        : | sudo -u "$ARTIFACT_USER" tee "$filtered" >/dev/null

        while IFS= read -r rel || [ -n "${rel:-}" ]; do
          # 공백/CR 제거
          rel="$(printf '%s' "$rel" | sed -e 's/\r$//' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
          [ -z "$rel" ] && continue

          total=$((total+1))

          case "$rel" in
            WEB-INF/classes/*.class)
              # 경로 → FQCN 변환
              class_rel="${rel#WEB-INF/classes/}"   # com/example/Foo.class
              fqcn="${class_rel%.class}"            # com/example/Foo
              fqcn="${fqcn//\//.}"                  # com.example.Foo

              old_class="${BASE_DIR%/}/WEB-INF/classes/$class_rel"
              new_class="${NEW_DIR%/}/WEB-INF/classes/$class_rel"

              # 한쪽이라도 없으면 의미 있는 변경으로 간주
              if ! sudo test -f "$old_class" || ! sudo test -f "$new_class"; then
                echo "$rel" | sudo -u "$ARTIFACT_USER" tee -a "$filtered" >/dev/null
                kept=$((kept+1))
                continue
              fi

              tmp1="$(mktemp)"; tmp2="$(mktemp)"

              # BASE 쪽 javap
              if ! sudo sh -c "cd '$BASE_DIR/WEB-INF/classes' && javap '$fqcn'" >"$tmp1" 2>/dev/null; then
                rm -f "$tmp1" "$tmp2"
                # 안전하게: 비교 실패 시 무조건 포함
                echo "$rel" | sudo -u "$ARTIFACT_USER" tee -a "$filtered" >/dev/null
                kept=$((kept+1))
                continue
              fi

              # NEW 쪽 javap
              if ! sudo sh -c "cd '$NEW_DIR/WEB-INF/classes' && javap '$fqcn'" >"$tmp2" 2>/dev/null; then
                rm -f "$tmp1" "$tmp2"
                echo "$rel" | sudo -u "$ARTIFACT_USER" tee -a "$filtered" >/dev/null
                kept=$((kept+1))
                continue
              fi

              # javap(no option) 결과 비교
              if diff -q "$tmp1" "$tmp2" >/dev/null 2>&1; then
                # 의미 없는 diff → rsync 대상에서 제외
                skipped=$((skipped+1))
              else
                echo "$rel" | sudo -u "$ARTIFACT_USER" tee -a "$filtered" >/dev/null
                kept=$((kept+1))
              fi

              rm -f "$tmp1" "$tmp2"
              ;;
            *)
              # .class 가 아니면 그대로 유지
              echo "$rel" | sudo -u "$ARTIFACT_USER" tee -a "$filtered" >/dev/null
              kept=$((kept+1))
              ;;
          esac
        done < "$orig"

        sudo mv "$filtered" "$CHANGED_LIST"
        log "[class-diff] 필터링 완료: total=$total, kept=$kept, skipped_class_noise=$skipped"
      }

        compute_diff_lists
        compare_predicted_with_rsync               # [ADD]
        filter_class_noise                         # [ADD class-diff] ← 여기 추가
        apply_deletions "$TARGET" "$DELETE_LIST"
        apply_changes