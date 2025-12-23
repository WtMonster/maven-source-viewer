#!/usr/bin/env bash
# decompile.sh - 反编译相关

[[ -n "${_DECOMPILE_SH_LOADED:-}" ]] && return 0
_DECOMPILE_SH_LOADED=1

# ============================================================================
# 反编译器检测
# ============================================================================

init_decompilers() {
  if [[ -z "${CFR_JAR:-}" && -f "${TOOLS_DIR%/}/cfr.jar" ]]; then
    CFR_JAR="${TOOLS_DIR%/}/cfr.jar"
  fi
  if [[ -z "${CFR_JAR:-}" && -n "${HOME:-}" && -f "${HOME%/}/.cache/maven-source-viewer/tools/cfr.jar" ]]; then
    CFR_JAR="${HOME%/}/.cache/maven-source-viewer/tools/cfr.jar"
  fi
  if [[ -z "${FERNFLOWER_JAR:-}" && -f "${TOOLS_DIR%/}/fernflower.jar" ]]; then
    FERNFLOWER_JAR="${TOOLS_DIR%/}/fernflower.jar"
  fi
  if [[ -z "${FERNFLOWER_JAR:-}" && -n "${HOME:-}" && -f "${HOME%/}/.cache/maven-source-viewer/tools/fernflower.jar" ]]; then
    FERNFLOWER_JAR="${HOME%/}/.cache/maven-source-viewer/tools/fernflower.jar"
  fi

  # 尝试复用 IntelliJ IDEA 自带的 Fernflower（更贴近 IDE 反编译效果）
  if [[ -z "${FERNFLOWER_JAR:-}" && -n "${HOME:-}" ]]; then
    local candidate=""
    for candidate in \
      "/Applications/IntelliJ IDEA.app/Contents/plugins/java-decompiler/lib/java-decompiler.jar" \
      "/Applications/IntelliJ IDEA CE.app/Contents/plugins/java-decompiler/lib/java-decompiler.jar" \
      "${HOME%/}/Applications/IntelliJ IDEA.app/Contents/plugins/java-decompiler/lib/java-decompiler.jar" \
      "${HOME%/}/Applications/IntelliJ IDEA CE.app/Contents/plugins/java-decompiler/lib/java-decompiler.jar"; do
      if [[ -f "$candidate" ]]; then
        FERNFLOWER_JAR="$candidate"
        break
      fi
    done
  fi

  # JetBrains Toolbox 安装路径（Mac/Linux），尽量限制搜索范围避免过慢
  if [[ -z "${FERNFLOWER_JAR:-}" && -n "${HOME:-}" ]]; then
    local toolbox_base="${HOME%/}/Library/Application Support/JetBrains/Toolbox/apps"
    if [[ -d "$toolbox_base" ]]; then
      local found=""
      found="$(find "$toolbox_base" -maxdepth 10 -type f -name "java-decompiler.jar" 2>/dev/null | head -n 1 || true)"
      [[ -n "$found" && -f "$found" ]] && FERNFLOWER_JAR="$found"
    fi
  fi
}

# ============================================================================
# 源码下载
# ============================================================================

try_download_sources_for_binary_jar() {
  local jar="$1"
  local settings="${2:-}"
  local repo_local="${3:-}"

  [[ -n "$jar" && -f "$jar" ]] || return 1

  local gav
  gav="$(jar_gav "$jar" 2>/dev/null || true)"
  [[ -n "$gav" ]] || return 1

  local g a v
  g="$(echo "$gav" | cut -d: -f1)"
  a="$(echo "$gav" | cut -d: -f2)"
  v="$(echo "$gav" | cut -d: -f3)"
  [[ -n "$g" && -n "$a" && -n "$v" ]] || return 1

  local sources_jar
  sources_jar="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
  if [[ -n "$sources_jar" && -f "$sources_jar" ]]; then
    echo "$sources_jar"
    return 0
  fi

  if [[ -z "$repo_local" ]]; then
    repo_local="$(mvn_repo_local_path)"
  fi

  run_mvn_standalone "$repo_local" "$settings" \
    "dependency:get" \
    "-Dartifact=${g}:${a}:${v}:jar:sources" \
    "-Dtransitive=false" >/dev/null 2>&1 || return 1

  sources_jar="$(find_sources_jar_for_binary "$jar" 2>/dev/null || true)"
  if [[ -n "$sources_jar" && -f "$sources_jar" ]]; then
    echo "$sources_jar"
    return 0
  fi

  return 1
}

