# SeaBlock Chinese Translation

Simplified Chinese translations for the [SeaBlock2](https://github.com/KompetenzAirbag/SeaBlock) modpack,
covering SeaBlock, Angel's mods and related mods.

**Factorio version:** 2.0.72

## 工作流

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

## 依赖

`git` >= 2.27，`jq`，`diff`

## upstream-cache/

bare clone 缓存，已加入 `.gitignore`，可随时删除重建。
