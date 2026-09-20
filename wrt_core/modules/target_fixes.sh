#!/usr/bin/env bash
# target、kernel 与 base system 源码修正。

set_official_openwrt_apk_repo() {
    local version_makefile="$BUILD_DIR/include/version.mk"

    if [ ! -f "$version_makefile" ]; then
        echo "错误：当前源码缺少 include/version.mk。" >&2
        return 1
    fi

    python3 - "$version_makefile" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
matches = [
    index
    for index, line in enumerate(lines)
    if line.startswith("VERSION_REPO:=")
    and (
        "https://downloads.immortalwrt.org" in line
        or "https://downloads.openwrt.org" in line
    )
]
if len(matches) != 1:
    raise SystemExit("include/version.mk 中未找到唯一的 VERSION_REPO 定义")

index = matches[0]
line = lines[index]
if "https://downloads.openwrt.org" in line:
    raise SystemExit(0)
if "https://downloads.immortalwrt.org" not in line:
    raise SystemExit("include/version.mk 的 VERSION_REPO 不是可识别的官方仓库")

lines[index], count = re.subn(
    r"https://downloads\.immortalwrt\.org",
    "https://downloads.openwrt.org",
    line,
    count=1,
)
if count != 1:
    raise SystemExit("无法替换 include/version.mk 中的 VERSION_REPO")
path.write_text("".join(lines))
PY

    echo "已将 APK 默认软件源切换为 OpenWrt 官方仓库。"
}

disable_default_apk_mirror() {
    local settings_path="$BUILD_DIR/package/emortal/default-settings/files/99-default-settings-chinese"

    if [ ! -f "$settings_path" ]; then
        echo "错误：当前源码缺少 99-default-settings-chinese。" >&2
        return 1
    fi

    python3 - "$settings_path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
start_marker = "if uci -q get system.@imm_init[0].opkg_mirror"
end_marker = 'sed -i.bak "s,https://downloads.immortalwrt.org,$apk_mirror,g" "/etc/apk/repositories.d/distfeeds.list"'

if start_marker not in text and end_marker not in text:
    raise SystemExit(0)
if start_marker not in text or end_marker not in text:
    raise SystemExit("99-default-settings-chinese 中的 APK 镜像替换逻辑不完整")

start = text.index(start_marker)
end = text.index(end_marker, start) + len(end_marker)
while end < len(text) and text[end] in "\r\n":
    end += 1

path.write_text(text[:start].rstrip() + "\n\n" + text[end:].lstrip("\r\n"))
PY

    if grep -qE 'mirrors\.vsean\.net/openwrt|downloads\.immortalwrt\.org,\$apk_mirror' "$settings_path"; then
        echo "错误：ImmortalWrt APK 国内镜像替换逻辑仍然存在。" >&2
        return 1
    fi

    echo "已禁用 APK 国内镜像替换，保留 OpenWrt 官方软件源。"
}

fix_default_set() {
    # 注入默认主题、系统设置和目标平台通用补丁。
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
    fi

    set_official_openwrt_apk_repo
    disable_default_apk_mirror

    install -Dm544 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
    install -Dm544 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"
    install -Dm544 "$BASE_PATH/patches/992_set-wifi-uci.sh" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/992_set-wifi-uci.sh"

    if [ -f "$BUILD_DIR/package/emortal/autocore/files/tempinfo" ] && [ -f "$BASE_PATH/patches/autocore-tempinfo-hwmon.patch" ]; then
        if grep -q "hwmon driver name" "$BUILD_DIR/package/emortal/autocore/files/tempinfo"; then
            : # already applied
        elif (cd "$BUILD_DIR" && patch -p1 -N -r - -s < "$BASE_PATH/patches/autocore-tempinfo-hwmon.patch"); then
            echo "Applied autocore-tempinfo-hwmon patch"
        else
            echo "WARNING: autocore-tempinfo-hwmon.patch failed to apply cleanly - rebase needed" >&2
        fi
    fi

    # rpcd: legacy iStoreOS backends (quickstartd) require values.token in
    # session data. Dropping the patch file into the package's patches/ dir
    # lets the package build apply it to the extracted source.
    if [ -d "$BUILD_DIR/package/system/rpcd" ] && [ -f "$BASE_PATH/patches/rpcd-session-values-token.patch" ]; then
        mkdir -p "$BUILD_DIR/package/system/rpcd/patches"
        \cp -f "$BASE_PATH/patches/rpcd-session-values-token.patch" \
            "$BUILD_DIR/package/system/rpcd/patches/999-session-values-token.patch"
    fi
}

