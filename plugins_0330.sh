#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
WORKDIR="${TMPDIR:-/tmp}/NRadio_plugin"
BACKUP_DIR="$SCRIPT_DIR/.backup"
CFG="/etc/config/appcenter"
TPL="/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm"
FEEDS="/etc/opkg/distfeeds.conf"
OPENCLASH_LOGSH="/usr/share/openclash/log.sh"
OPENCLASH_FIX_BACKUP_DIR="/root/openclash-appcenter-fix"
OPENCLASH_BRANCH="${OPENCLASH_BRANCH:-master}"
OPENCLASH_MIRRORS="${OPENCLASH_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://fastly.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH}}"
OPENCLASH_CORE_VERSION_MIRRORS="${OPENCLASH_CORE_VERSION_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev}"
OPENCLASH_CORE_SMART_MIRRORS="${OPENCLASH_CORE_SMART_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart}"
KMS_CORE_VERSION="${KMS_CORE_VERSION:-svn1113-1}"
KMS_CORE_IPK_BASE_URL="${KMS_CORE_IPK_BASE_URL:-https://raw.githubusercontent.com/cokebar/openwrt-vlmcsd/gh-pages}"
KMS_LUCI_IPK_URL="${KMS_LUCI_IPK_URL:-https://github.com/cokebar/luci-app-vlmcsd/releases/download/v1.0.2-1/luci-app-vlmcsd_1.0.2-1_all.ipk}"

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

confirm_or_exit() {
    prompt="${1:-确认继续吗？}"
    printf '%s [Y/n]: ' "$prompt"
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) die 'user cancelled' ;;
    esac
}

confirm_default_yes() {
    prompt="${1:-确认继续吗？}"
    printf '%s [Y/n]: ' "$prompt"
    read -r answer
    case "$answer" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

backup_file() {
    target="$1"
    [ -e "$target" ] || return 0
    mkdir -p "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    safe_name="$(printf '%s' "$target" | sed 's#/#_#g')"
    cp -f "$target" "$BACKUP_DIR/${safe_name}.${stamp}.bak"
}

require_root() {
    [ "$(id -u)" = "0" ] || die 'please run as root'
}

require_file() {
    [ -f "$1" ] || die "missing file: $1"
}

ensure_default_feeds() {
    [ -f "$FEEDS" ] || return 0

    mkdir -p "$WORKDIR"
    feeds_tmp="$WORKDIR/distfeeds.default"

    cat > "$feeds_tmp" <<'EOF'
# Unsupported vendor target feeds disabled
# src/gz openwrt_core https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/targets/mediatek/mt7987/packages
src/gz openwrt_base https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/base
src/gz openwrt_luci https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/luci
# Vendor private feed unavailable on Tsinghua mirror
# src/gz openwrt_mtk_openwrt_feed https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/mtk_openwrt_feed
src/gz openwrt_packages https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/packages
src/gz openwrt_routing https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/routing
src/gz openwrt_telephony https://mirrors.tuna.tsinghua.edu.cn/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/telephony
EOF

    if ! cmp -s "$feeds_tmp" "$FEEDS"; then
        log 'tip: switching opkg feeds to Tsinghua mirror defaults...'
        backup_file "$FEEDS"
        cp "$feeds_tmp" "$FEEDS"
    fi
}

require_safe_uci_value() {
    value_name="$1"
    value="$2"

    case "$value" in
        *"
"*|*"'"*)
            die "unsafe $value_name for uci set"
            ;;
    esac
}

download_with_tool() {
    url="$1"
    dest="$2"

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -O "$dest" "$url"
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
        return
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$dest" "$url"
        return
    fi

    die 'no supported download tool found (uclient-fetch/wget/curl)'
}

download_from_mirrors() {
    file_name="$1"
    out="$2"
    base_list="${3:-$OPENCLASH_MIRRORS}"

    for base_url in $base_list; do
        [ -n "$base_url" ] || continue
        if download_with_tool "$base_url/$file_name" "$out" >/dev/null 2>&1; then
            printf '%s\n' "$base_url"
            return 0
        fi
    done

    return 1
}

ensure_opkg_update() {
    ensure_default_feeds
    log 'tip: running opkg update...'
    opkg update >/tmp/NRadio_plugin-opkg-update.log 2>&1 || {
        sed -n '1,120p' /tmp/NRadio_plugin-opkg-update.log >&2
        die 'opkg update failed'
    }
}

find_package_url() {
    pkg_name="$1"

    awk -v pkg="$pkg_name" '
        $0 == "Package: " pkg { found=1; next }
        found && /^Filename: / {
            sub(/^Filename: /, "", $0)
            print
            exit
        }
        found && /^$/ { found=0 }
    ' /var/opkg-lists/* 2>/dev/null | head -n 1
}

get_package_filename_and_feed_from_lists() {
    pkg_name="$1"

    awk -v pkg="$pkg_name" '
        FNR == 1 {
            feed = FILENAME
            sub(/^.*\//, "", feed)
        }
        $0 == "Package: " pkg { found=1; next }
        found && /^Filename: / {
            sub(/^Filename: /, "", $0)
            print feed "|" $0
            exit
        }
        found && /^$/ { found=0 }
    ' /var/opkg-lists/* 2>/dev/null | head -n 1
}

get_feed_url() {
    feed_name="$1"
    awk -v n="$feed_name" '$1=="src/gz" && $2==n {print $3; exit}' "$FEEDS" 2>/dev/null
}

get_feed_package_field() {
    feed_name="$1"
    package_name="$2"
    field_name="$3"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1

    mkdir -p "$WORKDIR/feed-index"
    feed_idx="$WORKDIR/feed-index/${feed_name}.Packages.gz"
    download_with_tool "$feed_url/Packages.gz" "$feed_idx" >/dev/null 2>&1 || return 1

    gzip -dc "$feed_idx" 2>/dev/null | awk -v pkg="$package_name" -v fld="$field_name" '
        $0 == ("Package: " pkg) { found = 1; next }
        found && index($0, fld ": ") == 1 {
            sub("^" fld ": ", "")
            print
            exit
        }
        found && $0 == "" { exit }
    '
}

resolve_feed_package_url() {
    feed_name="$1"
    package_name="$2"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1
    filename="$(get_feed_package_field "$feed_name" "$package_name" Filename)"
    [ -n "$filename" ] || return 1
    printf '%s/%s\n' "$feed_url" "$filename"
}

resolve_package_url_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        url="$(resolve_feed_package_url "$feed_name" "$package_name" 2>/dev/null || true)"
        if [ -n "$url" ]; then
            printf '%s\n' "$url"
            return 0
        fi
    done

    return 1
}

resolve_package_download_url() {
    package_name="$1"

    url="$(resolve_package_url_any_feed "$package_name" 2>/dev/null || true)"
    if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi

    info="$(get_package_filename_and_feed_from_lists "$package_name" 2>/dev/null || true)"
    [ -n "$info" ] || return 1

    feed_name="${info%%|*}"
    filename="${info#*|}"
    [ -n "$feed_name" ] || return 1
    [ -n "$filename" ] || return 1

    feed_url="$(get_feed_url "$feed_name" 2>/dev/null || true)"
    [ -n "$feed_url" ] || return 1

    case "$filename" in
        http://*|https://*) printf '%s\n' "$filename" ;;
        *) printf '%s/%s\n' "${feed_url%/}" "${filename#./}" ;;
    esac
}

resolve_package_version_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        ver="$(get_feed_package_field "$feed_name" "$package_name" Version 2>/dev/null || true)"
        if [ -n "$ver" ]; then
            printf '%s\n' "$ver"
            return 0
        fi
    done

    return 1
}

download_url_to_file_or_die() {
    url="$1"
    dest="$2"
    label="$3"

    [ -n "$url" ] || die "missing download url for $label"
    log "tip: downloading $label..."
    download_with_tool "$url" "$dest"
    [ -s "$dest" ] || die "$label download failed"
}

download_feed_package_or_die() {
    package_name="$1"
    dest="$2"
    label="${3:-$package_name}"

    pkg_url="$(resolve_package_download_url "$package_name" 2>/dev/null || true)"
    [ -n "$pkg_url" ] || die "failed to resolve $package_name package from feeds"
    download_url_to_file_or_die "$pkg_url" "$dest" "$label"
}

get_installed_or_feed_version() {
    package_name="$1"
    fallback="${2:-}"

    ver="$(opkg status "$package_name" 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$ver" ] || ver="$(resolve_package_version_any_feed "$package_name" 2>/dev/null || true)"
    [ -n "$ver" ] || ver="$fallback"
    [ -n "$ver" ] || ver='unknown'
    printf '%s\n' "$ver"
}



ensure_packages() {
    missing=""
    for pkg in "$@"; do
        opkg status "$pkg" >/dev/null 2>&1 && continue
        opkg install "$pkg" >/tmp/NRadio_plugin-extra-install.log 2>&1 || missing="$missing $pkg"
    done

    if [ -n "$missing" ]; then
        log "warn: optional packages install failed:$missing"
    fi
}

ensure_required_packages() {
    missing=""
    for pkg in "$@"; do
        opkg status "$pkg" >/dev/null 2>&1 && continue
        if ! opkg install "$pkg" >/tmp/NRadio_plugin-extra-install.log 2>&1; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        sed -n '1,160p' /tmp/NRadio_plugin-extra-install.log >&2
        die "required packages install failed:$missing"
    fi
}

extract_ipk_archive() {
    ipk="$1"
    out_dir="$2"
    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    if tar -xzf "$ipk" -C "$out_dir" >/dev/null 2>&1 && [ -f "$out_dir/data.tar.gz" ] && [ -f "$out_dir/control.tar.gz" ]; then
        return 0
    fi

    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    if command -v ar >/dev/null 2>&1; then
        (cd "$out_dir" && ar x "$ipk" >/dev/null 2>&1) || true
    else
        (cd "$out_dir" && busybox ar x "$ipk" >/dev/null 2>&1) || true
    fi

    [ -f "$out_dir/data.tar.gz" ] && [ -f "$out_dir/control.tar.gz" ] || die "failed to extract ipk: $ipk"
}

