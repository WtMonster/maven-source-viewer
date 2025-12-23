#!/usr/bin/env bash
# maven.sh - Maven/IDEA 集成

[[ -n "${_MAVEN_SH_LOADED:-}" ]] && return 0
_MAVEN_SH_LOADED=1

# ============================================================================
# IDEA Maven 配置读取
# ============================================================================

IDEA_MVN_LOADED="0"
IDEA_MVN_HOME=""
IDEA_MVN_SETTINGS_FILE=""
IDEA_MVN_LOCAL_REPO=""
IDEA_MVN_SOURCE=""

expand_idea_path() {
  local value="${1:-}"
  local project_root="${2:-}"

  if [[ -n "${HOME:-}" ]]; then
    value="${value//\$USER_HOME\$/${HOME}}"
  fi
  if [[ -n "$project_root" ]]; then
    value="${value//\$PROJECT_DIR\$/${project_root}}"
    value="${value//\$MODULE_DIR\$/${project_root}}"
  fi

  echo "$value"
}

resolve_idea_project_dir() {
  local input="${1:-}"
  [[ -n "$input" ]] || return 1

  local dir="$input"
  if [[ -f "$dir" ]]; then
    dir="$(dirname "$dir")"
  fi
  [[ -d "$dir" ]] || return 1

  local cur="$dir"
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    if [[ -f "$cur/.idea/workspace.xml" || -f "$cur/.idea/misc.xml" || -d "$cur/.idea/libraries" ]]; then
      echo "$cur"
      return 0
    fi
    cur="$(dirname "$cur")"
  done
  return 1
}

xml_option_value_in_maven_import_preferences() {
  local xml_file="$1"
  local option_name="$2"
  [[ -f "$xml_file" ]] || return 1

  local component_content
  component_content="$(sed -n '/<component name="MavenImportPreferences">/,/<\/component>/p' "$xml_file" 2>/dev/null)"
  [[ -n "$component_content" ]] || return 1

  # 优先尝试从 MavenGeneralSettings 嵌套结构中提取（新版 IDEA 格式）
  local nested_val
  nested_val="$(echo "$component_content" | \
    sed -n '/<MavenGeneralSettings>/,/<\/MavenGeneralSettings>/p' 2>/dev/null | \
    sed -n -E "s/.*<option name=\"${option_name}\" value=\"([^\"]*)\".*/\\1/p" | head -n 1)"
  if [[ -n "$nested_val" ]]; then
    echo "$nested_val"
    return 0
  fi

  # 回退到直接结构（旧版 IDEA 格式）
  echo "$component_content" | \
    sed -n -E "s/.*<option name=\"${option_name}\" value=\"([^\"]*)\".*/\\1/p" | head -n 1
}

jetbrains_default_project_xml() {
  [[ -n "${HOME:-}" ]] || return 1

  local base=""
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin)
      base="${HOME%/}/Library/Application Support/JetBrains"
      ;;
    Linux)
      base="${HOME%/}/.config/JetBrains"
      ;;
    *)
      return 1
      ;;
  esac
  [[ -d "$base" ]] || return 1

  local best=""
  local best_mtime="0"
  local file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    local m="0"
    m="$(file_mtime "$file" 2>/dev/null || echo 0)"
    if [[ -z "$best" || "$m" -gt "$best_mtime" ]]; then
      best="$file"
      best_mtime="$m"
    fi
  done < <(find "$base" -maxdepth 4 -type f -name "project.default.xml" 2>/dev/null || true)

  [[ -n "$best" ]] || return 1
  echo "$best"
}

