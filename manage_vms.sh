#!/usr/bin/env bash
# ============================================================================
# manage_vms.sh — 虚拟机批量启动/停止/状态查看/重启（自动适配 Linux / macOS 平台）
#
# 功能说明:
#   Linux (KVM/libvirt): start=启动宿主机上全部 libvirt VM（virsh start）；
#                        stop=对全部 libvirt VM 优雅关机（virsh shutdown），已停止的自动跳过；
#                        status=查看全部 libvirt VM 的运行状态（只读，不修改任何状态）；
#                        restart=先批量优雅停止再批量启动
#   macOS (Lima):        start=逐台启动 deploy_vms.env 中 MACHINE_NAMES 定义的 Lima VM
#                        （只操作本项目定义的 VM，不影响 colima 等其他实例），
#                        并等待各 VM 的 SSH 端口就绪；
#                        stop=逐台优雅关机（ACPI shutdown），已停止的自动跳过；
#                        status=查看各 VM 运行状态与 SSH 端口就绪情况（只读）；
#                        restart=先批量优雅停止再批量启动（等价 stop + start）
#
# 使用说明:
#   ./manage_vms.sh <start|stop|status|restart> [选项]
#
# 参数说明:
#   start           批量启动 VM（已运行的自动跳过）
#   stop            批量停止 VM（已停止的自动跳过）
#   status          查看 VM 运行状态（只读，仅输出状态信息，不产生阶段日志）
#   restart         批量重启 VM（等价于先 stop 再 start）
#   -h, --help      显示本帮助
#   --dry-run       预览将执行的操作，不实际执行
#   -f, --force     仅 stop 有效: 强制断电（macOS/Lima 等价 limactl stop --force；
#                   Linux/KVM 等价 virsh destroy），不推荐
#
# 依赖说明:
#   - Linux: virsh（libvirt-clients）
#   - macOS: limactl（brew install lima）
#
# 配置文件说明:
#   同目录 manage_vms.env（VM 清单与部署共用，内部引入 deploy_vms.env 的 macOS 配置段；
#   Linux 分支不读取）
#
# 日志目录说明:
#   ./logs/manage_vms_<start|stop|status|restart>_YYYYmmdd_HHMMSS.log
#
# 产物目录说明:
#   无（本脚本不产生持久化产物）
#
# 示例命令:
#   ./manage_vms.sh start
#   ./manage_vms.sh start --dry-run
#   ./manage_vms.sh stop
#   ./manage_vms.sh stop --dry-run
#   ./manage_vms.sh stop --force
#   ./manage_vms.sh status
#   ./manage_vms.sh restart
#   ./manage_vms.sh restart --dry-run
#
# 风险提示:
#   stop --force 为强制断电，可能导致 VM 内文件系统损坏，仅作兜底手段。
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# 路径初始化（全部基于脚本所在目录）
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
ENV_FILE="$SCRIPT_DIR/manage_vms.env"

ACTION=""      # start | stop | status | restart
DRY_RUN=0
FORCE=0
STAGE_NO=0
STAGE_TOTAL=4

# ----------------------------------------------------------------------------
# 日志（带时间戳、级别、阶段进度）
# ----------------------------------------------------------------------------
LOG_FILE=""

log_msg() { # $1=级别 $2=内容
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$1] [${STAGE_NO}-${STAGE_TOTAL}] $2"
  echo -e "$line"
  [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}
log()  { log_msg "INFO" "$*"; }
warn() { log_msg "WARN" "$*"; }
err()  { log_msg "ERROR" "$*"; }
die()  { err "$*"; exit 1; }

stage_begin() { STAGE_NO="$1"; log "========== 阶段 $1/$STAGE_TOTAL: $2 =========="; }
stage_end()   { log "---------- 阶段 $1/$STAGE_TOTAL 完成 ----------"; }

# ----------------------------------------------------------------------------
# 参数解析: 子命令 + 选项
# ----------------------------------------------------------------------------
usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; }

parse_args() {
  [[ $# -ge 1 ]] || { err "缺少子命令（start / stop / status / restart）"; usage; exit 1; }
  case "$1" in
    start|stop|status|restart) ACTION="$1" ;;
    -h|--help)  usage; exit 0 ;;
    *) err "未知子命令: $1（支持 start / stop / status / restart）"; usage; exit 1 ;;
  esac
  shift
  for arg in "$@"; do
    case "$arg" in
      -h|--help)  usage; exit 0 ;;
      --dry-run)  DRY_RUN=1 ;;
      -f|--force) FORCE=1 ;;
      *) err "未知参数: $arg"; usage; exit 1 ;;
    esac
  done
  if [[ "$ACTION" != "stop" && "$FORCE" -eq 1 ]]; then
    die "--force 仅在 stop 时有效"
  fi
}

