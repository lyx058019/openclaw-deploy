#!/bin/bash
# 批量部署脚本 - V1.2
# 支持多主机并行/串行部署，读取 inventory.ini 主机清单

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/deploy/common.sh" 2>/dev/null || source "$PROJECT_DIR/build/common.sh"

INVENTORY_FILE=""
PACKAGE=""
INSTALL_DIR="/opt/openclaw"
MODE="cover"
PARALLEL=1
MAX_JOBS=4
DRY_RUN=false
TIMEOUT_SECONDS=300

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

declare -a HOSTS=()

usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  --inventory <file>     主机清单文件（必需）
  --package <tar.gz>     部署包路径（必需）
  --parallel <N>         并行部署主机数（默认: 4）
  --install-dir <dir>    远程安装目录（默认: /opt/openclaw）
  --mode <mode>          冲突处理模式（默认: cover）
  --timeout <seconds>    单台主机超时（默认: 300）
  --dry-run              模拟运行，不实际部署
  -h, --help             显示帮助

示例:
  $0 --inventory ./hosts.ini --package ./openclaw.tar.gz
  $0 --inventory ./hosts.ini --package ./openclaw.tar.gz --parallel 8
  $0 --inventory ./hosts.ini --package ./openclaw.tar.gz --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) INVENTORY_FILE="$2"; shift 2;;
    --package) PACKAGE="$2"; shift 2;;
    --parallel) PARALLEL="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --timeout) TIMEOUT_SECONDS="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) log_error "未知参数: $1"; usage; exit 1;;
  esac
done

# 验证参数
if [ -z "$INVENTORY_FILE" ]; then
  log_error "必须提供 --inventory 参数"
  usage; exit 1
fi

if [ ! -f "$INVENTORY_FILE" ]; then
  log_error "主机清单文件不存在: $INVENTORY_FILE"
  exit 1
fi

if [ -z "$PACKAGE" ]; then
  log_error "必须提供 --package 参数"
  usage; exit 1
fi

if [ ! -f "$PACKAGE" ]; then
  log_error "部署包不存在: $PACKAGE"
  exit 1
fi

if [ ! -f "${PACKAGE}.sha256" ]; then
  log_warn "未找到 SHA256 文件: ${PACKAGE}.sha256，部署时将跳过校验"
fi

# 解析 inventory 文件
# 格式: [group_name]
# host1 ansible_host=192.168.1.10 ansible_user=root ansible_port=22
parse_inventory() {
  local current_group="ungrouped"
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # 节头 [group_name]
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      current_group="${BASH_REMATCH[1]}"
      continue
    fi

    # 跳过 key=value 全局变量行（ansible 内联变量）
    [[ "$line" =~ ^ansible_ ]] && continue

    # 解析 host 行
    local host_entry
    host_entry="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$host_entry" ]] && continue

    local host_alias="${host_entry%% *}"
    local host_addr="$host_alias"
    local host_user="root"
    local host_port="22"
    local host_key=""

    # 解析 ansible_xxx=yyy 形式的内联变量
    while IFS='=' read -r key value; do
      case "$key" in
        ansible_host) host_addr="$value" ;;
        ansible_user) host_user="$value" ;;
        ansible_port) host_port="$value" ;;
        ansible_ssh_private_key_file) host_key="$value" ;;
      esac
    done < <(echo "$host_entry" | grep -oE 'ansible_[a-z_]+=[^ ]+' | tr '=' '\n')

    HOSTS+=("$host_alias|$host_addr|$host_user|$host_port|$host_key|$current_group")
  done < "$INVENTORY_FILE"
}

parse_inventory