# 从 IDEA 项目配置中解析 Maven 根 pom.xml（最接近 IDE 实际导入的 Maven 项目）
resolve_idea_maven_root_pom() {
  local hint="${1:-}"
  local idea_project_dir=""
  idea_project_dir="$(resolve_idea_project_dir "$hint" 2>/dev/null || true)"
  [[ -n "$idea_project_dir" ]] || return 1

  local misc="${idea_project_dir%/}/.idea/misc.xml"
  [[ -f "$misc" ]] || return 1

  local component_content
  component_content="$(sed -n '/<component name="MavenProjectsManager">/,/<\/component>/p' "$misc" 2>/dev/null)"
  [[ -n "$component_content" ]] || return 1

  local pom_path
  pom_path="$(printf "%s\n" "$component_content" | sed -n -E 's/.*<option value="([^"]*pom\.xml)".*/\1/p' | head -n 1)"
  [[ -n "$pom_path" ]] || return 1

  pom_path="$(expand_idea_path "$pom_path" "$idea_project_dir")"
  [[ -f "$pom_path" ]] || return 1
  echo "$pom_path"
}

maybe_load_idea_maven_settings() {
  local hint="${1:-.}"

  if [[ "${IDEA_MVN_LOADED:-0}" == "1" ]]; then
    return 0
  fi
  IDEA_MVN_LOADED="1"
  IDEA_MVN_HOME=""
  IDEA_MVN_SETTINGS_FILE=""
  IDEA_MVN_LOCAL_REPO=""
  IDEA_MVN_SOURCE=""

  local idea_project_dir=""
  idea_project_dir="$(resolve_idea_project_dir "$hint" 2>/dev/null || true)"
  if [[ -n "$idea_project_dir" ]]; then
    local xml
    for xml in "$idea_project_dir/.idea/workspace.xml" "$idea_project_dir/.idea/misc.xml"; do
      [[ -f "$xml" ]] || continue

      local home_val settings_val repo_val
      home_val="$(xml_option_value_in_maven_import_preferences "$xml" "customMavenHome" 2>/dev/null || true)"
      if [[ -z "$home_val" ]]; then
        home_val="$(xml_option_value_in_maven_import_preferences "$xml" "mavenHome" 2>/dev/null || true)"
      fi
      settings_val="$(xml_option_value_in_maven_import_preferences "$xml" "userSettingsFile" 2>/dev/null || true)"
      repo_val="$(xml_option_value_in_maven_import_preferences "$xml" "localRepository" 2>/dev/null || true)"

      home_val="$(expand_idea_path "$home_val" "$idea_project_dir")"
      settings_val="$(expand_idea_path "$settings_val" "$idea_project_dir")"
      repo_val="$(expand_idea_path "$repo_val" "$idea_project_dir")"

      [[ -z "$IDEA_MVN_HOME" ]] && IDEA_MVN_HOME="$home_val"
      [[ -z "$IDEA_MVN_SETTINGS_FILE" ]] && IDEA_MVN_SETTINGS_FILE="$settings_val"
      [[ -z "$IDEA_MVN_LOCAL_REPO" ]] && IDEA_MVN_LOCAL_REPO="$repo_val"
      [[ -z "$IDEA_MVN_SOURCE" && ( -n "$home_val" || -n "$settings_val" || -n "$repo_val" ) ]] && IDEA_MVN_SOURCE="idea-project"
    done
  fi

  if [[ -z "$IDEA_MVN_HOME" || -z "$IDEA_MVN_SETTINGS_FILE" || -z "$IDEA_MVN_LOCAL_REPO" ]]; then
    local global_xml=""
    global_xml="$(jetbrains_default_project_xml 2>/dev/null || true)"
    if [[ -n "$global_xml" ]]; then
      local home_val settings_val repo_val
      home_val="$(xml_option_value_in_maven_import_preferences "$global_xml" "customMavenHome" 2>/dev/null || true)"
      if [[ -z "$home_val" ]]; then
        home_val="$(xml_option_value_in_maven_import_preferences "$global_xml" "mavenHome" 2>/dev/null || true)"
      fi
      settings_val="$(xml_option_value_in_maven_import_preferences "$global_xml" "userSettingsFile" 2>/dev/null || true)"
      repo_val="$(xml_option_value_in_maven_import_preferences "$global_xml" "localRepository" 2>/dev/null || true)"

      home_val="$(expand_idea_path "$home_val" "")"
      settings_val="$(expand_idea_path "$settings_val" "")"
      repo_val="$(expand_idea_path "$repo_val" "")"

      [[ -z "$IDEA_MVN_HOME" ]] && IDEA_MVN_HOME="$home_val"
      [[ -z "$IDEA_MVN_SETTINGS_FILE" ]] && IDEA_MVN_SETTINGS_FILE="$settings_val"
      [[ -z "$IDEA_MVN_LOCAL_REPO" ]] && IDEA_MVN_LOCAL_REPO="$repo_val"
      [[ -z "$IDEA_MVN_SOURCE" ]] && IDEA_MVN_SOURCE="idea-global"
    fi
  fi
}

# ============================================================================
# IDEA Libraries 直接读取（避免调用 mvn）
# ============================================================================

# 从 IDEA .idea/libraries/*.xml 文件中提取 JAR 路径
parse_idea_library_xml() {
  local xml_file="$1"
  local project_dir="$2"
  [[ -f "$xml_file" ]] || return 1

  # 提取 CLASSES 中的 jar:// 路径
  sed -n '/<CLASSES>/,/<\/CLASSES>/p' "$xml_file" 2>/dev/null | \
    grep -oE 'jar://[^!]+' | \
    sed 's|^jar://||' | \
    while read -r path; do
      # 展开 IDEA 变量
      path="$(expand_idea_path "$path" "$project_dir")"
      # 处理 $MAVEN_REPOSITORY$ 变量
      if [[ "$path" == *'$MAVEN_REPOSITORY$'* ]]; then
        local repo="${IDEA_MVN_LOCAL_REPO:-$M2_REPO}"
        path="${path//\$MAVEN_REPOSITORY\$/$repo}"
      fi
      [[ -f "$path" ]] && echo "$path"
    done
}

# 从 IDEA libraries 目录获取所有依赖 JAR
get_idea_libraries_jars() {
  local project_dir="$1"
  local idea_libs_dir="${project_dir}/.idea/libraries"

  [[ -d "$idea_libs_dir" ]] || return 1

  maybe_load_idea_maven_settings "$project_dir"

  local xml_file
  find "$idea_libs_dir" -maxdepth 1 -name "*.xml" -type f 2>/dev/null | while read -r xml_file; do
    parse_idea_library_xml "$xml_file" "$project_dir"
  done | sort -u
}

# 检查 IDEA libraries 缓存是否有效
idea_libraries_cache_key() {
  local project_dir="$1"
  local idea_libs_dir="${project_dir}/.idea/libraries"

  [[ -d "$idea_libs_dir" ]] || return 1

  # 基于所有 library xml 文件的 mtime 生成缓存 key
  local signature=""
  local xml_file
  while IFS= read -r xml_file; do
    local mtime
    mtime="$(file_mtime "$xml_file" 2>/dev/null || echo 0)"
    signature="${signature}${xml_file}=${mtime};"
  done < <(find "$idea_libs_dir" -maxdepth 1 -name "*.xml" -type f 2>/dev/null | sort)

  [[ -n "$signature" ]] || return 1
  hash_string "idea-libs-v1|${project_dir}|${signature}"
}

# 尝试从 IDEA libraries 获取 classpath（快速路径）
try_get_idea_libraries_classpath() {
  local project_dir="$1"
  local out_file="$2"

  local idea_libs_dir="${project_dir}/.idea/libraries"
  [[ -d "$idea_libs_dir" ]] || return 1

  # 检查缓存
  local cache_key
  cache_key="$(idea_libraries_cache_key "$project_dir" 2>/dev/null || true)"
  if [[ -n "$cache_key" ]]; then
    local cached_file="${CLASSPATH_DIR%/}/idea-${cache_key}.jars"
    if [[ -f "$cached_file" ]]; then
      cp "$cached_file" "$out_file"
      return 0
    fi
  fi

  # 解析 IDEA libraries
  local jars
  jars="$(get_idea_libraries_jars "$project_dir" 2>/dev/null || true)"
  [[ -n "$jars" ]] || return 1

  echo "$jars" > "$out_file"

  # 写入缓存
  if [[ -n "$cache_key" ]]; then
    cp "$out_file" "${CLASSPATH_DIR%/}/idea-${cache_key}.jars" 2>/dev/null || true
  fi

  return 0
}

# ============================================================================
# IDEA 系统缓存读取（external_build_system）
# ============================================================================

# 查找项目对应的 IDEA 系统缓存目录
find_idea_system_cache_dir() {
  local project_dir="$1"
  [[ -n "$project_dir" ]] || return 1

  local base=""
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin)
      base="${HOME%/}/Library/Caches/JetBrains"
      ;;
    Linux)
      base="${HOME%/}/.cache/JetBrains"
      ;;
    *)
      return 1
      ;;
  esac
  [[ -d "$base" ]] || return 1

  # 获取项目目录名和父目录名（IDEA 可能使用任一个）
  local project_name
  project_name="$(basename "$project_dir")"
  local parent_name
  parent_name="$(basename "$(dirname "$project_dir")")"

  # 查找最新的 IntelliJ IDEA 缓存目录
  local idea_cache=""
  local idea_version=""
  local dir
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    local ver="${dir##*/}"
    if [[ "$ver" == IntelliJIdea* ]]; then
      if [[ -z "$idea_version" || "$ver" > "$idea_version" ]]; then
        idea_version="$ver"
        idea_cache="$dir"
      fi
    fi
  done < <(find "$base" -maxdepth 1 -type d -name "IntelliJIdea*" 2>/dev/null)

  [[ -n "$idea_cache" ]] || return 1

  # 在 projects 目录下查找匹配的项目缓存
  local projects_dir="${idea_cache}/projects"
  [[ -d "$projects_dir" ]] || return 1

  local best_match=""
  local best_mtime="0"
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    local dirname="${dir##*/}"
    # 项目缓存目录格式: project_name.hash 或 project_name
    # 尝试匹配项目目录名或父目录名
    if [[ "$dirname" == "${project_name}."* || "$dirname" == "$project_name" || \
          "$dirname" == "${parent_name}."* || "$dirname" == "$parent_name" ]]; then
      local modules_dir="${dir}/external_build_system/modules"
      if [[ -d "$modules_dir" ]]; then
        local mtime
        mtime="$(file_mtime "$modules_dir" 2>/dev/null || echo 0)"
        if [[ "$mtime" -gt "$best_mtime" ]]; then
          best_mtime="$mtime"
          best_match="$dir"
        fi
      fi
    fi
  done < <(find "$projects_dir" -maxdepth 1 -type d 2>/dev/null)

  [[ -n "$best_match" ]] || return 1
  echo "$best_match"
}

