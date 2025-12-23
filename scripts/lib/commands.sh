#!/usr/bin/env bash
# commands.sh - 命令实现

[[ -n "${_COMMANDS_SH_LOADED:-}" ]] && return 0
_COMMANDS_SH_LOADED=1

# ============================================================================
# find 命令
# ============================================================================

cmd_find() {
  local include_binary="0"
  local limit_jars="0"
  local class_fqn=""
  local search_path="$M2_REPO"
  local search_path_explicit="0"
  local project_dir=""
  local classpath_file=""
  local scope="compile"
  local mvn_offline="0"
  local mvn_settings=""
  local mvn_repo_local=""
  local allow_fallback="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary) include_binary="1"; shift ;;
      --limit-jars) limit_jars="${2:-0}"; shift 2 ;;
      --search-path) search_path="${2:-$M2_REPO}"; search_path_explicit="1"; shift 2 ;;
      --project) project_dir="${2:-}"; shift 2 ;;
      --classpath-file) classpath_file="${2:-}"; shift 2 ;;
      --scope) scope="${2:-compile}"; shift 2 ;;
      --offline|--mvn-offline) mvn_offline="1"; shift ;;
      --mvn-settings) mvn_settings="${2:-}"; shift 2 ;;
      --mvn-repo-local) mvn_repo_local="${2:-}"; shift 2 ;;
      --allow-fallback) allow_fallback="1"; shift ;;
      -*)
        die_with_hint "未知参数: $1" "使用 'maven-source.sh find --help' 查看帮助"
        ;;
      *)
        if [[ -z "$class_fqn" ]]; then
          class_fqn="$1"; shift
        elif [[ "$search_path_explicit" == "0" && -z "$project_dir" && -z "$classpath_file" ]]; then
          search_path="$1"; search_path_explicit="1"; shift
        else
          die_with_hint "多余参数: $1" "find 命令只接受一个类名参数"
        fi
        ;;
    esac
  done

  [[ -n "$class_fqn" ]] || die_with_hint "缺少类名参数" "用法: find <class-fqn> [--project DIR] [--binary]"

  local resolved_info binary_jars_file tmp_file_flag resolved_project_dir
  resolved_info="$(resolve_binary_jars_file "$classpath_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$allow_fallback")"
  binary_jars_file="$(printf "%s" "$resolved_info" | cut -f1)"
  tmp_file_flag="$(printf "%s" "$resolved_info" | cut -f2)"
  resolved_project_dir="$(printf "%s" "$resolved_info" | cut -f3)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"

  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    maybe_load_idea_maven_settings "$project_dir"
    if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" && -d "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
      search_path="$IDEA_MVN_LOCAL_REPO"
    fi
  fi

  if [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]]; then
    echo "正在搜索类: $class_fqn"
    [[ -n "$project_dir" ]] && echo "项目目录: $project_dir" && echo "scope: $scope"
    [[ -n "$classpath_file" && -z "$project_dir" ]] && echo "classpath-file: $classpath_file"
    echo "---"

    local jar class_entry bin_resolved=""
    bin_resolved="$(resolve_class_first_in_jars_file "$class_fqn" "$binary_jars_file" 2>/dev/null || true)"
    if [[ -n "$bin_resolved" ]]; then
      jar="$(printf "%s" "$bin_resolved" | cut -f1)"
      class_entry="$(printf "%s" "$bin_resolved" | cut -f2)"
    else
      local module_hit=""
      module_hit="$(resolve_class_first_in_modules "$class_fqn" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" 2>/dev/null || true)"
      if [[ -n "$module_hit" ]]; then
        echo "命中模块: $(printf "%s" "$module_hit" | cut -f1)"
        jar="$(printf "%s" "$module_hit" | cut -f3)"
        class_entry="$(printf "%s" "$module_hit" | cut -f4)"
      fi
    fi

    if [[ -n "$jar" && -n "$class_entry" ]]; then
      echo "找到 JAR: $jar"
      echo "  类文件: $class_entry"
      local gav; gav="$(jar_gav "$jar" 2>/dev/null || true)"
      [[ -n "$gav" ]] && echo "  Maven: $gav"
      local source_jar; source_jar="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
      if [[ -n "$source_jar" ]]; then
        echo "  源码 JAR: $source_jar"
      else
        echo "  (无源码 JAR，可用 open 直接反编译查看)"
      fi
    else
      echo "未在项目依赖中找到该类。"
      echo "提示: 可尝试 'search ${class_fqn##*.}' 模糊搜索"
    fi

    cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
    return 0
  fi

  [[ -n "$project_dir" || -n "$classpath_file" ]] && warn "将降级为按 search-path 扫描"

  echo "正在搜索类: $class_fqn"
  echo "搜索路径: $search_path"
  echo "---"

  local found_any="0" jar entry
  while IFS=$'\t' read -r jar entry; do
    [[ -n "$jar" ]] || continue
    echo "找到源码 JAR: $jar"
    echo "  源码文件: $entry"
    found_any="1"
  done < <(resolve_source_all "$class_fqn" "$search_path")

  if [[ "$include_binary" != "1" ]]; then
    [[ "$found_any" != "1" ]] && echo "未在 *-sources.jar 中找到该类。" && echo "提示: 使用 --binary 参数在二进制 JAR 中查找"
    return 0
  fi

  local class_candidates_file; class_candidates_file="$(mktemp "${TMP_DIR%/}/class-candidates.XXXXXX")"
  class_entry_candidates "$class_fqn" >"$class_candidates_file"

  local scanned=0
  while IFS= read -r jar; do
    ((scanned++))
    [[ "$limit_jars" =~ ^[0-9]+$ ]] && ((limit_jars > 0)) && ((scanned > limit_jars)) && break
    local idx match; idx="$(ensure_zip_index "$jar")" || continue
    match="$(grep -F -x -m1 -f "$class_candidates_file" "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      echo "找到 JAR: $jar"
      echo "  类文件: $match"
      local gav; gav="$(jar_gav "$jar" 2>/dev/null || true)"
      [[ -n "$gav" ]] && echo "  Maven: $gav"
      local source_jar; source_jar="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
      [[ -n "$source_jar" ]] && echo "  源码 JAR 可用: $source_jar" || echo "  (无源码 JAR)"
      found_any="1"
    fi
  done < <(list_binary_jars "$search_path")

  rm -f "$class_candidates_file" >/dev/null 2>&1 || true
}

