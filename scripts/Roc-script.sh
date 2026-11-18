#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  # Keep direct invocations compatible with an existing OpenWrt .config.
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 修改默认IP & 固件名称 & 编译署名和时间
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/laipeng668/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by Roc $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# Aria2 & nginx & Go & DDNS & frp & UPnP & Wol
rm -rf feeds/packages/lang/golang
git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv package/golang feeds/packages/lang/golang

if package_enabled luci-app-aria2 aria2; then
  rm -rf feeds/packages/net/aria2
  git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
  mv package/aria2 feeds/packages/net/aria2
fi
if package_enabled ariang; then
  rm -rf feeds/packages/net/ariang
  git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
  mv package/ariang feeds/packages/net/ariang
fi

if package_enabled nginx nginx-full nginx-ssl luci-app-nginx; then
  rm -rf feeds/packages/net/nginx
  git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
  mv package/nginx feeds/packages/net/nginx
fi

if package_enabled luci-app-ddns ddns-scripts ddns-scripts-cloudflare; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/laipeng668/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

if package_enabled frp frpc frps luci-app-frpc luci-app-frps; then
  rm -rf \
    feeds/packages/net/frp
  git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
  mv package/frp feeds/packages/net/frp
fi

frp_luci_paths=()
if package_enabled luci-app-frpc; then
  rm -rf feeds/luci/applications/luci-app-frpc
  frp_luci_paths+=(applications/luci-app-frpc)
fi
if package_enabled luci-app-frps; then
  rm -rf feeds/luci/applications/luci-app-frps
  frp_luci_paths+=(applications/luci-app-frps)
fi
if [ "${#frp_luci_paths[@]}" -gt 0 ]; then
  git_sparse_clone frp https://github.com/laipeng668/luci "${frp_luci_paths[@]}"
  for frp_luci_path in "${frp_luci_paths[@]}"; do
    mv "package/$(basename "$frp_luci_path")" "feeds/luci/$frp_luci_path"
    sed -i '/^LUCI_EXTRA_DEPENDS:=/d' "feeds/luci/$frp_luci_path/Makefile"
  done
fi

if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# Themes and standalone applications. A config application pulls in its theme as a dependency.
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

if package_enabled luci-app-openlist2 openlist2; then
  clone_repository https://github.com/laipeng668/luci-app-openlist2 main package/openlist2
fi

if package_enabled luci-app-lucky lucky; then
  clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky
fi

if package_enabled luci-app-wechatpush; then
  rm -rf feeds/luci/applications/luci-app-wechatpush
  clone_repository https://github.com/tty228/luci-app-wechatpush master package/luci-app-wechatpush
fi

if package_enabled luci-app-oaf open-app-filter; then
  rm -rf feeds/luci/applications/luci-app-appfilter feeds/packages/net/open-app-filter
  clone_repository https://github.com/destan19/OpenAppFilter.git master package/OpenAppFilter
fi

if package_enabled luci-app-gecoosac gecoosac; then
  clone_repository https://github.com/laipeng668/luci-app-gecoosac main package/luci-app-gecoosac
fi

if package_enabled luci-app-athena-led luci-i18n-athena-led-zh-cn; then
  clone_repository https://github.com/NONGFAH/luci-app-athena-led main package/luci-app-athena-led
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led
fi

### PassWall & OpenClash ###

if package_enabled luci-app-passwall luci-app-passwall2; then
  # 移除 OpenWrt Feeds 自带的核心库
  rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall-packages main package/passwall-packages
fi

if package_enabled luci-app-passwall; then
  rm -rf feeds/luci/applications/luci-app-passwall
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall main package/luci-app-passwall
fi

if package_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall2 main package/luci-app-passwall2
fi

if package_enabled luci-app-openclash; then
  rm -rf feeds/luci/applications/luci-app-openclash
  clone_repository https://github.com/vernesong/OpenClash master package/luci-app-openclash
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a

# =============================================================================
# Roc-script.sh 附加块 —— 针对京东云 RE-CS-02 (AX6600) 定制
# 用法：把本文件内容【粘贴到 scripts/Roc-script.sh 的末尾】
#       （即最后的 "./scripts/feeds update -i -a / ./scripts/feeds install -a" 之前或之后均可，
#        涉及 feeds 的部分请在 feeds install 之前，纯 files/ 注入可放在最后）
# =============================================================================