# 从 IDEA 系统缓存的模块 XML 中提取 Maven 依赖
parse_idea_module_cache_xml() {
  local xml_file="$1"
  local repo_local="$2"
  [[ -f "$xml_file" && -n "$repo_local" ]] || return 1

  # 提取 <orderEntry type="library" name="Maven: groupId:artifactId:version" ...>
  grep -oE 'name="Maven: [^"]+' "$xml_file" 2>/dev/null | \
    sed 's/^name="Maven: //' | \
    while read -r gav; do
      # GAV 格式: groupId:artifactId:version 或 groupId:artifactId:packaging:version 或 groupId:artifactId:packaging:classifier:version
      local groupId artifactId version packaging classifier

      # 使用 awk 分割字符串（兼容 bash 和 zsh）
      local num_parts
      num_parts="$(echo "$gav" | awk -F: '{print NF}')"

      if [[ "$num_parts" -eq 3 ]]; then
        # groupId:artifactId:version
        groupId="$(echo "$gav" | cut -d: -f1)"
        artifactId="$(echo "$gav" | cut -d: -f2)"
        version="$(echo "$gav" | cut -d: -f3)"
        packaging="jar"
        classifier=""
      elif [[ "$num_parts" -eq 4 ]]; then
        # groupId:artifactId:packaging:version
        groupId="$(echo "$gav" | cut -d: -f1)"
        artifactId="$(echo "$gav" | cut -d: -f2)"
        packaging="$(echo "$gav" | cut -d: -f3)"
        version="$(echo "$gav" | cut -d: -f4)"
        classifier=""
      elif [[ "$num_parts" -ge 5 ]]; then
        # groupId:artifactId:packaging:classifier:version
        groupId="$(echo "$gav" | cut -d: -f1)"
        artifactId="$(echo "$gav" | cut -d: -f2)"
        packaging="$(echo "$gav" | cut -d: -f3)"
        classifier="$(echo "$gav" | cut -d: -f4)"
        version="$(echo "$gav" | cut -d: -f5)"
      else
        continue
      fi

      # 跳过 pom 类型
      [[ "$packaging" == "pom" ]] && continue

      # 构建 JAR 路径（使用 tr 替换，避免 zsh 转义问题）
      local group_path
      group_path="$(echo "$groupId" | tr '.' '/')"
      local jar_name="${artifactId}-${version}"
      [[ -n "$classifier" ]] && jar_name="${jar_name}-${classifier}"
      jar_name="${jar_name}.${packaging:-jar}"

      local jar_path="${repo_local}/${group_path}/${artifactId}/${version}/${jar_name}"
      [[ -f "$jar_path" ]] && echo "$jar_path"
    done
}

