#!/usr/bin/env bash
# jar.sh - JAR 索引和解析

[[ -n "${_JAR_SH_LOADED:-}" ]] && return 0
_JAR_SH_LOADED=1

# ============================================================================
# JAR 列表缓存配置
# ============================================================================

# 缓存有效期（秒），默认 24 小时
JAR_LIST_CACHE_TTL="${JAR_LIST_CACHE_TTL:-86400}"
# 增量更新检查间隔（秒），默认 5 分钟
JAR_LIST_INCREMENTAL_INTERVAL="${JAR_LIST_INCREMENTAL_INTERVAL:-300}"

# ============================================================================
# JAR 文件查找
# ============================================================================

binary_to_sources_jar() {
  local jar="$1"
  local base="${jar%.jar}"
  echo "${base}-sources.jar"
}

find_sources_jar_for_binary() {
  local jar="$1"
  [[ -n "$jar" && -f "$jar" ]] || return 1

  local base="${jar%.jar}"
  local sources="${base}-sources.jar"
  if [[ -f "$sources" ]]; then
    echo "$sources"
    return 0
  fi

  local dir name
  dir="$(dirname "$jar")"
  name="$(basename "$jar" .jar)"

  local candidate
  for candidate in \
    "${dir}/${name}-sources.jar" \
    "${dir}/../sources/${name}-sources.jar" \
    "${dir}/../${name}-sources.jar"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if [[ "$jar" == */.m2/repository/* ]]; then
    local rel="${jar#*/.m2/repository/}"
    local artifact_dir
    artifact_dir="$(dirname "$rel")"
    local artifact_name
    artifact_name="$(basename "$jar" .jar)"
    local m2_sources="${M2_REPO}/${artifact_dir}/${artifact_name}-sources.jar"
    if [[ -f "$m2_sources" ]]; then
      echo "$m2_sources"
      return 0
    fi
  fi

  return 1
}

binary_jars_to_sources_list() {
  local jars_file="$1"
  local out_file="$2"
  [[ -f "$jars_file" ]] || return 1

  local jar
  while IFS= read -r jar; do
    [[ -n "$jar" && -f "$jar" ]] || continue
    local sources
    sources="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
    if [[ -n "$sources" && -f "$sources" ]]; then
      echo "$sources"
    fi
  done <"$jars_file" >"$out_file"
}

join_jars_classpath() {
  local jars_file="$1"
  [[ -f "$jars_file" ]] || return 1

  local result=""
  local jar
  while IFS= read -r jar; do
    [[ -n "$jar" && -f "$jar" ]] || continue
    if [[ -z "$result" ]]; then
      result="$jar"
    else
      result="${result}:${jar}"
    fi
  done <"$jars_file"
  echo "$result"
}

# ============================================================================
# 增量更新 JAR 列表
# ============================================================================

# 获取目录的最新修改时间（递归检查子目录）
_get_dir_newest_mtime() {
  local dir="$1"
  local max_depth="${2:-3}"

  # 只检查目录的 mtime，不检查文件（更快）
  find "$dir" -maxdepth "$max_depth" -type d -newer "$dir" 2>/dev/null | head -n1
}

# 检查是否需要完整扫描
_needs_full_scan() {
  local list_file="$1"
  local search_path="$2"

  # 缓存文件不存在，需要完整扫描
  [[ -f "$list_file" ]] || return 0

  local list_mtime
  list_mtime="$(file_mtime "$list_file" 2>/dev/null || echo 0)"

  local now
  now="$(date +%s 2>/dev/null || echo 0)"
  local age=$((now - list_mtime))

  # 超过 TTL，需要完整扫描
  ((age >= JAR_LIST_CACHE_TTL)) && return 0

  # 在增量检查间隔内，不需要扫描
  ((age < JAR_LIST_INCREMENTAL_INTERVAL)) && return 1

  # 检查是否有新目录被创建（快速检查）
  if [[ -n "$(_get_dir_newest_mtime "$search_path" 3)" ]]; then
    return 0
  fi

  return 1
}

# 增量更新：只扫描新增的 JAR
_incremental_update_jar_list() {
  local list_file="$1"
  local search_path="$2"
  local pattern="$3"

  [[ -f "$list_file" ]] || return 1

  local list_mtime
  list_mtime="$(file_mtime "$list_file" 2>/dev/null || echo 0)"

  # 查找比缓存文件更新的 JAR
  local new_jars
  new_jars="$(find "$search_path" -type f -name "$pattern" -newer "$list_file" 2>/dev/null || true)"

  if [[ -n "$new_jars" ]]; then
    # 追加新 JAR 到缓存
    echo "$new_jars" >> "$list_file"
    # 重新排序去重
    LC_ALL=C sort -u "$list_file" -o "$list_file"
    # 更新缓存文件时间戳
    touch "$list_file"
  else
    # 没有新文件，只更新时间戳避免频繁检查
    touch "$list_file"
  fi
}

list_source_jars() {
  local search_path="${1:-$M2_REPO}"
  [[ -d "$search_path" ]] || return 1

  local list_file="${LIST_DIR%/}/sources-$(hash_string "$search_path").list"

  if _needs_full_scan "$list_file" "$search_path"; then
    # 完整扫描
    find "$search_path" -type f -name "*-sources.jar" 2>/dev/null | LC_ALL=C sort >"${list_file}.tmp" || true
    mv "${list_file}.tmp" "$list_file" 2>/dev/null || true
  else
    # 尝试增量更新
    _incremental_update_jar_list "$list_file" "$search_path" "*-sources.jar" 2>/dev/null || true
  fi

  cat "$list_file"
}

list_binary_jars() {
  local search_path="${1:-$M2_REPO}"
  [[ -d "$search_path" ]] || return 1

  local list_file="${LIST_DIR%/}/binary-$(hash_string "$search_path").list"

  if _needs_full_scan "$list_file" "$search_path"; then
    # 完整扫描
    find "$search_path" -type f -name "*.jar" ! -name "*-sources.jar" ! -name "*-javadoc.jar" 2>/dev/null | LC_ALL=C sort >"${list_file}.tmp" || true
    mv "${list_file}.tmp" "$list_file" 2>/dev/null || true
  else
    # 尝试增量更新（排除 sources 和 javadoc）
    local new_jars
    new_jars="$(find "$search_path" -type f -name "*.jar" ! -name "*-sources.jar" ! -name "*-javadoc.jar" -newer "$list_file" 2>/dev/null || true)"
    if [[ -n "$new_jars" ]]; then
      echo "$new_jars" >> "$list_file"
      LC_ALL=C sort -u "$list_file" -o "$list_file"
    fi
    touch "$list_file"
  fi

  cat "$list_file"
}

# ============================================================================
# JAR 索引
# ============================================================================

zip_index_path() {
  local jar="$1"
  local mtime size
  mtime="$(file_mtime "$jar" 2>/dev/null || echo 0)"
  size="$(file_size "$jar" 2>/dev/null || echo 0)"
  echo "${INDEX_DIR%/}/$(hash_string "${jar}|${mtime}|${size}").idx"
}

ensure_zip_index() {
  local jar="$1"
  [[ -f "$jar" ]] || return 1

  local idx
  idx="$(zip_index_path "$jar")"
  if [[ -f "$idx" ]]; then
    echo "$idx"
    return 0
  fi

  unzip -Z1 "$jar" >"${idx}.tmp" 2>/dev/null || {
    rm -f "${idx}.tmp" >/dev/null 2>&1 || true
    return 1
  }
  mv "${idx}.tmp" "$idx"
  echo "$idx"
}

zip_has_entry() {
  local jar="$1"
  local entry="$2"
  local idx
  idx="$(ensure_zip_index "$jar")" || return 1
  grep -qFx "$entry" "$idx" 2>/dev/null
}

# ============================================================================
# 类名处理
# ============================================================================

normalize_fqn() {
  local fqn="$1"
  echo "${fqn//\//.}"
}

guess_top_level_index() {
  local fqn="$1"
  fqn="$(normalize_fqn "$fqn")"

  if [[ "$fqn" == *'$'* ]]; then
    echo "${fqn%%\$*}"
    return 0
  fi

  if [[ "$fqn" == *.* ]]; then
    local last="${fqn##*.}"
    local prefix="${fqn%.*}"
    if [[ "$last" =~ ^[A-Z] && "$prefix" == *.* ]]; then
      local second_last="${prefix##*.}"
      if [[ "$second_last" =~ ^[A-Z] ]]; then
        echo "$prefix"
        return 0
      fi
    fi
  fi

  echo "$fqn"
}

k_candidates() {
  local fqn="$1"
  fqn="$(normalize_fqn "$fqn")"

  local top
  top="$(guess_top_level_index "$fqn")"

  local path="${top//.//}"

  local ext
  for ext in "${SOURCE_EXTS[@]}"; do
    echo "${path}.${ext}"
  done

  if [[ "$top" != "$fqn" ]]; then
    local inner_path="${fqn//.//}"
    for ext in "${SOURCE_EXTS[@]}"; do
      echo "${inner_path}.${ext}"
    done
  fi

  if [[ "$fqn" == *'$'* ]]; then
    local outer="${fqn%%\$*}"
    local outer_path="${outer//.//}"
    for ext in "${SOURCE_EXTS[@]}"; do
      echo "${outer_path}.${ext}"
    done
  fi
}

source_entry_candidates() {
  local fqn="$1"
  k_candidates "$fqn" | LC_ALL=C sort -u
}

class_entry_candidates() {
  local fqn="$1"
  fqn="$(normalize_fqn "$fqn")"

  local path="${fqn//.//}"
  echo "${path}.class"

  if [[ "$fqn" == *'$'* ]]; then
    local outer="${fqn%%\$*}"
    local outer_path="${outer//.//}"
    echo "${outer_path}.class"
  fi

  local top
  top="$(guess_top_level_index "$fqn")"
  if [[ "$top" != "$fqn" ]]; then
    local top_path="${top//.//}"
    echo "${top_path}.class"
  fi
}

# ============================================================================
# JAR 坐标解析
# ============================================================================

jar_gav() {
  local jar="$1"
  [[ -n "$jar" && -f "$jar" ]] || return 1

  if [[ "$jar" == */.m2/repository/* ]]; then
    local rel="${jar#*/.m2/repository/}"
    local filename
    filename="$(basename "$jar" .jar)"
    filename="${filename%-sources}"
    filename="${filename%-javadoc}"

    local dir_path
    dir_path="$(dirname "$rel")"
    local version
    version="$(basename "$dir_path")"
    dir_path="$(dirname "$dir_path")"
    local artifact_id
    artifact_id="$(basename "$dir_path")"
    dir_path="$(dirname "$dir_path")"
    local group_id="${dir_path//\//.}"

    echo "${group_id}:${artifact_id}:${version}"
    return 0
  fi

  local pom_props
  pom_props="$(unzip -p "$jar" 'META-INF/maven/*/*/pom.properties' 2>/dev/null | head -n 20 || true)"
  if [[ -n "$pom_props" ]]; then
    local g a v
    g="$(echo "$pom_props" | grep '^groupId=' | head -n1 | cut -d= -f2 | tr -d '\r')"
    a="$(echo "$pom_props" | grep '^artifactId=' | head -n1 | cut -d= -f2 | tr -d '\r')"
    v="$(echo "$pom_props" | grep '^version=' | head -n1 | cut -d= -f2 | tr -d '\r')"
    if [[ -n "$g" && -n "$a" && -n "$v" ]]; then
      echo "${g}:${a}:${v}"
      return 0
    fi
  fi

  return 1
}