install_ipk_file() {
    ipk="$1"
    label="$2"
    opkg install "$ipk" --force-reinstall >/tmp/NRadio_plugin-install.log 2>&1 || {
        opkg install "$ipk" --force-reinstall --force-depends >/tmp/NRadio_plugin-install.log 2>&1 || {
            sed -n '1,160p' /tmp/NRadio_plugin-install.log >&2
            die "$label install failed"
        }
    }
}

install_ipk_file_force_overwrite() {
    ipk="$1"
    label="$2"
    opkg install "$ipk" --force-reinstall --force-overwrite >/tmp/NRadio_plugin-install.log 2>&1 || {
        opkg install "$ipk" --force-reinstall --force-depends --force-overwrite >/tmp/NRadio_plugin-install.log 2>&1 || {
            sed -n '1,200p' /tmp/NRadio_plugin-install.log >&2
            die "$label install failed"
        }
    }
}

rebuild_ipk_without_dep() {
    src_ipk="$1"
    out_ipk="$2"
    dep_name="$3"
    work_name="${4:-ipk-repack}"

    pkg_dir="$WORKDIR/$work_name/pkg"
    ctrl_dir="$WORKDIR/$work_name/control"

    extract_ipk_archive "$src_ipk" "$pkg_dir"
    [ -f "$pkg_dir/control.tar.gz" ] || die "package missing control.tar.gz: $src_ipk"

    rm -rf "$ctrl_dir"
    mkdir -p "$ctrl_dir"
    tar -xzf "$pkg_dir/control.tar.gz" -C "$ctrl_dir" >/dev/null 2>&1 || die "failed to unpack control archive: $src_ipk"
    [ -f "$ctrl_dir/control" ] || die "package control file missing: $src_ipk"

    awk -v dep="$dep_name" '
        function trim(s) {
            sub(/^[ \t]+/, "", s)
            sub(/[ \t]+$/, "", s)
            return s
        }
        function normalize_dep(s) {
            s = trim(s)
            sub(/^\+/, "", s)
            sub(/ .*/, "", s)
            return s
        }
        BEGIN {
            dep_line = ""
        }
        /^Depends:[[:space:]]*/ {
            dep_line = substr($0, index($0, ":") + 1)
            split(dep_line, arr, ",")
            out = ""
            for (i = 1; i <= length(arr); i++) {
                item = trim(arr[i])
                if (item == "")
                    continue
                if (normalize_dep(item) == dep)
                    continue
                out = (out == "" ? item : out ", " item)
            }
            print "Depends: " out
            next
        }
        { print }
    ' "$ctrl_dir/control" > "$ctrl_dir/control.new" || die "failed to rewrite package dependencies: $src_ipk"
    mv -f "$ctrl_dir/control.new" "$ctrl_dir/control"

    tar -czf "$pkg_dir/control.tar.gz" -C "$ctrl_dir" . >/dev/null 2>&1 || die "failed to rebuild control archive: $src_ipk"
    rm -f "$out_ipk"
    pack_ok=0
    if command -v ar >/dev/null 2>&1; then
        if (cd "$pkg_dir" && ar rc "$out_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz) >/dev/null 2>&1; then
            pack_ok=1
        fi
    fi
    if [ "$pack_ok" = 0 ] && command -v busybox >/dev/null 2>&1; then
        if (cd "$pkg_dir" && busybox ar rc "$out_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz) >/dev/null 2>&1; then
            pack_ok=1
        fi
    fi
    if [ "$pack_ok" = 0 ]; then
        log "warn: ar packaging unavailable, fallback to tar-style compatibility package"
        (cd "$pkg_dir" && tar -czf "$out_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz) >/dev/null 2>&1 || die "failed to rebuild package: $src_ipk"
    fi
    [ -s "$out_ipk" ] || die "failed to rebuild package: $src_ipk"
}

ensure_ttyd_uci_config() {
    [ -f /etc/config/ttyd ] || {
        mkdir -p /etc/config
        : > /etc/config/ttyd
    }

    if ! uci -q get ttyd.@ttyd[0] >/dev/null 2>&1; then
        backup_file /etc/config/ttyd
        sec="$(uci -q add ttyd ttyd 2>/dev/null || true)"
        [ -n "$sec" ] || sec='@ttyd[0]'
        uci -q set ttyd."$sec".enable='1' >/dev/null 2>&1 || true
        uci -q set ttyd."$sec".interface='@lan' >/dev/null 2>&1 || true
        uci -q set ttyd."$sec".command='/bin/login' >/dev/null 2>&1 || true
        uci -q commit ttyd >/dev/null 2>&1 || true
    fi
}

write_ttyd_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/ttyd

    cat > /usr/lib/lua/luci/controller/ttyd.lua <<'EOF'
module("luci.controller.ttyd", package.seeall)
local dispatcher = require "luci.dispatcher"

function index()
    local page = entry({"admin", "services", "ttyd"}, alias("admin", "services", "ttyd", "ttyd"), _("ttyd"), 15)
    page.dependent = true
    entry({"admin", "services", "ttyd", "ttyd"}, template("ttyd/oem_terminal"), _("Terminal"), 1).leaf = true
    entry({"admin", "services", "ttyd", "config"}, template("ttyd/oem_config"), _("Config"), 2).leaf = true
    entry({"admin", "services", "ttyd", "restart"}, call("restart")).leaf = true
end

function restart()
    local http = require "luci.http"
    os.execute("( /etc/init.d/ttyd restart >/dev/null 2>&1 || /etc/init.d/ttyd start >/dev/null 2>&1 ) &")
    http.redirect(dispatcher.build_url("admin", "services", "ttyd", "ttyd"))
end
EOF

    cat > /usr/lib/lua/luci/view/ttyd/oem_terminal.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local port = uci:get("ttyd", "@ttyd[0]", "port") or "7681"
local is_embed = (http.formvalue("appcenter") == "1")
%>
<% if not is_embed then %><%+header%><% end %>
<style>
    .ttyd-shell { width: 100%; max-width: none; margin: 0; color: #10233a; }
    .ttyd-frame-wrap { position: relative; overflow: hidden; border: 1px solid #d6e3f5; border-radius: 22px; background: linear-gradient(180deg, #0f172a 0%, #111827 100%); box-shadow: 0 22px 40px rgba(15, 23, 42, 0.16); }
    .ttyd-frame-top { display: flex; align-items: center; justify-content: flex-start; gap: 12px; padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,.08); background: linear-gradient(90deg, rgba(2,6,23,.88), rgba(15,23,42,.88)); color: #dbeafe; }
    .ttyd-frame-dots { display: inline-flex; gap: 6px; }
    .ttyd-frame-dots i { width: 10px; height: 10px; border-radius: 999px; display: inline-block; }
    .ttyd-frame-dots i:nth-child(1) { background: #fb7185; }
    .ttyd-frame-dots i:nth-child(2) { background: #fbbf24; }
    .ttyd-frame-dots i:nth-child(3) { background: #34d399; }
    .ttyd-frame { display: block; width: 100%; min-height: 76vh; border: 0; background: #0b1120; }
<% if is_embed then %>
    html, body { height: 100%; }
    body { margin: 0; overflow: hidden; }
    .ttyd-shell { height: calc(100vh - 4px); }
    .ttyd-frame-wrap { display: flex; flex-direction: column; height: calc(100vh - 4px); }
    .ttyd-frame { flex: 1 1 auto; min-height: 0; height: calc(100vh - 48px); }
<% end %>
</style>
<div class="cbi-map ttyd-shell">
    <div class="ttyd-frame-wrap">
        <div class="ttyd-frame-top">
            <div class="ttyd-frame-dots"><i></i><i></i><i></i></div>
        </div>
        <iframe id="ttyd_frame" class="ttyd-frame" src="about:blank"></iframe>
    </div>
</div>
<script>
function getTtydUrl() {
    var proto = (window.location.protocol === 'https:') ? 'https://' : 'http://';
    return proto + window.location.hostname + ':<%=port%>/';
}
function loadTtydFrame() {
    var frame = document.getElementById('ttyd_frame');
    if (frame) frame.src = getTtydUrl();
}
function openTtydWindow() {
    window.open(getTtydUrl(), '_blank');
}
loadTtydFrame();
</script>
<% if not is_embed then %><%+footer%><% end %>
EOF

    cat > /usr/lib/lua/luci/view/ttyd/oem_config.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local http = require "luci.http"
local port = uci:get("ttyd", "@ttyd[0]", "port") or "7681"
local interface = uci:get("ttyd", "@ttyd[0]", "interface") or "@lan"
local command = uci:get("ttyd", "@ttyd[0]", "command") or "/bin/login"
local enable = uci:get("ttyd", "@ttyd[0]", "enable") or "1"
local debug = util.trim(util.exec("sed -n '1,120p' /etc/config/ttyd 2>/dev/null || true"))
local is_embed = (http.formvalue("appcenter") == "1")
%>
<% if not is_embed then %><%+header%><% end %>
<style>
    .ttyd-shell { width: 100%; max-width: none; margin: 0 0 20px; color: #10233a; }
    .ttyd-hero { position: relative; overflow: hidden; margin: 12px 0 16px; padding: 24px 24px 20px; border: 1px solid #d6e3f5; border-radius: 22px; background: radial-gradient(circle at top right, rgba(14, 165, 233, 0.18), rgba(14, 165, 233, 0) 34%), radial-gradient(circle at left 20%, rgba(37, 99, 235, 0.14), rgba(37, 99, 235, 0) 28%), linear-gradient(135deg, #f6fbff 0%, #ffffff 48%, #f7fbff 100%); box-shadow: 0 18px 44px rgba(15, 23, 42, 0.08); }
    .ttyd-hero:before { content: ""; position: absolute; right: -48px; top: -48px; width: 180px; height: 180px; border-radius: 999px; background: radial-gradient(circle, rgba(59, 130, 246, 0.22) 0%, rgba(59, 130, 246, 0) 72%); }
    .ttyd-toolbar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 10px; }
    .ttyd-pill { display: inline-flex; align-items: center; padding: 5px 12px; border-radius: 999px; background: #ebf5ff; color: #175cd3; font-size: 12px; font-weight: 700; letter-spacing: .03em; }
    .ttyd-title { margin: 0; font-size: 28px; line-height: 1.15; color: #0f172a; }
    .ttyd-sub { margin: 8px 0 0; max-width: 760px; color: #5f6f82; line-height: 1.75; }
    .ttyd-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px; margin-bottom: 16px; }
    .ttyd-metric { padding: 16px 18px; border: 1px solid #e5edf7; border-radius: 18px; background: linear-gradient(180deg, #ffffff 0%, #f9fcff 100%); box-shadow: 0 8px 18px rgba(15, 23, 42, 0.04); }
    .ttyd-metric-label { display: block; color: #738298; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; margin-bottom: 8px; }
    .ttyd-metric-value { display: block; color: #0f172a; font-size: 18px; font-weight: 700; word-break: break-all; }
    .ttyd-card { margin-bottom: 16px; padding: 18px; border: 1px solid #dbe8f6; border-radius: 20px; background: linear-gradient(180deg, #ffffff 0%, #f8fbff 100%); box-shadow: 0 12px 28px rgba(15, 23, 42, 0.05); }
    .ttyd-card-title { margin: 0 0 10px; font-size: 16px; font-weight: 700; color: #0f172a; }
    .ttyd-note { margin: 0; color: #64748b; line-height: 1.7; }
    .ttyd-pre { margin-top: 12px; padding: 14px 16px; border-radius: 16px; background: #0f172a; color: #dbeafe; white-space: pre-wrap; word-break: break-word; font-family: Menlo, Consolas, monospace; font-size: 12px; line-height: 1.6; }
</style>
<div class="cbi-map ttyd-shell">
    <div class="ttyd-hero">
        <div class="ttyd-toolbar"><span class="ttyd-pill">NROS Service Profile</span></div>
        <h2 class="ttyd-title" name="content">ttyd 配置概览</h2>
        <p class="ttyd-sub">保留鲲鹏 NROS 风格的浅色科技仪表板布局，把核心运行参数和配置文件内容汇总到一个页面里，便于排查和快速确认服务状态。</p>
    </div>
    <div class="ttyd-grid">
        <div class="ttyd-metric"><span class="ttyd-metric-label">Enabled</span><span class="ttyd-metric-value"><%=pcdata(enable)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Port</span><span class="ttyd-metric-value"><%=pcdata(port)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Interface</span><span class="ttyd-metric-value"><%=pcdata(interface)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Command</span><span class="ttyd-metric-value"><%=pcdata(command)%></span></div>
    </div>
    <div class="ttyd-card">
        <div class="ttyd-card-title">兼容说明</div>
        <p class="ttyd-note">当前固件的 LuCI 与官方 ttyd 新版页面结构不兼容时，这里会显示兼容摘要页。需要更细的配置时，可以直接编辑 <code>/etc/config/ttyd</code>。</p>
    </div>
    <div class="ttyd-card">
        <div class="ttyd-card-title">/etc/config/ttyd</div>
        <div class="ttyd-pre"><%=pcdata(debug ~= "" and debug or "no config")%></div>
    </div>
</div>
<% if not is_embed then %><%+footer%><% end %>
EOF
}

find_uci_section() {
    sec_type="$1"
    pkg_name="$2"

    uci show appcenter 2>/dev/null | awk -v st="$sec_type" -v n="$pkg_name" '
        $0 ~ ("^appcenter\\.@" st "\\[[0-9]+\\]=" st "$") {
            line = $0
            sub(/^appcenter\./, "", line)
            sub(/=.*/, "", line)
            sec = line
            next
        }
        sec != "" && $0 == ("appcenter." sec ".name='\''" n "'\''") {
            print sec
            exit
        }
    '
}

cleanup_appcenter_route_entries() {
    target_route="$1"

    uci show appcenter 2>/dev/null | awk -v route="$target_route" '
        /^appcenter\.@package_list\[[0-9]+\]=package_list$/ {
            sec=$1
            sub(/^appcenter\./, "", sec)
            sub(/=.*/, "", sec)
            current=sec
            next
        }
        current != "" && $0 == ("appcenter." current ".luci_module_route='"'"'" route "'"'"'") {
            print current
            current=""
        }
    ' | while IFS= read -r list_sec; do
        [ -n "$list_sec" ] || continue
        old_name="$(uci -q get "appcenter.$list_sec.name" 2>/dev/null || true)"
        if [ -n "$old_name" ]; then
            pkg_sec="$(find_uci_section package "$old_name")"
            [ -n "$pkg_sec" ] && uci delete "appcenter.$pkg_sec" >/dev/null 2>&1 || true
        fi
        uci delete "appcenter.$list_sec" >/dev/null 2>&1 || true
    done
}

set_appcenter_entry() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller_file="$5"
    route="$6"

    require_safe_uci_value "plugin name" "$plugin_name"
    require_safe_uci_value "package name" "$pkg_name"
    require_safe_uci_value "version" "$version"
    require_safe_uci_value "size" "$size"
    require_safe_uci_value "controller file" "$controller_file"
    require_safe_uci_value "route" "$route"

    cleanup_appcenter_route_entries "$route"

    pkg_sec="$(find_uci_section package "$plugin_name")"
    [ -n "$pkg_sec" ] || pkg_sec="$(uci add appcenter package)"

    list_sec="$(find_uci_section package_list "$plugin_name")"
    [ -n "$list_sec" ] || list_sec="$(uci add appcenter package_list)"

    uci set "appcenter.$pkg_sec.name=$plugin_name"
    uci set "appcenter.$pkg_sec.version=$version"
    uci set "appcenter.$pkg_sec.size=$size"
    uci set "appcenter.$pkg_sec.status=1"
    uci set "appcenter.$pkg_sec.has_luci=1"
    uci set "appcenter.$pkg_sec.open=1"

    uci set "appcenter.$list_sec.name=$plugin_name"
    uci set "appcenter.$list_sec.pkg_name=$pkg_name"
    uci set "appcenter.$list_sec.parent=$plugin_name"
    uci set "appcenter.$list_sec.size=$size"
    uci set "appcenter.$list_sec.luci_module_file=$controller_file"
    uci set "appcenter.$list_sec.luci_module_route=$route"
    uci set "appcenter.$list_sec.version=$version"
    uci set "appcenter.$list_sec.has_luci=1"
    uci set "appcenter.$list_sec.type=1"
}

register_appcenter_plugin() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller_file="$5"
    route="$6"

    backup_file "$CFG"
    set_appcenter_entry "$plugin_name" "$pkg_name" "$version" "$size" "$controller_file" "$route"
    uci commit appcenter

    patch_appcenter_template
    refresh_luci_appcenter
    verify_appcenter_route "$plugin_name" "$route"
}

write_appcenter_dialog_css() {
    cat <<'EOF'
    .modal.app_frame .modal-dialog{
        width: calc(100vw - 64px);
        max-width: 1560px;
        margin: 28px auto;
    }
    .modal.app_frame .app_frame_box{
        width: 100%;
        max-width: 1500px;
        margin: 0 auto;
    }
    .modal.app_frame.app_frame_openclash .app_frame_box iframe{
        height: calc(100vh - 172px);
        min-height: 720px;
    }
    .modal.app_frame .app_frame_nav{
        display: flex;
        flex-wrap: wrap;
        gap: 10px;
        padding: 0 15px 12px;
        border-bottom: 1px solid #e5e5e5;
    }
    .modal.app_frame .app_frame_nav_item{
        display: inline-block;
        padding: 6px 10px;
        color: #666;
        cursor: pointer;
        border-bottom: 2px solid transparent;
    }
    .modal.app_frame .app_frame_nav_item_active{
        color: #0088cc;
        border-bottom-color: #0088cc;
    }
    .modal.app_frame .app_frame_box iframe{
        height: 80vh;
        overflow: auto;
        border: 0;
        width: 100%;
        background: #fff;
        transition: opacity .12s ease;
    }
    .modal.app_frame .app_frame_box iframe.app_frame_iframe_pending{
        visibility: hidden;
        opacity: 0;
        pointer-events: none;
    }
    @media (max-width: 991px){
        .modal.app_frame .modal-dialog,
        .modal.app_frame.app_frame_openclash .modal-dialog{
            width: calc(100vw - 24px);
            margin: 12px auto;
        }
        .modal.app_frame .app_frame_nav{
            padding: 0 10px 10px;
        }
        .modal.app_frame.app_frame_openclash .app_frame_box iframe{
            height: calc(100vh - 132px);
            min-height: 0;
        }
        .modal.app_frame .app_frame_box iframe{
            height: 74vh;
        }
    }
EOF
}

write_appcenter_runtime_js() {
    cat <<'EOF'
    function get_active_app_modal(){
        return $('.modal.app_frame.in:visible').last();
    }
    function get_target_frame(frame){
        if(frame && frame.length)
            return frame;
        var modal = get_active_app_modal();
        if(modal.length){
            frame = modal.find('#sub_frame');
            if(frame.length)
                return frame;
        }
        return $('#sub_frame').last();
    }
    function reload_iframe(frame){
        var target_frame = get_target_frame(frame);
        if(!target_frame.length)
            return;

        try {
            var frame_node = target_frame.get(0);
            if (!frame_node || !frame_node.src)
                return;

            if (frame_node.src.indexOf('/admin/services/openclash') !== -1 || frame_node.src.indexOf('/admin/services/vlmcsd') !== -1 || frame_node.src.indexOf('/admin/services/ttyd') !== -1) {
                var d = frame_node.contentWindow.document;
                if (d && d.head) {
                    var is_openclash_page = frame_node.src.indexOf('/admin/services/openclash') !== -1;
                    var is_ttyd_page = frame_node.src.indexOf('/admin/services/ttyd') !== -1;
                    if (is_openclash_page && d.body) {
                        d.body.classList.add('appcenter-openclash');
                        Array.prototype.forEach.call(d.querySelectorAll('.main'), function(node){
                            if (!node.classList.contains('openclash-main'))
                                node.classList.add('openclash-main');
                        });
                    }
                    var style_id = is_openclash_page ? 'appcenter_openclash_embed_style' : (is_ttyd_page ? 'appcenter_ttyd_embed_style' : 'appcenter_default_embed_style');
                    var style_node = d.getElementById(style_id);
                    if (!style_node) {
                        style_node = d.createElement('style');
                        style_node.type = 'text/css';
                        style_node.id = style_id;
                        if (is_openclash_page) {
                            style_node.textContent = [
                                'html,body{margin-top:0 !important;padding-top:0 !important;min-height:100% !important;}',
                                'header,.menu_mobile,.mobile_bg_color.container.body-container.visible-xs-block,.footer,.tail_wave{display:none !important;}',
                                'body > .container.body-container:not(.visible-xs-block){box-sizing:border-box !important;width:100% !important;max-width:none !important;margin:0 auto !important;padding:10px 18px 18px !important;}',
                                '.appcenter-openclash .openclash-main,.appcenter-openclash .main-content{width:100% !important;max-width:1420px !important;margin:0 auto !important;padding:0 !important;}',
                                '.appcenter-openclash .cbi-map,.appcenter-openclash .cbi-section,.appcenter-openclash .cbi-section-node{max-width:none !important;}',
                                '@media (min-width: 1200px){.appcenter-openclash .openclash-main{height:auto !important;}}',
                                '@media (max-width: 991px){body > .container.body-container:not(.visible-xs-block){padding:8px 8px 14px !important;}}'
                            ].join('');
                        } else if (is_ttyd_page) {
                            style_node.textContent = [
                                'html,body{margin-top:0 !important;padding-top:0 !important;background:#101114 !important;}',
                                'header,.menu_mobile,.mobile_bg_color.container.body-container.visible-xs-block,.footer,.tail_wave{display:none !important;}',
                                'html,body{height:100% !important;}',
                                'body > .container.body-container:not(.visible-xs-block){box-sizing:border-box !important;width:100% !important;max-width:1440px !important;height:100% !important;margin:0 auto !important;padding:6px 8px 0 !important;}',
                                '.main,.main-content{width:100% !important;max-width:none !important;margin:0 !important;padding:0 !important;background:transparent !important;}',
                                '.ttyd-shell,.cbi-map{margin:0 !important;max-width:none !important;height:calc(100vh - 8px) !important;}',
                                '.ttyd-frame-wrap{display:flex !important;flex-direction:column !important;height:calc(100vh - 8px) !important;border-radius:18px !important;}',
                                '.ttyd-frame-top{flex:0 0 auto !important;padding:8px 12px !important;}',
                                '.ttyd-frame{display:block !important;flex:1 1 auto !important;min-height:0 !important;height:auto !important;}',
                                '@media (max-width: 991px){body > .container.body-container:not(.visible-xs-block){padding:4px 4px 0 !important;}.ttyd-shell,.cbi-map,.ttyd-frame-wrap{height:calc(100vh - 4px) !important;}}'
                            ].join('');
                        } else {
                            style_node.textContent = [
                                'html,body{margin-top:0 !important;padding-top:0 !important;}',
                                'header,.menu_mobile,.mobile_bg_color.container.body-container.visible-xs-block,.footer,.tail_wave{display:none !important;}',
                                'body > .container.body-container:not(.visible-xs-block){box-sizing:border-box !important;width:100% !important;max-width:1480px !important;margin:0 auto !important;padding-left:20px !important;padding-right:20px !important;}',
                                '.main,.main-content{width:100% !important;max-width:none !important;}',
                                '.cbi-map,.cbi-section{max-width:none !important;}',
                                '@media (max-width: 991px){body > .container.body-container:not(.visible-xs-block){padding-left:12px !important;padding-right:12px !important;}}'
                            ].join('');
                        }
                        d.head.appendChild(style_node);
                    }
                }
            }
        }
        catch(e) {}

        target_frame.removeClass('app_frame_iframe_pending');
        target_frame.css({
            visibility: '',
            opacity: '',
            pointerEvents: ''
        });
    }
    function get_app_route_url(route){
        var url = "<%=controller%>" + route;
        if(is_ttyd_route(route) || is_openclash_route(route))
            return url + (url.indexOf('?') === -1 ? '?appcenter=1' : '&appcenter=1');
        return url;
    }
    function build_app_iframe(route){
        var iframe_class = "app_frame_iframe";
        if(is_openclash_route(route) || is_ttyd_route(route))
            iframe_class += " app_frame_iframe_pending";
        if(route && route.length > 0)
            return "<iframe id='sub_frame' class='" + iframe_class + "' src='" + get_app_route_url(route) + "' name='subpage'></iframe>";
        return "<iframe id='sub_frame' class='" + iframe_class + "' name='subpage'></iframe>";
    }
    function is_openclash_route(route){
        return route && route.indexOf("admin/services/openclash") === 0;
    }
    function is_ttyd_route(route){
        return route && route.indexOf("admin/services/ttyd") === 0;
    }
    function is_kms_route(route){
        return route && route.indexOf("admin/services/vlmcsd") === 0;
    }
    function get_app_dialog_class(route){
        if(is_openclash_route(route))
            return "app_frame app_frame_openclash";
        return "app_frame";
    }
    function get_openclash_frame(route){
        var current_route = route && route.length > 0 ? route : "admin/services/openclash/client";
        if(current_route == "admin/services/openclash")
            current_route = "admin/services/openclash/client";

        var tabs = [
            {route: "admin/services/openclash/client", title: "运行状态"},
            {route: "admin/services/openclash/settings", title: "插件设置"},
            {route: "admin/services/openclash/config-overwrite", title: "覆写设置"},
            {route: "admin/services/openclash/config-subscribe", title: "配置订阅"},
            {route: "admin/services/openclash/config", title: "配置管理"},
            {route: "admin/services/openclash/log", title: "运行日志"}
        ];

        var sub_web_ht = "<div class='app_frame_box'><div class='app_frame_nav'>";
        $.each(tabs, function(index, tab){
            var active_class = "";
            if(tab.route == current_route)
                active_class = " app_frame_nav_item_active";
            sub_web_ht += "<span class='app_frame_nav_item" + active_class + "' data-route='" + tab.route + "' onclick='switch_app_frame_route(this)'>" + tab.title + "</span>";
        });
        sub_web_ht += "</div>" + build_app_iframe(current_route) + "</div>";
        return sub_web_ht;
    }
    function get_ttyd_frame(route){
        var current_route = route && route.length > 0 ? route : "admin/services/ttyd/ttyd";
        if(current_route == "admin/services/ttyd" || current_route == "admin/services/ttyd/")
            current_route = "admin/services/ttyd/ttyd";
        return "<div class='app_frame_box'>" + build_app_iframe(current_route) + "</div>";
    }
    function get_kms_frame(route){
        var current_route = route && route.length > 0 ? route : "admin/services/vlmcsd";
        if(current_route == "admin/services/vlmcsd/" || current_route == "admin/services/vlmcsd")
            current_route = "admin/services/vlmcsd";
        return "<div class='app_frame_box'>" + build_app_iframe(current_route) + "</div>";
    }
    function build_app_frame(route){
        if(is_openclash_route(route))
            return get_openclash_frame(route);
        if(is_ttyd_route(route))
            return get_ttyd_frame(route);
        if(is_kms_route(route))
            return get_kms_frame(route);
        return build_app_iframe(route);
    }
    function switch_app_frame_route(obj){
        var route = $(obj).data("route");
        var frame_box = $(obj).closest(".app_frame_box");
        var frame = frame_box.find("#sub_frame");
        frame_box.find(".app_frame_nav_item").removeClass("app_frame_nav_item_active");
        $(obj).addClass("app_frame_nav_item_active");
        if(is_openclash_route(route) || is_ttyd_route(route)) {
            frame.addClass("app_frame_iframe_pending");
            frame.css("visibility", "hidden");
        }
        frame.attr("src", get_app_route_url(route));
    }
    function callback(id,route){
        var sub_web_ht = build_app_frame(route);
        $(".top_menu").removeClass("top_menu_active");
        $(".top_menu").each(function(){
            if($(this).data("index") == id)
                $(this).addClass("top_menu_active");
        });
        sub_dialogDeal = BootstrapDialog.show({
            type: BootstrapDialog.TYPE_DEFAULT,
            closeByBackdrop: true,
            cssClass:get_app_dialog_class(route),
            title: '',
            message: sub_web_ht,
            onhide:function(dialogRef){
                var modal = dialogRef && dialogRef.getModal ? dialogRef.getModal() : get_active_app_modal();
                if(modal && modal.length)
                    modal.find(".modal-dialog").css("display","none");
                $(".top_menu").removeClass("top_menu_active");
                $(".top_menu").eq(0).addClass("top_menu_active");
            },
            onshown:function(dialogRef){
                var modal = dialogRef && dialogRef.getModal ? dialogRef.getModal() : get_active_app_modal();
                var frame = modal.find('#sub_frame');
                reload_iframe(frame);
                frame.off('load.appframe').on('load.appframe', function() {
                    reload_iframe($(this));
                });
            }
        });
    }
EOF
}

write_appcenter_patch_assets() {
    write_appcenter_dialog_css > "$css_file"
    write_appcenter_runtime_js > "$js_file"
}

inject_appcenter_css_block() {
    if grep -q 'function get_ttyd_frame(route)' "$APPCENTER_TEMPLATE_SRC" && grep -q 'function get_openclash_frame(route)' "$APPCENTER_TEMPLATE_SRC"; then
        cp "$APPCENTER_TEMPLATE_SRC" "$tmp1"
    else
        awk -v css_file="$css_file" '
            {
                print
                if ($0 ~ /^    \.modal\.app_frame\.in \.modal-content\{$/) {
                    in_target = 1
                    next
                }
                if (in_target && $0 ~ /^    }$/) {
                    while ((getline extra < css_file) > 0) print extra
                    close(css_file)
                    in_target = 0
                }
            }
        ' "$APPCENTER_TEMPLATE_SRC" > "$tmp1"
    fi
}

inject_appcenter_runtime_block() {
    awk -v js_file="$js_file" '
        BEGIN { skip = 0 }
        {
            if (!skip && $0 ~ /^    function reload_iframe\(/) {
                while ((getline extra < js_file) > 0) print extra
                close(js_file)
                skip = 1
                next
            }
            if (skip) {
                if ($0 ~ /^    function app_action\(app_name,action,id,route\)\{$/) {
                    skip = 0
                    print
                }
                next
            }
            print
        }
    ' "$tmp1" > "$tmp2"
}

inject_appcenter_route_overrides() {
    if grep -q 'db.name == "TTYD"' "$tmp2" && grep -q 'db.name == "OpenClash"' "$tmp2" && grep -q 'db.name == "KMS"' "$tmp2"; then
        cp "$tmp2" "$tmp3"
    else
        awk '
            {
                print
                if ($0 ~ /open_route = route;/) {
                    print "            if (db.name == \"OpenClash\")"
                    print "                open_route = \"admin/services/openclash\";"
                    print "            if (db.name == \"TTYD\")"
                    print "                open_route = \"admin/services/ttyd/ttyd\";"
                    print "            if (db.name == \"KMS\")"
                    print "                open_route = \"admin/services/vlmcsd\";"
                }
            }
        ' "$tmp2" > "$tmp3"
    fi
}

normalize_appcenter_template() {
    if [ "$APPCENTER_TEMPLATE_DST" = "$APPCENTER_TEMPLATE_SRC" ]; then
        backup_file "$APPCENTER_TEMPLATE_DST"
    fi
    # Normalize the stock desktop dialog margin in the original template.
    # Some OEM templates ship with `margin: 150px 10%`, which mis-centers
    # the modal on wide screens; keep it centered with `auto`.
    sed 's/margin: 150px 10%;/margin: 150px auto;/' "$tmp3" > "$APPCENTER_TEMPLATE_DST"
}

verify_appcenter_template_patch() {
    grep -q 'function get_ttyd_frame(route)' "$APPCENTER_TEMPLATE_DST" || die 'appcenter template patch failed: ttyd frame hook missing'
    grep -q 'function get_openclash_frame(route)' "$APPCENTER_TEMPLATE_DST" || die 'appcenter template patch failed: openclash frame hook missing'
    grep -q 'function get_kms_frame(route)' "$APPCENTER_TEMPLATE_DST" || die 'appcenter template patch failed: kms frame hook missing'
    grep -q 'function build_app_frame(route)' "$APPCENTER_TEMPLATE_DST" || die 'appcenter template patch failed: build_app_frame hook missing'
    grep -q 'function callback(id,route)' "$APPCENTER_TEMPLATE_DST" || die 'appcenter template patch failed: callback hook missing'
}

build_appcenter_modified_template() {
    APPCENTER_TEMPLATE_SRC="$1"
    APPCENTER_TEMPLATE_DST="$2"

    mkdir -p "$WORKDIR"
    css_file="$WORKDIR/appcenter-ttyd.css"
    js_file="$WORKDIR/appcenter-ttyd.js"
    tmp1="$WORKDIR/appcenter-ttyd.1"
    tmp2="$WORKDIR/appcenter-ttyd.2"
    tmp3="$WORKDIR/appcenter-ttyd.3"

    write_appcenter_patch_assets
    inject_appcenter_css_block
    inject_appcenter_runtime_block
    inject_appcenter_route_overrides
    normalize_appcenter_template
    verify_appcenter_template_patch
}

patch_appcenter_template() {
    build_appcenter_modified_template "$TPL" "$TPL"
}

build_workspace_appcenter_modified_v1() {
    build_appcenter_modified_template "$SCRIPT_DIR/appcenter.htm" "$SCRIPT_DIR/appcenter_modified_v1.htm"
}

refresh_luci_appcenter() {
    rm -f /tmp/luci-indexcache /tmp/infocd/cache/appcenter 2>/dev/null || true
    rm -f /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/infocd stop >/dev/null 2>&1 || true
    killall infocd infocd_consumer 2>/dev/null || true
    /etc/init.d/infocd start >/dev/null 2>&1 || true
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    /etc/init.d/appcenter stop >/dev/null 2>&1 || true
    killall appcenter 2>/dev/null || true
    /etc/init.d/appcenter start >/dev/null 2>&1 || /etc/init.d/appcenter restart >/dev/null 2>&1 || true
    sleep 2
}

verify_appcenter_route() {
    plugin_name="$1"
    expect_route="$2"
    sec="$(find_uci_section package_list "$plugin_name")"
    [ -n "$sec" ] || die "$plugin_name verify failed: appcenter package_list missing"
    actual_route="$(uci -q get appcenter.$sec.luci_module_route 2>/dev/null || true)"
    [ "$actual_route" = "$expect_route" ] || die "$plugin_name verify failed: appcenter route mismatch ($actual_route)"
}

verify_ttyd_route() {
    verify_appcenter_route "TTYD" "admin/services/ttyd/ttyd"
}

verify_kms_route() {
    verify_appcenter_route "KMS" "admin/services/vlmcsd"
}

get_openclash_core_arch() {
    machine="$(uname -m 2>/dev/null || true)"
    case "$machine" in
        x86_64) printf '%s\n' amd64 ;;
        i386|i686) printf '%s\n' 386 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        armv7l|armv7) printf '%s\n' armv7 ;;
        armv6l|armv6) printf '%s\n' armv6 ;;
        armv5tel|armv5*) printf '%s\n' armv5 ;;
        mips64el|mips64le) printf '%s\n' mips64le ;;
        mips64) printf '%s\n' mips64 ;;
        mipsel|mipsle)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mipsle-softfloat
            else
                printf '%s\n' mipsle-hardfloat
            fi
            ;;
        mips)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mips-softfloat
            else
                printf '%s\n' mips-hardfloat
            fi
            ;;
        *) return 1 ;;
    esac
}

install_openclash_smart_core() {
    core_arch="$(get_openclash_core_arch 2>/dev/null || true)"
    [ -n "$core_arch" ] || die "failed to detect OpenClash smart core architecture"

    mkdir -p "$WORKDIR/openclash/core" /etc/openclash/core
    core_version_file="$WORKDIR/openclash/core_version"
    smart_core_tar="$WORKDIR/openclash/clash-linux-${core_arch}.tar.gz"
    smart_core_dir="/etc/openclash/core"

    log "tip: downloading OpenClash smart core version file..."
    download_from_mirrors "core_version" "$core_version_file" "$OPENCLASH_CORE_VERSION_MIRRORS" >/dev/null || die "failed to fetch OpenClash smart core version file"
    smart_core_ver="$(sed -n '2p' "$core_version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || smart_core_ver="$(sed -n '1p' "$core_version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || die "failed to parse OpenClash smart core version"

    log "tip: downloading OpenClash smart core v$smart_core_ver for $core_arch..."
    download_from_mirrors "clash-linux-${core_arch}.tar.gz" "$smart_core_tar" "$OPENCLASH_CORE_SMART_MIRRORS" >/dev/null || die "failed to fetch OpenClash smart core"
    [ -s "$smart_core_tar" ] || die "OpenClash smart core download failed"

    tar -xzf "$smart_core_tar" -C "$smart_core_dir" >/dev/null 2>&1 || die "failed to extract OpenClash smart core"
    smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ && $0 ~ /(^|\/)clash([._-]|$)/ { print; exit }')"
    [ -n "$smart_core_entry" ] || smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ { print; exit }')"
    smart_core_entry_target="${smart_core_entry#./}"
    smart_core_binary="$(basename "$smart_core_entry_target" 2>/dev/null || true)"
    [ -n "$smart_core_binary" ] || die "failed to locate extracted smart core binary"

    [ "$smart_core_binary" = "clash_meta" ] || mv -f "$smart_core_dir/$smart_core_entry_target" "$smart_core_dir/clash_meta" 2>/dev/null || ln -sf "$smart_core_entry_target" "$smart_core_dir/clash_meta"
    [ -e "$smart_core_dir/clash" ] || ln -sf clash_meta "$smart_core_dir/clash"
    chmod 755 "$smart_core_dir"/clash* 2>/dev/null || true

    printf '%s\n%s\n' "$(sed -n '1p' "$core_version_file")" "$(sed -n '2p' "$core_version_file")" > /etc/openclash/core_version
    chmod 644 /etc/openclash/core_version 2>/dev/null || true
}

fix_openclash_luci_compat() {
    oc_overwrite="/usr/lib/lua/luci/model/cbi/openclash/config-overwrite.lua"
    [ -f "$oc_overwrite" ] || return 0
    if grep -q 'datatype.cidr4(value)' "$oc_overwrite"; then
        backup_file "$oc_overwrite"
        sed -i 's/if datatype.cidr4(value) then/if ((datatype.cidr4 and datatype.cidr4(value)) or (datatype.ipmask4 and datatype.ipmask4(value))) then/' "$oc_overwrite"
    fi
}

backup_openclash_fix_files() {
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    mkdir -p "$OPENCLASH_FIX_BACKUP_DIR"

    cp -f "$TPL" "$OPENCLASH_FIX_BACKUP_DIR/appcenter.htm.$ts.bak" 2>/dev/null || true
    cp -f "$CFG" "$OPENCLASH_FIX_BACKUP_DIR/appcenter.$ts.bak" 2>/dev/null || true
    if [ -f "$OPENCLASH_LOGSH" ]; then
        cp -f "$OPENCLASH_LOGSH" "$OPENCLASH_FIX_BACKUP_DIR/log.sh.$ts.bak" 2>/dev/null || true
    fi

    for old in /etc/config/appcenter.bak-openclash-route-*; do
        [ -e "$old" ] || continue
        mv "$old" "$OPENCLASH_FIX_BACKUP_DIR/$(basename "$old").$ts" 2>/dev/null || true
    done
}

write_openclash_log_i18n_script() {
    [ -f "$OPENCLASH_LOGSH" ] || return 0
    backup_file "$OPENCLASH_LOGSH"

    cat > "$OPENCLASH_LOGSH" <<'EOF'
#!/bin/sh

START_LOG="/tmp/openclash_start.log"
LOG_FILE="/tmp/openclash.log"

OC_LOG_I18N()
{
    local msg
    msg="$1"
    [ -z "$msg" ] && return 0
    printf '%s' "$msg" | sed \
    -e 's/^Step \([0-9][0-9]*\): /步骤 \1：/g' \
    -e 's/OpenClash Start Successful!/OpenClash 启动成功！/g' \
    -e 's/OpenClash Already Running, Exit.../OpenClash 已在运行，退出.../g' \
    -e 's/OpenClash Start Running.../OpenClash 开始启动.../g' \
    -e 's/OpenClash Now Disabled, Need Start From Luci Page, Exit.../OpenClash 当前已禁用，请从 LuCI 页面启动后再试，退出.../g' \
    -e 's/OpenClash Stoping.../OpenClash 正在停止.../g' \
    -e 's/OpenClash Already Stop!/OpenClash 已停止！/g' \
    -e 's/OpenClash Restart.../OpenClash 重启中.../g' \
    -e 's/OpenClash update successful, about to restart!/OpenClash 更新成功，即将重启！/g' \
    -e 's/Step 3: Quick Start Mode, Skip Modify The Config File/步骤 3：快速启动模式，跳过修改配置文件/g' \
    -e 's/Quick Start Mode, Skip Modify The Config File/快速启动模式，跳过修改配置文件/g' \
    -e 's/Get The Configuration/获取配置/g' \
    -e 's/Check The Components/检查组件/g' \
    -e 's/Modify The Config File/修改配置文件/g' \
    -e 's/Quick Start Mode/快速启动模式/g' \
    -e 's/Start Running The Clash Core/启动 Clash 内核/g' \
    -e 's/Add Cron Rules, Start Daemons/添加定时任务并启动守护进程/g' \
    -e 's/Core Status Checking and Firewall Rules Setting/检查内核状态并设置防火墙规则/g' \
    -e 's/Backup The Current Groups State/备份当前分组状态/g' \
    -e 's/Delete OpenClash Firewall Rules/删除 OpenClash 防火墙规则/g' \
    -e 's/Close The OpenClash Services/关闭 OpenClash 服务/g' \
    -e 's/Restart Dnsmasq/重启 Dnsmasq/g' \
    -e 's/Delete OpenClash Residue File/清理 OpenClash 残留文件/g' \
    -e 's/Please Note That Network May Abnormal With IPv6.s DHCP Server/请注意：启用 IPv6 的 DHCP 服务器可能导致网络异常/g' \
    -e 's/DNS Hijacking is Disabled.../DNS 劫持已禁用.../g' \
    -e 's/DNS Hijacking Mode is Dnsmasq Redirect.../DNS 劫持模式：Dnsmasq 重定向.../g' \
    -e 's/DNS Hijacking Mode is Firewall Redirect.../DNS 劫持模式：防火墙重定向.../g' \
    -e 's/IPv6 Proxy Mode is Redirect.../IPv6 代理模式：Redirect.../g' \
    -e 's/IPv6 Proxy Mode is TUN.../IPv6 代理模式：TUN.../g' \
    -e 's/IPv6 Proxy Mode is Mix.../IPv6 代理模式：Mix.../g' \
    -e 's/IPv6 Proxy Mode is TProxy.../IPv6 代理模式：TProxy.../g' \
    -e 's/Start Add Port Bypassing Rules For Firewall Redirect and Firewall Rules.../开始为防火墙重定向和防火墙规则添加端口绕过规则.../g' \
    -e 's/Start Add Custom Firewall Rules.../开始添加自定义防火墙规则.../g' \
    -e 's/Start Running Custom Overwrite Scripts.../开始运行自定义覆写脚本.../g' \
    -e 's/Tip: /提示：/g'
}

LOG_OUT()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "${msg}" > $START_LOG
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Info] ${msg}" >> $LOG_FILE
    fi
}

LOG_TIP()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "${msg}" > $START_LOG
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Tip] ${msg}" >> $LOG_FILE
    fi
}

LOG_WARN()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "${msg}" > $START_LOG
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Warning] ${msg}" >> $LOG_FILE
    fi
}

LOG_ERROR()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "${msg}" > $START_LOG
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Error] ${msg}" >> $LOG_FILE
    fi
}

LOG_INFO()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Info] ${msg}" >> $LOG_FILE
    fi
}