# 从 IDEA 系统缓存获取项目的所有依赖 JAR
get_idea_system_cache_jars() {
  local project_dir="$1"
  local repo_local="$2"

  local cache_dir
  cache_dir="$(find_idea_system_cache_dir "$project_dir" 2>/dev/null || true)"
  [[ -n "$cache_dir" ]] || return 1

  local modules_dir="${cache_dir}/external_build_system/modules"
  [[ -d "$modules_dir" ]] || return 1

  local xml_file
  find "$modules_dir" -maxdepth 1 -name "*.xml" -type f 2>/dev/null | while read -r xml_file; do
    parse_idea_module_cache_xml "$xml_file" "$repo_local"
  done | sort -u
}

# 尝试从 IDEA 系统缓存获取 classpath
try_get_idea_system_cache_classpath() {
  local project_dir="$1"
  local out_file="$2"

  maybe_load_idea_maven_settings "$project_dir"
  local repo_local="${IDEA_MVN_LOCAL_REPO:-$M2_REPO}"
  [[ -d "$repo_local" ]] || return 1

  local jars
  jars="$(get_idea_system_cache_jars "$project_dir" "$repo_local" 2>/dev/null || true)"
  [[ -n "$jars" ]] || return 1

  echo "$jars" > "$out_file"
  return 0
}

