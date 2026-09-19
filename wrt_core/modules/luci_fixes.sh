#!/usr/bin/env bash
# LuCI 展示、菜单和前端相关修正。

set_build_signature() {
    local file="$BUILD_DIR/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -d "$(dirname "$file")" ] && [ -f $file ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by dqsq2e2')/g" "$file"
    fi
}

update_menu_location() {
    local samba4_path="$BUILD_DIR/feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    if [ -d "$(dirname "$samba4_path")" ] && [ -f "$samba4_path" ]; then
        sed -i 's/nas/services/g' "$samba4_path"
    fi

    local tailscale_path="$(get_custom_feed_worktree_dir)/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    if [ -d "$(dirname "$tailscale_path")" ] && [ -f "$tailscale_path" ]; then
        sed -i 's/services/vpn/g' "$tailscale_path"
    fi

    # 遍历构建树中所有 menu.d/*.json 配置文件进行全局菜单定位与清理
    find "$BUILD_DIR" -type f -path "*/usr/share/luci/menu.d/*.json" 2>/dev/null | while read -r jf; do
        [ -f "$jf" ] || continue

        # 1. 彻底删除 diskman 菜单，消除磁盘阵列与 S.M.A.R.T 的入口
        if [[ "$(basename "$jf")" == "luci-app-diskman.json" ]]; then
            rm -f "$jf"
            continue
        fi

        # 2. 超级网络唤醒移动至服务菜单
        if [[ "$(basename "$jf")" == "luci-app-wolultra.json" ]]; then
            sed -i 's#"admin/control/wolultra"#"admin/services/wolultra"#g' "$jf"
            sed -i '/"admin\/control": {/,/^[[:space:]]*},/d' "$jf"
        fi

        # 3. NetBird 移动至 VPN 菜单并补全 admin/vpn 节点定义
        if [[ "$(basename "$jf")" == "luci-app-netbird.json" ]]; then
            python3 - "$jf" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    new_data = {}
    new_data["admin/vpn"] = {
        "title": "VPN",
        "order": 45,
        "action": {"type": "firstchild"}
    }
    for k, v in data.items():
        new_k = k.replace("admin/services/netbird", "admin/vpn/netbird")
        new_data[new_k] = v
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(new_data, f, indent="\t", ensure_ascii=False)
except Exception:
    pass
PY
        fi

        # 4. 全局清理残留的 admin/control (管控菜单) 与 admin/nas (NAS菜单)
        sed -i 's#"admin/control/#"admin/services/#g' "$jf"
        sed -i '/"admin\/control": {/,/^[[:space:]]*},/d' "$jf"
        sed -i 's#"admin/nas/#"admin/services/#g' "$jf"
        sed -i '/"admin\/nas": {/,/^[[:space:]]*},/d' "$jf"
    done
}


update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    local source_date="2024-03-02"
    local source_version="564fa3e9c2b04ea298ea659b793480415da26415"
    local mirror_hash="92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f"

    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=$source_date/g" "$makefile_path"
        sed -i "s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=$source_version/g" "$makefile_path"
        sed -i "s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=$mirror_hash/g" "$makefile_path"
        echo "已更新 nginx-mod-ubus 模块的 SOURCE_DATE, SOURCE_VERSION 和 MIRROR_HASH。"
    else
        echo "错误：未找到 $makefile_path 文件，无法更新 nginx-mod-ubus 模块。" >&2
    fi
}
