# L2TP Server Shell

Debian/Ubuntu 下一键部署 **L2TP（无 IPsec）** VPN 服务端脚本，基于 xl2tpd + ppp + nftables。

---

## 一、项目总结

### 功能

- **一键安装**：交互输入用户名、密码、内网网段、同时 PPP 连接数，自动安装并配置 xl2tpd、ppp、nftables。
- **公网 IP 检测**：本机网卡 → 阿里云/通用 metadata → 外网接口，适配云服务器。
- **内网网段**：支持输入三组（如 `10.10.10`）或四段 IP（如 `10.10.10.2` 自动取前三位）。
- **PPP 连接数**：安装时可自定义「同时允许的 PPP 连接数」（默认 1），对应地址池大小。
- **同一账号单点**：通过 `/etc/ppp/ip-up` 记录在线用户，同一账号多地登录会踢掉新连接。
- **防火墙**：仅卸载已安装的 ufw/firewalld/iptables，避免包不存在报错；使用 nftables 做 NAT 转发。
- **兼容性**：不使用 xl2tpd 不支持的 `max sessions`，Debian 12 等可正常启动。

### 安装时输入项

| 输入项 | 说明 | 示例 |
|--------|------|------|
| L2TP 用户名 | 客户端拨号用的用户名 | `aa123` |
| L2TP 密码 | 客户端拨号用的密码 | `aa123` |
| 同时允许的 PPP 连接数 | 默认 1，可填 1–253 | `1` 或 `19` |
| 内网地址段 | 三组数字或四段 IP | `10.10.10` 或 `10.10.10.2` |

### 一键安装命令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qing48674431-cmd/l2tp-Server-Shell/main/l2tp-Server-dhcp.sh)
```

---

## 二、常用命令

### 服务状态与启停

```bash
# 查看 xl2tpd 状态
systemctl status xl2tpd

# 启动 / 停止 / 重启
systemctl start xl2tpd
systemctl stop xl2tpd
systemctl restart xl2tpd

# 开机自启（安装脚本已执行）
systemctl enable xl2tpd
```

### 查看当前连接（PPP 接口 / 在线用户）

```bash
# 在线用户列表（每行一个用户名）
cat /var/run/ppp-active-users

# 当前连接数
wc -l /var/run/ppp-active-users

# PPP 接口数量
ip addr show | grep -c "^[0-9]*: ppp"

# 查看 ppp 接口及 IP
ip -4 addr show | grep -A2 ppp
```

### 配置文件位置

```bash
# xl2tpd 主配置
/etc/xl2tpd/xl2tpd.conf

# PPP 选项与认证
/etc/ppp/options.xl2tpd
/etc/ppp/chap-secrets

# 连接/断开时执行的脚本
/etc/ppp/ip-up
/etc/ppp/ip-down

# 防火墙
/etc/nftables.conf
```

### 修改配置后

```bash
# 改完 xl2tpd 或 ppp 配置后重启服务
systemctl restart xl2tpd
```

### 日志与排错

```bash
# xl2tpd 服务日志
journalctl -xeu xl2tpd.service
journalctl -u xl2tpd -f

# 前台运行看报错（调试用，Ctrl+C 退出）
xl2tpd -D
```

### 内核模块（若服务起不来可先加载）

```bash
sudo modprobe l2tp_ppp
sudo modprobe l2tp_netlink
sudo systemctl restart xl2tpd
```

### 快速改地址池（仅允许 1 个客户端）

```bash
# 把地址池改成单个 IP（例如 10.10.10.2–10.10.10.2）
sudo sed -i 's/^ip range = \(.*\)-.*$/ip range = \1-\1/' /etc/xl2tpd/xl2tpd.conf
sudo systemctl restart xl2tpd
```

---

## 三、客户端连接参数

- **类型**：L2TP（无 IPsec，不勾选 IPsec/预共享密钥）。
- **服务器**：安装完成时输出的公网 IP（或你的域名）。
- **用户名 / 密码**：安装时填写的 L2TP 用户名和密码。

---

## 四、故障排查速查

| 现象 | 建议操作 |
|------|----------|
| xl2tpd 启动失败 | `xl2tpd -D` 看报错；`journalctl -xeu xl2tpd.service` 查日志 |
| 报错 Unknown field 'max sessions' | 删除配置里 `max sessions` 行：`sed -i '/^max sessions/d' /etc/xl2tpd/xl2tpd.conf`，再 `systemctl restart xl2tpd` |
| 服务起不来、怀疑缺内核模块 | `modprobe l2tp_ppp l2tp_netlink`，再重启 xl2tpd |
| 公网 IP 为空 | 脚本会尝试 metadata/外网接口；云机一般可拿到，本机可 `curl icanhazip.com` 手动查看 |

---

## 五、许可证与仓库

- 仓库：<https://github.com/qing48674431-cmd/l2tp-Server-Shell>
- 脚本：`l2tp-Server-dhcp.sh`
