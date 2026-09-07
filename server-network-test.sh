#!/usr/bin/env bash

# ============================================================
# network_test.sh
# Version: 2.2.0
# Ubuntu 24.04
#
# 网络 / 三网回程 / 多节点测速 / 并发峰值 /
# DNS / TCP / HTTPS / TLS / MTR / MTU /
# Target IP / IP网络层风险综合检测
#
# 注意：
# 1. 三路并发 != 中国电信/联通/移动三条物理线路
# 2. Target IP TCP端口失败不代表IP不可达
# 3. 平台账号注册风控无法仅通过网络测试准确判断
# ============================================================

set -u

VERSION="2.2.0"

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
BASE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"

REPORT_DIR="${BASE_DIR}/network_test_reports"

mkdir -p "$REPORT_DIR"

TIMEOUT=8
DURATION=10
PARALLEL=3

TARGET_IP=""

PUBLIC_IPV4=""
PUBLIC_IPV6=""
LOCAL_IPV4=""
DEFAULT_IF=""
DEFAULT_GW=""
DNS_SERVER=""

DNS_FAIL=0
PING_FAIL=0
TCP_FAIL=0
HTTPS_FAIL=0
TLS_FAIL=0

SPAMHAUS="UNKNOWN"
TOR_EXIT="UNKNOWN"

NETWORK_SCORE=100
RISK_LEVEL="未知"

CLOUDFLARE_SPEED="N/A"
OVH_SPEED="N/A"
MAX_PARALLEL_SPEED="N/A"

REPORT_TXT=""
REPORT_JSON=""
REPORT_TIME=""
START_TIME=""

# ============================================================
# 三网目标
# ============================================================

CT_IP="202.96.134.33"
CU_IP="210.22.70.3"
CM_IP="211.136.17.107"

# ============================================================
# 测速地址
# ============================================================

CLOUDFLARE_URL="https://speed.cloudflare.com/__down?bytes=50000000"
OVH_URL="https://proof.ovh.net/files/100Mb.dat"

# ============================================================
# 测试域名
# ============================================================

DOMAINS=(
    "www.google.com"
    "www.youtube.com"
    "www.facebook.com"
    "www.tiktok.com"
)

# ============================================================
# 并发测速级别
# ============================================================

PARALLEL_LEVELS=(1 3 5 10)

# ============================================================
# 颜色
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ============================================================
# 通用输出
# ============================================================

print_header() {

    clear 2>/dev/null || true

    echo
    echo "============================================================"
    echo "              NETWORK TEST v${VERSION}"
    echo "============================================================"
    echo
    echo " Ubuntu 24.04 网络 / 三网回程 / 峰值测速 / IP风险检测"
    echo
    echo "============================================================"
}

section() {

    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"

    if [[ -n "${REPORT_TXT:-}" ]]; then

        {
            echo
            echo "============================================================"
            echo "$1"
            echo "============================================================"
        } >> "$REPORT_TXT" 2>/dev/null || true

    fi
}

log() {

    local level="$1"
    shift

    case "$level" in

        OK)
            echo -e "${GREEN}[ OK ]${NC} $*"
            ;;

        WARN)
            echo -e "${YELLOW}[WARN]${NC} $*"
            ;;

        ERROR)
            echo -e "${RED}[ERROR]${NC} $*"
            ;;

        INFO)
            echo -e "${BLUE}[INFO]${NC} $*"
            ;;

        *)
            echo "$*"
            ;;

    esac

    if [[ -n "${REPORT_TXT:-}" ]]; then
        echo "[$level] $*" >> "$REPORT_TXT" 2>/dev/null || true
    fi
}

pause_screen() {

    echo
    read -rp "按 Enter 返回菜单..." _
}

# ============================================================
# IP格式验证
# ============================================================

valid_ipv4() {

    local ip="$1"

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    read -r a b c d <<< "$ip"

    ((a <= 255 && b <= 255 && c <= 255 && d <= 255))
}

# ============================================================
# Root检查
# ============================================================

check_root() {

    if [[ $EUID -ne 0 ]]; then

        echo -e "${YELLOW}当前不是 root 用户。${NC}"

        if command -v sudo >/dev/null 2>&1; then

            echo "尝试使用 sudo..."

            exec sudo bash "$SCRIPT_PATH"

        else

            echo "请使用 root 运行。"
            exit 1

        fi
    fi
}

# ============================================================
# 依赖
# ============================================================

install_dependencies() {

    section "检查 Ubuntu 24.04 依赖"

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

        log OK "依赖完整，无需安装"
        return 0

    fi

    echo
    echo "需要安装：${packages[*]}"
    echo

    read -rp "是否自动安装？[Y/n]：" answer

    if [[ "$answer" =~ ^[Nn]$ ]]; then

        log WARN "跳过依赖安装"
        return 0

    fi

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    if apt-get install -y "${packages[@]}"; then

        log OK "依赖安装完成"

    else

        log ERROR "依赖安装失败"

    fi
}

# ============================================================
# 创建报告
# ============================================================

create_report() {

    REPORT_TIME="$(date '+%Y%m%d_%H%M%S')"

    REPORT_TXT="${REPORT_DIR}/network_test_${REPORT_TIME}.txt"
    REPORT_JSON="${REPORT_DIR}/network_test_${REPORT_TIME}.json"

    START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

    cat > "$REPORT_TXT" <<EOF
============================================================
network_test.sh
Version: ${VERSION}
Time: ${START_TIME}
============================================================
EOF
}

