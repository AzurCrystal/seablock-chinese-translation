# SeaBlock Chinese Translation

Simplified Chinese translations for the [SeaBlock2](https://github.com/KompetenzAirbag/SeaBlock) modpack,
covering SeaBlock, Angel's mods and related mods.

**Factorio version:** 2.0.72

## 安装

安装脚本分两种模式：

| 模式 | 说明 |
|------|------|
| **默认（仅翻译）** | 只部署 `seablock-translate` 翻译 mod，不下载其他 mod |
| **`--full` / `-Full`** | 从上游下载全部 mod 并部署，适合首次安装或更新 mod 版本 |

### Windows

**依赖：** PowerShell 5.1+（完整安装无需额外工具，PowerShell 内置下载能力）

在 PowerShell 中运行：

```powershell
git clone https://github.com/AzurCrystal/seablock-chinese-translation
cd seablock-chinese-translation

# 仅部署翻译（日常更新）
.\scripts\windows\install.ps1

# 完整安装（首次安装，或需要更新/重新下载 mod 时）
.\scripts\windows\install.ps1 -Full
```

如需手动指定 mods 目录（默认自动检测 `%APPDATA%\Factorio\mods`）：

```powershell
.\scripts\windows\install.ps1 -ModsDir "D:\Factorio\mods"
.\scripts\windows\install.ps1 -Full -ModsDir "D:\Factorio\mods"
```

模拟运行（不实际写入）：

```powershell
.\scripts\windows\install.ps1 -DryRun
.\scripts\windows\install.ps1 -Full -DryRun
```

### Linux（桌面）

**依赖：**
- 仅翻译：`git`、`jq`
- 完整安装：`git`、`jq`、`curl` 或 `wget`、`unzip`

```bash
git clone https://github.com/AzurCrystal/seablock-chinese-translation
cd seablock-chinese-translation

# 仅部署翻译（日常更新）
bash scripts/linux/install.sh

# 完整安装（首次安装，或需要更新/重新下载 mod 时）
bash scripts/linux/install.sh --full
```

如需手动指定 mods 目录（默认自动检测 `~/.factorio/mods`）：

```bash
bash scripts/linux/install.sh --mods-dir ~/.factorio/mods
bash scripts/linux/install.sh --full --mods-dir ~/.factorio/mods
```

### Linux（无头服务器）

通过环境变量或参数指定服务器的 mods 目录：

```bash
git clone https://github.com/AzurCrystal/seablock-chinese-translation
cd seablock-chinese-translation

# 方式一：环境变量（适合 CI / systemd 环境）
FACTORIO_MODS_DIR=/opt/factorio/mods bash scripts/linux/install.sh --full

# 方式二：命令行参数
bash scripts/linux/install.sh --full --mods-dir /opt/factorio/mods
```

脚本自动探测的服务器路径（按优先级）：
- `/opt/factorio/mods`
- `/srv/factorio/mods`
- `/factorio/mods`

下载的文件会缓存在 `download-cache/`，如遇到更新问题，可删除整个文件夹后重新运行完整安装。

## 更新翻译

翻译有更新时，拉取最新代码后运行脚本即可（无需重新下载 mod）：

**Windows：**

```powershell
cd seablock-chinese-translation
git pull
.\scripts\windows\install.ps1
```

**Linux：**

```bash
cd seablock-chinese-translation
git pull
bash scripts/linux/install.sh
```

## 更新 mod 版本

如需同时更新 mod 文件（mods.lock 有变动），使用 `--full`：

**Windows：**

```powershell
cd seablock-chinese-translation
git pull
.\scripts\windows\install.ps1 -Full
```

**Linux：**

```bash
cd seablock-chinese-translation
git pull
bash scripts/linux/install.sh --full
```

已下载的 mod zip 会复用缓存（`download-cache/`），无需重新下载。如遇问题，删除 `download-cache/` 后重新运行脚本。

## 翻译维护工作流

```bash
# 1. 检查上游是否有新 commit（零带宽，仅 git ls-remote）
./scripts/linux/check-updates.sh

# 2. 查看 locale 文件变更（按需拉取 blob，不落盘）
./scripts/linux/diff-upstream.sh <mod-name> [new-sha]

# 3. 确认后更新 mods.lock 中的 pinned_sha
./scripts/linux/update-pin.sh <mod-name> [new-sha]

# 4. 编辑翻译、提交
git add mods.lock locale/zh-CN/
git commit -m "chore: upgrade <mod-name> to <short-sha>"
```

`check-updates.sh` 输出：
- `[OK]` — 已是最新
- `[OK/auto]` — 已是最新，该 mod 标记为 `upstream_only`（直接用上游翻译，无本地文件）
- `[CHANGED]` — 上游有新 commit

## mods.lock

记录每个被跟踪 mod 的上游地址、锁定 SHA 及 locale 文件映射。

- `cache_key`（可选）：多个 Factorio mod 共享同一 git 仓库时，指定 bare clone 目录名；`check-updates.sh` 对相同 URL 只发起一次请求。
- `upstream_only`：直接使用上游翻译，无需本地维护。

## upstream-cache/

bare clone 缓存，已加入 `.gitignore`，可随时删除重建。
