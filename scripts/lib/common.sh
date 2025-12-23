#!/usr/bin/env bash
# common.sh - 通用工具函数

# 防止重复加载
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ============================================================================
# 全局变量
# ============================================================================

M2_REPO="${M2_REPO:-$HOME/.m2/repository}"
MAX_LINES_DEFAULT="${MAX_LINES_DEFAULT:-400}"
SOURCE_EXTS=(java kt kts groovy scala)

# ============================================================================
# 配置文件（全局/项目级）
# ============================================================================

# 配置优先级（从高到低）：
# 1) 命令行参数（如 --mvn-settings / --mvn-repo-local）
# 2) 环境变量（如 MVN_SETTINGS / MVN_REPO_LOCAL）
# 3) 项目配置文件（默认 .maven-source-viewer.conf）
# 4) 全局配置文件（默认 ~/.config/maven-source-viewer/config）
#
# 配置文件格式：
# - 只支持 KEY=VALUE（忽略空行和以 # 开头的注释）
# - 仅允许白名单中的 KEY，避免执行任意 shell 代码

MSV_CONFIG_SET_VARS="${MSV_CONFIG_SET_VARS:-|}"

msv__is_set_by_config() {
  local var="$1"
  [[ "$MSV_CONFIG_SET_VARS" == *"|${var}|"* ]]
}

msv__mark_set_by_config() {
  local var="$1"
  msv__is_set_by_config "$var" && return 0
  MSV_CONFIG_SET_VARS="${MSV_CONFIG_SET_VARS}${var}|"
}

msv__set_config_var() {
  local var="$1"
  local val="$2"

  # 不覆盖用户显式环境变量；允许“后加载的配置”覆盖“先加载的配置”
  if [[ -z "${!var-}" ]] || msv__is_set_by_config "$var"; then
    printf -v "$var" '%s' "$val"
    export "$var"
    msv__mark_set_by_config "$var"
  fi
}

msv__apply_config_kv() {
  local key="$1"
  local val="$2"

  case "$key" in
    M2_REPO|CACHE_DIR|MAX_LINES_DEFAULT|PARALLEL_JOBS|JAR_LIST_CACHE_TTL|JAR_LIST_INCREMENTAL_INTERVAL)
      msv__set_config_var "$key" "$val"
      ;;
    MVN_BIN|MAVEN_HOME|MVN_SETTINGS|MVN_REPO_LOCAL)
      msv__set_config_var "$key" "$val"
      ;;
    CFR_JAR|FERNFLOWER_JAR|CFR_VERSION)
      msv__set_config_var "$key" "$val"
      ;;
    *)
      # 忽略未知 key
      ;;
  esac
}

msv_load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *"="* ]] || continue

    local key="${line%%=*}"
    local val="${line#*=}"
    key="$(printf "%s" "$key" | tr -d '[:space:]')"
    val="$(printf "%s" "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

    [[ -n "$key" ]] || continue
    msv__apply_config_kv "$key" "$val"
  done <"$file"
}

msv_global_config_file() {
  if [[ -n "${MSV_GLOBAL_CONFIG:-}" ]]; then
    echo "$MSV_GLOBAL_CONFIG"
    return 0
  fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    echo "${XDG_CONFIG_HOME%/}/maven-source-viewer/config"
  else
    echo "${HOME%/}/.config/maven-source-viewer/config"
  fi
}

msv_load_global_config() {
  local file
  file="$(msv_global_config_file)"
  msv_load_config_file "$file" >/dev/null 2>&1 || true
}

msv_load_project_config() {
  local project_dir="${1:-}"
  [[ -n "$project_dir" && -d "$project_dir" ]] || return 1
  local file="${project_dir%/}/.maven-source-viewer.conf"
  msv_load_config_file "$file" >/dev/null 2>&1 || return 1
  return 0
}

# 加载全局默认配置（如存在）
msv_load_global_config

# ============================================================================
# 错误处理
# ============================================================================

die() {
  echo "错误: $*" >&2
  exit 1
}

die_with_hint() {
  local msg="$1"
  local hint="$2"
  echo "错误: $msg" >&2
  if [[ -n "$hint" ]]; then
    echo "提示: $hint" >&2
  fi
  exit 1
}

warn() {
  echo "警告: $*" >&2
}

debug() {
  [[ "${VERBOSE:-0}" == "1" ]] && echo "[DEBUG] $*" >&2 || true
}