# ============================================================
# 公网IP
# ============================================================

get_public_ip() {

    section "公网 IP"

    PUBLIC_IPV4=""

    local apis=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me/ip"
        "https://ipinfo.io/ip"
    )

    for api in "${apis[@]}"; do

        PUBLIC_IPV4="$(
            curl -4 -fsS \
                --max-time 8 \
                "$api" 2>/dev/null |
            tr -d '[:space:]'
        )"

        if valid_ipv4 "$PUBLIC_IPV4"; then
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

    PUBLIC_IPV6="$(
        curl -6 -fsS \
            --max-time 8 \
            https://api64.ipify.org \
            2>/dev/null |
        tr -d '[:space:]'
    )" || true

    if [[ "$PUBLIC_IPV6" == *:* ]]; then

        log OK "公网 IPv6：$PUBLIC_IPV6"

    else

        log WARN "没有检测到公网 IPv6"
        PUBLIC_IPV6=""

    fi
}

# ============================================================
# 本地网络信息
# ============================================================

network_info() {

    section "服务器网络信息"

    LOCAL_IPV4="$(
        ip -4 addr show scope global 2>/dev/null |
        awk '/inet / {print $2}' |
        head -1 |
        cut -d/ -f1
    )"

    DEFAULT_IF="$(
        ip route 2>/dev/null |
        awk '/default/ {print $5; exit}'
    )"

    DEFAULT_GW="$(
        ip route 2>/dev/null |
        awk '/default/ {print $3; exit}'
    )"

    DNS_SERVER="$(
        resolvectl dns 2>/dev/null |
        awk 'NF>1 {print $2}' |
        head -1
    )"

    if [[ -z "$DNS_SERVER" ]]; then

        DNS_SERVER="$(
            grep '^nameserver' /etc/resolv.conf 2>/dev/null |
            head -1 |
            awk '{print $2}'
        )"

    fi

    echo "本地 IPv4：${LOCAL_IPV4:-未知}"
    echo "默认网卡：${DEFAULT_IF:-未知}"
    echo "默认网关：${DEFAULT_GW:-未知}"
    echo "DNS服务器：${DNS_SERVER:-未知}"

    {
        echo "本地 IPv4：${LOCAL_IPV4:-未知}"
        echo "默认网卡：${DEFAULT_IF:-未知}"
        echo "默认网关：${DEFAULT_GW:-未知}"
        echo "DNS服务器：${DNS_SERVER:-未知}"
    } >> "$REPORT_TXT"
}

# ============================================================
# Target IP输入
# ============================================================

input_target_ip() {

    while true; do

        echo
        echo "============================================================"
        echo "目标 IP 设置"
        echo "============================================================"
        echo
        echo "当前目标 IP：${TARGET_IP:-未设置}"
        echo
        echo "请输入目标 IPv4。"
        echo "例如：183.23.226.212"
        echo
        echo "输入 0 返回菜单"
        echo

        read -rp "目标 IP： " input

        if [[ "$input" == "0" ]]; then
            return 1
        fi

        if valid_ipv4 "$input"; then

            TARGET_IP="$input"

            echo
            echo "目标 IP 已设置：$TARGET_IP"
            echo

            read -rp "确认开始测试？[Y/n]：" confirm

            if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                return 0
            fi

        else

            echo
            echo -e "${RED}IP 地址格式错误。${NC}"

        fi

    done
}

# ============================================================
# DNS
# ============================================================

dns_test() {

    section "DNS 解析测试"

    DNS_FAIL=0

    local domains=(
        "www.google.com"
        "www.youtube.com"
        "www.facebook.com"
        "www.tiktok.com"
        "www.cloudflare.com"
    )

    for domain in "${domains[@]}"; do

        local result

        result="$(
            dig +time=3 +tries=1 +short "$domain" 2>/dev/null |
            head -1
        )"

        if [[ -n "$result" ]]; then

            log OK "$domain -> $result"

        else

            log WARN "$domain -> DNS FAIL"
            ((DNS_FAIL++))

        fi

    done

    echo "DNS服务器：${DNS_SERVER:-未知}" >> "$REPORT_TXT"
}

# ============================================================
# Ping
# ============================================================

ping_test() {

    section "Ping / 丢包测试"

    PING_FAIL=0

    local targets=(
        "Cloudflare:1.1.1.1"
        "Google DNS:8.8.8.8"
    )

    if [[ -n "$TARGET_IP" ]]; then
        targets+=("目标 IP:$TARGET_IP")
    fi

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        local result

        result="$(
            ping -c 4 -W 2 "$ip" 2>/dev/null |
            grep -oE '[0-9]+% packet loss' |
            head -1
        )"

        if [[ -n "$result" ]]; then

            local loss="${result%%% packet loss}"

            if [[ "$loss" == "0" ]]; then

                log OK "$name：${loss}% 丢包"

            else

                log WARN "$name：${loss}% 丢包"
                ((PING_FAIL++))

            fi

        else

            log WARN "$name：Ping FAIL"
            ((PING_FAIL++))

        fi

    done
}

# ============================================================
# TCP
# ============================================================

