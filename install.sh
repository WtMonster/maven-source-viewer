#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="maven-source-viewer"
SKILL_DIR="${HOME}/.claude/skills/${SKILL_NAME}"
REPO_URL="https://github.com/WtMonster/maven-source-viewer.git"

echo "正在安装 ${SKILL_NAME} skill..."

# 检查是否已安装
if [[ -d "$SKILL_DIR" ]]; then
    echo "已存在，正在更新..."
    cd "$SKILL_DIR" && git pull
else
    echo "正在克隆..."
    mkdir -p "$(dirname "$SKILL_DIR")"
    git clone "$REPO_URL" "$SKILL_DIR"
fi

# 设置执行权限
chmod +x "$SKILL_DIR/scripts/"*.sh

echo ""
echo "安装完成！"
echo ""
echo "使用方式："
echo "  在 Claude Code 中调用 skill: maven-source-viewer"
echo ""
echo "快速开始："
echo "  \$SCRIPT open com.example.MyClass --project /path/to/project --all"
echo ""
