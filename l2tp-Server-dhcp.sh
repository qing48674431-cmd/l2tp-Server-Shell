#!/bin/bash

set -e

# 自动修复 dpkg 中断问题
if fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    echo "检测到 apt/dpkg 锁定，等待释放..."
    sleep 5
fi

echo "检查并修复 dpkg 状态..."
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || {
    echo "dpkg 修复失败，请手动执行：sudo dpkg --configure -a"
    exit 1
}

# 清理临时锁文件（若存在）
rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock
# 获取公网 IPv4（本机非私网 → 云 metadata → 外网）
get_public_ip() {
    local ip
    ip=$(ip -4 addr | awk '/inet/ && !/127.0.0.1/ && !/inet 10\.|192\.168|172\.(1[6-9]|2[0-9]|3[0-1])\./ {print $2}' | cut -d/ -f1 | head -n1)
    [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s --connect-timeout 2 -H "Metadata-Flavor: Google" "http://100.100.100.200/latest/meta-data/eipv4" 2>/dev/null || true)
    [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s --connect-timeout 2 "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
    [[ -n "$ip" ]] && echo "$ip" && return
    ip=$(curl -s --connect-timeout 3 icanhazip.com 2>/dev/null || curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || true)
    [[ -n "$ip" ]] && echo "$ip"
}

# 检查 DNS 可用性
check_dns() {
    echo "Checking DNS resolution..."
    if ! host google.com &>/dev/null; then
        echo "DNS 解析失败，正在设置临时 DNS..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
    fi
}

check_dns

# 获取用户输入
read -rp "请输入 L2TP 用户名: " L2TP_USER
read -rp "请输入 L2TP 密码: " L2TP_PASS
echo ""
read -rp "请输入内网地址段（三组数字，如 10.10.10）: " LAN_PREFIX
if [[ "$LAN_PREFIX" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    LAN_PREFIX="${LAN_PREFIX%.*}"
    echo "已使用网段前缀: $LAN_PREFIX"
fi

LOCAL_IP="${LAN_PREFIX}.1"
REMOTE_IP="${LAN_PREFIX}.2"
REMOTE_IP1="${LAN_PREFIX}.20"
PUBLIC_IP=$(get_public_ip)

echo "检测到公网 IP: $PUBLIC_IP"

# 检查旧 VPN 软件
echo "检测系统中已安装的 VPN 组件..."
OLD_VPNS=("strongswan" "openvpn" "pptpd" "ppp" "xl2tpd" "wireguard-tools" "wg-quick")
EXISTING_VPN=""
for pkg in "${OLD_VPNS[@]}"; do
    if dpkg -l | grep -q "$pkg"; then
        echo "已安装: $pkg"
        EXISTING_VPN+="$pkg "
    fi
done

if [[ -n "$EXISTING_VPN" ]]; then
    read -rp "是否删除以上旧 VPN 组件？[y/N]: " del_vpn
    case "${del_vpn,,}" in
    y|yes)
        apt purge -y $EXISTING_VPN
        ;;
    *)
        echo "跳过删除旧 VPN 组件。"
        ;;
esac
fi

# 检查并安装 nftables
if ! command -v nft &>/dev/null; then
    echo "未检测到 nftables，正在安装..."
    apt update
    apt install -y nftables
fi

# 移除其他防火墙工具，使用 nftables（只卸载已安装的，避免包不存在报错）
echo "移除 ufw / firewalld / iptables..."
for pkg in ufw firewalld iptables-persistent iptables; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        apt purge -y "$pkg" || true
    fi
done
apt install -y nftables

# 安装依赖
echo "安装必要组件..."
apt update
apt install -y xl2tpd ppp lsof net-tools

# 配置 /etc/xl2tpd/xl2tpd.conf（max sessions 限制同一账号不能多处同时拨号）
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
ipsec saref = no
[lns default]
ip range = ${REMOTE_IP}-${REMOTE_IP1}
local ip = ${LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
max sessions = 1
EOF

# 配置 /etc/ppp/options.xl2tpd
cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 1.1.1.1
asyncmap 0
auth
crtscts
lock
hide-password
modem
debug
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1410
mru 1410
connect-delay 5000
EOF

# 检查并创建 /etc/ppp/chap-secrets 文件
if [ ! -d /etc/ppp ]; then
    mkdir -p /etc/ppp
fi

echo "$L2TP_USER    l2tpd    $L2TP_PASS    *" > /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets

# 配置 ip-up 脚本：添加回程路由 + 同一账号仅允许一处在线（多拨则踢掉新连接）
cat > /etc/ppp/ip-up <<IPUPEOF
#!/bin/bash
SUBNET="${LAN_PREFIX}"
CLIENT_IP="\$5"
# 同一账号仅允许一处在线：pppd 会设置 PEERNAME，用文件记录已连接用户
if [ -n "\$PEERNAME" ]; then
    ACTIVE_FILE="/var/run/ppp-active-users"
    if [ -f "\$ACTIVE_FILE" ] && grep -q "^\$PEERNAME\$" "\$ACTIVE_FILE"; then
        logger -t xl2tpd "同一账号 \$PEERNAME 已在别处连接，拒绝重复拨入"
        kill -TERM \$PPID 2>/dev/null || true
        exit 0
    fi
    echo "\$PEERNAME" >> "\$ACTIVE_FILE" 2>/dev/null || true
fi
ip route add \${SUBNET}.0/24 via "\$CLIENT_IP" 2>/dev/null || true
IPUPEOF
chmod +x /etc/ppp/ip-up

# 配置 ip-down 脚本：删除回程路由 + 从在线用户列表移除，允许该账号再次拨入
cat > /etc/ppp/ip-down <<IPDOWNEOF
#!/bin/bash
SUBNET="${LAN_PREFIX}"
CLIENT_IP="\$5"
# 断开时从在线用户列表移除该账号（pppd 会设置 PEERNAME）
if [ -n "\$PEERNAME" ]; then
    ACTIVE_FILE="/var/run/ppp-active-users"
    [ -f "\$ACTIVE_FILE" ] && sed -i "/^\$PEERNAME\$/d" "\$ACTIVE_FILE" 2>/dev/null || true
fi
ip route del \${SUBNET}.0/24 via \$CLIENT_IP 2>/dev/null || true
IPDOWNEOF
chmod +x /etc/ppp/ip-down

# 配置 nftables NAT 转发规则
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;
        policy accept;
    }

    chain forward {
        type filter hook forward priority 0;
        policy accept;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
    }

   chain postrouting {
        type nat hook postrouting priority 100;
        oifname != "lo" masquerade
    }
}
EOF

systemctl enable nftables
systemctl restart nftables

# 启用 IP 转发及其bbr控制

cat > /etc/sysctl.d/99-l2tp.conf <<EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system


# 启动服务
systemctl enable xl2tpd
systemctl restart xl2tpd

# 输出结果
echo ""
echo "✅ L2TP 安装与配置完成"
echo "=============================="
echo "服务端公网 IP: ${PUBLIC_IP}"
echo "L2TP 用户名:   ${L2TP_USER}"
echo "L2TP 密码:     ${L2TP_PASS}"
echo "=============================="