# ============================================================
# macOS (Lima) 公共: 配置加载与状态查询
# ============================================================
load_lima_config() {
  [[ -f "$ENV_FILE" ]] || die "缺少配置文件: $ENV_FILE"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  : "${MACHINE_NAMES:?MACHINE_NAMES 未配置}"
}

vm_state() { limactl list --format '{{ .Status }}' "$1" 2>/dev/null || true; }

port_ready() { # $1=127.0.0.1端口
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}

# ============================================================
# macOS (Lima): 批量启动 VM（幂等: Running 跳过）
# ============================================================
start_lima() {
  stage_begin 1 "加载配置"
  load_lima_config
  : "${MACHINE_SSH_PORTS:?MACHINE_SSH_PORTS 未配置}"
  if [[ "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_SSH_PORTS[@]}" ]]; then
    die "配置错误: MACHINE_NAMES 与 MACHINE_SSH_PORTS 长度不一致，请检查 $ENV_FILE"
  fi
  stage_end 1

  stage_begin 2 "前置检查"
  command -v limactl >/dev/null 2>&1 || die "缺少 limactl，请先执行: brew install lima"
  stage_end 2

  # 阶段 3：逐台启动 VM（幂等：Running 跳过）
  stage_begin 3 "启动 VM"
  started=0; skipped=0; failed=0
  i=0
  for name in "${MACHINE_NAMES[@]}"; do
    port="${MACHINE_SSH_PORTS[$i]}"
    state="$(vm_state "$name")"
    if [[ -z "$state" ]]; then
      warn "$name 未部署（未在 limactl 中注册），跳过；请先执行 ./deploy_vms.sh deploy"
      skipped=$((skipped+1)); i=$((i+1)); continue
    fi
    if [[ "$state" == "Running" ]]; then
      log "$name 已在运行，跳过启动"
      skipped=$((skipped+1)); i=$((i+1)); continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] 将执行: limactl start --tty=false ${name}（当前状态: ${state}）"
      started=$((started+1)); i=$((i+1)); continue
    fi
    log "启动 ${name}（当前状态: ${state}）..."
    if limactl start --tty=false "$name" >>"$LOG_FILE" 2>&1; then
      started=$((started+1))
    else
      err "启动 $name 失败，详见 $LOG_FILE"
      failed=$((failed+1)); i=$((i+1)); continue
    fi
    i=$((i+1))
  done
  stage_end 3

  # 阶段 4：等待 SSH 端口就绪并汇总
  stage_begin 4 "等待 SSH 就绪并汇总"
  if [[ "$DRY_RUN" -eq 0 && "$started" -gt 0 ]]; then
    i=0
    for name in "${MACHINE_NAMES[@]}"; do
      port="${MACHINE_SSH_PORTS[$i]}"
      state="$(vm_state "$name")"
      if [[ "$state" == "Running" ]] && ! port_ready "$port"; then
        log "等待 $name SSH 端口就绪 (127.0.0.1:$port)..."
        attempt=1
        while [[ "$attempt" -le 100 ]]; do
          port_ready "$port" && break
          [[ "$attempt" -eq 100 ]] && warn "$name 等待 SSH 超时，可稍后手动检查: limactl shell $name"
          sleep 3
          attempt=$((attempt+1))
        done
        port_ready "$port" && log "$name SSH 已就绪: ssh $name"
      elif [[ "$state" == "Running" ]]; then
        log "$name SSH 已就绪: ssh $name"
      fi
      i=$((i+1))
    done
  fi
  log "启动完成统计: 新启动 ${started} 台，跳过 ${skipped} 台，失败 ${failed} 台"
  [[ "$failed" -eq 0 ]] || exit 1
  stage_end 4
}

