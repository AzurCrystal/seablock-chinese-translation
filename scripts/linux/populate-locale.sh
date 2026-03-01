#!/usr/bin/env bash
# populate-locale.sh — 从 bare clone 提取英文原文，初始化 zh-CN 翻译文件
#
# 用法: ./scripts/linux/populate-locale.sh [mod-name ...]
#   无参数：处理所有 upstream_only=false 且尚无 zh-CN 文件的 locale 文件
#   有参数：只处理指定 mod
#
# 前提: 先运行 init-cache.sh 建立 upstream-cache/
#
# 说明:
#   - 已存在的 zh-CN 文件不会被覆盖（用 --force 强制覆盖）
#   - 提取的是 pinned_sha 版本的英文原文，作为翻译起点
#
# 依赖: git, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK_FILE="$REPO_ROOT/mods.lock"
CACHE_DIR="$REPO_ROOT/upstream-cache"
LOCALE_DIR="$REPO_ROOT/locale/zh-CN"

FORCE=false
FILTER_MODS=()

for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE=true
    else
        FILTER_MODS+=("$arg")
    fi
done

if [ ! -f "$LOCK_FILE" ]; then
    echo "ERROR: mods.lock not found at $LOCK_FILE" >&2
    exit 1
fi

mkdir -p "$LOCALE_DIR"

ok_count=0
skip_count=0
fail_count=0

# git_show_with_retry <git-dir> <sha> <path>
git_show_with_retry() {
    local git_dir="$1" sha="$2" path="$3"
    local out
    for attempt in 1 2 3; do
        out=$(git --git-dir="$git_dir" show "${sha}:${path}" 2>/dev/null) && {
            printf '%s' "$out"
            return 0
        }
        [ "$attempt" -lt 3 ] && sleep 1
    done
    return 1
}

# 遍历 mods.lock 中所有条目
while IFS=$'\t' read -r mod url cache_key pinned upstream_only; do
    # 过滤：若指定了 mod 列表，只处理匹配项
    if [ "${#FILTER_MODS[@]}" -gt 0 ]; then
        matched=false
        for m in "${FILTER_MODS[@]}"; do
            [ "$m" = "$mod" ] && { matched=true; break; }
        done
        [ "$matched" = "false" ] && continue
    fi

    # 跳过 upstream_only mod
    if [ "$upstream_only" = "true" ]; then
        echo "[SKIP]  $mod — upstream_only"
        continue
    fi

    bare="$CACHE_DIR/${cache_key}.git"
    if [ ! -d "$bare" ]; then
        echo "[ERROR] $mod — bare clone missing: $bare" >&2
        echo "        Run ./scripts/linux/init-cache.sh first." >&2
        (( fail_count++ )) || true
        continue
    fi

    # 读取该 mod 的 locale_files 数组
    while IFS=$'\t' read -r upstream_path local_name; do
        dest="$LOCALE_DIR/$local_name"

        if [ -f "$dest" ] && [ "$FORCE" = "false" ]; then
            echo "[SKIP]  $local_name — already exists"
            (( skip_count++ )) || true
            continue
        fi

        echo -n "[FETCH] $mod  $upstream_path → zh-CN/$local_name ... "

        content=$(git_show_with_retry "$bare" "$pinned" "$upstream_path") || {
            echo "FAIL"
            echo "        ERROR: git show failed for $upstream_path at ${pinned:0:8}" >&2
            (( fail_count++ )) || true
            continue
        }

        printf '%s\n' "$content" > "$dest"
        echo "OK"
        (( ok_count++ )) || true

    done < <(jq -r ".mods[\"$mod\"].locale_files[] | [.upstream, .local] | @tsv" "$LOCK_FILE")

done < <(jq -r '
    .mods | to_entries[] |
    [
        .key,
        .value.url,
        (.value.cache_key // .key),
        .value.pinned_sha,
        .value.upstream_only
    ] | @tsv
' "$LOCK_FILE")

echo ""
echo "────────────────────────────────────────────────────────────"
echo "Done.  created: $ok_count  skipped: $skip_count  failed: $fail_count"
echo "Output: $LOCALE_DIR"
[ "$fail_count" -eq 0 ] || exit 1
