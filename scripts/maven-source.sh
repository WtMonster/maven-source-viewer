#!/usr/bin/env bash

# Maven Source Viewer - 查看 Maven 第三方依赖源码（类似 IDE 跳转源码）
#
# 设计目标：
# - 优先在 *-sources.jar 中定位源码文件
# - 支持内部类（Outer.Inner / Outer$Inner）定位到 Outer.java
# - 支持 Java/Kotlin/Groovy/Scala 源文件扩展名
# - 提供 fetch/open，便于把源码"落盘"到 workspace 供 vibe coding 这类工具读取
# - 通过缓存 JAR 索引（unzip -Z1）加速重复查找/搜索

set -euo pipefail

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载模块
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/maven.sh"
source "${SCRIPT_DIR}/lib/jar.sh"
source "${SCRIPT_DIR}/lib/class-resolver.sh"
source "${SCRIPT_DIR}/lib/decompile.sh"
source "${SCRIPT_DIR}/lib/commands.sh"

# 初始化
init_cache_dirs
init_decompilers

# ============================================================================
# 帮助信息
# ============================================================================

usage() {
  cat <<'EOF'
Maven Source Viewer - 查看 Maven 依赖的源码

用法:
  maven-source.sh find <class-fqn> [search-path] [--binary] [--limit-jars N] [--project DIR|--classpath-file FILE]
  maven-source.sh search <pattern> [search-path] [--limit-matches N] [--project DIR|--classpath-file FILE]
  maven-source.sh read <sources-jar> <class-fqn> [--all|--max-lines N]
  maven-source.sh open <class-fqn> [search-path] [--all|--max-lines N] [--project DIR|--classpath-file FILE] [--download-sources] [--decompiler auto|cfr|fernflower|javap] [--no-decompile]
  maven-source.sh fetch <class-fqn> <output-dir> [search-path] [--project DIR|--classpath-file FILE] [--download-sources] [--decompiler auto|cfr|fernflower|javap] [--no-decompile]
  maven-source.sh decompile <class-fqn> [search-path] [--all|--max-lines N] [--project DIR|--classpath-file FILE] [--decompiler auto|cfr|fernflower|javap]
  maven-source.sh classpath <project-dir> [--output FILE] [--scope compile|test|runtime] [--offline]
  maven-source.sh list <project-dir>
  maven-source.sh download <project-dir>
  maven-source.sh extract <sources-jar> <output-dir>
  maven-source.sh install-cfr [--version X] [--output FILE] [--url URL] [--mvn-settings FILE] [--mvn-repo-local DIR]
  maven-source.sh coordinates <jar-path>

环境变量:
  M2_REPO             Maven 本地仓库（默认 ~/.m2/repository）
  CACHE_DIR           缓存目录（默认优先 ~/.cache，不可写则回退到 /tmp）
  MAX_LINES_DEFAULT   read/open 默认输出行数（默认 400）
  MVN_BIN             指定 mvn 可执行文件路径（可选，优先级高于 MAVEN_HOME / IDEA 配置）
  MAVEN_HOME          Maven 安装目录（可选，使用 $MAVEN_HOME/bin/mvn）
  MVN_SETTINGS         Maven settings.xml 路径（可选，等价于 mvn --settings）
  MVN_REPO_LOCAL      Maven 本地仓库路径（默认优先复用 M2_REPO；不可写时回退到 CACHE_DIR 下的 maven-repo）
  CFR_JAR             CFR 反编译器 JAR 路径（可选）
  FERNFLOWER_JAR      Fernflower 反编译器 JAR 路径（可选）
  CFR_VERSION         install-cfr 默认版本（默认 0.152）

示例:
  maven-source.sh find org.springframework.core.SpringVersion
  maven-source.sh find org.springframework.core.SpringVersion --binary
  maven-source.sh open org.springframework.core.SpringVersion --project .
  maven-source.sh fetch org.springframework.core.SpringVersion ./.vibe/deps-src
EOF
}

# ============================================================================
# 主入口
# ============================================================================

main() {
  local cmd="${1:-}"
  shift 1 || true

  case "$cmd" in
    find)
      cmd_find "$@"
      ;;
    search)
      cmd_search "$@"
      ;;
    read)
      cmd_read "$@"
      ;;
    open)
      cmd_open "$@"
      ;;
    fetch)
      cmd_fetch "$@"
      ;;
    decompile)
      cmd_decompile "$@"
      ;;
    classpath)
      cmd_classpath "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    download)
      cmd_download "$@"
      ;;
    extract)
      cmd_extract "$@"
      ;;
    install-cfr)
      install_cfr "$@"
      ;;
    coordinates)
      cmd_coordinates "$@"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die_with_hint "未知命令: $cmd" "使用 'maven-source.sh --help' 查看可用命令"
      ;;
  esac
}

main "$@"
