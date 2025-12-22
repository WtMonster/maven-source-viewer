#!/usr/bin/env bash
# class-resolver.sh - 类解析核心逻辑

[[ -n "${_CLASS_RESOLVER_SH_LOADED:-}" ]] && return 0
_CLASS_RESOLVER_SH_LOADED=1

# ============================================================================
# 并行处理配置
# ============================================================================

PARALLEL_JOBS="${PARALLEL_JOBS:-8}"

# ============================================================================
# 源码解析
# ============================================================================

resolve_source_entry_in_jar() {
  local sources_jar="$1"
  local class_fqn="$2"
  [[ -n "$sources_jar" && -f "$sources_jar" ]] || return 1
  [[ -n "$class_fqn" ]] || return 1

  # 使用进程替换避免临时文件
  local candidates
  candidates="$(source_entry_candidates "$class_fqn")"

  local idx match
  idx="$(ensure_zip_index "$sources_jar")" || return 1
  match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
  [[ -n "$match" ]] || return 1
  echo "$match"
}

resolve_source_first() {
  local class_fqn="$1"
  local search_path="${2:-$M2_REPO}"

  local candidates
  candidates="$(source_entry_candidates "$class_fqn")"

  # 并行搜索：使用 xargs 并行处理，找到第一个匹配即停止
  local result
  result="$(list_source_jars "$search_path" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    jar="$1"
    candidates="$2"
    INDEX_DIR="$3"
    [[ -f "$jar" ]] || exit 0
    # 内联 ensure_zip_index 逻辑
    mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
    size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
    hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
    idx="${INDEX_DIR}/${hash}.idx"
    if [[ ! -f "$idx" ]]; then
      unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
    fi
    match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf "%s\t%s\n" "$jar" "$match"
      exit 0
    fi
  ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"

  [[ -n "$result" ]] || return 1
  echo "$result"
}

resolve_source_all() {
  local class_fqn="$1"
  local search_path="${2:-$M2_REPO}"

  local candidates
  candidates="$(source_entry_candidates "$class_fqn")"

  # 并行搜索所有匹配
  list_source_jars "$search_path" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    jar="$1"
    candidates="$2"
    INDEX_DIR="$3"
    [[ -f "$jar" ]] || exit 0
    mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
    size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
    hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
    idx="${INDEX_DIR}/${hash}.idx"
    if [[ ! -f "$idx" ]]; then
      unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
    fi
    match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf "%s\t%s\n" "$jar" "$match"
    fi
  ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null
}

resolve_source_first_in_jars_file() {
  local class_fqn="$1"
  local jars_file="$2"
  [[ -f "$jars_file" ]] || return 1

  local candidates
  candidates="$(source_entry_candidates "$class_fqn")"

  # 并行搜索
  local result
  result="$(cat "$jars_file" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    jar="$1"
    candidates="$2"
    INDEX_DIR="$3"
    [[ -n "$jar" && -f "$jar" ]] || exit 0
    mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
    size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
    hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
    idx="${INDEX_DIR}/${hash}.idx"
    if [[ ! -f "$idx" ]]; then
      unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
    fi
    match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf "%s\t%s\n" "$jar" "$match"
      exit 0
    fi
  ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"

  [[ -n "$result" ]] || return 1
  echo "$result"
}

# ============================================================================
# 二进制类解析
# ============================================================================

resolve_class_first() {
  local class_fqn="$1"
  local search_path="${2:-$M2_REPO}"

  local candidates
  candidates="$(class_entry_candidates "$class_fqn")"

  # 并行搜索
  local result
  result="$(list_binary_jars "$search_path" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    jar="$1"
    candidates="$2"
    INDEX_DIR="$3"
    [[ -f "$jar" ]] || exit 0
    mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
    size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
    hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
    idx="${INDEX_DIR}/${hash}.idx"
    if [[ ! -f "$idx" ]]; then
      unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
    fi
    match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf "%s\t%s\n" "$jar" "$match"
      exit 0
    fi
  ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"

  [[ -n "$result" ]] || return 1
  echo "$result"
}

resolve_class_first_in_jars_file() {
  local class_fqn="$1"
  local jars_file="$2"
  [[ -f "$jars_file" ]] || return 1

  local candidates
  candidates="$(class_entry_candidates "$class_fqn")"

  # 并行搜索
  local result
  result="$(cat "$jars_file" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    jar="$1"
    candidates="$2"
    INDEX_DIR="$3"
    [[ -n "$jar" && -f "$jar" ]] || exit 0
    mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
    size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
    hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
    idx="${INDEX_DIR}/${hash}.idx"
    if [[ ! -f "$idx" ]]; then
      unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
    fi
    match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      printf "%s\t%s\n" "$jar" "$match"
      exit 0
    fi
  ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"

  [[ -n "$result" ]] || return 1
  echo "$result"
}

