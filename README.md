# Network Test

Ubuntu 24.04 服务器网络综合检测与测速工具。

`network_test.sh` 用于快速检测服务器公网 IP、DNS、Ping、TCP、HTTPS、TLS、三网线路、MTR、MTU、下载速度以及 IP 网络层风险等信息，并自动生成 TXT 和 JSON 测试报告。

## 版本

**Current Version: v2.1.0**

**适用系统：Ubuntu 24.04 LTS**

---

## 功能

### 网络基础检测

* 公网 IPv4 检测
* 公网 IPv6 检测
* 本地 IPv4 检测
* 默认网卡检测
* 默认网关检测
* DNS 服务器检测
* DNS 解析测试

### 网络质量

* Cloudflare Ping
* Google DNS Ping
* 指定目标 IP Ping
* 平均 RTT 延迟
* TCP 443 端口测试
* HTTP/HTTPS 连通性
* TLS / SNI 握手测试

### 中国三网线路

支持测试：

* 中国电信
* 中国联通
* 中国移动

通过 `traceroute` 检测服务器到三网目标节点的线路和跳点延迟。

默认测试节点：

```text
中国电信：202.96.134.33
中国联通：210.22.70.3
中国移动：211.136.17.107
```

> 三网目标 IP 可以根据实际需求修改脚本顶部配置。

### MTR 路由质量

使用 MTR 对线路进行进一步检测：

* 跳数
* 丢包
* 延迟
* 路由质量

默认测试：

```text
中国电信
中国联通
中国移动
```

指定 `--target-ip` 后，同时测试目标 IP。

### MTU / PMTU

检测服务器当前：

* 默认网卡
* MTU
* IPv4 PMTU 1500 基础连通性

### 下载测速

支持：

* Cloudflare
* OVH

测速结果统一转换为 Mbps。

### 多路并发测速

支持多路同时下载，用于测试服务器公网出口的并发峰值速度。

默认：

```text
并发数量：3
```

可以通过参数调整：

```bash
--parallel 3
```

例如：

```bash
sudo ./network_test.sh --parallel 5
```

### 指定目标 IP

可以指定一个目标服务器 IP 进行综合测试：

```bash
sudo ./network_test.sh --target-ip xxxxxxxxx
```

测试内容包括：

* Ping
* TCP 22
* TCP 80
* TCP 443
* TCP 8080
* TCP 8443
* Traceroute
* MTR

### IP 信息

自动查询公网 IPv4 的基础网络信息，包括：

* 国家
* 地区
* 城市
* ASN
* 网络组织

脚本会依次尝试多个 IP 信息服务。

### IP 网络层风险

提供基础网络层风险检测：

* Spamhaus ZEN DNSBL
* Tor Exit Node
* DNS 异常
* Ping 异常
* HTTPS 异常

最终生成：

```text
Network Layer Score
Network Layer Risk
```

风险等级：

|     分数 | 风险 |
| -----: | -- |
| 90-100 | 低  |
|  70-89 | 较低 |
|  50-69 | 中等 |
|   0-49 | 较高 |

> 风险评分仅用于网络层面的基础诊断，不能代表 Google、Facebook、TikTok、YouTube 等平台的账号、设备或业务风控结果。

---

# 安装

## 方法一：直接下载

进入服务器：

```bash
cd /opt
```

创建目录：

```bash
sudo mkdir -p network-test
cd network-test
```

下载脚本：

```bash
sudo wget https://raw.githubusercontent.com/YOUR_USERNAME/network-test/main/network_test.sh
```

赋予执行权限：

```bash
sudo chmod +x network_test.sh
```

运行：

```bash
sudo ./network_test.sh
```

将：

```text
YOUR_USERNAME
```

替换成你的 GitHub 用户名。

---

# 快速测试

如果只需要进行基础网络检测：

```bash
sudo ./network_test.sh --quick
```

`--quick` 会跳过：

* MTR
* MTU
* 下载测速
* 多路并发测速

因此测试速度更快。

---

# 完整测试

执行：

```bash
sudo ./network_test.sh
```

完整测试包括：

```text
公网 IP
↓
服务器网络信息
↓
DNS
↓
Ping
↓
TCP
↓
HTTPS
↓
TLS
↓
RTT
↓
三网 Traceroute
↓
MTR
↓
MTU
↓
下载测速
↓
多路并发测速
↓
目标 IP
↓
IP 信息
↓
Spamhaus
↓
Tor Exit
↓
网络风险评分
↓
JSON 报告
```

---

# 指定目标 IP

例如：

```bash
sudo ./network_test.sh --target-ip xxxxxxxx
```

同时指定测速时间：

```bash
sudo ./network_test.sh \
  --target-ip xxxxxxxxxxxxx \
  --duration 15
```

---

# 参数