# ============================================================================
# 反编译实现
# ============================================================================

try_decompile_cfr() {
  local jar="$1"
  local class_entry="$2"
  local out_file="$3"
  local extra_cp="${4:-}"

  [[ -n "${CFR_JAR:-}" && -f "${CFR_JAR:-}" ]] || return 1

  local class_name="${class_entry%.class}"
  class_name="${class_name//\//.}"

  local args=("--silent" "true")
  if [[ -n "$extra_cp" ]]; then
    args+=("--extraclasspath" "$extra_cp")
  fi

  java -jar "$CFR_JAR" "$jar" --outputdir "$TMP_DIR" "${args[@]}" "$class_name" >/dev/null 2>&1 || return 1

  local expected_file="${TMP_DIR%/}/${class_entry%.class}.java"
  if [[ -f "$expected_file" ]]; then
    mv "$expected_file" "$out_file"
    return 0
  fi

  local found
  found="$(find "$TMP_DIR" -type f -name "*.java" -newer "$jar" 2>/dev/null | head -n1 || true)"
  if [[ -n "$found" && -f "$found" ]]; then
    mv "$found" "$out_file"
    return 0
  fi

  return 1
}

try_decompile_fernflower() {
  local jar="$1"
  local class_entry="$2"
  local out_file="$3"
  local extra_cp="${4:-}"

  [[ -n "${FERNFLOWER_JAR:-}" && -f "${FERNFLOWER_JAR:-}" ]] || return 1

  local tmp_out_dir
  tmp_out_dir="$(mktemp -d "${TMP_DIR%/}/fernflower.XXXXXX")"

  local args=()
  if [[ -n "$extra_cp" ]]; then
    local cp_jar
    for cp_jar in ${extra_cp//:/ }; do
      [[ -f "$cp_jar" ]] && args+=("-e=$cp_jar")
    done
  fi

  java -jar "$FERNFLOWER_JAR" "${args[@]}" "$jar" "$tmp_out_dir" >/dev/null 2>&1 || {
    rm -rf "$tmp_out_dir" >/dev/null 2>&1 || true
    return 1
  }

  local jar_name
  jar_name="$(basename "$jar" .jar)"
  local inner_jar="${tmp_out_dir}/${jar_name}.jar"
  if [[ -f "$inner_jar" ]]; then
    local source_entry="${class_entry%.class}.java"
    unzip -p "$inner_jar" "$source_entry" >"$out_file" 2>/dev/null || {
      rm -rf "$tmp_out_dir" >/dev/null 2>&1 || true
      return 1
    }
    rm -rf "$tmp_out_dir" >/dev/null 2>&1 || true
    return 0
  fi

  rm -rf "$tmp_out_dir" >/dev/null 2>&1 || true
  return 1
}

try_decompile_javap() {
  local jar="$1"
  local class_entry="$2"
  local out_file="$3"

  command -v javap >/dev/null 2>&1 || return 1

  local tmp_class
  tmp_class="$(mktemp "${TMP_DIR%/}/class.XXXXXX")"
  unzip -p "$jar" "$class_entry" >"$tmp_class" 2>/dev/null || {
    rm -f "$tmp_class" >/dev/null 2>&1 || true
    return 1
  }

  javap -c -p "$tmp_class" >"$out_file" 2>/dev/null || {
    rm -f "$tmp_class" >/dev/null 2>&1 || true
    return 1
  }

  rm -f "$tmp_class" >/dev/null 2>&1 || true
  return 0
}

decompile_class_to_file() {
  local jar="$1"
  local class_entry="$2"
  local out_file="$3"
  local decompiler="${4:-auto}"
  local extra_cp="${5:-}"

  local picked="$decompiler"
  if [[ "$picked" == "auto" ]]; then
    if [[ -n "${CFR_JAR:-}" && -f "${CFR_JAR:-}" ]]; then
      picked="cfr"
    elif [[ -n "${FERNFLOWER_JAR:-}" && -f "${FERNFLOWER_JAR:-}" ]]; then
      picked="fernflower"
    else
      picked="javap"
    fi
  fi

  case "$picked" in
    cfr)
      if try_decompile_cfr "$jar" "$class_entry" "$out_file" "$extra_cp"; then
        echo "cfr"
        return 0
      fi
      ;;
    fernflower)
      if try_decompile_fernflower "$jar" "$class_entry" "$out_file" "$extra_cp"; then
        echo "fernflower"
        return 0
      fi
      ;;
    javap)
      if try_decompile_javap "$jar" "$class_entry" "$out_file"; then
        echo "javap"
        return 0
      fi
      ;;
    *)
      die "未知 decompiler: $picked（可选: auto|cfr|fernflower|javap）"
      ;;
  esac

  # 自动兜底：无论 picked 是什么，只要失败就尝试 javap
  if try_decompile_javap "$jar" "$class_entry" "$out_file"; then
    echo "javap"
    return 0
  fi

  return 1
}