# ============================================================================
# open 命令
# ============================================================================

cmd_open() {
  local class_fqn="${1:-}"
  shift 1 || true
  [[ -n "$class_fqn" ]] || die_with_hint "缺少类名参数" "用法: open <class-fqn> [--project DIR] [--all]"

  eval "$(parse_project_args "$@")"
  local project_dir="$PARSED_PROJECT_DIR"
  local classpath_file="$PARSED_CLASSPATH_FILE"
  local scope="$PARSED_SCOPE"
  local mvn_offline="$PARSED_MVN_OFFLINE"
  local mvn_settings="$PARSED_MVN_SETTINGS"
  local mvn_repo_local="$PARSED_MVN_REPO_LOCAL"
  local search_path="$PARSED_SEARCH_PATH"
  local search_path_explicit="$PARSED_SEARCH_PATH_EXPLICIT"
  local decompiler="$PARSED_DECOMPILER"
  local allow_decompile="$PARSED_ALLOW_DECOMPILE"
  local download_sources="$PARSED_DOWNLOAD_SOURCES"
  local allow_fallback="$PARSED_ALLOW_FALLBACK"
  local all="$PARSED_ALL"
  local max_lines="$PARSED_MAX_LINES"

  local resolved_info binary_jars_file tmp_file_flag resolved_project_dir
  resolved_info="$(resolve_binary_jars_file "$classpath_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$allow_fallback")"
  binary_jars_file="$(printf "%s" "$resolved_info" | cut -f1)"
  tmp_file_flag="$(printf "%s" "$resolved_info" | cut -f2)"
  resolved_project_dir="$(printf "%s" "$resolved_info" | cut -f3)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"

  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  # 如果用户没显式指定 search_path，则优先复用 IDEA 的本地仓库路径（避免 ~/.m2/repository 与实际不一致）
  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    maybe_load_idea_maven_settings "$project_dir"
    if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" && -d "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
      search_path="$IDEA_MVN_LOCAL_REPO"
    fi
  fi

  local class_info result_type jar entry source_jar source_entry
  class_info="$(resolve_class_location "$class_fqn" "$binary_jars_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$search_path" "$download_sources" 2>/dev/null || echo "not_found")"
  result_type="$(printf "%s" "$class_info" | cut -f1)"
  jar="$(printf "%s" "$class_info" | cut -f2)"
  entry="$(printf "%s" "$class_info" | cut -f3)"
  source_jar="$(printf "%s" "$class_info" | cut -f4)"
  source_entry="$(printf "%s" "$class_info" | cut -f5)"

  case "$result_type" in
    source)
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      read_entry_from_jar "$source_jar" "$source_entry" "$max_lines" "$all"
      return 0
      ;;
    binary)
      if [[ "$allow_decompile" == "1" ]]; then
        local tmp_out; tmp_out="$(mktemp "${TMP_DIR%/}/decompile-out.XXXXXX")"
        local extra_cp=""; [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]] && extra_cp="$(join_jars_classpath "$binary_jars_file")"
        if ! decompile_class_to_file "$jar" "$entry" "$tmp_out" "$decompiler" "$extra_cp" >/dev/null; then
          rm -f "$tmp_out" >/dev/null 2>&1 || true
          cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
          die_with_hint "反编译失败: $class_fqn" "可尝试安装 CFR: maven-source.sh install-cfr"
        fi
        print_file_with_limit "$tmp_out" "$max_lines" "$all"
        rm -f "$tmp_out" >/dev/null 2>&1 || true
        cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
        return 0
      fi
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      die_with_hint "未找到类源码: $class_fqn" "可尝试: 1) --download-sources; 2) 移除 --no-decompile"
      ;;
    *)
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      class_not_found_error "$class_fqn" "$search_path" "$project_dir"
      ;;
  esac
}