LOG_WATCHDOG()
{
    if [ -n "${1}" ]; then
        local msg
        msg="$(OC_LOG_I18N "${1}")"
        echo -e "$(date "+%Y-%m-%d %H:%M:%S") [Watchdog] ${msg}" >> $LOG_FILE
    fi
}

LOG_ALERT()
{
    echo -e "$(tail -n 20 $LOG_FILE |grep -E 'level=fatal|level=error' |awk 'END {print}')" > $START_LOG
    sleep 3
}

SLOG_CLEAN()
{
    echo "##FINISH##" > $START_LOG
}
EOF
    chmod 755 "$OPENCLASH_LOGSH" 2>/dev/null || true
}

translate_openclash_runtime_log() {
    [ -f /tmp/openclash.log ] || return 0

    sed -i \
        -e 's/^\([0-9:-][0-9:-]* [0-9:][0-9:]*\) \[Info\] Step \([0-9][0-9]*\): /\1 [Info] 步骤 \2：/g' \
        -e 's/OpenClash Start Successful!/OpenClash 启动成功！/g' \
        -e 's/OpenClash Already Running, Exit.../OpenClash 已在运行，退出.../g' \
        -e 's/OpenClash Start Running.../OpenClash 开始启动.../g' \
        -e 's/OpenClash Now Disabled, Need Start From Luci Page, Exit.../OpenClash 当前已禁用，请从 LuCI 页面启动后再试，退出.../g' \
        -e 's/OpenClash Stoping.../OpenClash 正在停止.../g' \
        -e 's/OpenClash Already Stop!/OpenClash 已停止！/g' \
        -e 's/OpenClash Restart.../OpenClash 重启中.../g' \
        -e 's/OpenClash update successful, about to restart!/OpenClash 更新成功，即将重启！/g' \
        -e 's/Step 3: Quick Start Mode, Skip Modify The Config File/步骤 3：快速启动模式，跳过修改配置文件/g' \
        -e 's/Quick Start Mode, Skip Modify The Config File/快速启动模式，跳过修改配置文件/g' \
        -e 's/Get The Configuration/获取配置/g' \
        -e 's/Check The Components/检查组件/g' \
        -e 's/Modify The Config File/修改配置文件/g' \
        -e 's/Quick Start Mode/快速启动模式/g' \
        -e 's/Start Running The Clash Core/启动 Clash 内核/g' \
        -e 's/Add Cron Rules, Start Daemons/添加定时任务并启动守护进程/g' \
        -e 's/Core Status Checking and Firewall Rules Setting/检查内核状态并设置防火墙规则/g' \
        -e 's/Backup The Current Groups State/备份当前分组状态/g' \
        -e 's/Delete OpenClash Firewall Rules/删除 OpenClash 防火墙规则/g' \
        -e 's/Close The OpenClash Services/关闭 OpenClash 服务/g' \
        -e 's/Restart Dnsmasq/重启 Dnsmasq/g' \
        -e 's/Delete OpenClash Residue File/清理 OpenClash 残留文件/g' \
        -e 's/Please Note That Network May Abnormal With IPv6.s DHCP Server/请注意：启用 IPv6 的 DHCP 服务器可能导致网络异常/g' \
        -e 's/DNS Hijacking is Disabled.../DNS 劫持已禁用.../g' \
        -e 's/DNS Hijacking Mode is Dnsmasq Redirect.../DNS 劫持模式：Dnsmasq 重定向.../g' \
        -e 's/DNS Hijacking Mode is Firewall Redirect.../DNS 劫持模式：防火墙重定向.../g' \
        -e 's/IPv6 Proxy Mode is Redirect.../IPv6 代理模式：Redirect.../g' \
        -e 's/IPv6 Proxy Mode is TUN.../IPv6 代理模式：TUN.../g' \
        -e 's/IPv6 Proxy Mode is Mix.../IPv6 代理模式：Mix.../g' \
        -e 's/IPv6 Proxy Mode is TProxy.../IPv6 代理模式：TProxy.../g' \
        -e 's/Start Add Port Bypassing Rules For Firewall Redirect and Firewall Rules.../开始为防火墙重定向和防火墙规则添加端口绕过规则.../g' \
        -e 's/Start Add Custom Firewall Rules.../开始添加自定义防火墙规则.../g' \
        -e 's/Start Running Custom Overwrite Scripts.../开始运行自定义覆写脚本.../g' \
        -e 's/Tip: /提示：/g' \
        /tmp/openclash.log 2>/dev/null || true
}