resolve_class_first_in_modules() {
  local class_fqn="$1"
  local root_project_dir="$2"
  local scope="$3"
  local offline="$4"
  local settings="$5"
  local repo_local="$6"

  local module_dir
  while IFS= read -r module_dir; do
    [[ -n "$module_dir" ]] || continue
    local jars_file=""
    jars_file="$(get_project_classpath_file "$module_dir" "$scope" "$offline" "$settings" "$repo_local" 2>/dev/null || true)"
    [[ -n "$jars_file" && -f "$jars_file" ]] || continue

    local resolved
    resolved="$(resolve_class_first_in_jars_file "$class_fqn" "$jars_file" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      echo "${module_dir}"$'\t'"${jars_file}"$'\t'"${resolved}"
      return 0
    fi
  done < <(project_module_dirs "$root_project_dir")

  return 1
}

# ============================================================================
# 统一类解析
# ============================================================================

# 内联版本的 binary_jars_to_sources_list，直接输出到 stdout 避免临时文件
_binary_jars_to_sources_inline() {
  local jars_file="$1"
  [[ -f "$jars_file" ]] || return 1

  local jar
  while IFS= read -r jar; do
    [[ -n "$jar" && -f "$jar" ]] || continue
    local sources
    sources="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
    if [[ -n "$sources" && -f "$sources" ]]; then
      echo "$sources"
    fi
  done <"$jars_file"
}

# 使用进程替换的并行搜索（避免临时文件）
_resolve_source_first_inline() {
  local class_fqn="$1"
  local jars_input="$2"  # 可以是文件路径或 "-" 表示 stdin

  local candidates
  candidates="$(source_entry_candidates "$class_fqn")"

  local result
  if [[ "$jars_input" == "-" ]]; then
    result="$(cat | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
      jar="$1"
      candidates="$2"
      INDEX_DIR="$3"
      [[ -n "$jar" && -f "$jar" ]] || exit 0
      mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
      size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
      hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
      idx="${INDEX_DIR}/${hash}.idx"
      if [[ ! -f "$idx" ]]; then
        unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
      fi
      match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
      if [[ -n "$match" ]]; then
        printf "%s\t%s\n" "$jar" "$match"
        exit 0
      fi
    ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"
  else
    result="$(cat "$jars_input" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
      jar="$1"
      candidates="$2"
      INDEX_DIR="$3"
      [[ -n "$jar" && -f "$jar" ]] || exit 0
      mtime="$(stat -f %m "$jar" 2>/dev/null || stat -c %Y "$jar" 2>/dev/null || echo 0)"
      size="$(stat -f %z "$jar" 2>/dev/null || stat -c %s "$jar" 2>/dev/null || echo 0)"
      hash="$(printf "%s" "${jar}|${mtime}|${size}" | shasum -a 256 2>/dev/null | cut -d" " -f1 || printf "%s" "${jar}|${mtime}|${size}" | sha256sum 2>/dev/null | cut -d" " -f1)"
      idx="${INDEX_DIR}/${hash}.idx"
      if [[ ! -f "$idx" ]]; then
        unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null && mv "${idx}.tmp" "$idx" || exit 0
      fi
      match="$(echo "$candidates" | grep -F -x -m1 -f /dev/stdin "$idx" 2>/dev/null || true)"
      if [[ -n "$match" ]]; then
        printf "%s\t%s\n" "$jar" "$match"
        exit 0
      fi
    ' _ {} "$candidates" "$INDEX_DIR" 2>/dev/null | head -n1)"
  fi

  [[ -n "$result" ]] || return 1
  echo "$result"
}

