#!/usr/bin/env bash
# 不用 -e，避免某个测试失败导致整个脚本退出
set -uo pipefail

# =============================
# 配置区域
# =============================

# 批量配置的网口 IP
declare -A IF_IPS=(
  [ens2f0]="10.10.1.1/30"
  [ens4f1]="10.10.1.2/30"
  [ens2f1]="10.10.2.1/30"
  [ens5f0]="10.10.2.2/30"
  [ens3f0]="10.10.3.1/30"
  [ens5f1]="10.10.3.2/30"
  [ens3f1]="10.10.4.1/30"
  [ens6f0]="10.10.4.2/30"
  [ens4f0]="10.10.5.1/30"
  [ens6f1]="10.10.5.2/30"
)

# 指定哪些网卡放到哪个 namespace
NS_A="nsA"
NS_B="nsB"
NS_A_IFS=(ens2f0 ens2f1 ens3f0 ens3f1 ens4f0)
NS_B_IFS=(ens4f1 ens5f0 ens5f1 ens6f0 ens6f1)

# iperf3 参数
DURATION=10
PARALLEL=4
PROTO="tcp"      # tcp / udp（udp 会加 -u -b 0）

# 各对配置
PAIR1_IF_A="ens2f0"; PAIR1_IF_B="ens4f1"; PAIR1_IP_A="10.10.1.1"; PAIR1_IP_B="10.10.1.2"
PAIR2_IF_A="ens2f1"; PAIR2_IF_B="ens5f0"; PAIR2_IP_A="10.10.2.1"; PAIR2_IP_B="10.10.2.2"
PAIR3_IF_A="ens3f0"; PAIR3_IF_B="ens5f1"; PAIR3_IP_A="10.10.3.1"; PAIR3_IP_B="10.10.3.2"
PAIR4_IF_A="ens3f1"; PAIR4_IF_B="ens6f0"; PAIR4_IP_A="10.10.4.1"; PAIR4_IP_B="10.10.4.2"
PAIR5_IF_A="ens4f0"; PAIR5_IF_B="ens6f1"; PAIR5_IP_A="10.10.5.1"; PAIR5_IP_B="10.10.5.2"

# 保存每一对的结果："name|OK|9.03 Gbits/sec" 或 "name|FAIL|原因"
PAIR_RESULTS=()

# =============================
# 工具函数
# =============================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行：sudo $0"
    exit 1
  fi
}

check_iperf() {
  if ! command -v iperf3 &>/dev/null; then
    echo "iperf3 未安装，请先安装：sudo apt install iperf3 -y"
    exit 1
  fi
}

create_netns() {
  echo "=== 创建 network namespace ==="
  ip netns del "$NS_A" 2>/dev/null || true
  ip netns del "$NS_B" 2>/dev/null || true

  ip netns add "$NS_A"
  ip netns add "$NS_B"

  for iface in "${NS_A_IFS[@]}"; do
    if ip link show "$iface" &>/dev/null; then
      echo "  -> 将 $iface 移入 $NS_A"
      ip link set "$iface" down || true
      ip link set "$iface" netns "$NS_A" || true
    else
      echo "  [警告] $iface 不存在，跳过"
    fi
  done

  for iface in "${NS_B_IFS[@]}"; do
    if ip link show "$iface" &>/dev/null; then
      echo "  -> 将 $iface 移入 $NS_B"
      ip link set "$iface" down || true
      ip link set "$iface" netns "$NS_B" || true
    else
      echo "  [警告] $iface 不存在，跳过"
    fi
  done

  ip netns exec "$NS_A" ip link set lo up || true
  ip netns exec "$NS_B" ip link set lo up || true
  echo "=== namespace 创建完成 ==="
}

get_ns_for_iface() {
  local iface="$1"
  for i in "${NS_A_IFS[@]}"; do
    [[ "$i" == "$iface" ]] && { echo "$NS_A"; return; }
  done
  for i in "${NS_B_IFS[@]}"; do
    [[ "$i" == "$iface" ]] && { echo "$NS_B"; return; }
  done
  echo ""
}

config_ips() {
  echo "=== 在各 namespace 中配置 IP ==="
  for iface in "${!IF_IPS[@]}"; do
    local ns
    ns=$(get_ns_for_iface "$iface")
    local ip_cidr="${IF_IPS[$iface]}"

    if [[ -z "$ns" ]]; then
      echo "  [警告] $iface 未被分配到任何 namespace，跳过"
      continue
    fi

    echo "  -> [$ns] 配置 $iface = $ip_cidr"
    ip netns exec "$ns" ip addr flush dev "$iface" || true
    ip netns exec "$ns" ip addr add "$ip_cidr" dev "$iface" || true
    ip netns exec "$ns" ip link set "$iface" up || true
  done
  echo "=== IP 配置完成 ==="
}