# velocloud_5x0: applied in stage_post_install_package_fixes (after feeds are
# fully installed; running this earlier can silently miss the feed dir).
apply_custom_feed_patches() {
    # istore home-page CPU temperature fallback (coreboot has no
    # thermal_zone0; C2558 coretemp exposes only temp2..temp5). A reject here
    # means the feed file drifted - rebase the patch, don't shadow it.
    local istore_lua="$BUILD_DIR/feeds/custom_feed/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    if [ -f "$istore_lua" ] && [ -f "$BASE_PATH/patches/istore_backend-lua.patch" ]; then
        (cd "$BUILD_DIR/feeds/custom_feed/luci-app-quickstart" && patch -p1 -N -r - -s < "$BASE_PATH/patches/istore_backend-lua.patch") \
            && echo "Applied istore_backend.lua velocloud_5x0 patch" \
            || echo "WARNING: istore_backend-lua.patch failed to apply cleanly - rebase needed" >&2
    fi

    # appfilter bundles the LuCI ACL json that luci-app-oaf also ships;
    # apk rejects the duplicate file. The LuCI app is the proper owner.
    local oaf_mk="$BUILD_DIR/feeds/custom_feed/open-app-filter/Makefile"
    if [ -f "$oaf_mk" ] && [ -f "$BASE_PATH/patches/open-app-filter-no-bundled-acl.patch" ]; then
        if (cd "$BUILD_DIR/feeds/custom_feed/open-app-filter" && patch -p1 -N -r - -s < "$BASE_PATH/patches/open-app-filter-no-bundled-acl.patch"); then
            echo "Applied open-app-filter no-bundled-acl patch"
            # force rebuild+repackage: drop build dir and the stale apk
            rm -rf "$BUILD_DIR"/build_dir/target-*/open-app-filter* 2>/dev/null
            rm -f "$BUILD_DIR"/bin/packages/*/custom_feed/appfilter-*.apk 2>/dev/null
        else
            echo "WARNING: open-app-filter-no-bundled-acl.patch failed to apply cleanly - rebase needed" >&2
        fi
    fi

    # quickstart 首页深度定制：
    # 1. 挂载 OpenClash 科学代理卡片与 Lucky 运维管理卡片
    # 2. 移除冗余的存储服务卡片
    # 3. 文件管理按钮直达 luci-app-quickfile
    # 4. 修复小三角磁盘管理 404 错误 (diskman -> mini-diskmanager)
    # 5. 修正 appfilter -> oaf 链接及 linkState 检测
    local qs_js_list
    mapfile -t qs_js_list < <(find "$BUILD_DIR" -type f -path "*/luci-app-quickstart/htdocs/luci-static/quickstart/index.js" 2>/dev/null)
    for qs_js in "${qs_js_list[@]}"; do
        [ -f "$qs_js" ] || continue
        python3 - "$qs_js" <<'PY'
import sys
import re
from pathlib import Path

p = Path(sys.argv[1])
content = p.read_text(encoding="utf-8", errors="ignore")

# 1. 修复磁盘管理 404 错误与文件管理直达 quickfile
content = content.replace("/cgi-bin/luci/admin/system/diskman", "/cgi-bin/luci/admin/system/mini-diskmanager")
content = re.sub(
    r'zt\.installAndGo\("luci-app-linkease",[a-zA-Z0-9_$]+\("\\u6613\\u6709\\u4E91"\),"/cgi-bin/luci/admin/services/linkease/file/","app-meta-linkease"\)',
    r'window.open("/cgi-bin/luci/admin/system/quickfile", "_self")',
    content
)
content = content.replace("/cgi-bin/luci/admin/services/linkease/file/", "/cgi-bin/luci/admin/system/quickfile")

# 2. 定制 Lucky 卡片 (原 remoteDomain / s5)
content = content.replace("DDNSTO", "Lucky")
content = content.replace("https://www.kooldns.cn/app/#/devices", "/cgi-bin/luci/admin/services/lucky")
content = re.sub(r'b6\(\{url:p\.value\.ddnstoDomain\}\)', 'window.open("/cgi-bin/luci/admin/services/lucky", "_blank")', content)
content = content.replace(r'title:e(n)("\u8FDC\u7A0B\u57DF\u540D")', r'title:e(n)("Lucky 动态域名与反代")')
content = content.replace(r'dt(" "+i(e(n)("\u57DF\u540D\u914D\u7F6E")),1)', r'dt(" "+i(e(n)("Lucky 配置")),1)')

# 3. 将原 downloadService (n1) 改造为 OpenClash 卡片
content = content.replace(r'title:e(n)("\u4E0B\u8F7D\u670D\u52A1")', r'title:e(n)("OpenClash 科学代理")')
content = content.replace(r'i(e(n)("\u4E0B\u8F7D\u7BA1\u7406"))', r'i(e(n)("OpenClash 配置"))')
content = re.sub(r'const\s+v=\(\)=>\{G\.Guide\.DownloadPartition\.List\.GET\(\)[^}]+\};', 'const v=()=>{window.open("/cgi-bin/luci/admin/services/openclash", "_self")};', content)
content = content.replace(r'i(e(n)("Aria2\u9AD8\u7EA7\u914D\u7F6E"))', r'i(e(n)("OpenClash 控制台"))')
content = content.replace(r'i(e(n)("qBittorrent\u9AD8\u7EA7\u914D\u7F6E"))', r'i(e(n)("Cloudflare 优选测速"))')
content = content.replace(r'i(e(n)("Transmission\u9AD8\u7EA7\u914D\u7F6E"))', r'i(e(n)("NetBird 异地组网"))')
content = re.sub(r'y=\(\)=>\{b\("app-meta-aria2","Aria2","/cgi-bin/luci/admin/services/aria2"\)\}', 'y=()=>{window.open("/cgi-bin/luci/admin/services/openclash", "_self")}', content)
content = re.sub(r'f=\(\)=>\{b\("app-meta-qbittorrent","qBittorrent","/cgi-bin/luci/admin/nas/qBittorrent"\)\}', 'f=()=>{window.open("/cgi-bin/luci/admin/services/cloudflarespeedtest", "_self")}', content)
content = re.sub(r'F=\(\)=>\{b\("app-meta-transmission","Transmission","/cgi-bin/luci/admin/services/transmission"\)\}', 'F=()=>{window.open("/cgi-bin/luci/admin/vpn/netbird", "_self")}', content)

# 4. 移除 storage 相关的残留
content = re.sub(r'f\.value\.storage&&R\.push\(\{key:"storage",component:[a-zA-Z0-9_$]+\}\),', '', content)
content = re.sub(r'\{key:"storage",title:[a-zA-Z0-9_$]+\("\\u5B58\\u50A8\\u670D\\u52A1"\),description:[a-zA-Z0-9_$]+\("\\u5171\\u4EAB\\u4E0E\\u5B58\\u50A8\\u670D\\u52A1\\u6982\\u89C8"\)\},', '', content)

# 5. 确保在卡片数组 A 中挂载 OpenClash (n1) 和 Lucky (s5)
content = re.sub(
    r'f\.value\.downloadService&&R\.push\(\{key:"downloadService",component:[a-zA-Z0-9_$]+\}\)',
    r'R.push({key:"openclash",component:n1})',
    content
)
content = re.sub(
    r'f\.value\.remoteDomain&&R\.push\(\{key:"remoteDomain",component:[a-zA-Z0-9_$]+\}\)',
    r'R.push({key:"lucky",component:s5})',
    content
)

# 6. 更新设置管理列表 R 中的文案
content = re.sub(
    r'\{key:"downloadService",title:[a-zA-Z0-9_$]+\("\\u4E0B\\u8F7D\\u670D\\u52A1"\),description:[a-zA-Z0-9_$]+\("\\u4E0B\\u8F7D\\u4EFB\\u52A1\\u4E0E\\u670D\\u52A1\\u72B6\\u6001"\)\}',
    r'{key:"openclash",title:n("OpenClash"),description:n("科学代理与智能分流")}',
    content
)
content = re.sub(
    r'\{key:"remoteDomain",title:[a-zA-Z0-9_$]+\("\\u8FDC\\u7A0B\\u57DF\\u540D"\),description:[a-zA-Z0-9_$]+\("\\u8FDC\\u7A0B\\u8BBF\\u95EE\\u57DF\\u540D\\u7BA1\\u7406"\)\}',
    r'{key:"lucky",title:n("Lucky"),description:n("动态域名解析与反向代理")}',
    content
)

# 7. 修正 appfilter -> oaf 链接及 linkState
content = content.replace("admin/services/appfilter", "admin/services/oaf")
content = content.replace('linkState=="DOWN"', 'linkState!="UP"')

p.write_text(content, encoding="utf-8")
print(f"已成功对 {p} 应用定制补丁 (OpenClash + Lucky 卡片 / 修复 diskman 404 / QuickFile 替换)。")
PY
    done

    # 智能随动主题设置菜单（Argon / Aurora 随当前生效主题自适应显示，统一标题为“主题设置”）
    fix_theme_config_menus

    # PPtP 协议名称统一修正为 PPTP
    local pptp_js="$BUILD_DIR/feeds/luci/protocols/luci-proto-ppp/htdocs/luci-static/resources/protocol/pptp.js"
    if [ -f "$pptp_js" ] && grep -q "_('PPtP')" "$pptp_js"; then
        sed -i "s/_('PPtP')/_('PPTP')/g" "$pptp_js"
        echo "Patched pptp.js protocol label PPtP -> PPTP"
    fi

    # argon base font is 0.975rem (15.6px vs bootstrap 13px); use 0.875rem
    # (14px). The sidenav brand title (1.8rem) overflows its column; use
    # 1.4rem. Match bare values: upstream ships both minified and formatted
    # variants of cascade.css and each value appears exactly once.
    local argon_css="$BUILD_DIR/feeds/custom_feed/luci-theme-argon/htdocs/luci-static/argon/css/cascade.css"
    if [ -f "$argon_css" ]; then
        if grep -q "0\.975rem" "$argon_css"; then
            sed -i 's/0\.975rem/0.875rem/g' "$argon_css"
            echo "Patched argon base font-size 0.975rem -> 0.875rem"
        fi
        if grep -q "1\.8rem" "$argon_css"; then
            sed -i 's/1\.8rem/1.4rem/g' "$argon_css"
            echo "Patched argon sidenav brand 1.8rem -> 1.4rem"
        fi
    fi

    # argon-config ships font_weight '600' (bold) as the default, both in the
    # uci config and the settings form default; normal is the sane default.
    local argon_cfg="$BUILD_DIR/feeds/custom_feed/luci-app-argon-config/root/etc/config/argon"
    if [ -f "$argon_cfg" ] && grep -q "font_weight '600'" "$argon_cfg"; then
        sed -i "s/option font_weight '600'/option font_weight 'normal'/" "$argon_cfg"
        echo "Patched argon default font_weight 600 -> normal"
    fi
    local argon_js="$BUILD_DIR/feeds/custom_feed/luci-app-argon-config/htdocs/luci-static/resources/view/argon-config.js"
    if [ -f "$argon_js" ] && grep -q "default = '600'\|o.default='600'" "$argon_js"; then
        sed -i "s/default = '600'/default = 'normal'/; s/o.default='600'/o.default='normal'/" "$argon_js"
        echo "Patched argon-config form default font -> normal"
    fi

    # smartdns 1.2025.47: git-repack tarball is on no mirror and its hash is
    # not reproducible across toolchains; fetch the commit tarball from
    # codeload instead (identical bytes everywhere). Self-retires when the
    # feed bumps the version (grep guard stops matching).
    local sd_mk="$BUILD_DIR/feeds/packages/net/smartdns/Makefile"
    if [ -f "$sd_mk" ] && [ -f "$BASE_PATH/patches/smartdns-codeload.patch" ] \
        && ! grep -q "codeload.github.com/pymumu/smartdns" "$sd_mk"; then
        (cd "$BUILD_DIR/feeds/packages/net/smartdns" && patch -p1 -N -r - -s < "$BASE_PATH/patches/smartdns-codeload.patch") \
            && echo "Applied smartdns codeload patch" \
            || echo "WARNING: smartdns-codeload.patch failed to apply cleanly - rebase needed" >&2
    fi
}


