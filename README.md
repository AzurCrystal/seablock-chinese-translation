# SeaBlock Chinese Translation

Simplified Chinese translations for the [SeaBlock2](https://github.com/KompetenzAirbag/SeaBlock) modpack,
covering SeaBlock, Angel's mods and related mods.

**Factorio version:** 2.0.72

## 安装

安装脚本会从各上游仓库下载所有 mod，并将本翻译 mod 一并部署到 Factorio mods 目录。

**依赖工具：** `git`、`jq`、`curl` 或 `wget`、`unzip`

### Windows

以管理员身份在 PowerShell 中运行：

```powershell
git clone https://github.com/azurcrystal/seablock-translate
cd seablock-translate
.\scripts\install.ps1
```

如需指定 mods 目录（默认自动检测 `%APPDATA%\Factorio\mods`）：

```powershell
.\scripts\install.ps1 -ModsDir "D:\Factorio\mods"
```

### Linux（桌面）

```bash
git clone https://github.com/azurcrystal/seablock-translate
cd seablock-translate
bash scripts/install.sh
```

如需指定 mods 目录（默认自动检测 `~/.factorio/mods`）：

```bash
bash scripts/install.sh --mods-dir ~/.factorio/mods
```

### Linux（无头服务器）

通过环境变量或参数指定服务器的 mods 目录：

```bash
git clone https://github.com/azurcrystal/seablock-translate
cd seablock-translate

# 方式一：环境变量（适合 CI / systemd 环境）
FACTORIO_MODS_DIR=/opt/factorio/mods bash scripts/install.sh

# 方式二：命令行参数
bash scripts/install.sh --mods-dir /opt/factorio/mods
```

脚本自动探测的服务器路径（按优先级）：
- `/opt/factorio/mods`
- `/srv/factorio/mods`
- `/factorio/mods`

## 翻译维护工作流

```bash
# 1. 检查上游是否有新 commit（零带宽，仅 git ls-remote）
./scripts/check-updates.sh

# 2. 查看 locale 文件变更（按需拉取 blob，不落盘）
./scripts/diff-upstream.sh <mod-name> [new-sha]

# 3. 确认后更新 mods.lock 中的 pinned_sha
./scripts/update-pin.sh <mod-name> [new-sha]

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