extract_rate_from_log() {
  local log_file="$1"
  local line rate

  line=$(grep -E 'SUM.*bits/sec' "$log_file" 2>/dev/null | tail -n1 || true)
  if [[ -z "$line" ]]; then
    line=$(grep -E '[0-9]+\.[0-9]+\s+[KMG]bits/sec' "$log_file" 2>/dev/null | tail -n1 || true)
  fi
  if [[ -z "$line" ]]; then
    echo "unknown"
    return
  fi

  rate=$(awk '{
    for (i=1; i<=NF; i++) {
      if ($i ~ /^[0-9.]+$/ && $(i+1) ~ /bits\/sec$/) {
        print $i " " $(i+1);
        exit
      }
    }
  }' <<<"$line")
  [[ -z "$rate" ]] && rate="unknown"
  echo "$rate"
}

run_iperf_pair() {
  local name="$1"
  local if_a="$2" ip_a="$3"
  local if_b="$4" ip_b="$5"

  local ns_a ns_b
  ns_a=$(get_ns_for_iface "$if_a")
  ns_b=$(get_ns_for_iface "$if_b")

  echo
  echo "===== 开始测试: $name ====="

  if [[ -z "$ns_a" || -z "$ns_b" ]]; then
    echo "  [错误] $if_a 或 $if_b 未找到 namespace，跳过此对"
    PAIR_RESULTS+=("${name}|FAIL|namespace_not_found")
    return
  fi

  echo "  服务端: $ns_a/$if_a ($ip_a)"
  echo "  客户端: $ns_b/$if_b ($ip_b)"

  local proto_args=""
  [[ "$PROTO" == "udp" ]] && proto_args="-u -b 0"

  local server_log="iperf3_${name}_server.log"
  local client_log="iperf3_${name}_client.log"

  ip netns exec "$ns_a" iperf3 -s -B "$ip_a" -1 >"$server_log" 2>&1 &
  local server_pid=$!
  echo "  启动服务端 PID=${server_pid}"

  sleep 1

  echo "  客户端开始打流..."
  # 取管道第一个命令(iperf3)的返回码
  ip netns exec "$ns_b" iperf3 -c "$ip_a" -B "$ip_b" \
    -P "$PARALLEL" -t "$DURATION" $proto_args \
    | tee "$client_log"
  local client_rc=${PIPESTATUS[0]}

  wait "$server_pid"
  local server_rc=$?

  if (( client_rc == 0 && server_rc == 0 )); then
    local rate
    rate=$(extract_rate_from_log "$client_log")
    echo "  [结果] 成功，速率：$rate"
    PAIR_RESULTS+=("${name}|OK|${rate}")
  else
    local reason="client_rc=${client_rc}, server_rc=${server_rc}"
    echo "  [结果] 失败，原因：$reason"
    PAIR_RESULTS+=("${name}|FAIL|${reason}")
  fi

  echo "===== 测试结束: $name ====="
}

# =============================
# 主流程
# =============================

check_root
check_iperf
create_netns
config_ips

run_iperf_pair "pair1_${PAIR1_IF_A}_${PAIR1_IF_B}" "$PAIR1_IF_A" "$PAIR1_IP_A" "$PAIR1_IF_B" "$PAIR1_IP_B"
run_iperf_pair "pair2_${PAIR2_IF_A}_${PAIR2_IF_B}" "$PAIR2_IF_A" "$PAIR2_IP_A" "$PAIR2_IF_B" "$PAIR2_IP_B"
run_iperf_pair "pair3_${PAIR3_IF_A}_${PAIR3_IF_B}" "$PAIR3_IF_A" "$PAIR3_IP_A" "$PAIR3_IF_B" "$PAIR3_IP_B"
run_iperf_pair "pair4_${PAIR4_IF_A}_${PAIR4_IF_B}" "$PAIR4_IF_A" "$PAIR4_IP_A" "$PAIR4_IF_B" "$PAIR4_IP_B"
run_iperf_pair "pair5_${PAIR5_IF_A}_${PAIR5_IF_B}" "$PAIR5_IF_A" "$PAIR5_IP_A" "$PAIR5_IF_B" "$PAIR5_IP_B"

echo
echo "===================== 测试汇总 ====================="
for item in "${PAIR_RESULTS[@]}"; do
  IFS='|' read -r name status info <<<"$item"
  if [[ "$status" == "OK" ]]; then
    echo "  ${name}: 成功，速率 = ${info}"
  else
    echo "  ${name}: 失败，原因 = ${info}"
  fi
done
echo "===================================================="
