#!/usr/bin/env bash
# install.sh — SeaBlock 模组包一键安装脚本（Linux / macOS / 无头服务器）
# 用法：bash scripts/install.sh [--mods-dir <路径>] [--dry-run]
# 环境变量：FACTORIO_MODS_DIR 可替代 --mods-dir
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODS_LOCK="$REPO_ROOT/mods.lock"
EXTRA_MODS_DIR="$REPO_ROOT/extra-mods"
CACHE_DIR="$REPO_ROOT/download-cache"
MODS_DIR="${FACTORIO_MODS_DIR:-}"
DRY_RUN=false

# ── 颜色输出 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── 参数解析 ────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mods-dir) MODS_DIR="$2"; shift 2 ;;
            --dry-run)  DRY_RUN=true; shift ;;
            -h|--help)
                echo "用法：$0 [--mods-dir <路径>] [--dry-run]"
                echo ""
                echo "  --mods-dir <路径>  指定 Factorio mods 目录（默认自动检测）"
                echo "  --dry-run          模拟运行，不实际写入文件"
                echo ""
                echo "  环境变量：FACTORIO_MODS_DIR  等同于 --mods-dir（适合无头服务器）"
                exit 0 ;;
            *) error "未知参数：$1"; exit 1 ;;
        esac
    done
}

# ── 依赖检查 ────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in unzip jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing+=(wget/curl)
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少必要工具：${missing[*]}"
        error "请先安装后再运行此脚本。"
        exit 1
    fi
}

# ── 检测 Factorio mods 目录 ────────────────────────────────────────────────
detect_mods_dir() {
    if [[ -n "$MODS_DIR" ]]; then
        return
    fi

    local candidates=()
    case "$(uname -s)" in
        Linux)
            local xdg="${XDG_DATA_HOME:-$HOME/.local/share}"
            candidates=(
                "$xdg/factorio/mods"
                "$HOME/.factorio/mods"
                "/opt/factorio/mods"
                "/srv/factorio/mods"
                "/factorio/mods"
            )
            ;;
        Darwin)
            candidates=(
                "$HOME/Library/Application Support/factorio/mods"
            )
            ;;
        *)
            error "不支持的操作系统。Windows 用户请使用 scripts/install.ps1"
            exit 1
            ;;
    esac

    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            MODS_DIR="$dir"
            return
        fi
    done

    error "未找到 Factorio mods 目录。请通过 --mods-dir 手动指定。"
    error "候选路径：${candidates[*]}"
    exit 1
}

# ── 缓存目录管理 ────────────────────────────────────────────────────────────
setup_cache() {
    mkdir -p "$CACHE_DIR"
    # 清理上次中断留下的 .tmp 残留文件
    find "$CACHE_DIR" -name "*.tmp" -delete
}

# ── 下载 GitHub archive zip（同一 cache_key 只下载一次）─────────────────────
# 参数：$1=cache_key  $2=github_url  $3=sha
# 输出：解压后的路径（CACHE_DIR/<cache_key>/<repo>-<sha8>/）
declare -A DOWNLOADED_CACHE  # cache_key -> 解压根目录