tcp_test() {

    section "TCP 端口测试"

    TCP_FAIL=0

    local tests=(
        "www.google.com:443"
        "www.youtube.com:443"
        "www.facebook.com:443"
        "www.tiktok.com:443"
    )

    if [[ -n "$TARGET_IP" ]]; then

        tests+=(
            "$TARGET_IP:22"
            "$TARGET_IP:80"
            "$TARGET_IP:443"
            "$TARGET_IP:8080"
            "$TARGET_IP:8443"
        )

    fi

    for item in "${tests[@]}"; do

        local host="${item%:*}"
        local port="${item##*:}"

        local start
        local end
        local ms

        start="$(date +%s%3N)"

        if timeout "$TIMEOUT" \
            bash -c "</dev/tcp/$host/$port" \
            2>/dev/null; then

            end="$(date +%s%3N)"
            ms=$((end-start))

            log OK "$host:$port OPEN (${ms} ms)"

        else

            log WARN "$host:$port CLOSED/FILTERED"
            ((TCP_FAIL++))

        fi

    done
}

# ============================================================
# HTTPS
# ============================================================

https_test() {

    section "HTTPS / HTTP 状态码"

    HTTPS_FAIL=0

    for domain in "${DOMAINS[@]}"; do

        local result
        local code
        local connect
        local total

        result="$(
            curl -4 \
                -L \
                -o /dev/null \
                -sS \
                --connect-timeout "$TIMEOUT" \
                --max-time "$TIMEOUT" \
                -w '%{http_code}|%{time_connect}|%{time_total}' \
                "https://$domain" \
                2>/dev/null || true
        )"

        code="$(echo "$result" | cut -d'|' -f1)"
        connect="$(echo "$result" | cut -d'|' -f2)"
        total="$(echo "$result" | cut -d'|' -f3)"

        if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then

            log OK "$domain：HTTPS $code / Connect ${connect}s / Total ${total}s"

        else

            log WARN "$domain：HTTPS ${code:-FAIL}"
            ((HTTPS_FAIL++))

        fi

    done
}

# ============================================================
# TLS
# ============================================================

tls_test() {

    section "TLS / SNI"

    TLS_FAIL=0

    for domain in "${DOMAINS[@]}"; do

        local output

        output="$(
            timeout "$TIMEOUT" \
                openssl s_client \
                -connect "$domain:443" \
                -servername "$domain" \
                -brief \
                </dev/null \
                2>&1 || true
        )"

        if echo "$output" |
            grep -Eq "Protocol version|Verification: OK|Peer certificate"; then

            log OK "$domain TLS / SNI 正常"

        elif echo "$output" |
            grep -q "BEGIN CERTIFICATE"; then

            log OK "$domain TLS / SNI 正常"

        else

            warn_text="TLS握手失败"
            log WARN "$domain $warn_text"
            ((TLS_FAIL++))

        fi

    done
}

# ============================================================
# 平均延迟
# ============================================================

latency_test() {

    section "平均 RTT"

    local targets=(
        "Cloudflare:1.1.1.1"
        "Google DNS:8.8.8.8"
    )

    if [[ -n "$TARGET_IP" ]]; then
        targets+=("目标 IP:$TARGET_IP")
    fi

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        local avg

        avg="$(
            ping -c 5 -W 2 "$ip" 2>/dev/null |
            awk -F'/' '/rtt|round-trip/ {print $5}'
        )"

        if [[ -n "$avg" ]]; then

            log OK "$name：平均 RTT ${avg} ms"

        else

            log WARN "$name：无法获取 RTT"

        fi

    done
}

# ============================================================
# 三网回程
# ============================================================

carrier_test_one() {

    local carrier="$1"
    local ip="$2"

    local file="/tmp/network_${carrier}_$$.txt"

    echo
    echo "---------- ${carrier} ----------"
    echo "测试目标：$ip"
    echo

    traceroute \
        -n \
        -w 1 \
        -q 1 \
        -m 20 \
        "$ip" \
        2>/dev/null |
        tee "$file" |
        tee -a "$REPORT_TXT"

    local avg
    local max

    avg="$(
        awk '
        / ms/ {
            for(i=1;i<=NF;i++){
                if($i=="ms"){
                    v=$(i-1)
                    gsub(/[^0-9.]/,"",v)
                    if(v!=""){
                        sum+=v
                        count++
                    }
                }
            }
        }
        END {
            if(count>0)
                printf "%.1f",sum/count
        }' "$file"
    )"

    max="$(
        awk '
        / ms/ {
            for(i=1;i<=NF;i++){
                if($i=="ms"){
                    v=$(i-1)
                    gsub(/[^0-9.]/,"",v)
                    if(v!="" && v>max)
                        max=v
                }
            }
        }
        END {
            if(max!="")
                printf "%.1f",max
        }' "$file"
    )"

    if [[ -n "$avg" ]]; then

        echo
        echo "${carrier} 平均跳点 RTT：${avg} ms"
        echo "${carrier} 最大跳点 RTT：${max} ms"

        {
            echo
            echo "${carrier} 平均跳点 RTT：${avg} ms"
            echo "${carrier} 最大跳点 RTT：${max} ms"
        } >> "$REPORT_TXT"

    else

        log WARN "${carrier} 无法计算 RTT"

    fi

    rm -f "$file"
}

carrier_test() {

    section "三网回程测试"

    echo
    echo "中国电信目标：$CT_IP"
    echo "中国联通目标：$CU_IP"
    echo "中国移动目标：$CM_IP"

    carrier_test_one "中国电信" "$CT_IP"
    carrier_test_one "中国联通" "$CU_IP"
    carrier_test_one "中国移动" "$CM_IP"
}

# ============================================================
# MTR
# ============================================================