# ============================================================================
# 文件系统工具
# ============================================================================

ensure_writable_dir() {
  local dir="$1"
  mkdir -p "$dir" >/dev/null 2>&1 || return 1
  local test_file="${dir%/}/.write_test.$$"
  ( : >"$test_file" ) >/dev/null 2>&1 || return 1
  rm -f "$test_file" >/dev/null 2>&1 || true
  return 0
}

file_mtime() {
  local file="$1"
  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
  else
    stat -c %Y "$file"
  fi
}

file_size() {
  local file="$1"
  if stat -f %z "$file" >/dev/null 2>&1; then
    stat -f %z "$file"
  else
    stat -c %s "$file"
  fi
}

hash_string() {
  local s="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf "%s" "$s" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf "%s" "$s" | sha256sum | awk '{print $1}'
  else
    die "缺少 shasum/sha256sum，无法生成缓存 key"
  fi
}

# ============================================================================
# 缓存目录管理
# ============================================================================

pick_cache_dir() {
  if [[ -n "${CACHE_DIR:-}" ]]; then
    echo "$CACHE_DIR"
    return 0
  fi

  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    local candidate="${XDG_CACHE_HOME%/}/maven-source-viewer"
    if ensure_writable_dir "$candidate"; then
      echo "$candidate"
      return 0
    fi
  fi

  if [[ -n "${HOME:-}" ]]; then
    local candidate="${HOME%/}/.cache/maven-source-viewer"
    if ensure_writable_dir "$candidate"; then
      echo "$candidate"
      return 0
    fi
  fi

  local fallback="/tmp/maven-source-viewer-${USER:-user}"
  ensure_writable_dir "$fallback" || die "无法创建缓存目录: $fallback"
  echo "$fallback"
}

init_cache_dirs() {
  CACHE_DIR="$(pick_cache_dir)"
  INDEX_DIR="${CACHE_DIR%/}/index"
  TMP_DIR="${CACHE_DIR%/}/tmp"
  LIST_DIR="${CACHE_DIR%/}/lists"
  CLASSPATH_DIR="${CACHE_DIR%/}/classpath"
  TOOLS_DIR="${CACHE_DIR%/}/tools"
  MVN_REPO_LOCAL_DEFAULT="${CACHE_DIR%/}/maven-repo"

  mkdir -p "$INDEX_DIR" "$TMP_DIR" "$LIST_DIR" "$CLASSPATH_DIR" "$TOOLS_DIR" "$MVN_REPO_LOCAL_DEFAULT"
}

# ============================================================================
# 参数解析
# ============================================================================

parse_project_args() {
  local search_path="$M2_REPO"
  local search_path_explicit="0"
  local project_dir=""
  local classpath_file=""
  local scope="compile"
  local mvn_offline="0"
  local mvn_settings=""
  local mvn_repo_local=""
  local decompiler="auto"
  local allow_decompile="1"
  local download_sources="0"
  local allow_fallback="0"
  local all="0"
  local max_lines=""
  local verbose="0"
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        project_dir="${2:-}"
        shift 2
        ;;
      --classpath-file)
        classpath_file="${2:-}"
        shift 2
        ;;
      --scope)
        scope="${2:-compile}"
        shift 2
        ;;
      --offline|--mvn-offline)
        mvn_offline="1"
        shift
        ;;
      --mvn-settings)
        mvn_settings="${2:-}"
        shift 2
        ;;
      --mvn-repo-local)
        mvn_repo_local="${2:-}"
        shift 2
        ;;
      --decompiler)
        decompiler="${2:-auto}"
        shift 2
        ;;
      --no-decompile)
        allow_decompile="0"
        shift
        ;;
      --download-sources)
        download_sources="1"
        shift
        ;;
      --allow-fallback)
        allow_fallback="1"
        shift
        ;;
      --all)
        all="1"
        shift
        ;;
      --max-lines)
        max_lines="${2:-}"
        shift 2
        ;;
      --verbose|-v)
        verbose="1"
        shift
        ;;
      --search-path)
        search_path="${2:-$M2_REPO}"
        search_path_explicit="1"
        shift 2
        ;;
      *)
        remaining+=("$1")
        shift
        ;;
    esac
  done

  # 如果有 project_dir 且用户没有显式指定 search_path，尝试使用 IDEA 配置的本地仓库
  if [[ -n "$project_dir" && "$search_path_explicit" == "0" ]]; then
    # 需要先加载 IDEA Maven 配置（这里调用 maybe_load_idea_maven_settings）
    # 由于 common.sh 在 maven.sh 之前加载，这里通过输出变量让调用方处理
    :
  fi

  cat <<EOF