# ============================================================================
# Maven 命令执行
# ============================================================================

mvn_cmd() {
  if [[ -n "${MVN_BIN:-}" && -x "${MVN_BIN:-}" ]]; then
    echo "$MVN_BIN"
    return 0
  fi
  if [[ "${IDEA_MVN_SOURCE:-}" == "idea-project" && -n "${IDEA_MVN_HOME:-}" && -x "${IDEA_MVN_HOME%/}/bin/mvn" ]]; then
    echo "${IDEA_MVN_HOME%/}/bin/mvn"
    return 0
  fi
  if [[ -n "${MAVEN_HOME:-}" && -x "${MAVEN_HOME%/}/bin/mvn" ]]; then
    echo "${MAVEN_HOME%/}/bin/mvn"
    return 0
  fi
  if [[ -n "${IDEA_MVN_HOME:-}" && -x "${IDEA_MVN_HOME%/}/bin/mvn" ]]; then
    echo "${IDEA_MVN_HOME%/}/bin/mvn"
    return 0
  fi
  echo "mvn"
}

mvn_repo_local_path() {
  local repo=""
  if [[ -n "${MVN_REPO_LOCAL:-}" ]]; then
    repo="$MVN_REPO_LOCAL"
  elif [[ -n "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
    repo="$IDEA_MVN_LOCAL_REPO"
  elif [[ -d "$M2_REPO" && -w "$M2_REPO" ]]; then
    repo="$M2_REPO"
  else
    repo="$MVN_REPO_LOCAL_DEFAULT"
  fi
  mkdir -p "$repo" >/dev/null 2>&1 || die "无法创建 Maven 本地仓库目录: $repo"
  echo "$repo"
}

run_mvn_local() {
  local project_input="$1"
  shift

  local project_dir=""
  project_dir="$(resolve_project_dir "$project_input" 2>/dev/null || true)"
  [[ -n "$project_dir" && -f "$project_dir/pom.xml" ]] || die "未找到 pom.xml: ${project_input}"

  maybe_load_idea_maven_settings "$project_dir"

  local mvn_bin
  mvn_bin="$(mvn_cmd)"

  local repo_local
  repo_local="$(mvn_repo_local_path)"

  local settings="${MVN_SETTINGS:-}"
  if [[ -z "$settings" && -n "${IDEA_MVN_SETTINGS_FILE:-}" ]]; then
    settings="$IDEA_MVN_SETTINGS_FILE"
  fi
  local args=()
  if [[ -n "$settings" ]]; then
    args+=("--settings" "$settings")
  fi

  (cd "$project_dir" && "$mvn_bin" "${args[@]}" -Dmaven.repo.local="$repo_local" "$@")
}

run_mvn_standalone() {
  local repo_local="$1"
  local settings="${2:-}"
  shift 2 || true

  maybe_load_idea_maven_settings "$PWD"

  local mvn_bin
  mvn_bin="$(mvn_cmd)"

  if [[ -z "$settings" && -n "${MVN_SETTINGS:-}" ]]; then
    settings="$MVN_SETTINGS"
  fi
  if [[ -z "$settings" && -n "${IDEA_MVN_SETTINGS_FILE:-}" ]]; then
    settings="$IDEA_MVN_SETTINGS_FILE"
  fi

  local args=()
  if [[ -n "$settings" ]]; then
    args+=("--settings" "$settings")
  fi
  args+=("-q" "-Dmaven.repo.local=${repo_local}")

  (cd "$TMP_DIR" && "$mvn_bin" "${args[@]}" "$@")
}

# ============================================================================
# 项目解析
# ============================================================================

resolve_project_dir() {
  local input="${1:-}"
  local maxdepth="${2:-6}"
  [[ -n "$input" ]] || return 1

  local dir="$input"
  if [[ -f "$dir" ]]; then
    dir="$(dirname "$dir")"
  fi
  [[ -d "$dir" ]] || return 1

  local idea_root_pom=""
  idea_root_pom="$(resolve_idea_maven_root_pom "$dir" 2>/dev/null || true)"
  if [[ -n "$idea_root_pom" ]]; then
    echo "$(dirname "$idea_root_pom")"
    return 0
  fi

  if [[ -f "$dir/pom.xml" ]]; then
    echo "$dir"
    return 0
  fi

  local cur="$dir"
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    cur="$(dirname "$cur")"
    if [[ -f "$cur/pom.xml" ]]; then
      echo "$cur"
      return 0
    fi
  done

  local poms=""
  poms="$(find "$dir" -maxdepth "$maxdepth" -type f -name "pom.xml" 2>/dev/null | sort || true)"
  [[ -n "$poms" ]] || return 1

  local count="0"
  count="$(printf "%s\n" "$poms" | wc -l | tr -d ' ' || echo 0)"
  if [[ "$count" == "1" ]]; then
    echo "$(dirname "$poms")"
    return 0
  fi

  local best_dir=""
  local best_score="999999"
  local pom
  while IFS= read -r pom; do
    [[ -f "$pom" ]] || continue
    local score="0"
    local rel="${pom#"$dir"/}"
    local depth="0"
    depth="$(printf "%s" "$rel" | tr -cd '/' | wc -c | tr -d ' ' || echo 0)"
    score=$((depth * 10))
    if grep -q "<packaging>[[:space:]]*pom[[:space:]]*</packaging>" "$pom" 2>/dev/null; then
      score=$((score - 20))
    fi
    if grep -q "<modules>" "$pom" 2>/dev/null; then
      score=$((score - 30))
    fi
    if [[ "$score" -lt "$best_score" ]]; then
      best_score="$score"
      best_dir="$(dirname "$pom")"
    fi
  done <<<"$poms"

  [[ -n "$best_dir" ]] || return 1
  echo "$best_dir"
}

project_module_dirs() {
  local project_dir="$1"
  [[ -n "$project_dir" && -f "$project_dir/pom.xml" ]] || return 1

  local pom="$project_dir/pom.xml"
  local module
  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    local abs=""
    abs="$(cd "$project_dir" && cd "$module" 2>/dev/null && pwd -P)" || continue
    [[ -f "$abs/pom.xml" ]] || continue
    echo "$abs"
  done < <(
    awk '
      BEGIN{in_modules=0}
      /<modules>/ {in_modules=1}
      /<\/modules>/ {in_modules=0}
      in_modules {
        while (match($0, /<module>[^<]+<\/module>/)) {
          s = substr($0, RSTART+8, RLENGTH-17);
          print s;
          $0 = substr($0, RSTART+RLENGTH);
        }
      }
    ' "$pom" 2>/dev/null
  )
}

# ============================================================================
# Classpath 管理
# ============================================================================

normalize_classpath_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  local lines="0"
  lines="$(wc -l <"$file" 2>/dev/null | tr -d ' ' || echo 0)"
  if [[ "$lines" == "1" || "$lines" == "0" ]]; then
    tr ':' '\n' <"$file"
  else
    cat "$file"
  fi
}

project_pom_signature() {
  local project_dir="$1"
  local maxdepth="${2:-6}"

  local pom
  while IFS= read -r pom; do
    printf "%s=%s\n" "$pom" "$(file_mtime "$pom" 2>/dev/null || echo 0)"
  done < <(find "$project_dir" -maxdepth "$maxdepth" -type f -name "pom.xml" 2>/dev/null | sort)
}

classpath_cache_key() {
  local project_dir="$1"
  local scope="$2"
  local offline="$3"
  local settings="$4"
  local repo_local="$5"
  local signature
  signature="$(project_pom_signature "$project_dir")"
  hash_string "classpath-v2|${project_dir}|${scope}|${offline}|${settings}|${repo_local}|${signature}"
}

get_project_classpath_file() {
  local project_dir="$1"
  local scope="${2:-compile}"
  local offline="${3:-0}"
  local settings="${4:-}"
  local repo_local="${5:-}"

  local resolved_project_dir=""
  resolved_project_dir="$(resolve_project_dir "$project_dir" 2>/dev/null || true)"
  if [[ -z "$resolved_project_dir" ]]; then
    warn "未找到 pom.xml: $project_dir"
    return 1
  fi
  project_dir="$resolved_project_dir"

  maybe_load_idea_maven_settings "$project_dir"

  if [[ -z "$settings" && -n "${MVN_SETTINGS:-}" ]]; then
    settings="$MVN_SETTINGS"
  fi
  if [[ -z "$settings" && -n "${IDEA_MVN_SETTINGS_FILE:-}" ]]; then
    settings="$IDEA_MVN_SETTINGS_FILE"
  fi

  if [[ -z "$repo_local" ]]; then
    repo_local="$(mvn_repo_local_path)"
  else
    mkdir -p "$repo_local" >/dev/null 2>&1 || die "无法创建 Maven 本地仓库目录: $repo_local"
  fi

  # 检查 Maven classpath 缓存
  local key
  key="$(classpath_cache_key "$project_dir" "$scope" "$offline" "$settings" "$repo_local")"
  local out_file="${CLASSPATH_DIR%/}/${key}.jars"
  if [[ -f "$out_file" ]]; then
    echo "$out_file"
    return 0
  fi

  # 快速路径：尝试从 IDEA libraries 获取（避免调用 mvn）
  local idea_tmp
  idea_tmp="$(mktemp "${TMP_DIR%/}/idea-classpath.XXXXXX")"
  if try_get_idea_libraries_classpath "$project_dir" "$idea_tmp" 2>/dev/null; then
    # IDEA libraries 成功，直接使用
    mv "$idea_tmp" "$out_file"
    echo "$out_file"
    return 0
  fi
  rm -f "$idea_tmp" >/dev/null 2>&1 || true

  # 快速路径 2：尝试从 IDEA 系统缓存获取（external_build_system）
  idea_tmp="$(mktemp "${TMP_DIR%/}/idea-cache-classpath.XXXXXX")"
  if try_get_idea_system_cache_classpath "$project_dir" "$idea_tmp" 2>/dev/null; then
    # IDEA 系统缓存成功，直接使用
    mv "$idea_tmp" "$out_file"
    echo "$out_file"
    return 0
  fi
  rm -f "$idea_tmp" >/dev/null 2>&1 || true

  # 慢速路径：调用 Maven
  local tmp_cp
  tmp_cp="$(mktemp "${TMP_DIR%/}/maven-classpath.XXXXXX")"

  local -a attempts=()
  if [[ "$offline" == "1" ]]; then
    attempts=("1")
  else
    attempts=("0" "1")
  fi

  local ok="0"
  local last_fail_log=""
  local attempt_offline
  for attempt_offline in "${attempts[@]:-}"; do
    local args=()
    if [[ "$attempt_offline" == "1" ]]; then
      if [[ "$offline" != "1" ]]; then
        warn "Maven 生成 classpath 失败，将尝试使用 --offline 重试..."
      fi
      args+=("-o")
    fi
    if [[ -n "$settings" ]]; then
      args+=("--settings" "$settings")
    fi
    args+=(
      "-q"
      "-Dmaven.repo.local=${repo_local}"
      "-Dmdep.outputFile=${tmp_cp}"
      "-Dmdep.pathSeparator=:"
      "-DincludeScope=${scope}"
      "-Dmdep.includeScope=${scope}"
      "-DincludeTypes=jar"
      "-Dmdep.includeTypes=jar"
      "dependency:build-classpath"
    )

    local mvn_log
    mvn_log="$(mktemp "${TMP_DIR%/}/maven-classpath.log.XXXXXX")"
    local mvn_bin
    mvn_bin="$(mvn_cmd)"
    if (cd "$project_dir" && "$mvn_bin" "${args[@]}" >"$mvn_log" 2>&1); then
      ok="1"
      rm -f "$mvn_log" >/dev/null 2>&1 || true
      [[ -n "$last_fail_log" ]] && rm -f "$last_fail_log" >/dev/null 2>&1 || true
      break
    fi

    [[ -n "$last_fail_log" ]] && rm -f "$last_fail_log" >/dev/null 2>&1 || true
    last_fail_log="$mvn_log"
  done

  if [[ "$ok" != "1" ]]; then
    warn "Maven 生成 classpath 失败"
    [[ -n "$last_fail_log" ]] && tail -n 80 "$last_fail_log" >&2 || true
    rm -f "$last_fail_log" "$tmp_cp" >/dev/null 2>&1 || true
    return 1
  fi

  normalize_classpath_file "$tmp_cp" | sed '/^[[:space:]]*$/d' | while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ -f "$p" && "$p" == *.jar ]]; then
      echo "$p"
    fi
  done >"${out_file}.tmp"

  mv "${out_file}.tmp" "$out_file"
  rm -f "$tmp_cp" >/dev/null 2>&1 || true
  echo "$out_file"
}