mtr_test() {

    section "MTR 路由质量"

    local targets=(
        "中国电信:$CT_IP"
        "中国联通:$CU_IP"
        "中国移动:$CM_IP"
    )

    if [[ -n "$TARGET_IP" ]]; then
        targets+=("目标 IP:$TARGET_IP")
    fi

    for item in "${targets[@]}"; do

        local name="${item%%:*}"
        local ip="${item#*:}"

        echo
        echo "---------- $name / $ip ----------"

        if command -v mtr >/dev/null 2>&1; then

            timeout 60 \
                mtr \
                -r \
                -c 10 \
                -w \
                -n \
                "$ip" \
                2>/dev/null |
                tee -a "$REPORT_TXT"

        else

            log WARN "MTR 未安装"

        fi

    done
}

# ============================================================
# MTU
# ============================================================

mtu_test() {

    section "MTU / PMTU"

    local mtu

    mtu="$(
        ip link show "$DEFAULT_IF" 2>/dev/null |
        awk '
        /mtu/ {
            for(i=1;i<=NF;i++)
                if($i=="mtu")
                    print $(i+1)
        }'
    )"

    echo "当前接口：${DEFAULT_IF:-未知}"
    echo "当前 MTU：${mtu:-未知}"

    {
        echo "当前接口：${DEFAULT_IF:-未知}"
        echo "当前 MTU：${mtu:-未知}"
    } >> "$REPORT_TXT"

    if ping -4 \
        -M do \
        -s 1472 \
        -c 2 \
        -W 2 \
        1.1.1.1 \
        >/dev/null 2>&1; then

        log OK "IPv4 1472 bytes PMTU 测试通过"

    else

        log WARN "IPv4 1472 bytes PMTU 测试失败"

    fi
}

# ============================================================
# 单节点下载测速
# ============================================================

speed_test_one() {

    local name="$1"
    local url="$2"

    echo
    echo "---------- $name ----------"

    local tmp
    local start
    local end
    local elapsed
    local bytes
    local mbps

    tmp="/tmp/network_speed_${name// /_}_$$"

    start="$(date +%s%3N)"

    if ! timeout 40 \
        curl \
            -L \
            -4 \
            -sS \
            --connect-timeout 10 \
            --max-time 40 \
            -o "$tmp" \
            "$url" \
            2>/dev/null; then

        rm -f "$tmp"

        log WARN "$name：测速失败"
        return 1

    fi

    end="$(date +%s%3N)"

    elapsed=$((end-start))

    if [[ ! -s "$tmp" ]]; then

        rm -f "$tmp"

        log WARN "$name：没有下载到有效数据"
        return 1

    fi

    bytes="$(
        stat -c '%s' "$tmp" 2>/dev/null || echo 0
    )"

    rm -f "$tmp"

    if [[ "$bytes" -le 0 || "$elapsed" -le 0 ]]; then

        log WARN "$name：测速结果无效"
        return 1

    fi

    mbps="$(
        awk \
            -v bytes="$bytes" \
            -v ms="$elapsed" \
            'BEGIN {
                printf "%.2f",
                (bytes * 8 / (ms / 1000)) / 1000000
            }'
    )"

    if awk -v speed="$mbps" \
        'BEGIN {exit !(speed > 0)}'; then

        log OK "$name：${mbps} Mbps"

        echo "$name Speed=${mbps} Mbps" >> "$REPORT_TXT"

        if [[ "$name" == "Cloudflare" ]]; then
            CLOUDFLARE_SPEED="$mbps"
        fi

        if [[ "$name" == "OVH" ]]; then
            OVH_SPEED="$mbps"
        fi

        return 0

    fi

    log WARN "$name：测速结果无效"

    return 1
}

# ============================================================
# 公网测速
# ============================================================

speed_test() {

    section "公网多节点下载测速"

    CLOUDFLARE_SPEED="N/A"
    OVH_SPEED="N/A"

    speed_test_one \
        "Cloudflare" \
        "$CLOUDFLARE_URL" || true

    speed_test_one \
        "OVH" \
        "$OVH_URL" || true

    echo
    echo "Cloudflare：${CLOUDFLARE_SPEED} Mbps"
    echo "OVH：${OVH_SPEED} Mbps"
}

# ============================================================
# 单次并发测速
# ============================================================

parallel_speed_once() {

    local parallel="$1"

    local tmpdir
    local start
    local end
    local elapsed
    local total_bytes
    local speed
    local success

    tmpdir="/tmp/network_parallel_$$"

    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"

    start="$(date +%s%3N)"

    for ((i=1; i<=parallel; i++)); do

        (
            curl \
                -L \
                -4 \
                -sS \
                --connect-timeout 10 \
                --max-time "$((DURATION + 10))" \
                -o "${tmpdir}/${i}.dat" \
                "$CLOUDFLARE_URL" \
                2>/dev/null
        ) &

    done

    wait

    end="$(date +%s%3N)"

    elapsed=$((end-start))

    total_bytes="$(
        find "$tmpdir" \
            -type f \
            -printf '%s\n' 2>/dev/null |
        awk '{sum+=$1} END{print sum+0}'
    )"

    success="$(
        find "$tmpdir" \
            -type f \
            -size +0c \
            2>/dev/null |
        wc -l
    )"

    rm -rf "$tmpdir"

    if [[ "$success" -eq 0 ||
          "$total_bytes" -le 0 ||
          "$elapsed" -le 0 ]]; then

        log WARN "${parallel} 路并发：测速失败"

        return 1
    fi

    speed="$(
        awk \
            -v bytes="$total_bytes" \
            -v ms="$elapsed" \
            'BEGIN {
                printf "%.2f",
                (bytes * 8 / (ms / 1000)) / 1000000
            }'
    )"

    if awk -v speed="$speed" \
        'BEGIN {exit !(speed > 0)}'; then

        log OK "${parallel} 路并发：${speed} Mbps（${success} 路有效）"

        echo "Parallel_${parallel}=${speed} Mbps" >> "$REPORT_TXT"

        echo "$speed"

        return 0
    fi

    log WARN "${parallel} 路并发：结果无效"

    return 1
}