PARSED_PROJECT_DIR=$(printf '%q' "$project_dir")
PARSED_CLASSPATH_FILE=$(printf '%q' "$classpath_file")
PARSED_SCOPE=$(printf '%q' "$scope")
PARSED_MVN_OFFLINE=$(printf '%q' "$mvn_offline")
PARSED_MVN_SETTINGS=$(printf '%q' "$mvn_settings")
PARSED_MVN_REPO_LOCAL=$(printf '%q' "$mvn_repo_local")
PARSED_SEARCH_PATH=$(printf '%q' "$search_path")
PARSED_SEARCH_PATH_EXPLICIT=$(printf '%q' "$search_path_explicit")
PARSED_DECOMPILER=$(printf '%q' "$decompiler")
PARSED_ALLOW_DECOMPILE=$(printf '%q' "$allow_decompile")
PARSED_DOWNLOAD_SOURCES=$(printf '%q' "$download_sources")
PARSED_ALLOW_FALLBACK=$(printf '%q' "$allow_fallback")
PARSED_ALL=$(printf '%q' "$all")
PARSED_MAX_LINES=$(printf '%q' "$max_lines")
PARSED_VERBOSE=$(printf '%q' "$verbose")
PARSED_REMAINING_ARGS=($(printf '%q ' "${remaining[@]:-}"))
EOF
}

# ============================================================================
# 输出工具
# ============================================================================

read_entry_from_jar() {
  local jar="$1"
  local entry="$2"
  local max_lines="$3"
  local all="$4"

  [[ -f "$jar" ]] || die "JAR 文件不存在: $jar"

  local tmp_file
  tmp_file="$(mktemp "${TMP_DIR%/}/maven-source.XXXXXX")"
  unzip -p "$jar" "$entry" >"$tmp_file" 2>/dev/null || {
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    die "无法在 JAR 中读取文件: $entry"
  }

  if [[ "$all" == "1" ]]; then
    cat "$tmp_file"
  else
    if [[ -z "$max_lines" ]]; then
      max_lines="$MAX_LINES_DEFAULT"
    fi
    if [[ "$max_lines" =~ ^[0-9]+$ ]] && ((max_lines > 0)); then
      sed -n "1,${max_lines}p" "$tmp_file"
    else
      cat "$tmp_file"
    fi
  fi

  rm -f "$tmp_file" >/dev/null 2>&1 || true
}

print_file_with_limit() {
  local file="$1"
  local max_lines="$2"
  local all="$3"

  [[ -f "$file" ]] || return 1
  if [[ "$all" == "1" ]]; then
    cat "$file"
    return 0
  fi

  if [[ -z "$max_lines" ]]; then
    max_lines="$MAX_LINES_DEFAULT"
  fi
  if [[ "$max_lines" =~ ^[0-9]+$ ]] && ((max_lines > 0)); then
    sed -n "1,${max_lines}p" "$file"
  else
    cat "$file"
  fi
}

cleanup_tmp_file() {
  local file="$1"
  local is_tmp="$2"
  [[ "$is_tmp" == "1" && -n "$file" ]] && rm -f "$file" >/dev/null 2>&1 || true
}

# ============================================================================
# 错误信息生成
# ============================================================================

class_not_found_error() {
  local class_fqn="$1"
  local search_path="$2"
  local project_dir="$3"

  local msg="未找到类: $class_fqn"
  local hint=""

  if [[ "$class_fqn" == *"/"* ]]; then
    hint="类名应使用 '.' 分隔（如 com.example.MyClass），而不是 '/'"
  elif [[ "$class_fqn" != *.* ]]; then
    hint="请使用完整的类名（如 com.example.MyClass）；可尝试 'search $class_fqn' 模糊搜索"
  elif [[ -z "$project_dir" ]]; then
    hint="可尝试添加 --project <项目目录> 参数以精确匹配项目依赖版本"
  else
    hint="请检查类名是否正确；可尝试 'search ${class_fqn##*.}' 模糊搜索相似类名"
  fi

  die_with_hint "$msg" "$hint"
}