get_project_target_jars_file() {
  local input="${1:-}"
  local maxdepth="${2:-12}"
  [[ -n "$input" ]] || return 1

  local base="$input"
  if [[ -f "$base" ]]; then
    base="$(dirname "$base")"
  fi
  [[ -d "$base" ]] || return 1

  local tmp_file
  tmp_file="$(mktemp "${TMP_DIR%/}/project-target-jars.XXXXXX")"

  find "$base" -maxdepth "$maxdepth" -type f \
    \( \
      -path "*/target/*/WEB-INF/lib/*.jar" \
      -o -path "*/target/*/BOOT-INF/lib/*.jar" \
      -o -path "*/target/dependency/*.jar" \
      -o -path "*/target/lib/*.jar" \
    \) \
    ! -name "*-sources.jar" ! -name "*-javadoc.jar" 2>/dev/null | LC_ALL=C sort -u >"$tmp_file" || true

  if [[ ! -s "$tmp_file" ]]; then
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  echo "$tmp_file"
}

resolve_binary_jars_file() {
  local classpath_file="$1"
  local project_dir="$2"
  local scope="$3"
  local mvn_offline="$4"
  local mvn_settings="$5"
  local mvn_repo_local="$6"
  local allow_fallback="${7:-0}"

  local binary_jars_file=""
  local tmp_file_flag="0"
  local resolved_project_dir=""

  if [[ -n "$classpath_file" ]]; then
    [[ -f "$classpath_file" ]] || die_with_hint "classpath-file 不存在: $classpath_file" \
      "请检查文件路径是否正确，或使用 --project 指定项目目录"
    local tmp_file
    tmp_file="$(mktemp "${TMP_DIR%/}/classpath-input.XXXXXX")"
    normalize_classpath_file "$classpath_file" | sed '/^[[:space:]]*$/d' | while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if [[ -f "$p" && "$p" == *.jar ]]; then
        echo "$p"
      fi
    done >"$tmp_file"
    binary_jars_file="$tmp_file"
    tmp_file_flag="1"
  elif [[ -n "$project_dir" ]]; then
    resolved_project_dir="$(resolve_project_dir "$project_dir" 2>/dev/null || true)"
    if [[ -z "$resolved_project_dir" ]]; then
      if [[ "$allow_fallback" != "1" ]]; then
        die_with_hint "未能定位 pom.xml: $project_dir" \
          "为避免扫描整个本地仓库已终止；请指定正确的 Maven 项目目录，或使用 --allow-fallback 允许回退扫描 target/仓库"
      fi

      local target_jars
      target_jars="$(get_project_target_jars_file "$project_dir" 2>/dev/null || true)"
      if [[ -n "$target_jars" && -f "$target_jars" ]]; then
        warn "未能定位 pom.xml，改用项目 target 目录中的依赖 JAR"
        binary_jars_file="$target_jars"
        tmp_file_flag="1"
      fi
    else
      if binary_jars_file="$(get_project_classpath_file "$resolved_project_dir" "$scope" "$mvn_offline" "$mvn_settings" "$mvn_repo_local")"; then
        tmp_file_flag="0"
      else
        if [[ "$allow_fallback" != "1" ]]; then
          die_with_hint "Maven 生成项目 classpath 失败: $resolved_project_dir" \
            "为避免扫描整个本地仓库已终止；请修复 Maven 依赖/仓库/设置后重试，或使用 --allow-fallback 允许回退扫描 target/仓库"
        fi

        local target_jars
        target_jars="$(get_project_target_jars_file "$resolved_project_dir" 2>/dev/null || true)"
        if [[ -n "$target_jars" && -f "$target_jars" ]]; then
          # 加载 IDEA 配置，以便后续 search_path 能使用正确的本地仓库
          maybe_load_idea_maven_settings "$resolved_project_dir"
          if [[ -n "${IDEA_MVN_LOCAL_REPO:-}" ]]; then
            warn "Maven 解析失败，改用 target 目录 + IDEA 本地仓库回退搜索"
          else
            warn "Maven 解析失败，改用项目 target 目录中的依赖 JAR"
          fi
          binary_jars_file="$target_jars"
          tmp_file_flag="1"
        fi
      fi
    fi
  fi

  echo "${binary_jars_file}"$'\t'"${tmp_file_flag}"$'\t'"${resolved_project_dir}"
}
