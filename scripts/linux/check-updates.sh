#!/usr/bin/env bash
# check-updates.sh — 零带宽检测上游 locale 是否有新 commit
#
# 用法: ./scripts/check-updates.sh [mod-name ...]
#   不带参数: 检查 mods.lock 中所有 mod
#   带参数:   只检查指定的 mod
#
# 依赖: git, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK_FILE="$REPO_ROOT/mods.lock"

if [ ! -f "$LOCK_FILE" ]; then
    echo "ERROR: mods.lock not found at $LOCK_FILE" >&2
    exit 1
fi

# 获取要检查的 mod 列表
if [ $# -gt 0 ]; then
    mods=("$@")
else
    mapfile -t mods < <(jq -r '.mods | keys[]' "$LOCK_FILE")
fi

# 缓存 "url::branch" -> tip SHA（避免对同一远端重复发起请求）
declare -A tip_cache

ok_count=0
changed_count=0
error_count=0

for mod in "${mods[@]}"; do
    url=$(jq -r ".mods[\"$mod\"].url // empty" "$LOCK_FILE")
    if [ -z "$url" ]; then
        echo "[ERROR]   $mod — not found in mods.lock" >&2
        (( error_count++ )) || true
        continue
    fi

    branch=$(jq -r ".mods[\"$mod\"].upstream_branch" "$LOCK_FILE")
    pinned=$(jq -r ".mods[\"$mod\"].pinned_sha" "$LOCK_FILE")
    upstream_only=$(jq -r ".mods[\"$mod\"].upstream_only" "$LOCK_FILE")

    cache_key="${url}::${branch}"
    if [ -z "${tip_cache[$cache_key]+x}" ]; then
        current=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | cut -f1)
        tip_cache[$cache_key]="${current:-ERROR}"
    fi
    current="${tip_cache[$cache_key]}"

    if [ "$current" = "ERROR" ]; then
        printf "[ERROR]   %-40s — failed to reach remote\n" "$mod" >&2
        (( error_count++ )) || true
    elif [ "$current" = "$pinned" ]; then
        if [ "$upstream_only" = "true" ]; then
            printf "[OK/auto] %-40s @ %s  (upstream-only)\n" "$mod" "${pinned:0:8}"
        else
            printf "[OK]      %-40s @ %s\n" "$mod" "${pinned:0:8}"
        fi
        (( ok_count++ )) || true
    else
        if [ "$upstream_only" = "true" ]; then
            printf "[CHANGED] %-40s  pinned=%-8s  upstream=%-8s  (upstream-only, safe to auto-upgrade)\n" \
                "$mod" "${pinned:0:8}" "${current:0:8}"
        else
            printf "[CHANGED] %-40s  pinned=%-8s  upstream=%-8s\n" \
                "$mod" "${pinned:0:8}" "${current:0:8}"
        fi
        (( changed_count++ )) || true
    fi
done

echo ""
echo "Summary: ${ok_count} up-to-date, ${changed_count} changed, ${error_count} errors"

if [ "$changed_count" -gt 0 ]; then
    echo ""
    echo "To inspect changes for a mod:"
    echo "  ./scripts/linux/diff-upstream.sh <mod-name> <new-sha>"
    echo ""
    echo "To update the pin after reviewing:"
    echo "  ./scripts/linux/update-pin.sh <mod-name> <new-sha>"
fi