# ============================================================================
# fetch 命令
# ============================================================================

cmd_fetch() {
  local class_fqn="${1:-}"
  local output_dir="${2:-}"
  shift 2 || true

  [[ -n "$class_fqn" && -n "$output_dir" ]] || die_with_hint "缺少参数" "用法: fetch <class-fqn> <output-dir> [--project DIR]"
  mkdir -p "$output_dir" || die_with_hint "无法创建输出目录: $output_dir" "请检查目录权限"

  eval "$(parse_project_args "$@")"
  local project_dir="$PARSED_PROJECT_DIR"
  local classpath_file="$PARSED_CLASSPATH_FILE"
  local scope="$PARSED_SCOPE"
  local mvn_offline="$PARSED_MVN_OFFLINE"
  local mvn_settings="$PARSED_MVN_SETTINGS"
  local mvn_repo_local="$PARSED_MVN_REPO_LOCAL"
  local search_path="$PARSED_SEARCH_PATH"
  local search_path_explicit="$PARSED_SEARCH_PATH_EXPLICIT"
  local decompiler="$PARSED_DECOMPILER"
  local allow_decompile="$PARSED_ALLOW_DECOMPILE"
  local download_sources="$PARSED_DOWNLOAD_SOURCES"
  local allow_fallback="$PARSED_ALLOW_FALLBACK"

  local resolved_info binary_jars_file tmp_file_flag resolved_project_dir
  resolved_info="$(resolve_binary_jars_file "$classpath_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$allow_fallback")"
  binary_jars_file="$(printf "%s" "$resolved_info" | cut -f1)"
  tmp_file_flag="$(printf "%s" "$resolved_info" | cut -f2)"
  resolved_project_dir="$(printf "%s" "$resolved_info" | cut -f3)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"

  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    maybe_load_idea_maven_settings "$project_dir"
    if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" && -d "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
      search_path="$IDEA_MVN_LOCAL_REPO"
    fi
  fi

  local class_info result_type jar entry source_jar source_entry
  class_info="$(resolve_class_location "$class_fqn" "$binary_jars_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$search_path" "$download_sources" 2>/dev/null || echo "not_found")"
  result_type="$(printf "%s" "$class_info" | cut -f1)"
  jar="$(printf "%s" "$class_info" | cut -f2)"
  entry="$(printf "%s" "$class_info" | cut -f3)"
  source_jar="$(printf "%s" "$class_info" | cut -f4)"
  source_entry="$(printf "%s" "$class_info" | cut -f5)"

  case "$result_type" in
    source)
      local out_file="${output_dir%/}/${source_entry}"
      mkdir -p "$(dirname "$out_file")"
      unzip -p "$source_jar" "$source_entry" >"$out_file" 2>/dev/null || {
        cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
        die_with_hint "写入失败: $out_file" "请检查目录权限"
      }
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      echo "$out_file"
      return 0
      ;;
    binary)
      if [[ "$allow_decompile" == "1" ]]; then
        local tmp_out; tmp_out="$(mktemp "${TMP_DIR%/}/decompile-out.XXXXXX")"
        local extra_cp=""; [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]] && extra_cp="$(join_jars_classpath "$binary_jars_file")"
        local used; used="$(decompile_class_to_file "$jar" "$entry" "$tmp_out" "$decompiler" "$extra_cp" || true)"
        if [[ -z "$used" ]]; then
          rm -f "$tmp_out" >/dev/null 2>&1 || true
          cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
          die_with_hint "反编译失败: $class_fqn" "可尝试安装 CFR: maven-source.sh install-cfr"
        fi
        local base="${entry%.class}"
        local rel="${base}.java"; [[ "$used" == "javap" ]] && rel="${base}.javap.txt"
        local out_file="${output_dir%/}/${rel}"
        mkdir -p "$(dirname "$out_file")"
        mv "$tmp_out" "$out_file"
        cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
        echo "$out_file"
        return 0
      fi
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      die_with_hint "未找到类源码: $class_fqn" "可尝试: 1) --download-sources; 2) 移除 --no-decompile"
      ;;
    *)
      cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
      class_not_found_error "$class_fqn" "$search_path" "$project_dir"
      ;;
  esac
}