apply_openclash_all_fix() {
    backup_openclash_fix_files

    sed -i \
        -e 's#/usr/lib/lua/luci/controller/nradio_adv/openclash_full.lua#/usr/lib/lua/luci/controller/openclash.lua#g' \
        -e 's#nradioadv/system/openclashfull#admin/services/openclash#g' \
        "$CFG" 2>/dev/null || true

    write_openclash_log_i18n_script
    translate_openclash_runtime_log
}

write_openclash_switch_dashboard_template() {
    mkdir -p /usr/lib/lua/luci/view/openclash
    backup_file /usr/lib/lua/luci/view/openclash/switch_dashboard.htm
    cat > /usr/lib/lua/luci/view/openclash/switch_dashboard.htm <<'EOF'
<%+cbi/valueheader%>
<style type="text/css">
.cbi-value-field #switch_dashboard_Dashboard input[type="button"],
.cbi-value-field #switch_dashboard_Yacd input[type="button"],
.cbi-value-field #switch_dashboard_Metacubexd input[type="button"],
.cbi-value-field #switch_dashboard_Zashboard input[type="button"],
.cbi-value-field #delete_dashboard_Dashboard input[type="button"],
.cbi-value-field #delete_dashboard_Yacd input[type="button"],
.cbi-value-field #delete_dashboard_Metacubexd input[type="button"],
.cbi-value-field #delete_dashboard_Zashboard input[type="button"],
.cbi-value-field #default_dashboard_Dashboard input[type="button"],
.cbi-value-field #default_dashboard_Yacd input[type="button"],
.cbi-value-field #default_dashboard_Metacubexd input[type="button"],
.cbi-value-field #default_dashboard_Zashboard input[type="button"] {
    display: inline-block !important;
    min-width: 210px !important;
    padding: 6px 14px !important;
    margin: 0 8px 6px 0 !important;
    border: 1px solid #3b82f6 !important;
    border-radius: 8px !important;
    background: #ffffff !important;
    color: #1f2937 !important;
    font-weight: 600 !important;
    box-shadow: 0 1px 2px rgba(0,0,0,.08) !important;
    cursor: pointer !important;
}
</style>
<%
local uci = require "luci.model.uci".cursor()
local dashboard_type = uci:get("openclash", "config", "dashboard_type") or "Official"
local yacd_type = uci:get("openclash", "config", "yacd_type") or "Official"
local option_name = self.option or ""
local switch_title = ""
local switch_target = ""
if option_name == "Dashboard" then
    switch_title = dashboard_type == "Meta" and "Switch To Official Version" or "Switch To Meta Version"
    switch_target = dashboard_type == "Meta" and "Official" or "Meta"