download_and_extract() {
    local cache_key="$1"
    local github_url="$2"
    local sha="$3"

    # 已下载则直接返回
    if [[ -n "${DOWNLOADED_CACHE[$cache_key]+x}" ]]; then
        return
    fi

    # 从 URL 提取 owner/repo
    # 支持 https://github.com/owner/repo 和 https://github.com/owner/repo.git
    local repo_path
    repo_path="$(echo "$github_url" | sed 's|https://github.com/||; s|\.git$||')"
    local repo_name
    repo_name="$(basename "$repo_path")"

    local sha8="${sha:0:8}"
    local zip_file="$CACHE_DIR/${cache_key}.zip"
    local zip_tmp="$CACHE_DIR/${cache_key}.zip.tmp"
    local extract_dir="$CACHE_DIR/${cache_key}"
    local download_url="https://github.com/${repo_path}/archive/${sha}.zip"

    info "下载 $cache_key（${sha8}）..."
    if [[ "$DRY_RUN" == false ]]; then
        # 已有完整 zip 缓存则跳过下载
        if [[ -f "$zip_file" ]]; then
            info "已缓存，跳过下载：$cache_key"
        else
            local retries=3
            local success=false
            for ((i=1; i<=retries; i++)); do
                if command -v curl &>/dev/null; then
                    curl -fL --progress-bar -o "$zip_tmp" "$download_url" 2>&1 && success=true && break
                elif command -v wget &>/dev/null; then
                    wget --progress=dot:mega -O "$zip_tmp" "$download_url" 2>&1 && success=true && break
                fi
                warn "下载失败，${i}/${retries}，5 秒后重试..."
                sleep 5
                rm -f "$zip_tmp"
            done
            if [[ "$success" == false ]]; then
                rm -f "$zip_tmp"
                error "下载 $cache_key 失败，请检查网络连接后重新运行脚本。"
                exit 1
            fi
            mv "$zip_tmp" "$zip_file"
        fi

        # 已解压则跳过
        if [[ ! -d "$extract_dir" ]]; then
            mkdir -p "$extract_dir"
            unzip -q "$zip_file" -d "$extract_dir"
        fi
    fi

    # GitHub archive 解压后顶层目录名：<repo>-<sha>
    # 但 GitHub 实际用的是完整 sha，有时截断，找一下实际目录名
    local inner_dir
    if [[ "$DRY_RUN" == false ]]; then
        inner_dir="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"
    else
        inner_dir="$CACHE_DIR/${cache_key}/${repo_name}-${sha}"
    fi

    DOWNLOADED_CACHE[$cache_key]="$inner_dir"
}

# ── 安装一个 mod 目录到 MODS_DIR ────────────────────────────────────────────
# 参数：$1=来源目录  $2=mod 名（用于删除旧版本）
install_mod_dir() {
    local src_dir="$1"
    local mod_name="$2"

    if [[ ! -d "$src_dir" && "$DRY_RUN" == false ]]; then
        error "来源目录不存在：$src_dir"
        return 1
    fi

    # 读取 mod 版本号
    local version
    if [[ "$DRY_RUN" == false ]]; then
        version="$(jq -r '.version' "$src_dir/info.json")"
    else
        version="x.x.x"
    fi

    local dest_name="${mod_name}_${version}"
    local dest_dir="$MODS_DIR/$dest_name"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 将安装 $dest_name → $MODS_DIR/"
        return
    fi

    # 删除同名旧目录（所有版本）
    for old in "$MODS_DIR/${mod_name}_"*/; do
        [[ -d "$old" ]] && rm -rf "$old" && warn "已删除旧版本：$(basename "$old")"
    done

    cp -r "$src_dir" "$dest_dir"
    info "已安装：$dest_name"
}