# ============================================================
# 并发峰值
# ============================================================

parallel_speed_test() {

    section "并发峰值测速"

    echo
    echo "测速时间：${DURATION} 秒"
    echo "测试级别：1 / 3 / 5 / 10 路"
    echo

    MAX_PARALLEL_SPEED="N/A"

    local max="0"
    local result

    for p in "${PARALLEL_LEVELS[@]}"; do

        result="$(parallel_speed_once "$p" 2>/dev/null | tail -1)"

        if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

            if awk \
                -v a="$result" \
                -v b="$max" \
                'BEGIN {exit !(a>b)}'; then

                max="$result"

            fi

        fi

    done

    if awk -v speed="$max" \
        'BEGIN {exit !(speed > 0)}'; then

        MAX_PARALLEL_SPEED="${max} Mbps"

        echo
        log OK "最高并发峰值：${max} Mbps"

    else

        log WARN "所有并发测速均失败"

    fi
}

# ============================================================
# Target IP综合测试
# ============================================================

target_test() {

    if [[ -z "$TARGET_IP" ]]; then

        if ! input_target_ip; then
            return
        fi

    fi

    section "目标 IP 综合测试"

    echo
    echo "Target IP：$TARGET_IP"
    echo

    # --------------------------------------------------------
    # Ping
    # --------------------------------------------------------

    echo "---- Ping ----"

    local ping_output

    ping_output="$(
        ping -c 10 -W 2 "$TARGET_IP" 2>/dev/null || true
    )"

    echo "$ping_output" | tee -a "$REPORT_TXT"

    # --------------------------------------------------------
    # TCP
    # --------------------------------------------------------

    echo
    echo "---- TCP端口 ----"

    for port in 22 80 443 8080 8443; do

        local start
        local end
        local ms

        start="$(date +%s%3N)"

        if timeout "$TIMEOUT" \
            bash -c "</dev/tcp/$TARGET_IP/$port" \
            2>/dev/null; then

            end="$(date +%s%3N)"
            ms=$((end-start))

            log OK "$TARGET_IP:$port OPEN (${ms} ms)"

        else

            log WARN "$TARGET_IP:$port CLOSED/FILTERED"

        fi

    done

    # --------------------------------------------------------
    # Traceroute
    # --------------------------------------------------------

    echo
    echo "---- Traceroute ----"

    traceroute \
        -n \
        -w 1 \
        -q 1 \
        -m 20 \
        "$TARGET_IP" \
        2>/dev/null |
        tee -a "$REPORT_TXT"

    # --------------------------------------------------------
    # MTR
    # --------------------------------------------------------

    echo
    echo "---- MTR ----"

    if command -v mtr >/dev/null 2>&1; then

        timeout 60 \
            mtr \
            -r \
            -c 10 \
            -w \
            -n \
            "$TARGET_IP" \
            2>/dev/null |
            tee -a "$REPORT_TXT"

    else

        log WARN "MTR 未安装"

    fi
}

# ============================================================
# IP ASN / ISP
# ============================================================

ip_info() {

    section "公网 IP / ASN / ISP 信息"

    if [[ -z "$PUBLIC_IPV4" ]]; then
        return
    fi

    local result=""

    # API 1
    result="$(
        curl -4 \
            -fsS \
            --max-time 10 \
            "https://ipapi.co/${PUBLIC_IPV4}/json/" \
            2>/dev/null || true
    )"

    if [[ -n "$result" ]] &&
        echo "$result" | grep -q '"ip"'; then

        echo "$result" |
            jq -r '
            "IP: \(.ip // "-")",
            "国家: \(.country_name // "-")",
            "地区: \(.region // "-")",
            "城市: \(.city // "-")",
            "ASN: \(.asn // "-")",
            "组织: \(.org // "-")"
            ' 2>/dev/null |
            tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    # API 2
    result="$(
        curl -4 \
            -fsS \
            --max-time 10 \
            "https://ipinfo.io/${PUBLIC_IPV4}/json" \
            2>/dev/null || true
    )"

    if [[ -n "$result" ]] &&
        echo "$result" | grep -q '"ip"'; then

        echo "$result" |
            jq -r '
            "IP: \(.ip // "-")",
            "国家: \(.country // "-")",
            "地区: \(.region // "-")",
            "城市: \(.city // "-")",
            "组织: \(.org // "-")"
            ' 2>/dev/null |
            tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    # API 3
    result="$(
        curl -4 \
            -fsS \
            --max-time 10 \
            "https://ipwho.is/${PUBLIC_IPV4}" \
            2>/dev/null || true
    )"

    if [[ -n "$result" ]] &&
        echo "$result" | grep -q '"ip"'; then

        echo "$result" |
            jq -r '
            "IP: \(.ip // "-")",
            "国家: \(.country // "-")",
            "地区: \(.region // "-")",
            "城市: \(.city // "-")",
            "ASN: \(.connection.asn // "-")",
            "组织: \(.connection.org // "-")"
            ' 2>/dev/null |
            tee -a "$REPORT_TXT"

        log OK "IP 信息获取成功"

        return
    fi

    log WARN "IP 信息 API 暂时无法访问"
}