# ============================================================
# macOS (Lima): 批量停止 VM（幂等: 非 Running 跳过）
# ============================================================
stop_lima() {
  stage_begin 1 "加载配置"
  load_lima_config
  stage_end 1

  stage_begin 2 "前置检查"
  command -v limactl >/dev/null 2>&1 || die "缺少 limactl，请先执行: brew install lima"
  [[ "$FORCE" -eq 1 ]] && warn "已启用 --force 强制停止模式"
  stage_end 2

  # 阶段 3：逐台关闭 VM（幂等：非 Running 跳过）
  stage_begin 3 "关闭 VM"
  stopped=0; skipped=0; failed=0
  for name in "${MACHINE_NAMES[@]}"; do
    state="$(vm_state "$name")"
    if [[ -z "$state" ]]; then
      warn "$name 未部署（未在 limactl 中注册），跳过"
      skipped=$((skipped+1)); continue
    fi
    if [[ "$state" != "Running" ]]; then
      log "${name} 已停止（状态: ${state}），跳过"
      skipped=$((skipped+1)); continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] 将执行: limactl stop $name"
      stopped=$((stopped+1)); continue
    fi
    log "优雅关闭 $name ..."
    if [[ "$FORCE" -eq 1 ]]; then
      limactl stop --force "$name" >>"$LOG_FILE" 2>&1 || { err "强制停止 $name 失败"; failed=$((failed+1)); continue; }
    else
      limactl stop "$name" >>"$LOG_FILE" 2>&1 || { err "优雅关机 $name 失败（可尝试: $0 stop --force）"; failed=$((failed+1)); continue; }
    fi
    stopped=$((stopped+1))
  done
  stage_end 3

  # 阶段 4：确认关机结果并汇总
  stage_begin 4 "确认关机结果并汇总"
  if [[ "$DRY_RUN" -eq 0 && "$stopped" -gt 0 ]]; then
    for name in "${MACHINE_NAMES[@]}"; do
      state="$(vm_state "$name")"
      [[ "$state" == "Running" ]] && warn "$name 仍处于运行状态，可执行: $0 stop --force"
    done
  fi
  log "关机完成统计: 发起关闭 ${stopped} 台，跳过 ${skipped} 台，失败 ${failed} 台"
  [[ "$failed" -eq 0 ]] || exit 1
  stage_end 4
}

# ============================================================
# macOS (Lima): 查看各 VM 运行状态与 SSH 就绪情况（只读）
# ============================================================
status_msg() { # $1=内容（status 专用：控制台只输出状态信息，同时记录日志文件）
  echo "$1"
  [[ -n "$LOG_FILE" ]] && echo "[status] $1" >> "$LOG_FILE" 2>/dev/null || true
}

status_lima() {
  load_lima_config
  : "${MACHINE_SSH_PORTS:?MACHINE_SSH_PORTS 未配置}"
  if [[ "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_SSH_PORTS[@]}" ]]; then
    die "配置错误: MACHINE_NAMES 与 MACHINE_SSH_PORTS 长度不一致，请检查 $ENV_FILE"
  fi
  command -v limactl >/dev/null 2>&1 || die "缺少 limactl，请先执行: brew install lima"

  running=0; stopped=0; missing=0
  i=0
  for name in "${MACHINE_NAMES[@]}"; do
    port="${MACHINE_SSH_PORTS[$i]}"
    state="$(vm_state "$name")"
    if [[ -z "$state" ]]; then
      status_msg "$name: 未部署（未在 limactl 中注册），如需部署请执行 ./deploy_vms.sh deploy"
      missing=$((missing+1)); i=$((i+1)); continue
    fi
    if [[ "$state" == "Running" ]]; then
      if port_ready "$port"; then
        status_msg "$name: Running，SSH 已就绪 (127.0.0.1:$port，ssh $name)"
      else
        status_msg "$name: Running，SSH 未就绪 (127.0.0.1:$port 不通)"
      fi
      running=$((running+1))
    else
      status_msg "$name: ${state}（已停止）"
      stopped=$((stopped+1))
    fi
    i=$((i+1))
  done
  status_msg "状态统计: 运行中 ${running} 台，已停止 ${stopped} 台，未部署 ${missing} 台"
}

# ============================================================
# macOS (Lima): 批量重启 VM（等价于 stop + start）
# ============================================================
restart_lima() {
  log "restart = stop + start，先优雅停止全部 VM，再批量启动并等待 SSH 就绪"
  stop_lima
  start_lima
}

