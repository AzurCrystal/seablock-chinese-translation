#!/usr/bin/env bash
# init-cache.sh — 初始化所有 mods.lock 中的上游 bare clone 缓存
#
# 用法: ./scripts/linux/init-cache.sh
#   读取 mods.lock，对每个唯一仓库在 upstream-cache/ 下建立 bare clone。
#   已存在的缓存直接跳过；只拉取 pinned_sha，不下载多余对象。
#
# 完成后即可使用 diff-upstream.sh 等脚本而无需联网初始化。
#
# 依赖: git, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK_FILE="$REPO_ROOT/mods.lock"
CACHE_DIR="$REPO_ROOT/upstream-cache"

if [ ! -f "$LOCK_FILE" ]; then
    echo "ERROR: mods.lock not found at $LOCK_FILE" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"

declare -A seen_keys

ok_count=0
skip_count=0
fail_count=0

# 遍历所有 mod，按 cache_key 去重
while IFS=$'\t' read -r _mod url cache_key branch pinned; do
    # 已处理过该 cache_key 则跳过
    if [ "${seen_keys[$cache_key]+_}" ]; then
        continue
    fi
    seen_keys["$cache_key"]=1

    bare="$CACHE_DIR/${cache_key}.git"

    if [ -d "$bare" ]; then
        echo "[SKIP]  $cache_key — $bare"
        (( skip_count++ )) || true
        continue
    fi

    echo "[CLONE] $cache_key"
    echo "        $url  (branch: $branch)"

    if git clone --bare --filter=blob:none --no-tags \
            --branch "$branch" "$url" "$bare" 2>&1 | sed 's/^/        /'; then
        # 确保 pinned SHA 可达（shallow clone 可能缺旧提交）
        if ! git --git-dir="$bare" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
            echo "        Fetching pinned ${pinned:0:8} ..."
            git --git-dir="$bare" fetch --filter=blob:none --no-tags origin "$pinned" 2>/dev/null || \
            git --git-dir="$bare" fetch --filter=blob:none --no-tags origin 2>/dev/null || true
        fi
        echo "[OK]    $cache_key  (pinned: ${pinned:0:8})"
        (( ok_count++ )) || true
    else
        echo "[FAIL]  $cache_key — git clone failed" >&2
        rm -rf "$bare"
        (( fail_count++ )) || true
    fi
    echo ""
done < <(jq -r '
    .mods | to_entries[] |
    [
        .key,
        .value.url,
        (.value.cache_key // .key),
        .value.upstream_branch,
        .value.pinned_sha
    ] | @tsv
' "$LOCK_FILE")

echo "────────────────────────────────────────────────────────────"
echo "Done.  cloned: $ok_count  skipped: $skip_count  failed: $fail_count"
echo "Cache: $CACHE_DIR"

[ "$fail_count" -eq 0 ] || exit 1