# ============================================================
# Spamhaus
# ============================================================

spamhaus_test() {

    section "Spamhaus DNSBL"

    if [[ -z "$PUBLIC_IPV4" ]]; then
        return
    fi

    local reversed

    reversed="$(
        echo "$PUBLIC_IPV4" |
        awk -F. '{print $4"."$3"."$2"."$1}'
    )"

    if dig +short \
        "${reversed}.zen.spamhaus.org" \
        A 2>/dev/null |
        grep -qE '^127\.0\.0\.'; then

        log WARN "Spamhaus ZEN：LISTED"

        SPAMHAUS="LISTED"

    else

        log OK "Spamhaus ZEN：CLEAN"

        SPAMHAUS="CLEAN"

    fi
}

# ============================================================
# Tor Exit
# ============================================================

tor_test() {

    section "Tor Exit Node"

    if [[ -z "$PUBLIC_IPV4" ]]; then
        return
    fi

    local result

    result="$(
        curl \
            -fsS \
            --max-time 15 \
            https://check.torproject.org/torbulkexitlist \
            2>/dev/null || true
    )"

    if echo "$result" |
        grep -Fxq "$PUBLIC_IPV4"; then

        log WARN "公网 IP 出现在 Tor Exit Node 列表"

        TOR_EXIT="LISTED"

    else

        log OK "公网 IP 未发现于 Tor Exit Node 列表"

        TOR_EXIT="CLEAN"

    fi
}

# ============================================================
# 风险评分
# ============================================================

risk_score() {

    section "网络层风险评分"

    NETWORK_SCORE=100

    if [[ "$SPAMHAUS" == "LISTED" ]]; then
        NETWORK_SCORE=$((NETWORK_SCORE-40))
    fi

    if [[ "$TOR_EXIT" == "LISTED" ]]; then
        NETWORK_SCORE=$((NETWORK_SCORE-30))
    fi

    if [[ "$HTTPS_FAIL" -gt 2 ]]; then
        NETWORK_SCORE=$((NETWORK_SCORE-15))
    fi

    if [[ "$DNS_FAIL" -gt 2 ]]; then
        NETWORK_SCORE=$((NETWORK_SCORE-10))
    fi

    if [[ "$PING_FAIL" -gt 1 ]]; then
        NETWORK_SCORE=$((NETWORK_SCORE-10))
    fi

    [[ "$NETWORK_SCORE" -lt 0 ]] &&
        NETWORK_SCORE=0

    if [[ "$NETWORK_SCORE" -ge 90 ]]; then

        RISK_LEVEL="低"

    elif [[ "$NETWORK_SCORE" -ge 70 ]]; then

        RISK_LEVEL="较低"

    elif [[ "$NETWORK_SCORE" -ge 50 ]]; then

        RISK_LEVEL="中等"

    else

        RISK_LEVEL="较高"

    fi

    echo
    echo -e "${WHITE}网络层评分：${NETWORK_SCORE}/100${NC}"
    echo -e "${WHITE}网络层风险：${RISK_LEVEL}${NC}"

    {
        echo
        echo "Network Layer Score: ${NETWORK_SCORE}/100"
        echo "Network Layer Risk: ${RISK_LEVEL}"
    } >> "$REPORT_TXT"
}

# ============================================================
# JSON报告
# ============================================================

generate_json() {

    cat > "$REPORT_JSON" <<EOF
{
  "version": "${VERSION}",
  "time": "${START_TIME}",
  "public_ipv4": "${PUBLIC_IPV4}",
  "public_ipv6": "${PUBLIC_IPV6}",
  "local_ipv4": "${LOCAL_IPV4}",
  "interface": "${DEFAULT_IF}",
  "gateway": "${DEFAULT_GW}",
  "dns_server": "${DNS_SERVER}",
  "target_ip": "${TARGET_IP}",
  "network_score": ${NETWORK_SCORE},
  "network_risk": "${RISK_LEVEL}",
  "spamhaus": "${SPAMHAUS}",
  "tor_exit": "${TOR_EXIT}",
  "dns_fail": ${DNS_FAIL},
  "ping_fail": ${PING_FAIL},
  "tcp_fail": ${TCP_FAIL},
  "https_fail": ${HTTPS_FAIL},
  "tls_fail": ${TLS_FAIL},
  "cloudflare_speed_mbps": "${CLOUDFLARE_SPEED}",
  "ovh_speed_mbps": "${OVH_SPEED}",
  "max_parallel_speed_mbps": "${MAX_PARALLEL_SPEED}"
}
EOF
}

# ============================================================
# 最终报告
# ============================================================

