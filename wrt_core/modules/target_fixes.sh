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
    # 2. 移除冗余的存储服务卡片与下载服务卡片
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

# 2. 重写 o1 (原下载服务组件) 为原生三方块风格的 OpenClash 卡片组件
pos_o1_start = content.find("o1=I({")
pos_o1_end = content.find(";var n1=N(o1,")
if pos_o1_end == -1:
    pos_o1_end = content.find("var n1=N(o1,")

if pos_o1_start != -1 and pos_o1_end != -1:
    openclash_comp_code = '''o1=I({setup(o){const {$gettext:n}=J();const toOC=()=>{window.open("/cgi-bin/luci/admin/services/openclash","_self")},toCF=()=>{window.open("/cgi-bin/luci/admin/services/cloudflarespeedtest","_self")},toNB=()=>{window.open("/cgi-bin/luci/admin/vpn/netbird","_self")};return()=>(r(),Z(Wt,{title:e(n)("OpenClash 科学代理"),showSettings:!0,style:{width:"100%",height:"100%",display:"block"}},{icon:V(()=>[Y(pa,{color:"#155dfc",class:"icon"})]),settings:V(()=>[t("div",{class:"btn_settings",onClick:toOC},[Y(pa,{color:"#0a0a0a",class:"icon1",style:{"margin-right":"6px"}}),t("span",null,"配置中心",1)])]),default:V(()=>[t("div",Rc,[t("div",Wc,[t("div",{class:"item cloud",style:{cursor:"pointer"},onClick:toOC},[Y(pa,{color:"#155dfc",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"OpenClash"),t("span",{class:"configure enable"},"代理管理")]),t("div",{class:"item memory",style:{cursor:"pointer"},onClick:toCF},[Y(pa,{color:"#f54900",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"CF 测速"),t("span",{class:"configure enable"},"优选节点")]),t("div",{class:"item network",style:{cursor:"pointer"},onClick:toNB},[Y(pa,{color:"#009689",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"NetBird"),t("span",{class:"configure enable"},"异地组网")])]),t("div",{style:{padding:"12px 16px 4px",fontSize:"13px",color:"#666",display:"flex",justifyContent:"space-between",alignItems:"center"}},[t("span",null,"智能分流与科学代理中心"),t("a",{style:{color:"#155dfc",fontWeight:"bold",cursor:"pointer"},onClick:toOC},"进入 OpenClash 控制台 ➔")])])])}))}})'''
    content = content[:pos_o1_start] + openclash_comp_code + content[pos_o1_end:]

# 3. 重写 r5 (原远程域名组件) 为原生三方块风格的 Lucky 运维卡片组件
pos_r5_start = content.find("r5=I({")
pos_r5_end = content.find(";var s5=N(r5,")
if pos_r5_end == -1:
    pos_r5_end = content.find("var s5=N(r5,")

if pos_r5_start != -1 and pos_r5_end != -1:
    lucky_comp_code = '''r5=I({setup(o){const {$gettext:n}=J();const toLucky=()=>{window.open("/cgi-bin/luci/admin/services/lucky","_blank")};return()=>(r(),Z(Wt,{title:e(n)("Lucky 运维管理"),showSettings:!0,style:{width:"100%",height:"100%",display:"block"}},{icon:V(()=>[Y(He,{color:"#00a63e",class:"icon"})]),settings:V(()=>[t("div",{class:"btn_settings",onClick:toLucky},[Y(He,{color:"#0a0a0a",class:"icon1",style:{"margin-right":"6px"}}),t("span",null,"控制台",1)])]),default:V(()=>[t("div",Rc,[t("div",Wc,[t("div",{class:"item cloud",style:{cursor:"pointer"},onClick:toLucky},[Y(He,{color:"#00a63e",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"动态域名"),t("span",{class:"configure enable"},"DDNS")]),t("div",{class:"item memory",style:{cursor:"pointer"},onClick:toLucky},[Y(He,{color:"#155dfc",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"端口转发"),t("span",{class:"configure enable"},"反向代理")]),t("div",{class:"item network",style:{cursor:"pointer"},onClick:toLucky},[Y(He,{color:"#ea580c",class:"icon2"}),t("div",{class:"aria2-name",style:{fontWeight:"bold"}},"WebDAV"),t("span",{class:"configure enable"},"文件服务")])]),t("div",{style:{padding:"12px 16px 4px",fontSize:"13px",color:"#666",display:"flex",justifyContent:"space-between",alignItems:"center"}},[t("span",null,"Lucky 动态解析与内网穿透"),t("a",{style:{color:"#00a63e",fontWeight:"bold",cursor:"pointer"},onClick:toLucky},"打开 Lucky 控制台 ➔")])])])}))}})'''
    content = content[:pos_r5_start] + lucky_comp_code + content[pos_r5_end:]

