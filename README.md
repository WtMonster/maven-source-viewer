# Maven Source Viewer

Claude Code Skill：查看 Maven 项目中第三方依赖的源码，类似于 IDE 里的"跳转到源码"能力。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/WtMonster/maven-source-viewer/main/install.sh | bash
```

或手动安装：

```bash
git clone https://github.com/WtMonster/maven-source-viewer.git ~/.claude/skills/maven-source-viewer
chmod +x ~/.claude/skills/maven-source-viewer/scripts/*.sh
```

## 快速开始

在 Claude Code 中，当你需要查看第三方依赖的源码时，会自动调用此 skill。

**查看某个类的完整源码**（最常用）：

```bash
~/.claude/skills/maven-source-viewer/scripts/maven-source.sh open com.example.MyClass --project /path/to/project --all
```

## 核心命令

| 命令 | 用途 | 示例 |
|------|------|------|
| `open` | 打开类源码（推荐） | `open com.example.MyClass --project DIR --all` |
| `find` | 查找类所在的 JAR | `find com.example.MyClass --project DIR` |
| `search` | 模糊搜索类名 | `search RestTemplate --project DIR` |
| `decompile` | 强制反编译查看 | `decompile com.example.MyClass --project DIR` |
| `fetch` | 将源码落盘到目录 | `fetch com.example.MyClass ./output --project DIR` |
| `download` | 下载项目所有依赖源码 | `download /path/to/project` |

## 主要参数

| 参数 | 说明 |
|------|------|
| `--project DIR` | 指定项目目录，精确匹配项目依赖版本（强烈推荐） |
| `--all` | 输出完整源码（默认只输出 400 行） |
| `--max-lines N` | 限制输出行数 |
| `--download-sources` | 本地没有源码时尝试下载 |
| `--no-decompile` | 禁止反编译兜底 |

## 特性

- **智能 IDEA 集成**：自动读取 IDEA 的 Maven 配置（settings.xml、localRepository）
- **多级降级策略**：优先查找 sources.jar → 自动反编译（CFR → Fernflower → javap）
- **并行搜索**：使用 xargs 并行处理，大幅提升搜索速度
- **增量缓存**：JAR 索引、classpath 等都有缓存，加速重复查找
- **内部类支持**：正确处理 `Outer.Inner` 和 `Outer$Inner` 格式
- **多语言支持**：Java/Kotlin/Groovy/Scala 源文件

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `M2_REPO` | `~/.m2/repository` | Maven 本地仓库路径 |
| `PARALLEL_JOBS` | `8` | 并行搜索任务数 |
| `JAR_LIST_CACHE_TTL` | `86400` | JAR 列表缓存有效期（秒） |
| `MAX_LINES_DEFAULT` | `400` | 默认输出行数限制 |

## 反编译器

默认使用 `javap`（JDK 自带），如需更好的反编译效果，可安装 CFR：

```bash
~/.claude/skills/maven-source-viewer/scripts/maven-source.sh install-cfr
```

## 缓存位置

```
~/.cache/maven-source-viewer/
├── index/      # JAR 文件索引
├── lists/      # JAR 列表缓存
├── classpath/  # 项目 classpath 缓存
└── tools/      # 反编译器等工具
```

清理缓存：

```bash
rm -rf ~/.cache/maven-source-viewer/
```

## License

MIT