elseif option_name == "Yacd" then
    switch_title = yacd_type == "Meta" and "Switch To Official Version" or "Switch To Meta Version"
    switch_target = yacd_type == "Meta" and "Official" or "Meta"
elseif option_name == "Metacubexd" then
    switch_title = "Update Metacubexd Version"
    switch_target = "Official"
elseif option_name == "Zashboard" then
    switch_title = "Update Zashboard Version"
    switch_target = "Official"
end
%>
<div class="cbi-value-field" id="switch_dashboard_<%=self.option%>">
    <% if switch_title ~= "" then %>
    <input type="button" class="btn cbi-button cbi-button-reset" value="<%=switch_title%>" onclick="return switch_dashboard(this, '<%=option_name%>', '<%=switch_target%>')"/>
    <% else %>
    <%:Collecting data...%>
    <% end %>
</div>
<div class="cbi-value-field" id="delete_dashboard_<%=self.option%>"><input type="button" class="btn cbi-button cbi-button-reset" value="<%:Delete%>" onclick="return delete_dashboard(this, '<%=self.option%>')"/></div>
<div class="cbi-value-field" id="default_dashboard_<%=self.option%>"><input type="button" class="btn cbi-button cbi-button-reset" value="<%:Set to Default%>" onclick="return default_dashboard(this, '<%=self.option%>')"/></div>
<script type="text/javascript">//<![CDATA[
var btn_type_<%=self.option%> = "<%=self.option%>";
var switch_dashboard_<%=self.option%> = document.getElementById('switch_dashboard_<%=self.option%>');
var default_dashboard_<%=self.option%> = document.getElementById('default_dashboard_<%=self.option%>');
var delete_dashboard_<%=self.option%> = document.getElementById('delete_dashboard_<%=self.option%>');
XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "dashboard_type")%>', null, function(x, status) {
    if (x && x.status == 200) {
        if (btn_type_<%=self.option%> == "Dashboard")
            switch_dashboard_<%=self.option%>.innerHTML = status.dashboard_type == "Meta" ? '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Official Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Official\\')"/>' : '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Meta Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Meta\\')"/>';
        if (btn_type_<%=self.option%> == "Yacd")
            switch_dashboard_<%=self.option%>.innerHTML = status.yacd_type == "Meta" ? '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Official Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Official\\')"/>' : '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Switch To Meta Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Meta\\')"/>';
        if (btn_type_<%=self.option%> == "Metacubexd")
            switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Metacubexd Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Official\\')"/>';
        if (btn_type_<%=self.option%> == "Zashboard")
            switch_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Update Zashboard Version%>" onclick="return switch_dashboard(this, btn_type_<%=self.option%>, \\'Official\\')"/>';
        if (status.default_dashboard == btn_type_<%=self.option%>.toLowerCase())
            default_dashboard_<%=self.option%>.innerHTML = '<input type="button" class="btn cbi-button cbi-button-reset" value="<%:Default%>" disabled="disabled" onclick="return default_dashboard(this, btn_type_<%=self.option%>)"/>';
        if (!status[btn_type_<%=self.option%>.toLowerCase()]) {
            default_dashboard_<%=self.option%>.firstElementChild.disabled = true;
            delete_dashboard_<%=self.option%>.firstElementChild.disabled = true;
        }
    }
});
function switch_dashboard(btn, name, type){ btn.disabled = true; btn.value = '<%:Downloading File...%>'; XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "switch_dashboard")%>', {name: name, type : type}, function(){ location.reload(); }); btn.disabled = false; return false; }
function delete_dashboard(btn, name){ if (confirm("<%:Are you sure you want to delete this panel?%>")) { btn.disabled = true; XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "delete_dashboard")%>', {name: name}, function(){ location.reload(); }); } return false; }
function default_dashboard(btn, name){ btn.disabled = true; XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "default_dashboard")%>', {name: name}, function(){ location.reload(); }); return false; }
//]]></script>
<%+cbi/valuefooter%>
EOF
}