# ============================================================================
# search 命令
# ============================================================================

cmd_search() {
  local pattern="${1:-}"
  shift 1 || true
  [[ -n "$pattern" ]] || die_with_hint "缺少搜索模式" "用法: search <pattern> [--project DIR] [--limit-matches N]"

  eval "$(parse_project_args "$@")"
  local project_dir="$PARSED_PROJECT_DIR"
  local classpath_file="$PARSED_CLASSPATH_FILE"
  local scope="$PARSED_SCOPE"
  local mvn_offline="$PARSED_MVN_OFFLINE"
  local mvn_settings="$PARSED_MVN_SETTINGS"
  local mvn_repo_local="$PARSED_MVN_REPO_LOCAL"
  local search_path="$PARSED_SEARCH_PATH"
  local search_path_explicit="$PARSED_SEARCH_PATH_EXPLICIT"
  local allow_fallback="$PARSED_ALLOW_FALLBACK"
  local limit_matches="5"

  for arg in "${PARSED_REMAINING_ARGS[@]:-}"; do
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
      limit_matches="$arg"
    fi
  done

  echo "正在搜索匹配 '$pattern' 的文件..."
  echo "---"

  local resolved_info binary_jars_file tmp_file_flag
  resolved_info="$(resolve_binary_jars_file "$classpath_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$allow_fallback")"
  binary_jars_file="$(printf "%s" "$resolved_info" | cut -f1)"
  tmp_file_flag="$(printf "%s" "$resolved_info" | cut -f2)"
  local resolved_project_dir
  resolved_project_dir="$(printf "%s" "$resolved_info" | cut -f3)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"

  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    maybe_load_idea_maven_settings "$project_dir"
    if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" && -d "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
      search_path="$IDEA_MVN_LOCAL_REPO"
    fi
  fi

  local count=0 jar
  if [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]]; then
    local sources_jars_file; sources_jars_file="$(mktemp "${TMP_DIR%/}/project-sources.XXXXXX")"
    binary_jars_to_sources_list "$binary_jars_file" "$sources_jars_file"

    while IFS= read -r jar; do
      [[ -n "$jar" && -f "$jar" ]] || continue
      local idx; idx="$(ensure_zip_index "$jar")" || continue
      local matches; matches="$(grep -i "$pattern" "$idx" 2>/dev/null | head -n "$limit_matches" || true)"
      if [[ -n "$matches" ]]; then
        echo "JAR: $jar"
        echo "$matches" | while read -r m; do echo "  $m"; done
        ((count++))
      fi
    done <"$sources_jars_file"

    rm -f "$sources_jars_file" >/dev/null 2>&1 || true
    cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
  else
    while IFS= read -r jar; do
      local idx; idx="$(ensure_zip_index "$jar")" || continue
      local matches; matches="$(grep -i "$pattern" "$idx" 2>/dev/null | head -n "$limit_matches" || true)"
      if [[ -n "$matches" ]]; then
        echo "JAR: $jar"
        echo "$matches" | while read -r m; do echo "  $m"; done
        ((count++))
        ((count >= 10)) && break
      fi
    done < <(list_source_jars "$search_path")
  fi

  echo "---"
  echo "找到 $count 个匹配的 JAR"
}

