#!/usr/bin/env bash
set -euo pipefail

# =============================
# 配置区域：根据你自己的规划修改
# =============================

# 批量配置的网口 IP（想给 10 个全配就都写上）
# 这里先只给用到的 4 个网卡配 IP，其它你可以自己按格式往下加
declare -A IF_IPS=(
  # 对1: ens2f0 <-> ens4f1 使用 10.10.1.0/30
  [ens2f0]="10.10.1.1/30"
  [ens4f1]="10.10.1.2/30"

  # 对2: ens2f1 <-> ens5f0 使用 10.10.2.0/30
  [ens2f1]="10.10.2.1/30"
  [ens5f0]="10.10.2.2/30"

  # 其他网卡如果要配 IP，可以按下面格式往下加：
  [ens3f0]="10.10.3.1/24"
  [ens5f1]="10.10.3.2/24"
  
  [ens3f1]="10.10.4.1/24"  
  [ens6f0]="10.10.4.2/24"

  [ens4f0]="10.10.5.1/24"
  [ens6f1]="10.10.5.2/24"
)

# iperf3 参数（可以根据带宽/需求自己改）
DURATION=10         # 每次测试时长（秒）
PARALLEL=4          # 并发流数 -P
PROTO="tcp"         # tcp 或 udp, udp 的话会加 -u -b 0

# 对 1: ens2f0 <-> ens4f1
PAIR1_IF_A="ens2f0"
PAIR1_IF_B="ens4f1"
PAIR1_IP_A="10.10.1.1"
PAIR1_IP_B="10.10.1.2"

# 对 2: ens2f1 <-> ens5f0
PAIR2_IF_A="ens2f1"
PAIR2_IF_B="ens5f0"
PAIR2_IP_A="10.10.2.1"
PAIR2_IP_B="10.10.2.2"

# 对 3: ens3f0 <-> ens5f1
PAIR3_IF_A="ens3f0"
PAIR3_IF_B="ens5f1"
PAIR3_IP_A="10.10.3.1"
PAIR3_IP_B="10.10.3.2"

# 对 4: ens3f1 <-> ens6f0
PAIR4_IF_A="ens3f1"
PAIR4_IF_B="ens6f0"
PAIR4_IP_A="10.10.4.1"
PAIR4_IP_B="10.10.4.2"

# 对 5: ens4f0 <-> ens6f1
PAIR5_IF_A="ens4f0"
PAIR5_IF_B="ens6f1"
PAIR5_IP_A="10.10.5.1"
PAIR5_IP_B="10.10.5.2"
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

config_ips() {
  echo "=== 配置网卡 IP ==="
  for iface in "${!IF_IPS[@]}"; do
    ip_cidr="${IF_IPS[$iface]}"
    echo "-> 配置 $iface = $ip_cidr"

    # 确认网卡存在
    if ! ip link show "$iface" &>/dev/null; then
      echo "   [警告] 网卡 $iface 不存在，跳过"
      continue
    fi

    # 清空旧 IP（只清 IPv4，可按需加 -6）
    ip addr flush dev "$iface"

    # 配置新 IP
    ip addr add "$ip_cidr" dev "$iface"
    ip link set "$iface" up
  done
  echo "=== 网卡 IP 配置完成 ==="
}

run_iperf_pair() {
  local name="$1"
  local if_server="$2"
  local ip_server="$3"
  local if_client="$4"
  local ip_client="$5"

  echo
  echo "===== 开始测试: $name ====="
  echo "  服务端: $if_server ($ip_server)"
  echo "  客户端: $if_client ($ip_client)"

  # 构造协议参数
  local proto_args=""
  if [[ "$PROTO" == "udp" ]]; then
    proto_args="-u -b 0"
  fi

  # 启动服务端（-1 表示完成一次测试后自动退出）
  iperf3 -s -B "$ip_server" -1 >"iperf3_${name}_server.log" 2>&1 &
  local server_pid=$!
  echo "  启动服务端 PID=${server_pid}"

  # 稍等服务端起来
  sleep 1

  echo "  客户端开始打流..."
  iperf3 -c "$ip_server" -B "$ip_client" \
    -P "$PARALLEL" -t "$DURATION" $proto_args \
    | tee "iperf3_${name}_client.log"

  # 等待服务端退出
  wait "$server_pid" || true
  echo "===== 测试完成: $name（日志: iperf3_${name}_*.log） ====="
}

# =============================
# 主流程
# =============================

check_root
check_iperf
config_ips

# 对1: ens2f0 <-> ens4f1
run_iperf_pair "pair1_${PAIR1_IF_A}_${PAIR1_IF_B}" \
  "$PAIR1_IF_A" "$PAIR1_IP_A" \
  "$PAIR1_IF_B" "$PAIR1_IP_B"

# 对2: ens2f1 <-> ens5f0
run_iperf_pair "pair2_${PAIR2_IF_A}_${PAIR2_IF_B}" \
  "$PAIR2_IF_A" "$PAIR2_IP_A" \
  "$PAIR2_IF_B" "$PAIR2_IP_B"

echo
echo "所有测试完成。"