# ============================================================================
# CFR 安装
# ============================================================================

install_cfr() {
  local version="${CFR_VERSION:-0.152}"
  local output=""
  local url=""
  local settings=""
  local repo_local=""
  local method="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        version="${2:-$version}"
        shift 2
        ;;
      --output)
        output="${2:-}"
        shift 2
        ;;
      --url)
        url="${2:-}"
        shift 2
        ;;
      --mvn-settings)
        settings="${2:-}"
        shift 2
        ;;
      --mvn-repo-local)
        repo_local="${2:-}"
        shift 2
        ;;
      --method)
        method="${2:-auto}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -z "$output" ]]; then
    output="${TOOLS_DIR%/}/cfr.jar"
  fi

  if [[ -z "$url" ]]; then
    url="https://repo1.maven.org/maven2/org/benf/cfr/${version}/cfr-${version}.jar"
  fi

  mkdir -p "$(dirname "$output")" || die "无法创建目录: $(dirname "$output")"

  if [[ -z "$repo_local" ]]; then
    repo_local="$(mvn_repo_local_path)"
  fi

  if [[ "$method" == "auto" || "$method" == "maven" ]]; then
    local cached_jar="${repo_local%/}/org/benf/cfr/${version}/cfr-${version}.jar"
    if [[ ! -f "$cached_jar" ]]; then
      echo "正在通过 Maven 获取 CFR ${version}..."
      run_mvn_standalone "$repo_local" "$settings" \
        "dependency:get" \
        "-Dartifact=org.benf:cfr:${version}:jar" \
        "-Dtransitive=false" >/dev/null 2>&1 || true
    fi
    if [[ -f "$cached_jar" ]]; then
      cp "$cached_jar" "$output"
      echo "CFR 已安装到: $output"
      CFR_JAR="$output"
      return 0
    fi
    [[ "$method" == "maven" ]] && die "通过 Maven 获取 CFR 失败（未在本地仓库找到 ${cached_jar}）"
  fi

  echo "正在通过 HTTP 下载 CFR ${version}..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output" || die "下载失败: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output" || die "下载失败: $url"
  else
    die "需要 curl 或 wget 来下载 CFR（或使用 --method maven）"
  fi

  echo "CFR 已安装到: $output"
  CFR_JAR="$output"
}
