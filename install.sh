#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="maven-source-viewer"
SKILL_DIR="${HOME}/.claude/skills/${SKILL_NAME}"
REPO_URL="https://github.com/WtMonster/maven-source-viewer.git"

INSTALL_CFR="1"
CFR_VERSION_DEFAULT="0.152"
CFR_METHOD_DEFAULT="auto" # auto|maven|http
CFR_OUTPUT_DEFAULT="${HOME}/.cache/maven-source-viewer/tools/cfr.jar"

usage() {
  cat <<'EOF'
用法:
  install.sh [选项]

选项:
  --skill-dir DIR        安装目录（默认 ~/.claude/skills/maven-source-viewer）
  --repo-url URL         仓库地址（默认 https://github.com/WtMonster/maven-source-viewer.git）
  --no-cfr               不安装 CFR
  --cfr-version V        CFR 版本（默认 0.152）
  --cfr-method M         CFR 安装方式：auto|maven|http（默认 auto）
  --cfr-output FILE      CFR 输出路径（默认 ~/.cache/maven-source-viewer/tools/cfr.jar）
  -h, --help             显示帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/WtMonster/maven-source-viewer/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/WtMonster/maven-source-viewer/main/install.sh | bash -s -- --no-cfr
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-dir) SKILL_DIR="${2:-$SKILL_DIR}"; shift 2 ;;
    --repo-url) REPO_URL="${2:-$REPO_URL}"; shift 2 ;;
    --no-cfr) INSTALL_CFR="0"; shift ;;
    --cfr-version) CFR_VERSION_DEFAULT="${2:-$CFR_VERSION_DEFAULT}"; shift 2 ;;
    --cfr-method) CFR_METHOD_DEFAULT="${2:-$CFR_METHOD_DEFAULT}"; shift 2 ;;
    --cfr-output) CFR_OUTPUT_DEFAULT="${2:-$CFR_OUTPUT_DEFAULT}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

echo "正在安装 ${SKILL_NAME} skill..."

command -v git >/dev/null 2>&1 || { echo "错误: 缺少 git" >&2; exit 1; }

# 检查是否已安装
if [[ -d "$SKILL_DIR" ]]; then
  echo "已存在，正在更新..."
  (cd "$SKILL_DIR" && git pull)
else
  echo "正在克隆..."
  mkdir -p "$(dirname "$SKILL_DIR")"
  git clone "$REPO_URL" "$SKILL_DIR"
fi

# 设置执行权限
chmod +x "$SKILL_DIR/scripts/"*.sh

if [[ "$INSTALL_CFR" == "1" ]]; then
  echo ""
  echo "正在安装 CFR（可选）..."
  mkdir -p "$(dirname "$CFR_OUTPUT_DEFAULT")" >/dev/null 2>&1 || true
  if "$SKILL_DIR/scripts/maven-source.sh" install-cfr \
    --version "$CFR_VERSION_DEFAULT" \
    --output "$CFR_OUTPUT_DEFAULT" \
    --method "$CFR_METHOD_DEFAULT"; then
    echo "CFR 已安装: $CFR_OUTPUT_DEFAULT"
  else
    echo "警告: CFR 安装失败（不影响基础功能：仍可使用 Fernflower/javap 兜底）" >&2
    echo "提示: 可稍后执行: $SKILL_DIR/scripts/maven-source.sh install-cfr --method maven" >&2
  fi
fi

echo ""
echo "安装完成！"
echo ""
echo "使用方式："
echo "  在 Claude Code 中调用 skill: maven-source-viewer"
echo ""
echo "快速开始："
echo "  \$SCRIPT open com.example.MyClass --project /path/to/project --all"
echo ""