# ============================================================
# Linux (KVM/libvirt): 批量启动全部 VM
# ============================================================
start_kvm() {
  STAGE_TOTAL=3

  stage_begin 1 "前置检查"
  command -v virsh >/dev/null 2>&1 || die "缺少 virsh，请先安装 libvirt-clients"
  stage_end 1

  stage_begin 2 "启动 VM"
  mapfile -t vms < <(virsh --connect qemu:///system list --all --name | awk 'NF { print }')
  if [[ ${#vms[@]} -eq 0 ]]; then
    log "未发现任何 libvirt VM"
    stage_end 2
    return 0
  fi
  started=0; skipped=0; failed=0
  for vm in "${vms[@]}"; do
    state="$(virsh --connect qemu:///system domstate "$vm" 2>/dev/null || true)"
    if [[ "$state" == "running" || "$state" == "运行" ]]; then
      log "$vm 已启动，跳过"
      skipped=$((skipped+1)); continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] 将执行: virsh start ${vm}（当前状态: ${state:-unknown}）"
      started=$((started+1)); continue
    fi
    log "正在启动 ${vm}（当前状态: ${state:-unknown}）"
    if virsh --connect qemu:///system start "$vm" >>"$LOG_FILE" 2>&1; then
      started=$((started+1))
    else
      err "启动 $vm 失败，详见 $LOG_FILE"
      failed=$((failed+1))
    fi
  done
  stage_end 2

  stage_begin 3 "汇总"
  log "启动完成统计: 新启动 ${started} 台，跳过 ${skipped} 台，失败 ${failed} 台"
  [[ "$failed" -eq 0 ]] || exit 1
  stage_end 3
}

# ============================================================
# Linux (KVM/libvirt): 批量停止全部 VM
# ============================================================
stop_kvm() {
  STAGE_TOTAL=3

  stage_begin 1 "前置检查"
  command -v virsh >/dev/null 2>&1 || die "缺少 virsh，请先安装 libvirt-clients"
  [[ "$FORCE" -eq 1 ]] && warn "已启用 --force 强制停止模式（virsh destroy）"
  stage_end 1

  stage_begin 2 "关闭 VM"
  mapfile -t vms < <(virsh --connect qemu:///system list --all --name | awk 'NF { print }')
  if [[ ${#vms[@]} -eq 0 ]]; then
    log "未发现任何 libvirt VM"
    stage_end 2
    return 0
  fi
  stopped=0; skipped=0; failed=0
  for vm in "${vms[@]}"; do
    state="$(virsh --connect qemu:///system domstate "$vm" 2>/dev/null || true)"
    if [[ "$state" == "running" || "$state" == "运行" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] 将执行: $([[ "$FORCE" -eq 1 ]] && echo 'virsh destroy' || echo 'virsh shutdown') $vm"
        stopped=$((stopped+1)); continue
      fi
      if [[ "$FORCE" -eq 1 ]]; then
        log "强制停止 $vm"
        if virsh --connect qemu:///system destroy "$vm" >>"$LOG_FILE" 2>&1; then
          stopped=$((stopped+1))
        else
          err "强制停止 $vm 失败，详见 $LOG_FILE"
          failed=$((failed+1))
        fi
      else
        log "正在优雅关闭 $vm"
        if virsh --connect qemu:///system shutdown "$vm" >>"$LOG_FILE" 2>&1; then
          stopped=$((stopped+1))
        else
          err "优雅关机 $vm 失败（可尝试: $0 stop --force），详见 $LOG_FILE"
          failed=$((failed+1))
        fi
      fi
    else
      log "$vm 已停止，跳过"
      skipped=$((skipped+1))
    fi
  done
  stage_end 2

  stage_begin 3 "汇总"
  log "关机完成统计: 发起关闭 ${stopped} 台，跳过 ${skipped} 台，失败 ${failed} 台"
  [[ "$failed" -eq 0 ]] || exit 1
  stage_end 3
}

# ============================================================
# Linux (KVM/libvirt): 查看全部 VM 运行状态（只读）
# ============================================================
status_kvm() {
  command -v virsh >/dev/null 2>&1 || die "缺少 virsh，请先安装 libvirt-clients"

  mapfile -t vms < <(virsh --connect qemu:///system list --all --name | awk 'NF { print }')
  if [[ ${#vms[@]} -eq 0 ]]; then
    status_msg "未发现任何 libvirt VM"
    return 0
  fi
  running=0; stopped=0
  for vm in "${vms[@]}"; do
    state="$(virsh --connect qemu:///system domstate "$vm" 2>/dev/null || true)"
    if [[ "$state" == "running" || "$state" == "运行" ]]; then
      status_msg "$vm: running（运行中）"
      running=$((running+1))
    else
      status_msg "$vm: ${state:-unknown}（已停止）"
      stopped=$((stopped+1))
    fi
  done
  status_msg "状态统计: 运行中 ${running} 台，已停止 ${stopped} 台"
}

# ============================================================
# Linux (KVM/libvirt): 批量重启全部 VM（等价于 stop + start）
# ============================================================
restart_kvm() {
  log "restart = stop + start，先优雅停止全部 VM，再批量启动"
  stop_kvm
  start_kvm
}

# ----------------------------------------------------------------------------
# 主入口：参数解析 → 日志初始化 → 子命令 + 平台分发
# ----------------------------------------------------------------------------
parse_args "$@"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/manage_vms_${ACTION}_$(date '+%Y%m%d_%H%M%S').log"

if [[ "$(uname -s)" == "Darwin" ]]; then
  case "$ACTION" in
    start)   start_lima ;;
    stop)    stop_lima ;;
    status)  status_lima ;;
    restart) restart_lima ;;
  esac
else
  case "$ACTION" in
    start)   start_kvm ;;
    stop)    stop_kvm ;;
    status)  status_kvm ;;
    restart) restart_kvm ;;
  esac
fi