# 4. 彻底重写计算属性 A，确保 100% 渲染磁盘信息、Docker、OpenClash、Lucky 卡片
target_A = 'const A=Q(()=>{const R=[];return f.value.diskInfo&&R.push({key:"diskInfo",component:$g}),f.value.storage&&R.push({key:"storage",component:jf}),Qt("dockerd")&&f.value.docker&&R.push({key:"docker",component:Wv}),f.value.downloadService&&R.push({key:"downloadService",component:n1}),f.value.remoteDomain&&R.push({key:"remoteDomain",component:s5}),R})'
new_A = 'const A=Q(()=>{const R=[];return f.value.diskInfo!==false&&R.push({key:"diskInfo",component:$g}),Qt("dockerd")&&f.value.docker&&R.push({key:"docker",component:Wv}),R.push({key:"openclash",component:n1}),R.push({key:"lucky",component:s5}),R})'

if target_A in content:
    content = content.replace(target_A, new_A)
else:
    pattern_A = r'const A=Q\(\(\)=>\{const R=\[\];return .*?,R\}\)'
    m_A = re.search(pattern_A, content)
    if m_A:
        content = content[:m_A.start()] + new_A + content[m_A.end():]

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
print(f"已成功对 {p} 应用定制补丁 (OpenClash + Lucky 自包含组件 / 修复 diskman 404 / QuickFile 替换)。")
PY
    done

    # 双重保险：将定制完成的 index.js 写入 OpenWrt 构建树的 files/ 根文件系统覆盖层
    local final_qs_js
    final_qs_js=$(find "$BUILD_DIR" -type f -path "*/luci-app-quickstart/htdocs/luci-static/quickstart/index.js" 2>/dev/null | head -n 1)
    if [ -f "$final_qs_js" ]; then
        mkdir -p "$BUILD_DIR/files/www/luci-static/quickstart"
        cp -f "$final_qs_js" "$BUILD_DIR/files/www/luci-static/quickstart/index.js"
        echo "已将定制的 QuickStart index.js 写入 files/ 根文件系统终极覆盖层。"
    fi

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
    echo "正在配置主题菜单智能随动与视图隔离逻辑..."

    # 1. 核心层：在 ui.js 中对 getChildren 进行动态主题感知过滤，实现全局所有主题菜单的随动隔离
    #    同时规范化 Argon 与 Aurora 的 menu.d/*.json 菜单定义，并写入 files/ 根文件系统终极覆盖层
    python3 - "$BUILD_DIR" <<'PY'
import sys
import re
from pathlib import Path
import json

build_dir = Path(sys.argv[1])

# 1. 动态过滤 ui.js
ui_files = list(build_dir.glob("**/htdocs/luci-static/resources/ui.js"))
for p in ui_files:
    try:
        content = p.read_text(encoding="utf-8", errors="ignore")
        if "k === 'argon-config' && !curTheme.includes('argon')" in content:
            continue
        
        target = "if (!node.children[k].hasOwnProperty('title'))\n\t\t\t\tcontinue;"
        if target not in content:
            m = re.search(r"(if\s*\(!node\.children\[k\]\.hasOwnProperty\(['\"]title['\"]\)\)\s*continue;)", content)
            if m:
                target = m.group(1)
            else:
                continue
        
        patch_code = target + """\n
\t\t\tconst curTheme = L.env?.media || document.querySelector('link[href*="luci-static/"]')?.getAttribute('href') || '';
\t\t\tif (k === 'argon-config' && !curTheme.includes('argon'))
\t\t\t\tcontinue;
\t\t\tif (k === 'aurora' && !curTheme.includes('aurora'))
\t\t\t\tcontinue;"""
        content = content.replace(target, patch_code, 1)
        p.write_text(content, encoding="utf-8")
        print(f"已成功为 {p} 注入主题菜单动态过滤逻辑。")
    except Exception as e:
        sys.stderr.write(f"Error patching ui.js {p}: {e}\n")