final_summary() {

    section "最终测试结果"

    echo
    echo "公网 IPv4：${PUBLIC_IPV4:-未知}"
    echo "公网 IPv6：${PUBLIC_IPV6:-无}"
    echo "本地 IPv4：${LOCAL_IPV4:-未知}"
    echo "默认网卡：${DEFAULT_IF:-未知}"
    echo "默认网关：${DEFAULT_GW:-未知}"
    echo "DNS服务器：${DNS_SERVER:-未知}"

    if [[ -n "$TARGET_IP" ]]; then

        echo "目标 IP：$TARGET_IP"

    else

        echo "目标 IP：未指定"

    fi

    echo
    echo "------------------------------------------------------------"
    echo "网络层评分：${NETWORK_SCORE}/100"
    echo "网络层风险：${RISK_LEVEL}"
    echo "------------------------------------------------------------"

    echo
    echo "DNS失败：${DNS_FAIL}"
    echo "Ping失败：${PING_FAIL}"
    echo "TCP失败：${TCP_FAIL}"
    echo "HTTPS失败：${HTTPS_FAIL}"
    echo "TLS失败：${TLS_FAIL}"

    echo
    echo "Spamhaus：${SPAMHAUS}"
    echo "Tor Exit：${TOR_EXIT}"

    echo
    echo "公网测速："
    echo "Cloudflare：${CLOUDFLARE_SPEED} Mbps"
    echo "OVH：${OVH_SPEED} Mbps"
    echo "最高并发峰值：${MAX_PARALLEL_SPEED}"

    echo
    echo "TXT报告："
    echo "$REPORT_TXT"

    echo
    echo "JSON报告："
    echo "$REPORT_JSON"

    {
        echo
        echo "================ FINAL SUMMARY ================"
        echo "Public IPv4=${PUBLIC_IPV4}"
        echo "Public IPv6=${PUBLIC_IPV6}"
        echo "Local IPv4=${LOCAL_IPV4}"
        echo "Interface=${DEFAULT_IF}"
        echo "Gateway=${DEFAULT_GW}"
        echo "DNS=${DNS_SERVER}"
        echo "TargetIP=${TARGET_IP}"
        echo "NetworkScore=${NETWORK_SCORE}"
        echo "Risk=${RISK_LEVEL}"
        echo "DNSFail=${DNS_FAIL}"
        echo "PingFail=${PING_FAIL}"
        echo "TCPFail=${TCP_FAIL}"
        echo "HTTPSFail=${HTTPS_FAIL}"
        echo "TLSFail=${TLS_FAIL}"
        echo "Spamhaus=${SPAMHAUS}"
        echo "TorExit=${TOR_EXIT}"
        echo "CloudflareSpeed=${CLOUDFLARE_SPEED}"
        echo "OVHSpeed=${OVH_SPEED}"
        echo "MaxParallelSpeed=${MAX_PARALLEL_SPEED}"
    } >> "$REPORT_TXT"
}

# ============================================================
# 完整测试
# ============================================================

full_test() {

    create_report

    get_public_ip
    network_info

    if [[ -z "$TARGET_IP" ]]; then

        echo
        read -rp "是否设置 Target IP？[y/N]：" answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then

            input_target_ip || true

        fi

    fi

    dns_test
    ping_test
    tcp_test
    https_test
    tls_test
    latency_test
    carrier_test
    mtr_test
    mtu_test
    speed_test
    parallel_speed_test

    if [[ -n "$TARGET_IP" ]]; then
        target_test
    fi

    ip_info
    spamhaus_test
    tor_test
    risk_score

    generate_json
    final_summary

    pause_screen
}

# ============================================================
# 平台网络测试
# ============================================================

platform_test() {

    create_report

    get_public_ip
    network_info

    section "Google / YouTube / Facebook / TikTok"

    dns_test
    tcp_test
    https_test
    tls_test
    latency_test

    final_summary

    pause_screen
}

# ============================================================
# 三网测试
# ============================================================

carrier_only_test() {

    create_report

    carrier_test
    mtr_test

    if [[ -n "$TARGET_IP" ]]; then
        target_test
    fi

    final_summary

    pause_screen
}

# ============================================================
# 速度测试
# ============================================================

speed_only_test() {

    create_report

    speed_test
    parallel_speed_test

    final_summary

    pause_screen
}

# ============================================================
# IP风险测试
# ============================================================

risk_only_test() {

    create_report

    get_public_ip
    ip_info
    spamhaus_test
    tor_test

    risk_score

    final_summary

    pause_screen
}

# ============================================================
# 查看公网IP
# ============================================================

show_public_ip() {

    create_report

    get_public_ip

    echo
    echo "公网 IPv4：${PUBLIC_IPV4:-未知}"
    echo "公网 IPv6：${PUBLIC_IPV6:-无}"

    pause_screen
}

# ============================================================
# 历史报告
# ============================================================