write_openclash_alias_controller() {
    mkdir -p /usr/lib/lua/luci/controller/nradio_adv
    backup_file /usr/lib/lua/luci/controller/nradio_adv/openclash_alias.lua
    cat > /usr/lib/lua/luci/controller/nradio_adv/openclash_alias.lua <<'EOF'
module("luci.controller.nradio_adv.openclash_alias", package.seeall)

function index()
    local page = entry({"nradio", "advanced", "openclash"}, alias("admin", "services", "openclash"), _("OpenClash"), 60)
    page.dependent = true
end
EOF
}

patch_openclash_dashboard_settings() {
    settings="/usr/lib/lua/luci/model/cbi/openclash/settings.lua"
    [ -f "$settings" ] || return 0
    if ! grep -q 'o.rawhtml = true' "$settings"; then
        backup_file "$settings"
        sed -i '/o.template="openclash\/switch_dashboard"/a\    o.rawhtml = true' "$settings"
    fi
}

get_active_luci_theme() {
    mediaurlbase="$(uci -q get luci.main.mediaurlbase 2>/dev/null || true)"
    theme_name="${mediaurlbase##*/}"
    [ -n "$theme_name" ] && [ "$theme_name" != "$mediaurlbase" ] && {
        printf '%s\n' "$theme_name"
        return 0
    }
    return 1
}

