#!/usr/bin/env bash

# ============================================================
# network_test.sh
# Version: 2.1.0
# Ubuntu 24.04
#
# 网络 / 三网回程 / 下载测速 / TCP / HTTPS / TLS /
# DNS / MTR / MTU / IP网络层风险综合检测
# ============================================================

set -u

VERSION="2.1.0"

# -----------------------------
# 基础配置
# -----------------------------

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"
REPORT_DIR="${BASE_DIR}/network_test_reports"

mkdir -p "$REPORT_DIR"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
REPORT_TIME="$(date '+%Y%m%d_%H%M%S')"

REPORT_TXT="${REPORT_DIR}/network_test_${REPORT_TIME}.txt"
REPORT_JSON="${REPORT_DIR}/network_test_${REPORT_TIME}.json"

TARGET_IP=""
DURATION=10
PARALLEL=3
TIMEOUT=8

AUTO_DELETE=0

# 三网测试目标
CT_IP="202.96.134.33"
CU_IP="210.22.70.3"
CM_IP="211.136.17.107"

# 测速节点
CLOUDFLARE_URL="https://speed.cloudflare.com/__down?bytes=100000000"
OVH_URL="https://proof.ovh.net/files/100Mb.dat"

# 测试网站
DOMAINS=(
    "www.google.com"
    "www.youtube.com"
    "www.facebook.com"
    "www.tiktok.com"
)

# -----------------------------
# 颜色
# -----------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# -----------------------------
# 日志
# -----------------------------

log() {
    local level="$1"
    shift

    local color="$NC"

    case "$level" in
        OK) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
        INFO) color="$BLUE" ;;
    esac

    echo -e "${color}[ ${level} ]${NC} $*"

    {
        echo "[$level] $*"
    } >> "$REPORT_TXT" 2>/dev/null || true
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"

    {
        echo
        echo "============================================================"
        echo "$1"
        echo "============================================================"
    } >> "$REPORT_TXT" 2>/dev/null || true
}

# -----------------------------
# 参数
# -----------------------------

usage() {
    cat <<EOF

network_test.sh v${VERSION}

用法：

  ./network_test.sh

  ./network_test.sh --quick

  ./network_test.sh --target-ip 183.23.226.212

  ./network_test.sh --target-ip 183.23.226.212 --duration 15

参数：

  --target-ip IP       指定目标IP
  --duration 秒        iperf3/测速持续时间
  --parallel 数量      并发测速数量
  --timeout 秒         网络连接超时
  --quick              快速检测
  --auto-delete        测试完成后自动删除脚本
  --no-install         不自动安装依赖
  --help               查看帮助

示例：

  ./network_test.sh --target-ip 183.23.226.212

  ./network_test.sh --target-ip 183.23.226.212 --duration 15

  ./network_test.sh --quick

EOF
}

NO_INSTALL=0
QUICK=0

while [[ $# -gt 0 ]]; do

    case "$1" in

        --target-ip)
            TARGET_IP="${2:-}"
            shift 2
            ;;

        --duration)
            DURATION="${2:-10}"
            shift 2
            ;;

        --parallel)
            PARALLEL="${2:-3}"
            shift 2
            ;;

        --timeout)
            TIMEOUT="${2:-8}"
            shift 2
            ;;

        --quick)
            QUICK=1
            shift
            ;;

        --auto-delete)
            AUTO_DELETE=1
            shift
            ;;

        --no-install)
            NO_INSTALL=1
            shift
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            echo "未知参数：$1"
            usage
            exit 1
            ;;
    esac

done

# -----------------------------
# root
# -----------------------------

if [[ $EUID -ne 0 ]]; then
    log WARN "建议使用 root 运行。"

    if command -v sudo >/dev/null 2>&1; then
        log INFO "尝试使用 sudo..."
        exec sudo bash "$SCRIPT_PATH" "$@"
    else
        log ERROR "没有 sudo，请使用 root 运行。"
        exit 1
    fi