# ============================================================================
# read 命令
# ============================================================================

cmd_read() {
  local jar_path="${1:-}"
  local class_fqn="${2:-}"
  shift 2 || true

  [[ -n "$jar_path" && -n "$class_fqn" ]] || die_with_hint "缺少参数" "用法: read <sources-jar> <class-fqn> [--all|--max-lines N]"
  [[ -f "$jar_path" ]] || die_with_hint "JAR 文件不存在: $jar_path" "请检查文件路径"

  local all="0" max_lines=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all="1"; shift ;;
      --max-lines) max_lines="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local candidates_file; candidates_file="$(mktemp "${TMP_DIR%/}/source-candidates.XXXXXX")"
  source_entry_candidates "$class_fqn" >"$candidates_file"

  local idx match
  idx="$(ensure_zip_index "$jar_path")" || die "无法读取 JAR 索引: $jar_path"
  match="$(grep -F -x -m1 -f "$candidates_file" "$idx" 2>/dev/null || true)"
  rm -f "$candidates_file" >/dev/null 2>&1 || true

  [[ -n "$match" ]] || die_with_hint "无法在 JAR 中找到类源码: $class_fqn" "请检查类名是否正确"
  read_entry_from_jar "$jar_path" "$match" "$max_lines" "$all"
}

# ============================================================================
# decompile 命令
# ============================================================================

cmd_decompile() {
  local class_fqn="${1:-}"
  shift 1 || true
  [[ -n "$class_fqn" ]] || die_with_hint "缺少类名参数" "用法: decompile <class-fqn> [--project DIR]"

  eval "$(parse_project_args "$@")"
  local project_dir="$PARSED_PROJECT_DIR"
  local classpath_file="$PARSED_CLASSPATH_FILE"
  local scope="$PARSED_SCOPE"
  local mvn_offline="$PARSED_MVN_OFFLINE"
  local mvn_settings="$PARSED_MVN_SETTINGS"
  local mvn_repo_local="$PARSED_MVN_REPO_LOCAL"
  local search_path="$PARSED_SEARCH_PATH"
  local search_path_explicit="$PARSED_SEARCH_PATH_EXPLICIT"
  local decompiler="$PARSED_DECOMPILER"
  local allow_fallback="$PARSED_ALLOW_FALLBACK"
  local all="$PARSED_ALL"
  local max_lines="$PARSED_MAX_LINES"

  local resolved_info binary_jars_file tmp_file_flag resolved_project_dir
  resolved_info="$(resolve_binary_jars_file "$classpath_file" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" "$allow_fallback")"
  binary_jars_file="$(printf "%s" "$resolved_info" | cut -f1)"
  tmp_file_flag="$(printf "%s" "$resolved_info" | cut -f2)"
  resolved_project_dir="$(printf "%s" "$resolved_info" | cut -f3)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"

  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    maybe_load_idea_maven_settings "$project_dir"
    if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" && -d "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
      search_path="$IDEA_MVN_LOCAL_REPO"
    fi
  fi

  local jar entry bin_resolved=""
  if [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]]; then
    bin_resolved="$(resolve_class_first_in_jars_file "$class_fqn" "$binary_jars_file" 2>/dev/null || true)"
  fi
  if [[ -z "$bin_resolved" ]]; then
    bin_resolved="$(resolve_class_first "$class_fqn" "$search_path" 2>/dev/null || true)"
  fi

  if [[ -z "$bin_resolved" ]]; then
    cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
    class_not_found_error "$class_fqn" "$search_path" "$project_dir"
  fi

  jar="$(printf "%s" "$bin_resolved" | cut -f1)"
  entry="$(printf "%s" "$bin_resolved" | cut -f2)"

  local tmp_out; tmp_out="$(mktemp "${TMP_DIR%/}/decompile-out.XXXXXX")"
  local extra_cp=""; [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]] && extra_cp="$(join_jars_classpath "$binary_jars_file")"

  if ! decompile_class_to_file "$jar" "$entry" "$tmp_out" "$decompiler" "$extra_cp" >/dev/null; then
    rm -f "$tmp_out" >/dev/null 2>&1 || true
    cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
    die_with_hint "反编译失败: $class_fqn" "可尝试安装 CFR: maven-source.sh install-cfr"
  fi

  print_file_with_limit "$tmp_out" "$max_lines" "$all"
  rm -f "$tmp_out" >/dev/null 2>&1 || true
  cleanup_tmp_file "$binary_jars_file" "$tmp_file_flag"
}