wrap_openclash_embed_guard() {
    target="$1"
    [ -f "$target" ] || return 1
    grep -q 'OPENCLASH_APPCENTER_EMBED_GUARD' "$target" && return 0

    mkdir -p "$WORKDIR/openclash/theme"
    tmp="$WORKDIR/openclash/theme/$(basename "$target").guard"
    backup_file "$target"

    {
        printf '<!-- OPENCLASH_APPCENTER_EMBED_GUARD -->\n'
        cat <<'EOF'
<%
local http = require "luci.http"
local __nradio_request_uri = http.getenv("REQUEST_URI") or ""
local __nradio_openclash_embed = (http.formvalue("appcenter") == "1" and __nradio_request_uri:match("/cgi%-bin/luci/admin/services/openclash"))
if not __nradio_openclash_embed then
%>
EOF
        cat "$target"
        printf '\n<%% end %%>\n'
    } > "$tmp" || return 1

    mv "$tmp" "$target"
}

apply_openclash_embed_theme_patch() {
    patched=0
    theme_name="$(get_active_luci_theme 2>/dev/null || true)"

    for target in \
        "/usr/lib/lua/luci/view/themes/$theme_name/header.htm" \
        "/usr/lib/lua/luci/view/themes/$theme_name/footer.htm" \
        /usr/lib/lua/luci/view/header.htm \
        /usr/lib/lua/luci/view/footer.htm
    do
        [ -n "$target" ] || continue
        [ -f "$target" ] || continue
        if wrap_openclash_embed_guard "$target"; then
            patched=1
        fi
    done

    [ "$patched" = "1" ] || die 'failed to patch LuCI theme header/footer for OpenClash embed mode'
}