# ---------------------------------------------------------------------------
# 0) 【前置】统一创建所有需要的目录
#    上游脚本开头有 `set -Eeuo pipefail`，任何一次重定向到不存在的目录都会
#    立即终止整个构建。v1 构建失败正是因为在写 files/etc/uci-defaults/ 前
#    没有创建该目录（报错：99-ax6600-defaults: No such file or directory）。
# ---------------------------------------------------------------------------
mkdir -p files/usr/sbin \
         files/etc/uci-defaults \
         files/etc/init.d \
         files/lib/firmware/ath11k/IPQ6018/hw1.0 \
         files/lib/firmware/ath11k/QCN9074/hw1.0

# ---------------------------------------------------------------------------
# 1) 默认管理 IP / 主机名（脚本原逻辑已改成 192.168.2.1，如需其他网段在此调整）
#    保持与 CI release 说明一致：192.168.2.1 / root / password
# ---------------------------------------------------------------------------
# （无需改动，沿用原脚本的 192.168.2.1）

# ---------------------------------------------------------------------------
# 2) 1GB 内存的 NSS pbuf profile 兜底校验（防 config 项未生效）
#    若源码树 pbuf.uci 仍写着 512M 参数，强制改为 1G profile 数值
# ---------------------------------------------------------------------------
PBUF_UCI="package/kernel/mac80211/files/pbuf.uci"
if [ -f "$PBUF_UCI" ]; then
  sed -i 's/extra_pbuf_core0=3100000/extra_pbuf_core0=10000000/g' "$PBUF_UCI" || true
  sed -i 's/n2h_high_water_core0=30624/n2h_high_water_core0=72512/g' "$PBUF_UCI" || true
  sed -i 's/n2h_wifi_pool_buf=8192/n2h_wifi_pool_buf=36864/g' "$PBUF_UCI" || true
fi

# ---------------------------------------------------------------------------
# 3) 注入 JDC-RE-CS-02 原厂射频校准修复（消除 cal-pci-0000:01:00.0.bin -12 报错）
#    说明：laipeng668/LibWrt 25.12-nss 本身已内置 IPQ6018 与 QCN9074 的
#    JDC 板级 board-2.bin，通常无需再做。仅当实测 dmesg 仍报 -12 时启用下面这段。
#    启用方法：把 if false; then 改成 if true; then，并把你的 ART 中提取的
#    bdwlan.bin / board-2.bin 放到本 CI 仓库 files/ 对应路径后推送。
# ---------------------------------------------------------------------------
if false; then
  mkdir -p files/lib/firmware/ath11k/IPQ6018/hw1.0
  mkdir -p files/lib/firmware/ath11k/QCN9074/hw1.0
  # 将原厂 p19 WIFIFW 里提取的 board-2.bin / bdwlan.bin 放到 files/ 对应目录，
  # 编译时会自动覆盖到固件 /lib/firmware/ 下
  cp -f files/board-2-IPQ6018.bin files/lib/firmware/ath11k/IPQ6018/hw1.0/board-2.bin
  cp -f files/board-2-QCN9074.bin files/lib/firmware/ath11k/QCN9074/hw1.0/board-2.bin
fi

# ---------------------------------------------------------------------------
# 4) Docker / AdGuard Home 数据落到大分区 /mnt/mmcblk0p27 的初始化脚本
#    随固件内置一个首次开机脚本，自动挂载 p27、建目录、启 swapfile，
#    并把 Docker data-root 指到 p27，避免撑爆 18MB 的 overlay。
# ---------------------------------------------------------------------------
mkdir -p files/etc/init.d
cat > files/etc/init.d/ax6600-init <<'EOF'
#!/bin/sh /etc/rc.common
START=95
boot() {
    # 大分区 p27（storage）挂载（若系统已自动挂载则跳过）
    mkdir -p /mnt/mmcblk0p27
    mountpoint -q /mnt/mmcblk0p27 || mount -t ext4 /dev/mmcblk0p27 /mnt/mmcblk0p27 2>/dev/null

    # 建数据目录
    mkdir -p /mnt/mmcblk0p27/docker \
             /mnt/mmcblk0p27/AdGuardHome/data \
             /mnt/mmcblk0p27/share

    # 2GB swapfile（若不存在则创建一次）
    if [ ! -f /mnt/mmcblk0p27/swapfile ]; then
        dd if=/dev/zero of=/mnt/mmcblk0p27/swapfile bs=1M count=2048 2>/dev/null
        chmod 600 /mnt/mmcblk0p27/swapfile
        mkswap /mnt/mmcblk0p27/swapfile 2>/dev/null
    fi
    swapon /mnt/mmcblk0p27/swapfile 2>/dev/null

    # Docker data-root 指向大分区（dockerman 启动前写好 UCI）
    uci -q set dockerd.globals.data_root='/mnt/mmcblk0p27/docker'
    uci -q commit dockerd
}
EOF
chmod +x files/etc/init.d/ax6600-init