show_reports() {

    while true; do

        clear 2>/dev/null || true

        echo
        echo "============================================================"
        echo "历史测试报告"
        echo "============================================================"
        echo

        if [[ ! -d "$REPORT_DIR" ]]; then

            echo "暂无报告"
            pause_screen
            return

        fi

        mapfile -t reports < <(
            find "$REPORT_DIR" \
                -maxdepth 1 \
                -type f \
                \( -name "*.txt" -o -name "*.json" \) \
                -printf "%f\n" |
            sort -r
        )

        if [[ ${#reports[@]} -eq 0 ]]; then

            echo "暂无报告"
            pause_screen
            return

        fi

        local i=1

        for file in "${reports[@]}"; do

            echo "$i. $file"
            ((i++))

        done

        echo
        echo "0. 返回"
        echo

        read -rp "请选择报告： " choice

        if [[ "$choice" == "0" ]]; then
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#reports[@]} )); then

            local selected="${reports[$((choice-1))]}"

            clear

            echo
            echo "============================================================"
            echo "$selected"
            echo "============================================================"
            echo

            cat "$REPORT_DIR/$selected"

            pause_screen

        else

            echo
            echo -e "${RED}选择无效。${NC}"
            sleep 1

        fi

    done
}

# ============================================================
# 删除功能
# ============================================================

delete_menu() {

    while true; do

        clear

        echo
        echo "============================================================"
        echo "删除功能"
        echo "============================================================"
        echo
        echo "1. 删除所有测试报告"
        echo "2. 删除当前脚本"
        echo "3. 删除脚本 + 所有测试报告"
        echo "0. 返回"
        echo

        read -rp "请选择： " choice

        case "$choice" in

            1)

                echo
                echo -e "${YELLOW}即将删除：$REPORT_DIR${NC}"
                echo

                read -rp "请输入 DELETE 确认： " confirm

                if [[ "$confirm" == "DELETE" ]]; then

                    rm -rf "$REPORT_DIR"
                    mkdir -p "$REPORT_DIR"

                    echo
                    log OK "所有测试报告已删除"

                else

                    echo
                    log WARN "取消删除"

                fi

                sleep 2
                ;;

            2)

                echo
                echo -e "${YELLOW}即将删除当前脚本：${NC}"
                echo "$SCRIPT_PATH"
                echo

                read -rp "请输入 DELETE 确认： " confirm

                if [[ "$confirm" == "DELETE" ]]; then

                    rm -f -- "$SCRIPT_PATH"

                    echo
                    echo "脚本已经删除。"
                    exit 0

                else

                    echo
                    log WARN "取消删除"

                fi

                sleep 2
                ;;

            3)

                echo
                echo -e "${RED}警告：将删除脚本和全部报告。${NC}"
                echo

                read -rp "请输入 DELETE 确认： " confirm

                if [[ "$confirm" == "DELETE" ]]; then

                    rm -rf "$REPORT_DIR"
                    rm -f -- "$SCRIPT_PATH"

                    echo
                    echo "脚本和报告已经删除。"
                    exit 0

                else

                    echo
                    log WARN "取消删除"

                fi

                sleep 2
                ;;

            0)

                return
                ;;

            *)

                echo "无效选择"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 参数设置
# ============================================================

settings_menu() {

    while true; do

        clear

        echo
        echo "============================================================"
        echo "测试参数设置"
        echo "============================================================"
        echo
        echo "当前设置："
        echo
        echo "目标 IP   ：${TARGET_IP:-未设置}"
        echo "测速时间  ：${DURATION} 秒"
        echo "并发数量  ：${PARALLEL}"
        echo "连接超时  ：${TIMEOUT} 秒"
        echo
        echo "1. 设置目标 IP"
        echo "2. 设置测速时间"
        echo "3. 设置并发数量"
        echo "4. 设置连接超时"
        echo "5. 清除目标 IP"
        echo "0. 返回"
        echo

        read -rp "请选择： " choice

        case "$choice" in

            1)

                input_target_ip
                ;;

            2)

                read -rp "测速时间（秒）： " value

                if [[ "$value" =~ ^[0-9]+$ ]] &&
                    (( value > 0 && value <= 300 )); then

                    DURATION="$value"

                else

                    echo "请输入 1-300"
                    sleep 1

                fi

                ;;

            3)

                read -rp "并发数量： " value

                if [[ "$value" =~ ^[0-9]+$ ]] &&
                    (( value > 0 && value <= 20 )); then

                    PARALLEL="$value"

                else

                    echo "请输入 1-20"
                    sleep 1

                fi

                ;;

            4)

                read -rp "连接超时（秒）： " value

                if [[ "$value" =~ ^[0-9]+$ ]] &&
                    (( value > 0 && value <= 60 )); then

                    TIMEOUT="$value"

                else

                    echo "请输入 1-60"
                    sleep 1

                fi

                ;;

            5)

                TARGET_IP=""
                echo "目标 IP 已清除"
                sleep 1
                ;;

            0)

                return
                ;;

            *)

                echo "无效选择"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {

    while true; do

        print_header

        echo
        echo "当前服务器公网 IP：${PUBLIC_IPV4:-未检测}"

        if [[ -n "$TARGET_IP" ]]; then

            echo "当前目标 IP      ：$TARGET_IP"

        else

            echo "当前目标 IP      ：未设置"

        fi

        echo
        echo "============================================================"
        echo
        echo "  1. 完整网络测试"
        echo
        echo "  2. 公网多节点下载测速"
        echo
        echo "  3. 三网回程测试"
        echo
        echo "  4. Google / YouTube / Facebook / TikTok"
        echo
        echo "  5. 输入 IP 进行目标回程测试"
        echo
        echo "  6. IP 网络层风险检测"
        echo
        echo "  7. 查看历史测试报告"
        echo
        echo "  8. 删除脚本 / 测试报告"
        echo
        echo "  9. 查看公网 IP"
        echo
        echo "  10. 测试参数设置"
        echo
        echo "  0. 退出"
        echo
        echo "============================================================"
        echo

        read -rp "请选择操作： " choice

        case "$choice" in

            1)

                full_test
                ;;

            2)

                speed_only_test
                ;;

            3)

                carrier_only_test
                ;;

            4)

                platform_test
                ;;

            5)

                if input_target_ip; then

                    create_report
                    target_test
                    generate_json
                    final_summary
                    pause_screen

                fi

                ;;

            6)

                risk_only_test
                ;;

            7)

                show_reports
                ;;

            8)

                delete_menu
                ;;

            9)

                show_public_ip
                ;;

            10)

                settings_menu
                ;;

            0)

                echo
                echo "退出测试。"
                exit 0
                ;;

            *)

                echo
                echo -e "${RED}无效选择，请重新输入。${NC}"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 初始化
# ============================================================

check_root
install_dependencies
get_public_ip

main_menu