unwrap_openclash_embed_guard() {
    target="$1"
    [ -f "$target" ] || return 1
    grep -q 'OPENCLASH_APPCENTER_EMBED_GUARD' "$target" || return 0

    mkdir -p "$WORKDIR/openclash/theme"
    tmp="$WORKDIR/openclash/theme/$(basename "$target").unguard"
    backup_file "$target"

    tail -n +8 "$target" | sed '$d' > "$tmp" || return 1
    mv "$tmp" "$target"
}

remove_openclash_embed_theme_patch() {
    theme_name="$(get_active_luci_theme 2>/dev/null || true)"

    for target in \
        "/usr/lib/lua/luci/view/themes/$theme_name/header.htm" \
        "/usr/lib/lua/luci/view/themes/$theme_name/footer.htm" \
        /usr/lib/lua/luci/view/header.htm \
        /usr/lib/lua/luci/view/footer.htm
    do
        [ -n "$target" ] || continue
        [ -f "$target" ] || continue
        unwrap_openclash_embed_guard "$target" || true
    done
}

install_ttyd() {
    require_file "$CFG"
    require_file "$TPL"
    mkdir -p "$WORKDIR"

    ensure_opkg_update

    ttyd_ipk="$WORKDIR/ttyd.ipk"
    luci_ttyd_ipk="$WORKDIR/luci-app-ttyd.ipk"

    download_feed_package_or_die ttyd "$ttyd_ipk" 'ttyd core package'
    download_feed_package_or_die luci-app-ttyd "$luci_ttyd_ipk" 'ttyd LuCI package'

    confirm_or_exit "确认继续安装 ttyd 并接入 AppCenter 吗？"

    install_ipk_file "$ttyd_ipk" "ttyd"
    install_ipk_file "$luci_ttyd_ipk" "luci-app-ttyd"
    ensure_ttyd_uci_config
    /etc/init.d/ttyd enable >/dev/null 2>&1 || true
    /etc/init.d/ttyd restart >/dev/null 2>&1 || /etc/init.d/ttyd start >/dev/null 2>&1 || true

    backup_file /usr/lib/lua/luci/controller/ttyd.lua
    backup_file /usr/lib/lua/luci/view/ttyd/oem_terminal.htm
    backup_file /usr/lib/lua/luci/view/ttyd/oem_config.htm
    write_ttyd_wrapper_files

    ttyd_module_file="/usr/lib/lua/luci/controller/ttyd.lua"
    [ -f "$ttyd_module_file" ] || die 'ttyd controller file missing after install'

    ttyd_ver="$(get_installed_or_feed_version luci-app-ttyd)"
    ttyd_size="$(wc -c < "$luci_ttyd_ipk" | tr -d ' ')"

    register_appcenter_plugin "TTYD" "luci-app-ttyd" "$ttyd_ver" "$ttyd_size" "$ttyd_module_file" "admin/services/ttyd/ttyd"

    log 'done'
    log 'plugin:   ttyd'
    log "version:  $ttyd_ver"
    log 'route:    admin/services/ttyd/ttyd'
    log 'next:     close appcenter popup, then press Ctrl+F5 and reopen ttyd'
}

install_kms() {
    require_file "$CFG"
    require_file "$TPL"
    mkdir -p "$WORKDIR"

    ensure_opkg_update

    kms_arch="$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" { arch=$2 } END { print arch }')"
    [ -n "$kms_arch" ] || die 'failed to detect current OpenWrt package architecture for KMS core'

    kms_core_pkg='vlmcsd'
    kms_luci_pkg='luci-app-vlmcsd'
    kms_core_url="${KMS_CORE_IPK_BASE_URL%/}/vlmcsd_${KMS_CORE_VERSION}_${kms_arch}.ipk"
    kms_luci_url="$KMS_LUCI_IPK_URL"
    [ -n "$kms_luci_url" ] || die 'failed to resolve KMS LuCI package url'
    kms_core_ipk="$WORKDIR/${kms_core_pkg}.ipk"
    kms_luci_ipk="$WORKDIR/${kms_luci_pkg}.ipk"

    download_url_to_file_or_die "$kms_core_url" "$kms_core_ipk" 'KMS core package'
    download_url_to_file_or_die "$kms_luci_url" "$kms_luci_ipk" 'KMS LuCI package'

    confirm_or_exit "确认继续安装 KMS 并接入 AppCenter 吗？"

    install_ipk_file "$kms_core_ipk" "$kms_core_pkg"
    install_ipk_file "$kms_luci_ipk" "$kms_luci_pkg"
    /etc/init.d/vlmcsd enable >/dev/null 2>&1 || true
    /etc/init.d/vlmcsd restart >/dev/null 2>&1 || /etc/init.d/vlmcsd start >/dev/null 2>&1 || true

    kms_module_file=""
    for candidate in \
        /usr/lib/lua/luci/controller/vlmcsd.lua \
        /usr/lib/lua/luci/controller/kms.lua \
        /usr/share/luci/menu.d/luci-app-vlmcsd.json; do
        if [ -f "$candidate" ]; then
            kms_module_file="$candidate"
            break
        fi
    done
    [ -n "$kms_module_file" ] || die 'KMS controller file missing after install'

    kms_ver="$(get_installed_or_feed_version "$kms_luci_pkg")"
    kms_size="$(wc -c < "$kms_luci_ipk" | tr -d ' ')"

    register_appcenter_plugin "KMS" "$kms_luci_pkg" "$kms_ver" "$kms_size" "$kms_module_file" "admin/services/vlmcsd"

    log 'done'
    log 'plugin:   KMS'
    log "version:  $kms_ver"
    log 'route:    admin/services/vlmcsd'
    log 'next:     close appcenter popup, then press Ctrl+F5 and reopen KMS'
}

install_openclash() {
    require_file "$CFG"
    require_file "$TPL"
    mkdir -p "$WORKDIR/openclash/pkg" "$WORKDIR/openclash/control"

    version_file="$WORKDIR/openclash/version"
    raw_ipk="$WORKDIR/openclash/openclash.ipk"
    fixed_ipk="$WORKDIR/openclash/openclash-fixed.ipk"

    log "tip: downloading OpenClash version file..."
    mirror_base="$(download_from_mirrors "version" "$version_file")" || die "failed to fetch OpenClash version from mirrors"
    last_ver="$(sed -n '1p' "$version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$last_ver" ] || die "failed to parse OpenClash version"

    download_url_to_file_or_die "$mirror_base/luci-app-openclash_${last_ver}_all.ipk" "$raw_ipk" "OpenClash v$last_ver"

    confirm_or_exit "确认继续安装 OpenClash 并接入 AppCenter 吗？"

    ensure_opkg_update
    ensure_required_packages dnsmasq-full bash curl ca-bundle ip-full ruby ruby-yaml kmod-inet-diag kmod-nft-tproxy kmod-tun unzip

    rebuild_ipk_without_dep "$raw_ipk" "$fixed_ipk" "luci-compat" "openclash"

    install_ipk_file "$fixed_ipk" "luci-app-openclash"

    oc_ver="$(opkg status luci-app-openclash 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$oc_ver" ] || oc_ver="$last_ver"
    oc_size="$(wc -c < "$fixed_ipk" | tr -d ' ')"
    oc_controller="/usr/lib/lua/luci/controller/openclash.lua"
    [ -f "$oc_controller" ] || die "OpenClash controller file missing after install"

    apply_openclash_all_fix
    fix_openclash_luci_compat
    write_openclash_alias_controller
    write_openclash_switch_dashboard_template
    patch_openclash_dashboard_settings
    remove_openclash_embed_theme_patch
    register_appcenter_plugin "OpenClash" "luci-app-openclash" "$oc_ver" "$oc_size" "$oc_controller" "admin/services/openclash"

    if [ "${INSTALL_OPENCLASH_SMART_CORE:-1}" = "1" ] && confirm_default_yes "是否继续下载 OpenClash smart 核心？"; then
        install_openclash_smart_core
    fi

    log 'done'
    log 'plugin:   OpenClash'
    log "version:  $oc_ver"
    log 'route:    admin/services/openclash'
    log 'alias:    nradio/advanced/openclash'
    log "backup:   $OPENCLASH_FIX_BACKUP_DIR"
    log "log.sh:   $OPENCLASH_LOGSH"
    log 'next:     close appcenter popup, then press Ctrl+F5 and reopen OpenClash'
}

show_menu() {
    printf '1. 安装 ttyd\n'
    printf '2. 安装 OpenClash\n'
    printf '3. 安装 KMS\n'
    printf '4. 生成 appcenter_modified_v1.htm\n'
    printf '请选择 [1-4]: '
    read -r choice
    case "$choice" in
        1) install_ttyd ;;
        2) install_openclash ;;
        3) install_kms ;;
        4) build_workspace_appcenter_modified_v1 ;;
        *) die 'invalid choice' ;;
    esac
}

prepare_runtime() {
    case "${1:-}" in
        build-appcenter) ;;
        *)
            require_root
            ensure_default_feeds
            ;;
    esac
}

main() {
    prepare_runtime "${1:-}"
    case "${1:-}" in
        build-appcenter)
            build_workspace_appcenter_modified_v1
            ;;
        ttyd)
            install_ttyd
            ;;
        openclash)
            install_openclash
            ;;
        kms)
            install_kms
            ;;
        "" )
            show_menu
            ;;
        *) die 'usage: NRadio_plugin [ttyd|openclash|kms|build-appcenter]' ;;
    esac
}

main "$@"