# ============================================================================
# classpath 命令
# ============================================================================

cmd_classpath() {
  local project_dir="${1:-}"
  shift 1 || true
  [[ -n "$project_dir" ]] || die_with_hint "缺少项目目录" "用法: classpath <project-dir> [--output FILE]"

  local resolved_project_dir=""
  resolved_project_dir="$(resolve_project_dir "$project_dir" 2>/dev/null || true)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"
  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  local output="" scope="compile" offline="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output="${2:-}"; shift 2 ;;
      --scope) scope="${2:-compile}"; shift 2 ;;
      --offline) offline="1"; shift ;;
      *) shift ;;
    esac
  done

  local jars_file
  jars_file="$(get_project_classpath_file "$project_dir" "$scope" "$offline" "" "")" || die "无法生成 classpath"

  if [[ -n "$output" ]]; then
    cp "$jars_file" "$output"
    echo "Classpath 已写入: $output"
  else
    cat "$jars_file"
  fi
}

# ============================================================================
# extract 命令
# ============================================================================

cmd_extract() {
  local sources_jar="${1:-}"
  local output_dir="${2:-}"

  [[ -n "$sources_jar" && -n "$output_dir" ]] || die_with_hint "缺少参数" "用法: extract <sources-jar> <output-dir>"
  [[ -f "$sources_jar" ]] || die_with_hint "JAR 文件不存在: $sources_jar" "请检查文件路径"

  mkdir -p "$output_dir" || die "无法创建输出目录: $output_dir"
  unzip -o "$sources_jar" -d "$output_dir" >/dev/null 2>&1 || die "解压失败: $sources_jar"
  echo "已解压到: $output_dir"
}

# ============================================================================
# coordinates 命令
# ============================================================================

cmd_coordinates() {
  local jar_path="${1:-}"
  [[ -n "$jar_path" && -f "$jar_path" ]] || die_with_hint "缺少 JAR 路径或文件不存在" "用法: coordinates <jar-path>"

  local gav
  gav="$(jar_gav "$jar_path" 2>/dev/null || true)"
  if [[ -n "$gav" ]]; then
    echo "$gav"
  else
    die_with_hint "无法获取 Maven 坐标" "JAR 可能不是 Maven 构建的"
  fi
}

# ============================================================================
# list 命令
# ============================================================================

cmd_list() {
  local project_dir="${1:-}"
  [[ -n "$project_dir" ]] || die_with_hint "缺少项目目录" "用法: list <project-dir>"

  local resolved_project_dir=""
  resolved_project_dir="$(resolve_project_dir "$project_dir" 2>/dev/null || true)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"
  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  run_mvn_local "$project_dir" dependency:list -DoutputAbsoluteArtifactFilename=true
}

# ============================================================================
# download 命令
# ============================================================================

cmd_download() {
  local project_dir="${1:-}"
  [[ -n "$project_dir" ]] || die_with_hint "缺少项目目录" "用法: download <project-dir>"

  local resolved_project_dir=""
  resolved_project_dir="$(resolve_project_dir "$project_dir" 2>/dev/null || true)"
  [[ -n "$resolved_project_dir" ]] && project_dir="$resolved_project_dir"
  [[ -n "$project_dir" ]] && msv_load_project_config "$project_dir" >/dev/null 2>&1 || true

  echo "正在下载项目依赖的源码..."
  run_mvn_local "$project_dir" dependency:sources -Dsilent=true || warn "部分源码下载失败"
  echo "完成"
}