# 2. 规范化 Argon 主题设置菜单
argon_menus = list(build_dir.glob("**/luci-app-argon-config/**/menu.d/*.json"))
argon_data = {
    "admin/system/argon-config": {
        "title": "Argon 主题设置",
        "order": 90,
        "action": {
            "type": "view",
            "path": "argon-config"
        },
        "depends": {
            "acl": ["luci-app-argon-config"],
            "uci": {"argon": True}
        }
    }
}
for p in argon_menus:
    try:
        p.write_text(json.dumps(argon_data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    except Exception as e:
        pass

# 3. 规范化 Aurora 主题设置菜单
aurora_menus = list(build_dir.glob("**/luci-app-aurora*/**/menu.d/*.json"))
aurora_data = {
    "admin/system/aurora": {
        "title": "Aurora 主题设置",
        "order": 90,
        "action": {
            "type": "firstchild"
        },
        "depends": {
            "acl": ["luci-app-aurora"]
        }
    },
    "admin/system/aurora/studio": {
        "title": "设计工作室",
        "order": 10,
        "action": {
            "type": "view",
            "path": "aurora/studio"
        }
    },
    "admin/system/aurora/marketplace": {
        "title": "主题市场",
        "order": 15,
        "action": {
            "type": "view",
            "path": "aurora/marketplace"
        }
    }
}
for p in aurora_menus:
    try:
        p.write_text(json.dumps(aurora_data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    except Exception as e:
        pass

# 4. 根文件系统 files/ 终极覆盖层同步
files_dir = build_dir / "files"
(files_dir / "www/luci-static/resources").mkdir(parents=True, exist_ok=True)
(files_dir / "usr/share/luci/menu.d").mkdir(parents=True, exist_ok=True)

# 写入 menu.d json 到 files/
(files_dir / "usr/share/luci/menu.d/luci-app-argon-config.json").write_text(
    json.dumps(argon_data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8"
)
(files_dir / "usr/share/luci/menu.d/luci-app-aurora.json").write_text(
    json.dumps(aurora_data, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8"
)

# 写入已打补丁的 ui.js 到 files/
ui_src = next(build_dir.glob("**/feeds/luci/modules/luci-base/htdocs/luci-static/resources/ui.js"), None)
if ui_src and ui_src.exists():
    (files_dir / "www/luci-static/resources/ui.js").write_text(ui_src.read_text(encoding="utf-8"), encoding="utf-8")
    print("已将定制 ui.js 写入 files/ 根文件系统覆盖层。")
PY

    # 2. 视图层双向智能重定向防呆保护
    local argon_js_list
    mapfile -t argon_js_list < <(find "$BUILD_DIR" -type f -path "*/luci-app-argon-config/*/view/argon-config.js" 2>/dev/null)
    for f in "${argon_js_list[@]}"; do
        [ -f "$f" ] || continue
        if ! grep -q "window.location.replace" "$f"; then
            sed -i '/render:[[:space:]]*function/a \
\t\tvar curTheme = L.env?.media || document.querySelector("link[href*=\\\"luci-static\\\"]")?.getAttribute("href") || "";\
\t\tif (curTheme.indexOf("aurora") !== -1) {\
\t\t\twindow.location.replace(L.url("admin/system/aurora/studio"));\
\t\t\treturn E("div", { class: "cbi-map" }, _("正在跳转至当前主题设置..."));\
\t\t}' "$f"
            echo "已为 $f 注入智能主题检测跳转逻辑。"
        fi
        mkdir -p "$BUILD_DIR/files/www/luci-static/resources/view"
        cp -f "$f" "$BUILD_DIR/files/www/luci-static/resources/view/argon-config.js"
    done

    local aurora_js_list
    mapfile -t aurora_js_list < <(find "$BUILD_DIR" -type f -path "*/luci-app-aurora-config/*/view/aurora/studio.js" 2>/dev/null)
    for f in "${aurora_js_list[@]}"; do
        [ -f "$f" ] || continue
        if ! grep -q "window.location.replace" "$f"; then
            sed -i '/render:[[:space:]]*function/a \
\t\tvar curTheme = L.env?.media || document.querySelector("link[href*=\\\"luci-static\\\"]")?.getAttribute("href") || "";\
\t\tif (curTheme.indexOf("argon") !== -1) {\
\t\t\twindow.location.replace(L.url("admin/system/argon-config"));\
\t\t\treturn E("div", { class: "cbi-map" }, _("正在跳转至当前主题设置..."));\
\t\t}' "$f"
            echo "已为 $f 注入智能主题检测跳转逻辑。"
        fi
        mkdir -p "$BUILD_DIR/files/www/luci-static/resources/view/aurora"
        cp -f "$f" "$BUILD_DIR/files/www/luci-static/resources/view/aurora/studio.js"
    done

    # 3. 侧边栏 CSS 物理级随动隔离
    local argon_css_list
    mapfile -t argon_css_list < <(find "$BUILD_DIR" -type f -path "*/luci-theme-argon/*/cascade.css" 2>/dev/null)
    for f in "${argon_css_list[@]}"; do
        [ -f "$f" ] || continue
        if ! grep -q "admin/system/aurora" "$f"; then
            cat >>"$f" <<'EOF'

/* 智能随动：在 Argon 主题下自动隐藏 Aurora 菜单 */
[data-page*="admin/system/aurora"], li:has(> a[href*="admin/system/aurora"]), a[href*="admin/system/aurora"] { display: none !important; }
EOF
            echo "已为 $f 添加 Aurora 菜单隔离样式。"
        fi
        mkdir -p "$BUILD_DIR/files/www/luci-static/argon/css"
        cp -f "$f" "$BUILD_DIR/files/www/luci-static/argon/css/cascade.css"
    done

    local aurora_css_list
    mapfile -t aurora_css_list < <(find "$BUILD_DIR" -type f -path "*/luci-theme-aurora/*/cascade.css" 2>/dev/null)
    for f in "${aurora_css_list[@]}"; do
        [ -f "$f" ] || continue
        if ! grep -q "admin/system/argon-config" "$f"; then
            cat >>"$f" <<'EOF'

/* 智能随动：在 Aurora 主题下自动隐藏 Argon 菜单 */
[data-page*="admin/system/argon-config"], li:has(> a[href*="admin/system/argon-config"]), a[href*="admin/system/argon-config"] { display: none !important; }
EOF
            echo "已为 $f 添加 Argon 菜单隔离样式。"
        fi
        mkdir -p "$BUILD_DIR/files/www/luci-static/aurora/css"
        cp -f "$f" "$BUILD_DIR/files/www/luci-static/aurora/css/cascade.css"
    done

    # 5. 全局 CBI 表格卡片内自适应横向滚动条修复（保证多列表格在卡片内部横向滚动，不越界）
    local tbl_list
    mapfile -t tbl_list < <(find "$BUILD_DIR" -type f -path "*/luci-compat/*/view/cbi/tblsection.htm" 2>/dev/null)
    for f in "${tbl_list[@]}"; do
        [ -f "$f" ] || continue
        python3 - "$f" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
content = p.read_text(encoding="utf-8")
if ".cbi-tblsection-table-scroll" not in content:
    style = """<style type="text/css">
.cbi-section.cbi-tblsection {
    max-width: 100% !important;
    box-sizing: border-box !important;
    overflow: hidden !important;
}
.cbi-tblsection-table-scroll {
    width: 100% !important;
    max-width: 100% !important;
    overflow-x: auto !important;
    -webkit-overflow-scrolling: touch !important;
    box-sizing: border-box !important;
    margin: 10px 0 !important;
    padding-bottom: 6px !important;
}
.cbi-tblsection-table-scroll::-webkit-scrollbar {
    height: 8px !important;
    background: #f1f5f9 !important;
}
.cbi-tblsection-table-scroll::-webkit-scrollbar-thumb {
    background: #5e72e4 !important;
    border-radius: 4px !important;
}
.cbi-tblsection-table-scroll::-webkit-scrollbar-thumb:hover {
    background: #324cdd !important;
}
.cbi-tblsection-table-scroll > table.cbi-section-table {
    min-width: 100% !important;
    width: max-content !important;
    display: table !important;
    table-layout: auto !important;
}
.cbi-tblsection-table-scroll .cbi-section-table-cell {
    white-space: nowrap !important;
}
</style>
"""
    content = content.replace('<!-- tblsection -->', style + '\n<!-- tblsection -->')
    content = content.replace('<table class="table cbi-section-table">', '<div class="cbi-tblsection-table-scroll">\n\t<table class="table cbi-section-table">', 1)
    idx = content.find('</table>')
    if idx != -1:
        content = content[:idx] + '</table>\n\t</div>' + content[idx+8:]
    p.write_text(content, encoding="utf-8")
    print("已对", p, "应用卡片内横向滚动容器补丁。")
PY
        mkdir -p "$BUILD_DIR/files/usr/lib/lua/luci/view/cbi"
        cp -f "$f" "$BUILD_DIR/files/usr/lib/lua/luci/view/cbi/tblsection.htm"
    done
}


