---
name: maven-source-viewer
description: 查看 Maven 项目第三方依赖的源码。当用户需要查看、搜索或理解第三方 JAR 包中的类源码时使用此 Skill。支持查找类位置、读取源码、下载源码等功能。
allowed-tools:
  - Bash
  - Read
---

# Maven Source Viewer

查看 Maven 项目中第三方依赖的源码，类似于 IDE 里的"跳转到源码"能力。

## 脚本路径

```bash
SCRIPT=~/.claude/skills/maven-source-viewer/scripts/maven-source.sh
```

后续示例均使用 `$SCRIPT` 简写。

## 快速开始（90% 场景覆盖）

**查看某个类的完整源码**（最常用）：

```bash
$SCRIPT open <类的全限定名> --project <项目目录> --all
```

示例：

```bash
$SCRIPT open org.springframework.web.client.RestTemplate --project /Users/zhangsan/my-project --all
```

**输出**：直接输出源码内容到终端。

> **重要**：
> - 不加 `--all` 时默认只输出前 400 行
> - 加 `--project` 可精确匹配项目实际依赖的版本
> - 找不到源码时会自动反编译

---

## 核心命令详解

### 1. open - 打开类源码（推荐）

```bash
$SCRIPT open <类名> [--project DIR] [--all|--max-lines N] [--download-sources] [--no-decompile]
```

| 参数 | 说明 |
|------|------|
| `--project DIR` | 指定项目目录，精确匹配项目依赖版本（强烈推荐） |
| `--all` | 输出完整源码（默认只输出 400 行） |
| `--max-lines N` | 限制输出行数 |
| `--download-sources` | 本地没有源码时尝试下载 |
| `--no-decompile` | 禁止反编译兜底 |

**常用组合**：

```bash
# 查看完整源码（最常用）
$SCRIPT open com.example.MyClass --project /path/to/project --all

# 源码不存在时自动下载
$SCRIPT open com.example.MyClass --project /path/to/project --all --download-sources
```

**输出格式**：直接输出 Java/Kotlin/Groovy 源码内容。

---

### 2. find - 查找类所在的 JAR

```bash
$SCRIPT find <类名> [--project DIR] [--binary]
```

| 参数 | 说明 |
|------|------|
| `--project DIR` | 在项目依赖中查找 |
| `--binary` | 同时在二进制 JAR（非 sources.jar）中查找 |

**输出格式**：

```
找到 JAR: /path/to/xxx-sources.jar
  源码文件: com/example/MyClass.java
  Maven: com.example:artifact:1.0.0
```

---

### 3. search - 模糊搜索类名

```bash
$SCRIPT search <关键词> [--project DIR] [--limit-matches N]
```

示例：

```bash
$SCRIPT search RestTemplate --project /path/to/project
```

**输出格式**：

```
JAR: /path/to/spring-web-6.1.3-sources.jar
  org/springframework/web/client/RestTemplate.java
  org/springframework/web/client/RestTemplateBuilder.java
```

---

## 其他命令

| 命令 | 用途 | 示例 |
|------|------|------|
| `decompile` | 强制反编译查看 | `$SCRIPT decompile com.example.MyClass --project DIR --all` |
| `fetch` | 将源码落盘到目录 | `$SCRIPT fetch com.example.MyClass ./output --project DIR` |
| `download` | 下载项目所有依赖源码 | `$SCRIPT download /path/to/project` |
| `classpath` | 生成项目 classpath 文件 | `$SCRIPT classpath /path/to/project --output ./cp.txt` |
| `coordinates` | 获取 JAR 的 Maven 坐标 | `$SCRIPT coordinates /path/to/some.jar` |
| `extract` | 解压整个 sources.jar | `$SCRIPT extract /path/to/xxx-sources.jar ./output` |
| `install-cfr` | 安装 CFR 反编译器 | `$SCRIPT install-cfr` |

---

## 错误处理指南

### 问题 1：找不到类

**现象**：`未找到类: com.example.MyClass`

**排查步骤**：
1. 检查类名是否正确（全限定名，用 `.` 分隔）
2. 加 `--project` 参数指定项目目录
3. 用 `find --binary` 确认类是否在依赖中

### 问题 2：Maven 解析失败

**现象**：`Maven 生成 classpath 失败`

**解决方案**：
1. 脚本会自动降级到扫描 `target/` 目录中的 JAR
2. 或先手动执行 `mvn compile` 确保项目可构建
3. 网络受限时脚本会自动重试 `--offline` 模式

### 问题 3：源码 JAR 不存在

**现象**：输出的是反编译代码（不是原始源码）

**解决方案**：
```bash
# 方式 1：加 --download-sources 自动下载
$SCRIPT open com.example.MyClass --project DIR --all --download-sources

# 方式 2：手动下载项目所有依赖源码
$SCRIPT download /path/to/project
```

### 问题 4：反编译质量差

**现象**：输出的是 `javap` 反汇编（字节码），不是 Java 代码

**解决方案**：安装 CFR 反编译器
```bash
$SCRIPT install-cfr
```

---

## 使用场景示例

### 场景 1：用户说"帮我看看 XXX 类的源码"

```bash
$SCRIPT open com.example.SomeClass --project /当前项目目录 --all
```

### 场景 2：用户说"这个类在哪个 JAR 里"

```bash
$SCRIPT find com.example.SomeClass --project /当前项目目录
```

### 场景 3：用户说"搜一下有没有 XXX 相关的类"

```bash
$SCRIPT search XXX --project /当前项目目录
```

### 场景 4：用户想看某个包下的所有类

```bash
# 先解压整个 sources.jar
$SCRIPT extract /path/to/xxx-sources.jar /tmp/extracted

# 然后用 Read 工具浏览
```

---

## 注意事项

- **类名格式**：使用全限定名，用 `.` 分隔（如 `com.example.MyClass`）
- **内部类**：使用 `Outer.Inner` 格式（不要用 `Outer$Inner`，`$` 会被 shell 解释）
- **默认输出行数**：400 行，需要完整源码请加 `--all`
- **缓存位置**：`~/.cache/maven-source-viewer/`（JAR 索引、classpath 缓存等）
- **Maven 仓库**：默认 `~/.m2/repository`，可通过 `M2_REPO` 环境变量覆盖
- **IDEA 配置**：加 `--project` 时会自动读取 IDEA 的 Maven 配置（settings.xml、localRepository 等）