# ---------------------------------------------------------------------------
# 5) AdGuard Home 工作目录默认指向 p27（若 luci-app-adguardhome 提供 UCI）
# ---------------------------------------------------------------------------
cat > files/etc/uci-defaults/99-ax6600-defaults <<'EOF'
#!/bin/sh
uci -q set adguardhome.@adguardhome[0].workdir='/mnt/mmcblk0p27/AdGuardHome'
uci -q set adguardhome.@adguardhome[0].configdir='/mnt/mmcblk0p27/AdGuardHome/data'
uci -q commit adguardhome 2>/dev/null
/etc/init.d/ax6600-init enable 2>/dev/null
exit 0
EOF
chmod +x files/etc/uci-defaults/99-ax6600-defaults

# ---------------------------------------------------------------------------
# 6) iStore 运行时一键安装脚本（不编译进固件，避免依赖链导致构建失败）
#    背景：etzzy 文章(2025-05)的旧版 istore 是 4 个 ipk：
#      luci-lib-taskd / luci-lib-xterm / taskd / luci-app-store
#    这 4 个包的源码已从 linkease 官方开源仓库移除，immortalwrt 25.12 源
#    也没有；新版 iStoreNext 依赖 luci-app-store/luci-nginx/quickstart，
#    在 CI 源里不完整——两者都无法稳定编译进固件。
#    因此改为：固件内置一个安装脚本，刷机后 SSH 执行即可从 istore 官方
#    源安装（文章验证过的方式），固件只需自带 curl + ca-certificates。
# ---------------------------------------------------------------------------
# 统一创建所有需要的目录（缺一个就会因 set -e 直接退出，这是 v1 构建失败的根因）
mkdir -p files/usr/sbin \
         files/etc/uci-defaults \
         files/etc/init.d

cat > files/usr/sbin/install-istore <<'EOF'
#!/bin/sh
# 京东云 AX6600 一键安装 iStore（来源 istore.linkease.com）
# 版本号会随时间变化，这里从目录索引动态解析最新文件名，避免写死版本导致 404
set -e
REPO="https://istore.linkease.com/repo/all/store"
TMP="/tmp/istore-install"
mkdir -p "$TMP" && cd "$TMP"

# 抓取目录索引，提取所需 4 个包的真实文件名
INDEX="$TMP/index.html"
wget -q --no-check-certificate "$REPO/" -O "$INDEX" || curl -fsSL -k "$REPO/" -o "$INDEX"

resolve() {
  # $1 = 包名前缀，例如 luci-app-store
  grep -oE 'href="[^"]*'"$1"'[^"]*_all\.ipk"' "$INDEX" \
    | sed 's/href="//;s/"$//' | sort -V | tail -n 1
}

PKGS=""
for name in luci-lib-taskd luci-lib-xterm taskd luci-app-store; do
  f="$(resolve "$name")"
  [ -n "$f" ] || { echo "Cannot find $name in repo index"; exit 1; }
  echo "Found: $f"
  PKGS="$PKGS $f"
done

for f in $PKGS; do
  echo "Downloading $f ..."
  wget -q --no-check-certificate "$REPO/$f" -O "$f" || curl -fsSL -k "$REPO/$f" -o "$f"
done

# 严格按依赖顺序安装
for name in luci-lib-taskd luci-lib-xterm taskd luci-app-store; do
  f="$(resolve "$name")"
  echo "Installing $f ..."
  apk add --allow-untrusted "$f" 2>/dev/null || opkg install "$f"
done

rm -rf "$TMP"
echo "iStore installed. Refresh LuCI page."
EOF
chmod +x files/usr/sbin/install-istore

# 注意：下载工具 curl/wget-ssl 已在 configs/General.config 里启用
echo "iStore runtime installer injected (run: install-istore)."

echo "AX6600 customization applied."