# ── 处理 mods.lock 中的所有 mod ─────────────────────────────────────────────
install_mods_lock() {
    info "=== 安装 mods.lock 中的 mod ==="

    # 获取所有唯一的 (cache_key, url, sha) 组合并下载
    local -a cache_keys urls shas
    mapfile -t cache_keys < <(jq -r '.mods | to_entries | map(.value) | unique_by(.cache_key) | .[].cache_key' "$MODS_LOCK")
    mapfile -t urls      < <(jq -r '.mods | to_entries | map(.value) | unique_by(.cache_key) | .[].url' "$MODS_LOCK")
    mapfile -t shas      < <(jq -r '.mods | to_entries | map(.value) | unique_by(.cache_key) | .[].pinned_sha' "$MODS_LOCK")

    local i
    for i in "${!cache_keys[@]}"; do
        download_and_extract "${cache_keys[$i]}" "${urls[$i]}" "${shas[$i]}"
    done

    # 逐个 mod 安装
    local mod_names
    mapfile -t mod_names < <(jq -r '.mods | keys[]' "$MODS_LOCK")

    local mod
    for mod in "${mod_names[@]}"; do
        local cache_key inner_dir mod_src_dir

        cache_key="$(jq -r --arg m "$mod" '.mods[$m].cache_key' "$MODS_LOCK")"
        url="$(jq -r --arg m "$mod" '.mods[$m].url' "$MODS_LOCK")"

        # 确定 mod 来源目录：subdir=null 表示仓库根目录，有值则为子目录名
        local subdir mod_src_dir
        subdir="$(jq -r --arg m "$mod" '.mods[$m].subdir // empty' "$MODS_LOCK")"

        inner_dir="${DOWNLOADED_CACHE[$cache_key]:-}"

        if [[ -z "$subdir" ]]; then
            mod_src_dir="$inner_dir"
        else
            mod_src_dir="$inner_dir/$subdir"
        fi

        install_mod_dir "$mod_src_dir" "$mod"
    done
}

# ── 安装 extra-mods/ 中的附加 mod zip ──────────────────────────────────────
install_extra_mods() {
    if [[ ! -d "$EXTRA_MODS_DIR" ]]; then
        return
    fi

    local found=false
    local zip_file
    for zip_file in "$EXTRA_MODS_DIR"/*.zip; do
        [[ -f "$zip_file" ]] || continue
        found=true

        local zip_basename mod_name
        zip_basename="$(basename "$zip_file")"
        # 文件名格式：<modname>_<version>.zip，取第一个 _ 之前的部分作为 mod 名
        mod_name="${zip_basename%%_*}"

        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] 将安装附加 mod：$zip_basename"
            continue
        fi

        # 删除旧版本（zip 和目录形式）
        for old in "$MODS_DIR/${mod_name}_"*.zip "$MODS_DIR/${mod_name}_"*/; do
            [[ -e "$old" ]] && rm -rf "$old" && warn "已删除旧版本：$(basename "$old")"
        done

        cp "$zip_file" "$MODS_DIR/$zip_basename"
        info "已安装：$zip_basename"
    done

    if [[ "$found" == false ]]; then
        info "extra-mods/ 目录为空，跳过附加 mod 安装。"
    fi
}

# ── 安装 seablock-translate 本身 ────────────────────────────────────────────
install_self() {
    info "=== 安装 seablock-translate 翻译 mod ==="

    local version
    version="$(jq -r '.version' "$REPO_ROOT/info.json")"
    local dest_name="seablock-translate_${version}"
    local dest_dir="$MODS_DIR/$dest_name"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] 将安装 $dest_name → $MODS_DIR/"
        return
    fi

    # 删除旧版本
    for old in "$MODS_DIR/seablock-translate_"*/; do
        [[ -d "$old" ]] && rm -rf "$old" && warn "已删除旧版本：$(basename "$old")"
    done

    mkdir -p "$dest_dir"
    cp "$REPO_ROOT/info.json" "$dest_dir/"
    cp -r "$REPO_ROOT/locale" "$dest_dir/"
    for lua_file in "$REPO_ROOT"/*.lua; do
        [[ -f "$lua_file" ]] && cp "$lua_file" "$dest_dir/"
    done
    info "已安装：$dest_name"
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_deps
    detect_mods_dir
    setup_cache

    echo ""
    echo "=============================="
    echo " SeaBlock 模组包安装脚本"
    echo "=============================="
    echo "  mods 目录：$MODS_DIR"
    [[ "$DRY_RUN" == true ]] && echo "  模式：DRY-RUN（不实际写入）"
    echo ""

    install_mods_lock
    echo ""
    install_extra_mods
    echo ""
    install_self

    echo ""
    info "安装完成！请启动 Factorio 并在模组管理器中确认所有 mod 已启用。"
}

main "$@"