if [ ${#HOSTS[@]} -eq 0 ]; then
  log_error "未从清单文件中解析到任何主机"
  exit 1
fi

log_info "=============================================="
log_info "  OpenClaw 批量部署器 V1.2"
log_info "=============================================="
log_info "  主机数量:  ${#HOSTS[@]}"
log_info "  并行数:    $PARALLEL"
log_info "  部署包:    $PACKAGE"
log_info "  安装目录:  $INSTALL_DIR"
log_info "  冲突模式:  $MODE"
log_info "=============================================="
echo

if $DRY_RUN; then
  log_warn "=== 模拟模式（不实际部署）==="
  echo
  for entry in "${HOSTS[@]}"; do
    IFS='|' read -r alias addr user port key group <<< "$entry"
    echo "  [$group] $alias → $addr (user=$user, port=$port)"
  done
  echo
  log_success "模拟运行完成，共 ${#HOSTS[@]} 台主机"
  exit 0
fi

# 单主机部署函数
deploy_one_host() {
  local entry="$1"
  IFS='|' read -r alias addr user port key group <<< "$entry"

  local start_time
  start_time=$(date +%s)
  local status="✅ 成功"
  local log_file="${PROJECT_DIR}/logs/batch-${alias}.log"

  mkdir -p "$(dirname "$log_file")"

  {
    echo "=== 开始部署: $alias ($addr) [$(date)] ==="

    local ssh_opts=(
      -o "StrictHostKeyChecking=accept-new"
      -o "UserKnownHostsFile=$HOME/.ssh/known_hosts"
      -o "ConnectTimeout=10"
      -o "BatchMode=yes"
      -p "$port"
    )

    local scp_opts=("${ssh_opts[@]}")
    local ssh_cmd=(ssh "${ssh_opts[@]}")
    local scp_cmd=(scp "${scp_opts[@]}")

    [ -n "$key" ] && { ssh_cmd+=( -i "$key" ); scp_cmd+=( -i "$key" ); }

    # 快速连通性检测
    if ! "${ssh_cmd[@]}" "$user@$addr" echo "pong" &>/dev/null; then
      echo "❌ SSH 连接失败"
      return 1
    fi

    # 上传部署包
    local remote_pkg="/tmp/openclaw-deploy-${alias}.tar.gz"
    echo "📤 上传部署包 → $remote_pkg"
    "${scp_cmd[@]}" "$PACKAGE" "$user@$addr:$remote_pkg"

    [ -f "${PACKAGE}.sha256" ] && "${scp_cmd[@]}" "${PACKAGE}.sha256" "$user@$addr:${remote_pkg}.sha256"

    # 执行远程部署
    echo "🚀 执行远程部署..."
    "${ssh_cmd[@]}" "$user@$addr" bash -s -- \
      "$INSTALL_DIR" "$remote_pkg" "$MODE" <<'REMOTE'
set -euo pipefail
INSTALL_DIR="$1"; REMOTE_PKG="$2"; MODE="$3"

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"
  else echo "shasum -a 256"; fi
}

# 校验
SHA_FILE="${REMOTE_PKG}.sha256"
if [ -f "$SHA_FILE" ]; then
  expected=$(awk '{print $1}' "$SHA_FILE" | head -n1)
  actual=$(sha256_cmd "$REMOTE_PKG" | awk '{print $1}')
  [ "$expected" = "$actual" ] && echo "✅ SHA256 校验通过" || { echo "❌ SHA256 校验失败"; exit 1; }
fi

mkdir -p /tmp/openclaw-deploy-tmp
tar -xzf "$REMOTE_PKG" -C /tmp/openclaw-deploy-tmp

# 调用冲突处理
SCRIPT_DIR="/tmp/openclaw-deploy-tmp"
HANDLE="${SCRIPT_DIR}/$(ls "$SCRIPT_DIR" 2>/dev/null | grep -i deploy | head -1)/scripts/deploy/handle_conflict.sh"
if [ -f "${SCRIPT_DIR}/scripts/deploy/handle_conflict.sh" ]; then
  "${SCRIPT_DIR}/scripts/deploy/handle_conflict.sh" --mode "$MODE" --target "$INSTALL_DIR" --source "${SCRIPT_DIR}"
elif [ -f "${SCRIPT_DIR}/deploy/local/handle_conflict.sh" ]; then
  "${SCRIPT_DIR}/deploy/local/handle_conflict.sh" --mode "$MODE" --target "$INSTALL_DIR" --source "${SCRIPT_DIR}"
else
  echo "⚠️  未找到冲突处理脚本，跳过"
fi

# 清理
rm -rf /tmp/openclaw-deploy-tmp "$REMOTE_PKG" "${REMOTE_PKG}.sha256"
echo "✅ 部署完成"
REMOTE

    local end_time end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo "=== 结束: $alias (耗时 ${duration}s) [$(date)] ==="
  } &>"$log_file"

  if $?; then
    echo -e "  ${GREEN}✅${NC} [$group] $alias ($addr) — ${duration}s"
  else
    echo -e "  ${RED}❌${NC} [$group] $alias ($addr) — 见日志: $log_file"
  fi
}

export -f deploy_one_host
export PROJECT_DIR PACKAGE INSTALL_DIR MODE RED GREEN NC

echo "📋 主机清单："
for entry in "${HOSTS[@]}"; do
  IFS='|' read -r alias addr user port key group <<< "$entry"
  echo "   [$group] $alias → $addr"
done
echo

# 统计
declare -A group_stats
total=${#HOSTS[@]}
succeed=0
failed=0

log_info "🚀 开始部署（并行度: $PARALLEL）..."
echo

start_ts=$(date +%s)

if command -v GNU_PARALLEL_ARG:=$(command -v parallel) 2>/dev/null && [ -n "$(command -v parallel)" ]; then
  # 使用 GNU parallel 并行
  printf '%s\n' "${HOSTS[@]}" | parallel -j "$PARALLEL" --colsep '|' \
    "bash -c 'source $PROJECT_DIR/deploy/batch/batch_deploy.sh --help >/dev/null 2>&1; entry={1}; deploy_one_host \"\$entry\"' _ {}
else
  # 降级为 bash 后台任务
  declare -a pids=()
  for entry in "${HOSTS[@]}"; do
    while [ $(jobs -r | wc -l) -ge "$PARALLEL" ]; do sleep 1; done
    (deploy_one_host "$entry") &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do wait "$pid"; done
fi

end_ts=$(date +%s)
total_time=$((end_ts - start_ts))

echo
log_info "=============================================="
log_info "  部署完成！总耗时: ${total_time}s"
log_success "成功: $succeed / $total"
[ $failed -gt 0 ] && log_error "失败: $failed / $total"
log_info "=============================================="
