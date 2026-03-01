#!/usr/bin/env bash
# update-pin.sh — 更新 mods.lock 中指定 mod 的 pinned_sha
#
# 用法: ./scripts/update-pin.sh <mod-name> [new-sha]
#   <mod-name>: mods.lock 中的 mod 名称
#   [new-sha]:  要锁定到的新 commit SHA（必须是完整 40 位 SHA）；省略时自动取上游 branch tip
#
# 同一 cache_key 下的所有 mod 共享同一个仓库，若检测到相同 cache_key 的其他
# mod 仍在旧 SHA，脚本会提示一并更新。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/mods.lock"

usage() {
    echo "Usage: $0 <mod-name> [new-sha]" >&2
    echo "" >&2
    echo "  mod-name  — key in mods.lock" >&2
    echo "  new-sha   — full 40-character commit SHA to pin to" >&2
    echo "              omit to use current upstream branch tip" >&2
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

if [ $# -eq 2 ]; then
    new_sha="$2"
    # 验证 SHA 格式（40 位十六进制）
    if ! echo "$new_sha" | grep -qE '^[0-9a-f]{40}$'; then
        echo "ERROR: new-sha must be a full 40-character hex SHA (got: '$new_sha')" >&2
        exit 1
    fi
else
    branch=$(jq -r ".mods[\"$mod\"].upstream_branch" "$LOCK_FILE")
    echo "Fetching upstream tip for $mod ($branch) ..."
    new_sha=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | cut -f1)
    if [ -z "$new_sha" ]; then
        echo "ERROR: failed to reach upstream ($url)" >&2
        exit 1
    fi
    echo "  upstream tip: $new_sha"
    echo ""
fi

old_sha=$(jq -r ".mods[\"$mod\"].pinned_sha" "$LOCK_FILE")
today=$(date +%Y-%m-%d)

if [ "$old_sha" = "$new_sha" ]; then
    echo "Already pinned to $new_sha — nothing to do."
    exit 0
fi

cache_key=$(jq -r ".mods[\"$mod\"].cache_key // \"$mod\"" "$LOCK_FILE")
upstream_only=$(jq -r ".mods[\"$mod\"].upstream_only" "$LOCK_FILE")

if [ "$upstream_only" = "true" ]; then
    echo "Note: '$mod' is marked upstream_only."
    echo "      No local translation file to update — upgrading pin directly."
    echo ""
fi

# 找出共享同一 cache_key 且 pinned_sha 不同的 mod（同仓库其他条目）
mapfile -t siblings < <(
    jq -r --arg ck "$cache_key" --arg me "$mod" --arg new "$new_sha" \
        '.mods | to_entries[]
         | select(.key != $me)
         | select((.value.cache_key // .key) == $ck)
         | select(.value.pinned_sha != $new)
         | .key' \
        "$LOCK_FILE"
)

if [ ${#siblings[@]} -gt 0 ]; then
    echo "The following mods share the same upstream repo (cache_key=$cache_key)"
    echo "and are not yet pinned to $new_sha:"
    for s in "${siblings[@]}"; do
        ssha=$(jq -r ".mods[\"$s\"].pinned_sha" "$LOCK_FILE")
        echo "  - $s (currently ${ssha:0:8})"
    done
    echo ""
    echo "It is recommended to update all of them together."
    echo -n "Update all of the above as well? [Y/n] "
    read -r answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        update_siblings=true
    else
        update_siblings=false
        echo "Updating only '$mod'."
    fi
else
    update_siblings=false
fi

# 构造 jq 更新表达式（用 --arg 传参，避免 mod 名或 SHA 含特殊字符时破坏语法）
jq_args=(--arg new_sha "$new_sha" --arg today "$today" --arg mod "$mod")
jq_expr='.mods[$mod].pinned_sha = $new_sha | .mods[$mod].pinned_at = $today'

if [ "$update_siblings" = "true" ]; then
    for i in "${!siblings[@]}"; do
        s="${siblings[$i]}"
        jq_args+=(--arg "sib${i}" "$s")
        jq_expr+=" | .mods[\$sib${i}].pinned_sha = \$new_sha | .mods[\$sib${i}].pinned_at = \$today"
    done
fi

tmp=$(mktemp)
jq "${jq_args[@]}" "$jq_expr" "$LOCK_FILE" > "$tmp"
mv "$tmp" "$LOCK_FILE"

echo "Updated mods.lock:"
echo "  $mod: ${old_sha:0:8} → ${new_sha:0:8}"
if [ "$update_siblings" = "true" ]; then
    for s in "${siblings[@]}"; do
        echo "  $s: also updated to ${new_sha:0:8}"
    done
fi
echo ""
echo "Next steps:"
echo "  1. Update translations in locale/zh-CN/ if needed"
echo "  2. git add mods.lock locale/zh-CN/"
echo "  3. git commit -m \"chore: upgrade $mod to ${new_sha:0:8}\""