fi

# -----------------------------
# 初始化报告
# -----------------------------

cat > "$REPORT_TXT" <<EOF
============================================================
network_test.sh
Version: ${VERSION}
Time: ${START_TIME}
============================================================
EOF

# -----------------------------
# 检查依赖
# -----------------------------

install_dependencies() {

    section "检查 Ubuntu 依赖"

    local packages=()

    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v wget >/dev/null 2>&1 || packages+=("wget")
    command -v dig >/dev/null 2>&1 || packages+=("dnsutils")
    command -v traceroute >/dev/null 2>&1 || packages+=("traceroute")
    command -v mtr >/dev/null 2>&1 || packages+=("mtr-tiny")
    command -v iperf3 >/dev/null 2>&1 || packages+=("iperf3")
    command -v bc >/dev/null 2>&1 || packages+=("bc")
    command -v jq >/dev/null 2>&1 || packages+=("jq")
    command -v openssl >/dev/null 2>&1 || packages+=("openssl")
    command -v nc >/dev/null 2>&1 || packages+=("netcat-openbsd")

    if [[ ${#packages[@]} -eq 0 ]]; then
        log OK "依赖已经完整"
        return
    fi

    if [[ "$NO_INSTALL" -eq 1 ]]; then
        log WARN "检测到缺少依赖，但 --no-install 已开启"
        return
    fi

    log INFO "需要安装：${packages[*]}"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    if apt-get install -y "${packages[@]}"; then
        log OK "依赖安装完成"
    else
        log ERROR "依赖安装失败"
    fi
}

# -----------------------------
# 公网 IP
# -----------------------------

get_public_ip() {

    section "公网 IP"

    PUBLIC_IPV4=""

    local APIs=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me/ip"
        "https://ipinfo.io/ip"
    )

    for api in "${APIs[@]}"; do

        PUBLIC_IPV4="$(curl -4 -fsS --max-time 8 "$api" 2>/dev/null | tr -d '[:space:]')"

        if [[ "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi

        PUBLIC_IPV4=""
    done

    if [[ -n "$PUBLIC_IPV4" ]]; then
        log OK "公网 IPv4：$PUBLIC_IPV4"
    else
        log ERROR "无法获取公网 IPv4"
    fi

    PUBLIC_IPV6=""

    PUBLIC_IPV6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')" || true

    if [[ "$PUBLIC_IPV6" == *:* ]]; then
        log OK "公网 IPv6：$PUBLIC_IPV6"
    else
        log WARN "没有检测到公网 IPv6"
        PUBLIC_IPV6=""
    fi
}

# -----------------------------
# 本地网络
# -----------------------------

network_info() {

    section "服务器网络信息"

    LOCAL_IPV4="$(ip -4 addr show scope global | awk '/inet / {print $2}' | head -1 | cut -d/ -f1)"
    DEFAULT_IF="$(ip route | awk '/default/ {print $5; exit}')"
    DEFAULT_GW="$(ip route | awk '/default/ {print $3; exit}')"

    echo "本地 IPv4：${LOCAL_IPV4:-未知}"
    echo "默认网卡：${DEFAULT_IF:-未知}"
    echo "默认网关：${DEFAULT_GW:-未知}"

    {
        echo "本地 IPv4：${LOCAL_IPV4:-未知}"
        echo "默认网卡：${DEFAULT_IF:-未知}"
        echo "默认网关：${DEFAULT_GW:-未知}"
    } >> "$REPORT_TXT"
}

# -----------------------------
# DNS
# -----------------------------

dns_test() {

    section "DNS 解析测试"

    local domains=(
        "www.google.com"
        "www.youtube.com"
        "www.facebook.com"
        "www.tiktok.com"
        "www.cloudflare.com"
    )

    DNS_FAIL=0

    for domain in "${domains[@]}"; do

        local result

        result="$(dig +short "$domain" 2>/dev/null | head -1)"

        if [[ -n "$result" ]]; then
            log OK "$domain -> $result"
        else
            log WARN "$domain -> DNS FAIL"
            ((DNS_FAIL++))
        fi

    done

    local resolver

    resolver="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')"

    echo "DNS服务器：${resolver:-未知}" >> "$REPORT_TXT"
}

# -----------------------------
# Ping
# -----------------------------

ping_test() {

    section "Ping 测试"

    PING_FAIL=0

    local targets=(
        "Cloudflare:1.1.1.1"
        "Google DNS:8.8.8.8"
    )

    [[ -n "$TARGET_IP" ]] && targets+=("目标 IP:$TARGET_IP")

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        local result

        result="$(ping -c 4 -W 2 "$ip" 2>/dev/null | grep -oE '[0-9]+% packet loss' | head -1)"

        if [[ -n "$result" ]]; then

            local loss
            loss="${result%%% packet loss}"

            if [[ "$loss" == "0" ]]; then
                log OK "$name: ${loss}% 丢包"
            else
                log WARN "$name: ${loss}% 丢包"
                ((PING_FAIL++))
            fi

        else
            log WARN "$name: Ping FAIL"
            ((PING_FAIL++))
        fi

    done
}

# -----------------------------
# TCP
# -----------------------------

tcp_check() {

    section "TCP 端口测试"

    TCP_FAIL=0

    local tests=(
        "www.google.com:443"
        "www.youtube.com:443"
        "www.facebook.com:443"
        "www.tiktok.com:443"
    )

    [[ -n "$TARGET_IP" ]] && tests+=(
        "$TARGET_IP:80"
        "$TARGET_IP:443"
    )

    for item in "${tests[@]}"; do

        local host="${item%:*}"
        local port="${item##*:}"

        if timeout "$TIMEOUT" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
            log OK "$host:$port OPEN"
        else
            log WARN "$host:$port FAIL"
            ((TCP_FAIL++))
        fi

    done
}

# -----------------------------
# HTTPS
# -----------------------------

https_test() {

    section "HTTPS 测试"

    HTTPS_FAIL=0

    for domain in "${DOMAINS[@]}"; do

        local code

        code="$(curl -4 -L -o /dev/null \
            -sS \
            --connect-timeout "$TIMEOUT" \
            --max-time "$TIMEOUT" \
            -w '%{http_code}' \
            "https://$domain" 2>/dev/null || echo "000")"

        if [[ "$code" =~ ^2|^3 ]]; then
            log OK "$domain: HTTPS $code"
        else
            log WARN "$domain: HTTPS $code"
            ((HTTPS_FAIL++))
        fi

    done
}

# -----------------------------
# TLS
# -----------------------------

tls_test() {

    section "TLS / SNI 测试"

    TLS_FAIL=0

    for domain in "${DOMAINS[@]}"; do

        if timeout "$TIMEOUT" openssl s_client \
            -connect "$domain:443" \
            -servername "$domain" \
            </dev/null 2>/dev/null |
            grep -q "BEGIN CERTIFICATE"; then

            log OK "$domain TLS 测试完成"

        else

            log WARN "$domain TLS FAIL"
            ((TLS_FAIL++))

        fi

    done
}

# -----------------------------
# 延迟精确测试
# -----------------------------

latency_test() {

    section "延迟 / RTT 精确测试"

    local targets=(
        "Cloudflare:1.1.1.1"
        "Google DNS:8.8.8.8"
    )

    [[ -n "$TARGET_IP" ]] && targets+=("目标 IP:$TARGET_IP")

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        local result

        result="$(ping -c 5 -W 2 "$ip" 2>/dev/null | \
            awk -F'/' '/rtt|round-trip/ {print $5}')"

        if [[ -n "$result" ]]; then
            log OK "$name 平均 RTT：${result} ms"
        else
            log WARN "$name RTT 获取失败"
        fi

    done
}

# -----------------------------
# 三网 traceroute
# -----------------------------

carrier_trace() {

    section "三网回程线路"

    declare -A CARRIERS

    CARRIERS["中国电信"]="$CT_IP"
    CARRIERS["中国联通"]="$CU_IP"
    CARRIERS["中国移动"]="$CM_IP"

    for carrier in "中国电信" "中国联通" "中国移动"; do

        local ip="${CARRIERS[$carrier]}"
        local outfile="/tmp/${carrier}_trace.txt"

        echo
        echo "---------- $carrier ($ip) ----------"

        traceroute -n -w 1 -q 1 -m 20 "$ip" 2>/dev/null | tee "$outfile"

        local avg

        avg="$(
            awk '
            / ms/ {
                for(i=1;i<=NF;i++){
                    if($i ~ /ms/){
                        v=$(i-1)
                        gsub(/[^0-9.]/,"",v)
                        if(v!="") {
                            sum+=v
                            count++
                        }
                    }
                }
            }
            END {
                if(count>0)
                    printf "%.1f",sum/count
            }' "$outfile"
        )"

        if [[ -n "$avg" ]]; then
            echo "$carrier 平均跳点延迟：${avg} ms" | tee -a "$REPORT_TXT"
        fi

        echo
    done
}

# -----------------------------
# MTR
# -----------------------------

mtr_test() {

    section "MTR 路由质量测试"

    local targets=(
        "电信:$CT_IP"
        "联通:$CU_IP"
        "移动:$CM_IP"
    )

    [[ -n "$TARGET_IP" ]] && targets+=("目标IP:$TARGET_IP")

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        echo
        echo "---------- $name ($ip) ----------"

        if command -v mtr >/dev/null 2>&1; then

            timeout 60 mtr \
                -r \
                -c 10 \
                -w \
                -n \
                "$ip" 2>/dev/null |
                tee -a "$REPORT_TXT"

        else
            log WARN "MTR 不可用"
        fi

    done
}

# -----------------------------
# MTU
# -----------------------------

mtu_test() {

    section "MTU / PMTU 测试"

    local mtu

    mtu="$(ip link show "$DEFAULT_IF" 2>/dev/null |
        awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"

    echo "当前接口：${DEFAULT_IF:-未知}"
    echo "当前 MTU：${mtu:-未知}"

    if [[ -n "$mtu" ]]; then

        if ping -4 -M do -s 1472 -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
            log OK "1472 bytes + IPv4 header 测试通过，MTU 1500 基本正常"
        else
            log WARN "1472 bytes PMTU 测试失败"
        fi

    fi
}

# -----------------------------
# 下载测速
# -----------------------------

speed_test_one() {

    local name="$1"
    local url="$2"

    local result

    result="$(curl -L \
        -4 \
        -o /dev/null \
        -sS \
        --connect-timeout 10 \
        --max-time 30 \
        -w '%{speed_download}' \
        "$url" 2>/dev/null || echo 0)"

    if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

        local mbps

        mbps="$(awk -v b="$result" 'BEGIN {printf "%.2f", b*8/1000000}')"

        log OK "$name 下载速度：${mbps} Mbps"

        echo "$name: ${mbps} Mbps" >> "$REPORT_TXT"

    else
        log WARN "$name 下载测速失败"
    fi
}

speed_test() {

    section "公网多节点下载测速"

    speed_test_one "Cloudflare" "$CLOUDFLARE_URL"

    speed_test_one "OVH" "$OVH_URL"
}

# -----------------------------
# 三并发峰值测速
# -----------------------------

parallel_speed_test() {

    section "三并发峰值测速"

    local tmpdir="/tmp/network_parallel_$$"

    mkdir -p "$tmpdir"

    log INFO "启动 ${PARALLEL} 路并发下载测试"

    for i in $(seq 1 "$PARALLEL"); do

        (
            curl -L \
                -4 \
                -o /dev/null \
                -sS \
                --connect-timeout 10 \
                --max-time "$DURATION" \
                -w '%{speed_download}' \
                "$CLOUDFLARE_URL" \
                > "${tmpdir}/${i}.speed" 2>/dev/null
        ) &

    done

    wait

    local total=0
    local count=0

    for file in "$tmpdir"/*.speed; do

        [[ -f "$file" ]] || continue

        local speed

        speed="$(cat "$file" 2>/dev/null)"

        if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            total="$(awk -v a="$total" -v b="$speed" 'BEGIN {print a+b}')"
            ((count++))
        fi

    done

    if [[ "$count" -gt 0 ]]; then

        local mbps

        mbps="$(awk -v b="$total" 'BEGIN {printf "%.2f", b*8/1000000}')"

        log OK "${count} 路并发总峰值：${mbps} Mbps"

        echo "三并发总峰值：${mbps} Mbps" >> "$REPORT_TXT"

    else

        log WARN "三并发测速失败"

    fi

    rm -rf "$tmpdir"
}

# -----------------------------
# 目标 IP
# -----------------------------

target_test() {

    [[ -z "$TARGET_IP" ]] && return

    section "目标 IP 综合测试"

    echo "Target IP: $TARGET_IP"

    if ping -c 4 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
        log OK "目标 IP $TARGET_IP Ping 正常"
    else
        log WARN "目标 IP $TARGET_IP Ping 失败"
    fi

    for port in 22 80 443 8080 8443; do

        if timeout "$TIMEOUT" bash -c "</dev/tcp/$TARGET_IP/$port" 2>/dev/null; then
            log OK "$TARGET_IP:$port OPEN"
        else
            echo "$TARGET_IP:$port CLOSED/FILTERED" >> "$REPORT_TXT"
        fi

    done

    echo
    echo "目标 IP 路由："

    traceroute -n -w 1 -q 1 -m 20 "$TARGET_IP" 2>/dev/null |
        tee -a "$REPORT_TXT"

    echo
    echo "目标 IP MTR："

    if command -v mtr >/dev/null 2>&1; then

        timeout 60 mtr \
            -r \
            -c 10 \
            -w \
            -n \
            "$TARGET_IP" 2>/dev/null |
            tee -a "$REPORT_TXT"

    fi
}

# -----------------------------
# IP 信息
# -----------------------------

ip_info() {

    section "公网 IP 信息"

    [[ -z "${PUBLIC_IPV4:-}" ]] && return

    local result=""

    result="$(curl -4 -fsS --max-time 10 \
        "https://ipapi.co/${PUBLIC_IPV4}/json/" 2>/dev/null || true)"

    if [[ -n "$result" ]] && echo "$result" | grep -q '"ip"'; then

        echo "$result" | jq -r '
        "IP: \(.ip // "-")",
        "国家: \(.country_name // "-")",
        "地区: \(.region // "-")",
        "城市: \(.city // "-")",
        "ASN: \(.asn // "-")",
        "组织: \(.org // "-")"
        ' 2>/dev/null | tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    result="$(curl -4 -fsS --max-time 10 \
        "https://ipinfo.io/${PUBLIC_IPV4}/json" 2>/dev/null || true)"

    if [[ -n "$result" ]] && echo "$result" | grep -q '"ip"'; then

        echo "$result" | jq -r '
        "IP: \(.ip // "-")",
        "国家: \(.country // "-")",
        "地区: \(.region // "-")",
        "城市: \(.city // "-")",
        "组织: \(.org // "-")"
        ' 2>/dev/null | tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    result="$(curl -4 -fsS --max-time 10 \
        "https://ipwho.is/${PUBLIC_IPV4}" 2>/dev/null || true)"

    if [[ -n "$result" ]] && echo "$result" | grep -q '"ip"'; then

        echo "$result" | jq -r '
        "IP: \(.ip // "-")",
        "国家: \(.country // "-")",
        "地区: \(.region // "-")",
        "城市: \(.city // "-")",
        "ASN: \(.connection.asn // "-")",
        "组织: \(.connection.org // "-")"
        ' 2>/dev/null | tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    log WARN "无法获取 IP 信息"
}

# -----------------------------
# Spamhaus
# -----------------------------

spamhaus_test() {

    section "Spamhaus DNSBL"

    [[ -z "${PUBLIC_IPV4:-}" ]] && return

    local reversed

    reversed="$(echo "$PUBLIC_IPV4" | awk -F. '{print $4"."$3"."$2"."$1}')"

    if dig +short "${reversed}.zen.spamhaus.org" A 2>/dev/null | grep -qE '127\.0\.0\.'; then
        log WARN "Spamhaus ZEN 检测到命中"
        SPAMHAUS="LISTED"
    else
        log OK "未发现 Spamhaus ZEN DNSBL 命中"
        SPAMHAUS="CLEAN"
    fi
}

# -----------------------------
# Tor Exit
# -----------------------------

tor_test() {

    section "Tor Exit Node"

    [[ -z "${PUBLIC_IPV4:-}" ]] && return

    local result

    result="$(curl -fsS --max-time 15 \
        "https://check.torproject.org/torbulkexitlist" 2>/dev/null || true)"

    if echo "$result" | grep -qx "$PUBLIC_IPV4"; then
        log WARN "当前公网 IP 出现在 Tor Exit Node 列表"
        TOR_EXIT="LISTED"
    else
        log OK "当前公网 IP 未发现于 Tor Exit Node 列表"
        TOR_EXIT="CLEAN"
    fi
}

# -----------------------------
# 网络层风险评分
# -----------------------------

risk_score() {

    section "网络层风险评分"

    local score=100

    if [[ "${SPAMHAUS:-CLEAN}" == "LISTED" ]]; then
        score=$((score-40))
    fi

    if [[ "${TOR_EXIT:-CLEAN}" == "LISTED" ]]; then
        score=$((score-30))
    fi

    if [[ "${HTTPS_FAIL:-0}" -gt 2 ]]; then
        score=$((score-15))
    fi

    if [[ "${DNS_FAIL:-0}" -gt 2 ]]; then
        score=$((score-10))
    fi

    if [[ "${PING_FAIL:-0}" -gt 1 ]]; then
        score=$((score-10))
    fi

    if [[ "$score" -lt 0 ]]; then
        score=0
    fi

    if [[ "$score" -ge 90 ]]; then
        RISK_LEVEL="低"
    elif [[ "$score" -ge 70 ]]; then
        RISK_LEVEL="较低"
    elif [[ "$score" -ge 50 ]]; then
        RISK_LEVEL="中等"
    else
        RISK_LEVEL="较高"
    fi

    echo "Network Layer Score: ${score}/100"
    echo "Network Layer Risk: ${RISK_LEVEL}"

    {
        echo
        echo "Network Layer Score: ${score}/100"
        echo "Network Layer Risk: ${RISK_LEVEL}"
    } >> "$REPORT_TXT"
}

# -----------------------------
# 综合报告
# -----------------------------

summary() {

    section "最终综合结果"

    echo
    echo "服务器公网 IP：${PUBLIC_IPV4:-未知}"
    echo "目标 IP：${TARGET_IP:-未指定}"
    echo

    echo "网络层评分：${score:-100}/100"
    echo "网络层风险：${RISK_LEVEL:-未知}"

    echo
    echo "DNS失败：${DNS_FAIL:-0}"
    echo "Ping失败：${PING_FAIL:-0}"
    echo "TCP失败：${TCP_FAIL:-0}"
    echo "HTTPS失败：${HTTPS_FAIL:-0}"
    echo "TLS失败：${TLS_FAIL:-0}"

    echo
    echo "Spamhaus：${SPAMHAUS:-UNKNOWN}"
    echo "Tor Exit：${TOR_EXIT:-UNKNOWN}"

    echo
    echo "报告："
    echo "$REPORT_TXT"

    echo
    echo "JSON："
    echo "$REPORT_JSON"

    {
        echo
        echo "================ FINAL SUMMARY ================"
        echo "公网IPv4=${PUBLIC_IPV4:-}"
        echo "目标IP=${TARGET_IP:-}"
        echo "NetworkScore=${score:-100}"
        echo "Risk=${RISK_LEVEL:-UNKNOWN}"
        echo "DNSFail=${DNS_FAIL:-0}"
        echo "PingFail=${PING_FAIL:-0}"
        echo "TCPFail=${TCP_FAIL:-0}"
        echo "HTTPSFail=${HTTPS_FAIL:-0}"
        echo "TLSFail=${TLS_FAIL:-0}"
        echo "Spamhaus=${SPAMHAUS:-UNKNOWN}"
        echo "TorExit=${TOR_EXIT:-UNKNOWN}"
    } >> "$REPORT_TXT"
}

# -----------------------------
# JSON
# -----------------------------

generate_json() {

    local score="${score:-100}"

    cat > "$REPORT_JSON" <<EOF
{
  "version": "${VERSION}",
  "time": "${START_TIME}",
  "public_ipv4": "${PUBLIC_IPV4:-}",
  "public_ipv6": "${PUBLIC_IPV6:-}",
  "local_ipv4": "${LOCAL_IPV4:-}",
  "interface": "${DEFAULT_IF:-}",
  "gateway": "${DEFAULT_GW:-}",
  "target_ip": "${TARGET_IP:-}",
  "network_score": ${score},
  "network_risk": "${RISK_LEVEL:-UNKNOWN}",
  "spamhaus": "${SPAMHAUS:-UNKNOWN}",
  "tor_exit": "${TOR_EXIT:-UNKNOWN}",
  "dns_fail": ${DNS_FAIL:-0},
  "ping_fail": ${PING_FAIL:-0},
  "tcp_fail": ${TCP_FAIL:-0},
  "https_fail": ${HTTPS_FAIL:-0},
  "tls_fail": ${TLS_FAIL:-0}
}
EOF

    log OK "JSON 报告生成完成"
}

# -----------------------------
# 自动删除
# -----------------------------

auto_delete_script() {

    if [[ "$AUTO_DELETE" -eq 1 ]]; then

        section "自动清理"

        log INFO "报告已经保存：$REPORT_DIR"

        log WARN "开始删除当前脚本：$SCRIPT_PATH"

        sleep 2

        rm -f -- "$SCRIPT_PATH"

        if [[ ! -f "$SCRIPT_PATH" ]]; then
            echo
            echo "脚本已经自动删除。"
            echo "报告目录：$REPORT_DIR"
        else
            log WARN "脚本删除失败，请手动删除。"
        fi

    fi
}

# ============================================================
# 主测试
# ============================================================

main() {

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "NETWORK TEST v${VERSION}"
    echo "============================================================"
    echo
    echo "Ubuntu 24.04 网络 / 三网回程 / 速度 / IP网络层风险"
    echo
    echo "开始时间：${START_TIME}"
    echo

    install_dependencies

    get_public_ip

    network_info

    dns_test

    ping_test

    tcp_check

    https_test

    tls_test

    latency_test

    carrier_trace

    if [[ "$QUICK" -eq 0 ]]; then

        mtr_test

        mtu_test

        speed_test

        parallel_speed_test

    fi

    target_test

    ip_info

    spamhaus_test

    tor_test

    risk_score

    generate_json

    summary

    auto_delete_script

    echo
    echo "============================================================"
    echo "测试完成"
    echo "============================================================"
}

main "$@"