#!/usr/bin/env bash
# diff-upstream.sh — 按需拉取上游 locale 文件，比较两版本差异后丢弃
#
# 用法: ./scripts/diff-upstream.sh <mod-name> [new-sha]
#   <mod-name>: mods.lock 中的 mod 名称
#   [new-sha]:  上游新的 commit SHA（完整或前缀均可）；省略时自动取上游 branch tip
#
# 输出: 每个 locale 文件从 pinned_sha 到 new-sha 的 unified diff
# 不在磁盘写入任何英文 locale 文件。
#
# 依赖: git, jq, diff

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/mods.lock"
CACHE_DIR="$REPO_ROOT/upstream-cache"

usage() {
    echo "Usage: $0 <mod-name> [new-sha]" >&2
    echo "" >&2
    echo "  mod-name  — key in mods.lock" >&2
    echo "  new-sha   — upstream commit SHA to diff against (full or abbreviated)" >&2
    echo "              omit to use current upstream branch tip" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 angelspetrochem" >&2
    echo "  $0 angelspetrochem a3f9c2d1" >&2
    exit 1
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

mod="$1"

if [ ! -f "$LOCK_FILE" ]; then
    echo "ERROR: mods.lock not found at $LOCK_FILE" >&2
    exit 1
fi

url=$(jq -r ".mods[\"$mod\"].url // empty" "$LOCK_FILE")
if [ -z "$url" ]; then
    echo "ERROR: mod '$mod' not found in mods.lock" >&2
    exit 1
fi

branch=$(jq -r ".mods[\"$mod\"].upstream_branch" "$LOCK_FILE")

if [ $# -eq 2 ]; then
    new_sha="$2"
else
    echo "Fetching upstream tip for $mod ($branch) ..." >&2
    new_sha=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | cut -f1)
    if [ -z "$new_sha" ]; then
        echo "ERROR: failed to reach upstream ($url)" >&2
        exit 1
    fi
fi
pinned=$(jq -r ".mods[\"$mod\"].pinned_sha" "$LOCK_FILE")
cache_key=$(jq -r ".mods[\"$mod\"].cache_key // \"$mod\"" "$LOCK_FILE")
upstream_only=$(jq -r ".mods[\"$mod\"].upstream_only" "$LOCK_FILE")

bare="$CACHE_DIR/${cache_key}.git"

DIFF_DIR="$REPO_ROOT/diffs"
mkdir -p "$DIFF_DIR"
out_file="$DIFF_DIR/${mod}-${pinned:0:8}-${new_sha:0:8}.diff"

exec > >(tee "$out_file")

if [ "$upstream_only" = "true" ]; then
    echo "Note: '$mod' is marked upstream_only — upstream translations are used as-is."
    echo ""
fi

echo "Diffing $mod: ${pinned:0:8} → ${new_sha:0:8}"
echo "Upstream: $url ($branch)"
echo ""

# 建立 bare clone（若已存在则跳过）
if [ ! -d "$bare" ]; then
    echo "Cloning bare repo to $bare ..."
    mkdir -p "$CACHE_DIR"
    git clone --bare --filter=blob:none --no-tags \
        --branch "$branch" "$url" "$bare"
fi

# 确保 pinned SHA 可达（bare clone 是 --depth=1，可能不含旧 SHA）
ensure_sha() {
    local sha="$1"
    if ! git --git-dir="$bare" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo "Fetching missing commit ${sha:0:8} ..." >&2
        # 先尝试直接 fetch SHA
        git --git-dir="$bare" fetch --filter=blob:none --no-tags origin "$sha" 2>/dev/null || {
            # 若失败则 unshallow 整个仓库
            echo "Deepening clone to find ${sha:0:8} ..." >&2
            git --git-dir="$bare" fetch --filter=blob:none --no-tags --unshallow origin 2>/dev/null || \
            git --git-dir="$bare" fetch --filter=blob:none --no-tags origin 2>/dev/null || true
        }
    fi
}

ensure_sha "$pinned"
ensure_sha "$new_sha"

# git show 在 filter=blob:none bare clone 中首次调用会触发懒加载，
# 有时因网络时序问题首次失败。包装一层带重试的函数。
git_show_with_retry() {
    local git_dir="$1" sha="$2" path="$3"
    local out
    # 最多重试 3 次
    for attempt in 1 2 3; do
        out=$(git --git-dir="$git_dir" show "${sha}:${path}" 2>/dev/null) && {
            printf '%s' "$out"
            return 0
        }
        [ "$attempt" -lt 3 ] && sleep 1
    done
    return 1  # 所有重试均失败
}

# 对每个 locale 文件做 diff
found_diff=false
while IFS=$'\t' read -r upstream_path local_name; do
    echo "═══════════════════════════════════════════════════════════"
    echo "  File: $upstream_path"
    echo "  Maps to: locale/zh-CN/$local_name"
    echo "═══════════════════════════════════════════════════════════"

    old_exists=true; new_exists=true
    old_content=$(git_show_with_retry "$bare" "$pinned" "$upstream_path") || old_exists=false
    new_content=$(git_show_with_retry "$bare" "$new_sha" "$upstream_path") || new_exists=false

    if [ "$old_exists" = "false" ] && [ "$new_exists" = "false" ]; then
        echo "(file absent in both commits — skipping)"
    elif [ "$old_exists" = "false" ]; then
        echo "(file added in ${new_sha:0:8})"
        found_diff=true
        diff --unified=5 \
            --label "a/${upstream_path} (${pinned:0:8}) [did not exist]" \
            --label "b/${upstream_path} (${new_sha:0:8})" \
            /dev/null \
            <(printf '%s' "$new_content") \
            || true
    elif [ "$new_exists" = "false" ]; then
        echo "(file deleted in ${new_sha:0:8})"
        found_diff=true
        diff --unified=5 \
            --label "a/${upstream_path} (${pinned:0:8})" \
            --label "b/${upstream_path} (${new_sha:0:8}) [deleted]" \
            <(printf '%s' "$old_content") \
            /dev/null \
            || true
    elif [ "$old_content" = "$new_content" ]; then
        echo "(no changes)"
    else
        found_diff=true
        diff --unified=5 \
            --label "a/${upstream_path} (${pinned:0:8})" \
            --label "b/${upstream_path} (${new_sha:0:8})" \
            <(printf '%s' "$old_content") \
            <(printf '%s' "$new_content") \
            || true
    fi
    echo ""
done < <(jq -r ".mods[\"$mod\"].locale_files[] | [.upstream, .local] | @tsv" "$LOCK_FILE")

if [ "$found_diff" = "false" ]; then
    echo "No locale file changes between ${pinned:0:8} and ${new_sha:0:8}."
fi

echo "────────────────────────────────────────────────────────────"
echo "To update the pin after reviewing:"
echo "  ./scripts/update-pin.sh $mod $new_sha"
echo ""
echo "Diff saved to: $out_file"