resolve_class_location() {
  local class_fqn="$1"
  local binary_jars_file="$2"
  local project_dir="$3"
  local scope="$4"
  local mvn_offline="$5"
  local mvn_settings="$6"
  local mvn_repo_local="$7"
  local search_path="$8"
  local download_sources="$9"

  # 1. 如果有项目 classpath，优先在项目依赖中查找
  if [[ -n "$binary_jars_file" && -f "$binary_jars_file" ]]; then
    # 先尝试在 sources JAR 中查找（使用进程替换避免临时文件）
    local resolved
    if resolved="$(_binary_jars_to_sources_inline "$binary_jars_file" | _resolve_source_first_inline "$class_fqn" "-" 2>/dev/null)"; then
      local jar entry
      jar="$(printf "%s" "$resolved" | cut -f1)"
      entry="$(printf "%s" "$resolved" | cut -f2)"
      echo "source"$'\t'"$jar"$'\t'"$entry"$'\t'"$jar"$'\t'"$entry"
      return 0
    fi

    # 在二进制 JAR 中查找
    local bin_resolved
    bin_resolved="$(resolve_class_first_in_jars_file "$class_fqn" "$binary_jars_file" 2>/dev/null || true)"

    # 如果没找到，尝试在子模块中查找
    if [[ -z "$bin_resolved" && -n "$project_dir" ]]; then
      local module_hit
      module_hit="$(resolve_class_first_in_modules "$class_fqn" "$project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local" 2>/dev/null || true)"
      if [[ -n "$module_hit" ]]; then
        bin_resolved="$(printf "%s" "$module_hit" | cut -f3)"$'\t'"$(printf "%s" "$module_hit" | cut -f4)"
      fi
    fi

    if [[ -n "$bin_resolved" ]]; then
      local jar entry
      jar="$(printf "%s" "$bin_resolved" | cut -f1)"
      entry="$(printf "%s" "$bin_resolved" | cut -f2)"

      # 尝试下载源码
      if [[ "$download_sources" == "1" ]]; then
        local downloaded_sources
        downloaded_sources="$(try_download_sources_for_binary_jar "$jar" "$mvn_settings" "$mvn_repo_local" 2>/dev/null || true)"
        if [[ -n "$downloaded_sources" ]]; then
          local source_entry
          source_entry="$(resolve_source_entry_in_jar "$downloaded_sources" "$class_fqn" 2>/dev/null || true)"
          if [[ -n "$source_entry" ]]; then
            echo "source"$'\t'"$jar"$'\t'"$entry"$'\t'"$downloaded_sources"$'\t'"$source_entry"
            return 0
          fi
        fi
      fi

      # 检查是否有对应的 sources JAR
      local source_jar
      source_jar="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
      if [[ -n "$source_jar" ]]; then
        local source_entry
        source_entry="$(resolve_source_entry_in_jar "$source_jar" "$class_fqn" 2>/dev/null || true)"
        if [[ -n "$source_entry" ]]; then
          echo "source"$'\t'"$jar"$'\t'"$entry"$'\t'"$source_jar"$'\t'"$source_entry"
          return 0
        fi
      fi

      echo "binary"$'\t'"$jar"$'\t'"$entry"$'\t'""$'\t'""
      return 0
    fi
  fi

  # 2. 在 search_path 中查找
  local resolved
  if resolved="$(resolve_source_first "$class_fqn" "$search_path" 2>/dev/null)"; then
    local jar entry
    jar="$(printf "%s" "$resolved" | cut -f1)"
    entry="$(printf "%s" "$resolved" | cut -f2)"
    echo "source"$'\t'"$jar"$'\t'"$entry"$'\t'"$jar"$'\t'"$entry"
    return 0
  fi

  # 3. 在二进制 JAR 中查找
  local bin_resolved
  bin_resolved="$(resolve_class_first "$class_fqn" "$search_path" 2>/dev/null || true)"
  if [[ -n "$bin_resolved" ]]; then
    local jar entry
    jar="$(printf "%s" "$bin_resolved" | cut -f1)"
    entry="$(printf "%s" "$bin_resolved" | cut -f2)"

    # 尝试下载源码
    if [[ "$download_sources" == "1" ]]; then
      local downloaded_sources
      downloaded_sources="$(try_download_sources_for_binary_jar "$jar" "$mvn_settings" "$mvn_repo_local" 2>/dev/null || true)"
      if [[ -n "$downloaded_sources" ]]; then
        local source_entry
        source_entry="$(resolve_source_entry_in_jar "$downloaded_sources" "$class_fqn" 2>/dev/null || true)"
        if [[ -n "$source_entry" ]]; then
          echo "source"$'\t'"$jar"$'\t'"$entry"$'\t'"$downloaded_sources"$'\t'"$source_entry"
          return 0
        fi
      fi
    fi

    echo "binary"$'\t'"$jar"$'\t'"$entry"$'\t'""$'\t'""
    return 0
  fi

  echo "not_found"$'\t'""$'\t'""$'\t'""$'\t'""
  return 1
}