fix_miniupnpd() {
    local miniupnpd_dir="$BUILD_DIR/feeds/packages/net/miniupnpd"
    local patch_file="999-chanage-default-leaseduration.patch"

    if [ -d "$miniupnpd_dir" ] && [ -f "$BASE_PATH/patches/$patch_file" ]; then
        install -Dm644 "$BASE_PATH/patches/$patch_file" "$miniupnpd_dir/patches/$patch_file"
    fi
}


change_dnsmasq2full() {
    if ! grep -q "dnsmasq-full" $BUILD_DIR/include/target.mk; then
        sed -i 's/dnsmasq/dnsmasq-full/g' ./include/target.mk
    fi
}


fix_mk_def_depends() {
    sed -i 's/libustream-mbedtls/libustream-openssl/g' $BUILD_DIR/include/target.mk 2>/dev/null
    if [ -f $BUILD_DIR/target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' $BUILD_DIR/target/linux/qualcommax/Makefile
    fi
}


fix_kconfig_recursive_dependency() {
    local file="$BUILD_DIR/scripts/package-metadata.pl"
    if [ -f "$file" ]; then
        sed -i 's/<PACKAGE_\$pkgname/!=y/g' "$file"
        echo "已修复 package-metadata.pl 的 Kconfig 递归依赖生成逻辑。"
    fi
}


update_default_lan_addr() {
    local CFG_PATH="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
    fi
}


remove_something_nss_kmod() {
    local ipq_mk_path="$BUILD_DIR/target/linux/qualcommax/Makefile"
    local target_mks=("$BUILD_DIR/target/linux/qualcommax/ipq60xx/target.mk" "$BUILD_DIR/target/linux/qualcommax/ipq807x/target.mk")

    for target_mk in "${target_mks[@]}"; do
        if [ -f "$target_mk" ]; then
            sed -i 's/kmod-qca-nss-crypto//g' "$target_mk"
        fi
    done

    if [ -f "$ipq_mk_path" ]; then
        sed -i '/kmod-qca-nss-drv-eogremgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-gre/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-map-t/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-match/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-mirror/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tun6rd/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tunipip6/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-vxlanmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-wifi-meshmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-macsec/d' "$ipq_mk_path"

        sed -i 's/automount //g' "$ipq_mk_path"
        sed -i 's/cpufreq //g' "$ipq_mk_path"
    fi
}


update_affinity_script() {
    local affinity_script_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$affinity_script_dir" ]; then
        find "$affinity_script_dir" -name "set-irq-affinity" -exec rm -f {} \;
        find "$affinity_script_dir" -name "smp_affinity" -exec rm -f {} \;
        install -Dm755 "$BASE_PATH/patches/smp_affinity" "$affinity_script_dir/base-files/etc/init.d/smp_affinity"
    fi
}


fix_hash_value() {
    local makefile_path="$1"
    local old_hash="$2"
    local new_hash="$3"
    local package_name="$4"

    if [ -f "$makefile_path" ]; then
        sed -i "s/$old_hash/$new_hash/g" "$makefile_path"
        echo "已修正 $package_name 的哈希值。"
    fi
}


apply_hash_fixes() {
    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "860a816bf1e69d5a8a2049483197dbebe8a3da2c9b05b2da68c85ef7dee7bdde" \
        "582021891808442b01f551bc41d7d95c38fb00c1ec78a58ac3aaaf898fbd2b5b" \
        "smartdns"

    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "320c99a65ca67a98d11a45292aa99b8904b5ebae5b0e17b302932076bf62b1ec" \
        "43e58467690476a77ce644f9dc246e8a481353160644203a1bd01eb09c881275" \
        "smartdns"
}


update_ath11k_fw() {
    local makefile="$BUILD_DIR/package/firmware/ath11k-firmware/Makefile"
    local new_mk="$BASE_PATH/patches/ath11k_fw.mk"
    local url="https://raw.githubusercontent.com/VIKINGYFY/immortalwrt/refs/heads/main/package/firmware/ath11k-firmware/Makefile"
    local ipq60_target="$BUILD_DIR/target/linux/qualcommax/ipq60xx/target.mk"
    local ipq807_target="$BUILD_DIR/target/linux/qualcommax/ipq807x/target.mk"

    if [ -d "$(dirname "$makefile")" ]; then
        echo "正在更新 ath11k-firmware Makefile..."
        if ! curl_retry -fsSL -o "$new_mk" "$url"; then
            echo "错误：从 $url 下载 ath11k-firmware Makefile 失败" >&2
            exit 1
        fi
        if [ ! -s "$new_mk" ]; then
            echo "错误：下载的 ath11k-firmware Makefile 为空文件" >&2
            exit 1
        fi
        mv -f "$new_mk" "$makefile"

        if [ -f "$ipq60_target" ]; then
            sed -i 's/ath11k-firmware-ipq6018\([^-[:alnum:]_]\|$\)/ath11k-firmware-ipq6018-ddwrt\1/g' "$ipq60_target"
        fi

        if [ -f "$ipq807_target" ]; then
            sed -i 's/ath11k-firmware-ipq8074\([^-[:alnum:]_]\|$\)/ath11k-firmware-ipq8074-ddwrt\1/g' "$ipq807_target"
        fi

        if [ -f "$ipq60_target" ] || [ -f "$ipq807_target" ]; then
            echo "已同步 ipq60xx/ipq807x ath11k 固件依赖为 ddwrt 包名。"
        fi
    fi
}


change_cpuusage() {
    local luci_rpc_path="$BUILD_DIR/feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
    local qualcommax_sbin_dir="$BUILD_DIR/target/linux/qualcommax/base-files/sbin"
    local filogic_sbin_dir="$BUILD_DIR/target/linux/mediatek/filogic/base-files/sbin"

    if [ -f "$luci_rpc_path" ]; then
        sed -i "s#const fd = popen('top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\'')#const cpuUsageCommand = access('/sbin/cpuusage') ? '/sbin/cpuusage' : 'top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\''#g" "$luci_rpc_path"
        sed -i '/cpuUsageCommand/a \\t\t\tconst fd = popen(cpuUsageCommand);' "$luci_rpc_path"
    fi

    local old_script_path="$BUILD_DIR/package/base-files/files/sbin/cpuusage"
    if [ -f "$old_script_path" ]; then
        rm -f "$old_script_path"
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax" ]; then
        install -Dm755 "$BASE_PATH/patches/cpuusage" "$qualcommax_sbin_dir/cpuusage"
    fi
    if [ -d "$BUILD_DIR/target/linux/mediatek" ]; then
        install -Dm755 "$BASE_PATH/patches/hnatusage" "$filogic_sbin_dir/cpuusage"
    fi
}


update_nss_pbuf_performance() {
    local pbuf_path="$BUILD_DIR/package/kernel/mac80211/files/pbuf.uci"
    if [ -d "$(dirname "$pbuf_path")" ] && [ -f $pbuf_path ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" $pbuf_path
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" $pbuf_path
    fi
}


update_nss_diag() {
    local file="$BUILD_DIR/package/kernel/mac80211/files/nss_diag.sh"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        \rm -f "$file"
        install -Dm755 "$BASE_PATH/patches/nss_diag.sh" "$file"
    fi
}


fix_compile_coremark() {
    local file="$BUILD_DIR/feeds/packages/utils/coremark/Makefile"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i 's/mkdir \$/mkdir -p \$/g' "$file"
    fi
}


update_dnsmasq_conf() {
    local file="$BUILD_DIR/package/network/services/dnsmasq/files/dhcp.conf"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i '/dns_redirect/d' "$file"
    fi
}


add_backup_info_to_sysupgrade() {
    local conf_path="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"

    if [ -f "$conf_path" ]; then
        cat >"$conf_path" <<'EOF'
/etc/AdGuardHome.yaml
/etc/easytier
/etc/lucky/
EOF
    fi
}


fix_rust_compile_error() {
    if [ -f "$BUILD_DIR/feeds/packages/lang/rust/Makefile" ]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$BUILD_DIR/feeds/packages/lang/rust/Makefile"
    fi
}


fix_theme_config_menus() {
    # 统一主题设置菜单并实现根据当前激活主题智能随动显隐
    local argon_menus
    mapfile -t argon_menus < <(find "$BUILD_DIR" -type f -path "*/luci-app-argon-config/*/menu.d/*.json" 2>/dev/null)
    for f in "${argon_menus[@]}"; do
        [ -f "$f" ] || continue
        python3 - "$f" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fp:
        data = json.load(fp)
    for k, v in data.items():
        v["title"] = "主题设置"
        v["order"] = 90
        v["depends"] = {
            "uci": { "luci": { "main": { "mediaurlbase": "/luci-static/argon" } } }
        }
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(data, fp, indent="\t", ensure_ascii=False)
    print(f"已更新 {path} 为 Argon 智能随动菜单。")
except Exception as e:
    sys.stderr.write(f"Error updating argon menu: {e}\n")
PY
    done

    local aurora_menus
    mapfile -t aurora_menus < <(find "$BUILD_DIR" -type f -path "*/luci-app-aurora-config/*/menu.d/*.json" 2>/dev/null)
    for f in "${aurora_menus[@]}"; do
        [ -f "$f" ] || continue
        python3 - "$f" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fp:
        data = json.load(fp)
    for k, v in data.items():
        if k == "admin/system/aurora":
            v["title"] = "主题设置"
            v["order"] = 90
            v["depends"] = {
                "uci": { "luci": { "main": { "mediaurlbase": "/luci-static/aurora" } } }
            }
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(data, fp, indent="\t", ensure_ascii=False)
    print(f"已更新 {path} 为 Aurora 智能随动菜单。")
except Exception as e:
    sys.stderr.write(f"Error updating aurora menu: {e}\n")
PY
    done
}