| 参数               | 默认值 | 说明            |
| ---------------- | --: | ------------- |
| `--target-ip IP` |   无 | 指定目标 IP       |
| `--duration 秒`   |  10 | 并发测速持续时间      |
| `--parallel 数量`  |   3 | 并发测速数量        |
| `--timeout 秒`    |   8 | TCP/网络连接超时    |
| `--quick`        |  关闭 | 快速检测          |
| `--auto-delete`  |  关闭 | 测试完成后自动删除当前脚本 |
| `--no-install`   |  关闭 | 不自动安装依赖       |
| `--help`         |   - | 查看帮助          |

---

# 使用示例

## 基础测试

```bash
sudo ./network_test.sh
```

## 快速测试

```bash
sudo ./network_test.sh --quick
```

## 指定目标 IP

```bash
sudo ./network_test.sh --target-ip 183.23.226.212
```

## 15 秒测速

```bash
sudo ./network_test.sh --duration 15
```

## 5 路并发

```bash
sudo ./network_test.sh --parallel 5
```

## 指定目标 IP + 5 路并发

```bash
sudo ./network_test.sh \
  --target-ip 183.23.226.212 \
  --parallel 5 \
  --duration 15
```

## 不自动安装依赖

```bash
sudo ./network_test.sh --no-install
```

## 测试完成后删除脚本

```bash
sudo ./network_test.sh --auto-delete
```

---

# 自动安装依赖

首次运行时，脚本会检查以下工具：

```text
curl
wget
dig
traceroute
mtr
iperf3
bc
jq
openssl
nc
```

如果缺少依赖，脚本会通过 Ubuntu APT 自动安装。

等价于：

```bash
apt-get update
apt-get install -y \
  curl \
  wget \
  dnsutils \
  traceroute \
  mtr-tiny \
  iperf3 \
  bc \
  jq \
  openssl \
  netcat-openbsd
```

如果不希望脚本自动安装：

```bash
sudo ./network_test.sh --no-install
```

---

# 测试报告

运行完成后，脚本会自动创建：

```text
network_test_reports/
```

报告示例：

```text
network_test_reports/
├── network_test_20260907_103000.txt
└── network_test_20260907_103000.json
```

TXT 报告用于人工查看。

JSON 报告用于：

* 程序读取
* API 上传
* 自动化分析
* 批量服务器检测
* 后续 Web 面板开发

---

# JSON 示例

```json
{
  "version": "2.1.0",
  "time": "2026-09-07 10:30:00",
  "public_ipv4": "1.2.3.4",
  "public_ipv6": "",
  "local_ipv4": "172.19.30.100",
  "interface": "eth0",
  "gateway": "172.19.63.253",
  "target_ip": "",
  "network_score": 100,
  "network_risk": "低",
  "spamhaus": "CLEAN",
  "tor_exit": "CLEAN",
  "dns_fail": 0,
  "ping_fail": 0,
  "tcp_fail": 0,
  "https_fail": 0,
  "tls_fail": 0
}
```

# 修改测速节点

默认：

```bash
CLOUDFLARE_URL="https://speed.cloudflare.com/__down?bytes=100000000"
OVH_URL="https://proof.ovh.net/files/100Mb.dat"
```

可以根据实际网络环境增加或更换测速节点。

---

# 安全说明

本项目主要用于服务器网络质量、线路和基础 IP 网络层状态检测。

脚本不会：

* 保存账号密码
* 保存 Cookie
* 保存访问令牌
* 自动登录第三方平台
* 修改服务器防火墙规则
* 修改 SSH 配置
* 修改系统网络配置

公网 IP、ASN、地理位置等信息属于服务器网络信息，生成的测试报告建议不要直接公开上传到 GitHub。

---

# 注意事项

## 1. Ping 不通不一定代表网络异常

部分服务器或目标节点可能禁止 ICMP，因此：

```text
Ping FAIL
```

并不一定意味着：

```text
TCP/HTTPS FAIL
```

需要结合 TCP、HTTPS、Traceroute 和 MTR 综合判断。

## 2. Traceroute 中的 `*`

出现：

```text
*
* *
```

可能只是中间路由器限制 ICMP/UDP 探测，并不一定代表真实丢包。

## 3. IP 风险评分不是平台账号风控评分

本项目中的：

```text
Network Layer Score
```

主要反映基础网络层状态。

它不能直接判断：

```text
Google Account Risk
Facebook Account Risk
TikTok Account Risk
YouTube Account Risk
```

平台实际风控还可能涉及：

* IP 历史
* ASN
* 代理/VPN 属性
* Cookie
* 浏览器环境
* 设备信息
* 登录行为
* 账号历史
* 地理位置一致性

因此不要将本项目的网络层评分理解为第三方平台的账号通过率。

---

# License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to the conditions of the MIT License.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
