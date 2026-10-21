#!/usr/bin/env bash
# deploy_vms.sh — 使用 KVM 在本机部署多台 VM（普通机台数见 deploy_vms.env 的 WORKER_COUNT）
# 内置性能优化: q35 机型 / host-passthrough CPU / CPU 拓扑 sockets=1 / virtio 磁盘网卡 /
#               磁盘 cache=none + 独立 IO 线程 / kvmvapic.bin ROM 自动补齐（中断优化）/
#               虚机内自动创建 swapfile（大小见 MACHINE_SWAP_GB，不占宿主机内存）
# 开机自启动: 所有 VM 注册为 libvirt autostart，宿主机重启后随 libvirtd 自动拉起
#               （libvirtd 与 default 网络也在部署时一并设置 enable/autostart）
# 机器配置自动生成: 机器名/静态 IP/随机 MAC/磁盘/swap 均按 WORKER_COUNT 自动生成，
#               实际部署台数 = WORKER_COUNT + 1（额外 1 台 VIP 机）
#               CPU/内存按份均分: 共 WORKER_COUNT*2+1 份，普通机各占 2 份，VIP 机占 1 份
# 用法:
#   ./deploy_vms.sh                         # 交互式列出可装系统类型并选择后部署（非交互环境默认麒麟 V10）
#   ./deploy_vms.sh deploy                  # 同上
#   ./deploy_vms.sh deploy ubuntu           # 使用 Ubuntu 22.04 镜像部署（无交互）
#   ./deploy_vms.sh deploy kylin-v10        # 使用麒麟 V10 镜像部署（无交互）
#   ./deploy_vms.sh status                  # 查看 VM 状态
#   ./deploy_vms.sh ssh-config [ubuntu|kylin-v10]  # 给 root 和所有本地普通用户配置 VM 免密 SSH（默认自动检测已部署 VM 的用户）
#   ./deploy_vms.sh destroy                 # 销毁本脚本部署的全部 VM 及相关文件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/deploy_vms.env"
CACHE_DIR="$SCRIPT_DIR/cache"

# 平台自动分发: macOS (Darwin) 上转交 Lima 后端实现 deploy_vms_mac.sh，
# 用法/子命令/参数完全一致，Linux 上继续走本文件的 KVM/libvirt 逻辑
if [[ "$(uname -s)" == "Darwin" ]]; then
  exec bash "$SCRIPT_DIR/deploy_vms_mac.sh" "$@"
fi

[[ -f "$ENV_FILE" ]] || { echo -e "\033[31m[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]\033[0m 缺少配置文件: $ENV_FILE"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

MACHINE_IP_LIST_FILE="$BASE_DIR/machine_and_ip_list.txt"

IMAGE_TYPE=""
IMAGE_LABEL=""
IMAGE_USER=""
OS_VARIANT="generic"
IMG_NAME=""
IMG_URLS=()
BASE_IMG=""

TS() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo -e "\033[32m[$(TS)] [INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[$(TS)] [WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[$(TS)] [ERROR]\033[0m $*"; exit 1; }

# ============ 机器配置自动生成 ============
# 配置文件只指定 WORKER_COUNT（普通机台数），其余全部自动生成：
#   机器名: 从 MACHINE_NAME_START（默认 machine1，可自定义前缀如 node5）起统一编号排列，
#           最后一台为 VIP 机（共 WORKER_COUNT+1 台）
#   CPU/内存: 按 RESOURCE_RATIO（默认 2:1，普通机份额:VIP机份额）分摊宿主机资源，
#           系数之和恒为 1（正好用满不超分）
#   IP:     从 IP_START（默认 192.168.122.10）起顺序递增
#   MAC:    52:54:00 随机生成并去重；已部署过的机器从清单文件复用旧 MAC，
#           保证重复部署时 MAC 不变（destroy/ensure_dhcp_host 按 MAC 清理才准确）
#   磁盘/swap: 普通机取配置值，VIP 机按 RESOURCE_RATIO 反向缩放
#           （比例越大表示 VIP 机 CPU/内存越小，但磁盘/swap 反而越大）
generate_machine_config() {
  WORKER_COUNT="${WORKER_COUNT:-2}"
  RESOURCE_RATIO="${RESOURCE_RATIO:-2:1}"
  DISK_GB="${DISK_GB:-100}"
  MACHINE_SWAP_GB="${MACHINE_SWAP_GB:-16}"
  IP_START="${IP_START:-192.168.122.10}"
  MACHINE_NAME_START="${MACHINE_NAME_START:-machine1}"

  [[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] || die "WORKER_COUNT='$WORKER_COUNT' 必须为正整数（deploy_vms.env）"
  [[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "DISK_GB='$DISK_GB' 必须为正整数"
  [[ "$MACHINE_SWAP_GB" =~ ^[0-9]+$ ]] || die "MACHINE_SWAP_GB='$MACHINE_SWAP_GB' 必须为非负整数（0=不创建 swap）"

  # 解析资源比例（普通机份额:VIP机份额，支持小数，如 2:1、2.5:1）
  local worker_shares vip_shares
  [[ "$RESOURCE_RATIO" =~ ^([0-9]+(\.[0-9]+)?):([0-9]+(\.[0-9]+)?)$ ]] \
    || die "RESOURCE_RATIO='$RESOURCE_RATIO' 格式非法，应为如 2:1 或 2.5:1（普通机份额:VIP机份额，正数）"
  worker_shares="${BASH_REMATCH[1]}"
  vip_shares="${BASH_REMATCH[3]}"
  awk -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{exit !(w>0 && v>0)}' \
    || die "RESOURCE_RATIO='$RESOURCE_RATIO' 两项份额都必须大于 0"

  # 解析起始机器名（如 machine1 → 前缀 machine + 起始编号 1；node5 → node + 5），
  # 机器名统一按 前缀N、前缀N+1... 排列；前缀需以字母开头（合法主机名）
  local name_prefix name_start_num
  [[ "$MACHINE_NAME_START" =~ ^([A-Za-z][A-Za-z0-9_-]*?)([0-9]+)$ ]] \
    || die "MACHINE_NAME_START='$MACHINE_NAME_START' 格式非法，应为如 machine1（主机名前缀+起始编号）"
  name_prefix="${BASH_REMATCH[1]}"
  name_start_num=$(( 10#${BASH_REMATCH[2]} ))   # 10# 强制十进制，避免 01/08 被当作八进制

  # 解析 IP 起始地址（如 192.168.122.10），IP 在该网段内顺序递增
  local net_prefix start_octet
  [[ "$IP_START" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    || die "IP_START='$IP_START' 格式非法，应为如 192.168.122.10"
  net_prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  start_octet="${BASH_REMATCH[4]}"
  awk -v o="$start_octet" 'BEGIN{exit !(o>=2 && o<=250)}' \
    || die "IP_START='$IP_START' 最后一段需在 2~250 之间（0 为网络地址、1 通常是网关）"
  local gw="${NET_GW:-192.168.122.1}" gw_last="${NET_GW##*.}"
  awk -v o="$start_octet" -v g="$gw_last" 'BEGIN{exit !(o!=g)}' \
    || warn "IP_START 末段 .${start_octet} 与网关 ${gw} 末段相同，请注意是否冲突"

  MACHINE_NAMES=()
  MACHINE_IPS=()
  MACHINE_MACS=()
  MACHINE_CPU_RATIOS=()
  MACHINE_MEM_RATIOS=()
  local -a disks=()
  MACHINE_SWAP_GBS=()

  # 复用上次部署记录的 MAC（清单文件每行: 机器名 IP MAC）
  local -a saved_macs=()
  if [[ -f "$MACHINE_IP_LIST_FILE" ]]; then
    local _n _ip _mac
    while read -r _n _ip _mac || [[ -n "${_n:-}" ]]; do
      [[ "${_mac:-}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && saved_macs+=("$_mac")
    done < "$MACHINE_IP_LIST_FILE"
  fi

  # CPU/内存按份分配: 资源共 total_shares 份（=台数*普通份额+VIP份额，支持小数份额），
  # 系数之和恰为 1，正好用满宿主机资源不超分；磁盘/swap 反向缩放：
  # VIP 份额越小（CPU/内存越少），磁盘/swap 反而越大（VIP 机磁盘 = 配置值 * 普通份额/VIP份额）
  local total=$((WORKER_COUNT + 1)) i mac dup existing ratio disk swap
  local total_shares
  total_shares="$(awk -v n="$WORKER_COUNT" -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{printf "%.6f", n*w+v}')"
  for ((i = 1; i <= total; i++)); do
    if (( i <= WORKER_COUNT )); then
      MACHINE_NAMES+=("${name_prefix}$((name_start_num + i - 1))")
      ratio="$(awk -v s="$worker_shares" -v t="$total_shares" 'BEGIN{printf "%.6g", s/t}')"
      disk="$DISK_GB"
      swap="$MACHINE_SWAP_GB"
    else
      MACHINE_NAMES+=("${name_prefix}$((name_start_num + WORKER_COUNT))")
      ratio="$(awk -v s="$vip_shares" -v t="$total_shares" 'BEGIN{printf "%.6g", s/t}')"
      disk="$(awk -v d="$DISK_GB" -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{printf "%d", d*w/v}')"
      (( disk < 1 )) && disk=1
      swap="$(awk -v s="$MACHINE_SWAP_GB" -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{printf "%d", s*w/v}')"
    fi
    MACHINE_CPU_RATIOS+=("$ratio")
    MACHINE_MEM_RATIOS+=("$ratio")
    disks+=("$disk")
    MACHINE_SWAP_GBS+=("$swap")

    MACHINE_IPS+=("${net_prefix}.$((start_octet + i - 1))")

    if [[ -n "${saved_macs[$((i - 1))]:-}" ]]; then
      MACHINE_MACS+=("${saved_macs[$((i - 1))]}")
    else
      while :; do
        mac="$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))"
        dup=0
        for existing in "${MACHINE_MACS[@]}"; do
          [[ "$existing" == "$mac" ]] && dup=1 && break
        done
        (( dup == 0 )) && break
      done
      MACHINE_MACS+=("$mac")
    fi
  done

  DISK_GB=("${disks[@]}")
}

generate_machine_config
ALL_NAMES=("${MACHINE_NAMES[@]}")

select_image() {
  local choice="${1:-}"

  if [[ -z "$choice" ]]; then
    choice="kylin-v10"
  fi

  case "$choice" in
    1|ubuntu|Ubuntu|UBUNTU)
      local ubuntu_ver="jammy" ubuntu_rel="22.04"
      IMAGE_TYPE="ubuntu"
      IMAGE_LABEL="Ubuntu 22.04"
      # 默认 ubuntu，可在 deploy_vms.env 中用 UBUNTU_IMAGE_USER 覆盖（如 root）
      IMAGE_USER="${UBUNTU_IMAGE_USER:-ubuntu}"
      OS_VARIANT="ubuntu22.04"
      IMG_NAME="${ubuntu_ver}-server-cloudimg-amd64.img"   # 远端下载文件名（codename）
      IMG_URLS=(
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/${ubuntu_ver}/current/${IMG_NAME}"
        "https://cloud-images.ubuntu.com/${ubuntu_ver}/current/${IMG_NAME}"
      )
      # 本地保存名带明确版本号，见名知义
      BASE_IMG="${IMG_DIR}/ubuntu-${ubuntu_rel}-server-cloudimg-amd64.qcow2"
      ;;
    2|kylin|kylin-v10|Kylin|KYLIN)
      IMAGE_TYPE="kylin-v10"
      IMAGE_LABEL="麒麟 V10"
      IMAGE_USER="root"
      OS_VARIANT="generic"
      IMG_NAME="Kylin-Server-V10-SP3-Cloud-Image.qcow2"
      IMG_URLS=(
        "https://update.cs2c.com.cn/NS/V10/V10SP3/os/adv/lic/base/x86_64/Kylin-Server-V10-SP3-Cloud-Image.qcow2"
      )
      BASE_IMG="${IMG_DIR}/Kylin-Server-V10-SP3-2403-Release-20240426-X86_64.qcow2"
      ;;
    *)
      die "未知镜像类型: ${choice}（可选: ubuntu, kylin-v10）"
      ;;
  esac
}

ensure_deps() {
  if ! command -v virt-install >/dev/null 2>&1; then
    log "安装 KVM/libvirt 依赖..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
      cloud-image-utils genisoimage
  fi
  command -v cloud-localds >/dev/null 2>&1 || command -v genisoimage >/dev/null 2>&1 \
    || die "缺少 cloud-localds/genisoimage"
}

ensure_libvirt() {
  systemctl enable --now libvirtd >/dev/null 2>&1 || true
  virsh net-start default >/dev/null 2>&1 || true   # 已激活时忽略报错
  virsh net-autostart default >/dev/null
}

# kvmvapic.bin 是 QEMU 的 VAPIC 中断优化 ROM。
# 本机 /usr 为只读挂载且 qemu-system-data 包内不含该文件，缺失会降低虚机中断处理性能，
# 因此下载到脚本 cache 目录，创建 VM 时通过 --qemu-commandline "-L" 附加 ROM 搜索路径加载。
ensure_kvmvapic_rom() {
  QEMU_ROM_ARGS=()
  [[ -f /usr/share/qemu/kvmvapic.bin ]] && return 0   # 系统包已提供，无需处理
  mkdir -p "$CACHE_DIR"
  local rom="$CACHE_DIR/kvmvapic.bin" qver url ok=0
  # PC option ROM 头部固定为 55 aa，据此校验文件有效性
  if [[ -s "$rom" && "$(head -c2 "$rom" | od -An -tx1 | tr -d ' \n')" == "55aa" ]]; then
    ok=1
  else
    qver="$(qemu-system-x86_64 --version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+\.[0-9]+')"
    qver="${qver:-8.2.0}"
    for url in \
      "https://cdn.jsdelivr.net/gh/qemu/qemu@v${qver}/pc-bios/kvmvapic.bin" \
      "https://fastly.jsdelivr.net/gh/qemu/qemu@v${qver}/pc-bios/kvmvapic.bin" \
      "https://raw.githubusercontent.com/qemu/qemu/v${qver}/pc-bios/kvmvapic.bin"; do
      log "获取 kvmvapic.bin: $url"
      if wget -q -T 15 -O "$rom.part" "$url" \
        && [[ "$(head -c2 "$rom.part" | od -An -tx1 | tr -d ' \n')" == "55aa" ]]; then
        mv "$rom.part" "$rom"
        ok=1
        break
      fi
      rm -f "$rom.part"
      warn "下载失败或文件无效，尝试下一个源"
    done
  fi
  if [[ $ok -eq 1 ]]; then
    QEMU_ROM_ARGS=(--qemu-commandline "-L $CACHE_DIR")
    log "kvmvapic.bin 已就绪: $rom"
  else
    warn "kvmvapic.bin 获取失败，跳过（仅轻微影响中断处理性能）"
  fi
}

ensure_dhcp_host() {
  local name="$1" mac="$2" ip="$3"
  virsh net-update default delete ip-dhcp-host \
    "<host mac='$mac' name='$name' ip='$ip'/>" \
    --live --config >/dev/null 2>&1 || true
  virsh net-update default delete ip-dhcp-host \
    "<host mac='$mac'/>" \
    --live --config >/dev/null 2>&1 || true
  virsh net-update default delete ip-dhcp-host \
    "<host name='$name'/>" \
    --live --config >/dev/null 2>&1 || true
  virsh net-update default add-last ip-dhcp-host \
    "<host mac='$mac' name='$name' ip='$ip'/>" \
    --live --config >/dev/null
}

download_base_image() {
  if [[ -f "$BASE_IMG" ]]; then
    log "基础镜像已存在: $BASE_IMG"
    return
  fi

  if [[ "$IMAGE_TYPE" == "kylin-v10" && -n "$KYLIN_IMG_FILE" ]]; then
    [[ -f "$KYLIN_IMG_FILE" ]] || die "麒麟本地镜像不存在: $KYLIN_IMG_FILE"
    log "使用本地麒麟镜像: $KYLIN_IMG_FILE"
    cp "$KYLIN_IMG_FILE" "$BASE_IMG"
    return
  fi

  for url in "${IMG_URLS[@]}"; do
    log "下载基础镜像: $url"
    if wget -q --show-progress -O "$BASE_IMG.part" "$url"; then
      mv "$BASE_IMG.part" "$BASE_IMG"
      return
    fi
    rm -f "$BASE_IMG.part"
    warn "下载失败，尝试下一个源"
  done
  if [[ "$IMAGE_TYPE" == "kylin-v10" ]]; then
    die "麒麟基础镜像下载失败。请先下载 qcow2 镜像后执行: KYLIN_IMG_FILE=/path/to/kylin.qcow2 $0 deploy kylin-v10"
  fi
  die "基础镜像下载失败"
}

gen_ssh_key() {
  [[ -f "$SSH_KEY" ]] || { log "生成 SSH 密钥: $SSH_KEY"; ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY" -q; }
}

cluster_hosts_block() {
  local i
  for i in "${!MACHINE_NAMES[@]}"; do
    printf "%s %s\n" "${MACHINE_IPS[$i]}" "${MACHINE_NAMES[$i]}"
  done
}

cluster_ssh_config_block() {
  local identity_file="$1"
  local i
  for i in "${!MACHINE_NAMES[@]}"; do
    printf "Host %s %s@%s\n" "${MACHINE_NAMES[$i]}" "$IMAGE_USER" "${MACHINE_NAMES[$i]}"
    printf "  HostName %s\n" "${MACHINE_IPS[$i]}"
    printf "  User %s\n" "$IMAGE_USER"
    printf "  IdentityFile %s\n" "$identity_file"
    printf "  StrictHostKeyChecking no\n"
    printf "  UserKnownHostsFile /dev/null\n\n"
  done
}

machine1_ssh_write_files_block() {
  local name="$1" ssh_identity="$2" ssh_dir="$3"
  [[ "$name" == "${MACHINE_NAMES[0]}" ]] || return 0
  cat <<EOF
  - path: $ssh_identity
    owner: $IMAGE_USER:$IMAGE_USER
    permissions: '0600'
    content: |
$(sed 's/^/      /' "$SSH_KEY")
  - path: $ssh_identity.pub
    owner: $IMAGE_USER:$IMAGE_USER
    permissions: '0644'
    content: |
$(sed 's/^/      /' "$SSH_KEY.pub")
  - path: $ssh_dir/config
    owner: $IMAGE_USER:$IMAGE_USER
    permissions: '0600'
    content: |
$(cluster_ssh_config_block "$ssh_identity" | sed 's/^/      /')
EOF
}

machine1_ssh_runcmd_block() {
  local name="$1" ssh_identity="$2" ssh_dir="$3"
  [[ "$name" == "${MACHINE_NAMES[0]}" ]] || return 0
  cat <<EOF
  - chmod 600 $ssh_identity $ssh_dir/config
  - chmod 644 $ssh_identity.pub
EOF
}

write_cloud_init() {
  local name="$1" ip="$2" mac="$3" swap_gb="${4:-0}"
  local dir="$WORK_DIR/$name"
  local ssh_home ssh_dir ssh_identity
  mkdir -p "$dir"

  # swap>0 时在虚机内创建 /swapfile（guest 磁盘上的溢出分区，不占宿主机内存），
  # 并将 swappiness 调低到 10，仅内存压力时才使用
  local swap_runcmd=""
  if [[ "$swap_gb" =~ ^[1-9][0-9]*$ ]]; then
    swap_runcmd="  - if ! swapon --show=NAME --noheadings | grep -q '^/swapfile\$'; then fallocate -l ${swap_gb}G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile; grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi || true
  - echo 'vm.swappiness=10' > /etc/sysctl.d/99-vm-deploy-swap.conf && sysctl -w vm.swappiness=10 || true"
  fi

  if [[ "$IMAGE_USER" == "root" ]]; then
    ssh_home="/root"
  else
    ssh_home="/home/$IMAGE_USER"
  fi
  ssh_dir="$ssh_home/.ssh"
  ssh_identity="$ssh_dir/id_rsa_vm_deploy"

  cat > "$dir/user-data" <<EOF
#cloud-config
hostname: $name
timezone: Asia/Shanghai
users:
  - name: $IMAGE_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo,wheel
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
ssh_pwauth: false
write_files:
  - path: /etc/ssh/sshd_config.d/00-vm-deploy-trae.conf
    permissions: '0644'
    content: |
      AllowTcpForwarding yes
      AllowAgentForwarding yes
      PermitOpen any
      PermitListen any
  - path: /etc/hosts.vm_deploy
    permissions: '0644'
    content: |
$(cluster_hosts_block | sed 's/^/      /')
$(machine1_ssh_write_files_block "$name" "$ssh_identity" "$ssh_dir")
runcmd:
  - mkdir -p $ssh_dir
  - chown -R $IMAGE_USER:$IMAGE_USER $ssh_dir
  - chmod 700 $ssh_dir
$(machine1_ssh_runcmd_block "$name" "$ssh_identity" "$ssh_dir")
  - sed -i '/[[:space:]]machine[0-9]$/d' /etc/hosts
  - cat /etc/hosts.vm_deploy >> /etc/hosts
  - parted -s /dev/vda resizepart 2 100% || true
  - pvresize /dev/vda2 || true
  - lvextend -l +100%FREE /dev/mapper/klas-root || true
  - xfs_growfs / || true
${swap_runcmd}
  - grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  - sed -i 's/^AllowTcpForwarding[[:space:]].*/AllowTcpForwarding yes/; s/^AllowAgentForwarding[[:space:]].*/AllowAgentForwarding yes/' /etc/ssh/sshd_config
  - if [ "$IMAGE_USER" = "root" ]; then sed -i 's/^#\?PermitRootLogin[[:space:]].*/PermitRootLogin yes/' /etc/ssh/sshd_config; grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; fi
  - systemctl restart sshd || systemctl restart ssh
chpasswd:
  expire: false
EOF

  cat > "$dir/meta-data" <<EOF
instance-id: $name-001
local-hostname: $name
EOF

  cat > "$dir/network-config" <<EOF
version: 2
ethernets:
  mainnic:
    match:
      macaddress: "$mac"
    set-name: ens3
    dhcp4: false
    addresses: [$ip/24]
    routes:
      # 注意: 不能写 "to: default"，cloud-init 19.4 sysconfig 渲染器会生成
      # 非法的 route-ens3 (ADDRESS0=default)，导致 NetworkManager 拒绝加载静态配置
      - to: 0.0.0.0/0
        via: $NET_GW
    nameservers:
      addresses: [223.5.5.5, 114.114.114.114]
EOF

  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data" --network-config="$dir/network-config"
  else
    (cd "$dir" && genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data network-config >/dev/null)
  fi
}

create_vm() {
  local name="$1" cpu="$2" mem="$3" disk="$4" mac="$5" ip="$6" swap="$7"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    warn "VM $name 已存在，跳过创建（如需重建: $0 destroy）"
    # 已存在的 VM 幂等补开自启动（重复执行无副作用）
    virsh autostart "$name" >/dev/null 2>&1 || warn "VM $name 设置开机自启动失败"
    return
  fi
  log "创建 VM: $name (CPU=$cpu MEM=${mem}MB DISK=${disk}GB SWAP=${swap}GB IP=$ip)"

  ensure_dhcp_host "$name" "$mac" "$ip"
  write_cloud_init "$name" "$ip" "$mac" "$swap"

  # 基于 base 镜像创建精简置备 overlay 磁盘
  qemu-img create -f qcow2 -F qcow2 \
    -b "$BASE_IMG" "$POOL_DIR/$name.qcow2" "${disk}G" >/dev/null

  # 检测可用 os-variant（无 osinfo-query 或当前镜像变体不可用时回退 generic）
  local osv="generic"
  if [[ "$OS_VARIANT" != "generic" ]] \
    && command -v osinfo-query >/dev/null 2>&1 \
    && osinfo-query os 2>/dev/null | grep -q "^${OS_VARIANT}"; then
    osv="$OS_VARIANT"
  fi

  # 性能优化项：
  #   --machine q35                     PCIe 机型，整体延迟低于 i440fx
  #   sockets=1,cores=N                 CPU 拓扑与真实形态一致，利于 guest 调度
  #   cache=none,io=native,iothread=1   磁盘绕过宿主机页缓存并使用独立 IO 线程
  #   --iothreads 1                     为磁盘 iothread=1 声明域级 IO 线程
  #   --qemu-commandline "-L ..."       补充 ROM 搜索路径（见 ensure_kvmvapic_rom）
  # 2> >(grep -v ...) 过滤 virt-install 对 --os-variant generic 的固定性能告警：
  # osinfo-db 无麒麟条目只能用 generic，且本脚本已显式指定全部性能项
  # （q35/host-passthrough/virtio/cache=none/iothreads），generic 不会覆盖，无实际性能影响
  virt-install --connect qemu:///system \
    --name "$name" \
    --vcpus "$cpu,sockets=1,cores=$cpu,threads=1" \
    --memory "$mem" \
    --cpu host-passthrough \
    --machine q35 \
    --iothreads 1 \
    --disk path="$POOL_DIR/$name.qcow2",format=qcow2,bus=virtio,cache=none,io=native,discard=unmap,driver.iothread=1 \
    --disk path="$WORK_DIR/$name/seed.iso",device=cdrom,format=raw,bus=sata \
    --network network=default,model=virtio,mac="$mac" \
    --autostart \
    --import --noautoconsole --graphics none \
    --console pty,target_type=serial \
    --os-variant "$osv" \
    "${QEMU_ROM_ARGS[@]}" 2> >(grep -v -- '--osinfo generic' >&2)
}

wait_vm() {
  local name="$1" ip="$2" i
  log "等待 $name ($ip) 启动（首次启动约 2-4 分钟）..."
  for i in $(seq 1 120); do
    if timeout 1 bash -c "echo >/dev/tcp/$ip/22" 2>/dev/null; then
      log "$name 已就绪: ssh -i $SSH_KEY $IMAGE_USER@$ip"
      return 0
    fi
    sleep 3
  done
  warn "$name 等待超时，可稍后手动检查: virsh console $name"
}

cleanup_known_host() {
  local ip="$1" name="${2:-}"
  [[ -f /root/.ssh/known_hosts ]] && ssh-keygen -f /root/.ssh/known_hosts -R "$ip" >/dev/null 2>&1 || true
  [[ -n "$name" && -f /root/.ssh/known_hosts ]] && ssh-keygen -f /root/.ssh/known_hosts -R "$name" >/dev/null 2>&1 || true
}

add_hosts() {
  local name="$1" ip="$2"
  cleanup_known_host "$ip" "$name"
  sed -i "/[[:space:]]$name$/d" /etc/hosts
  echo "$ip  $name" >> /etc/hosts
}

write_one_ssh_config() {
  local user="$1" home="$2"
  local ssh_dir="$home/.ssh"
  local ssh_config="$ssh_dir/config"
  local identity_file="$ssh_dir/id_rsa_vm_deploy"
  local tmp i

  mkdir -p "$ssh_dir"
  if [[ "$SSH_KEY" != "$identity_file" ]]; then
    cp -f "$SSH_KEY" "$identity_file"
    [[ -f "$SSH_KEY.pub" ]] && cp -f "$SSH_KEY.pub" "$identity_file.pub"
  fi
  touch "$ssh_config"

  tmp="$(mktemp)"
  awk '
    /^# BEGIN vm_deploy( k8s)?$/ { skip=1; next }
    /^# END vm_deploy( k8s)?$/ { skip=0; next }
    /^Host machine[0-9]+/ { skip_legacy=1; next }
    /^Host / && skip_legacy { skip_legacy=0 }
    !skip && !skip_legacy { print }
  ' "$ssh_config" > "$tmp"

  {
    cat "$tmp"
    echo "# BEGIN vm_deploy"
    for i in "${!MACHINE_NAMES[@]}"; do
      printf "Host %s %s@%s\n" "${MACHINE_NAMES[$i]}" "$IMAGE_USER" "${MACHINE_NAMES[$i]}"
      printf "  HostName %s\n" "${MACHINE_IPS[$i]}"
      printf "  User %s\n" "$IMAGE_USER"
      printf "  IdentityFile %s\n" "$identity_file"
      printf "  StrictHostKeyChecking no\n"
      printf "  UserKnownHostsFile /dev/null\n\n"
    done
    echo "# END vm_deploy"
  } > "$ssh_config"

  rm -f "$tmp"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || true
  chmod 700 "$ssh_dir"
  chmod 600 "$ssh_config" "$identity_file"
  [[ -f "$identity_file.pub" ]] && chmod 644 "$identity_file.pub"
  log "SSH 免密别名已写入: $ssh_config"
}

write_ssh_config() {
  write_one_ssh_config root /root

  while IFS=: read -r user _ uid _ _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    [[ "$uid" -ge 1000 ]] || continue
    [[ -d "$home" ]] || continue
    [[ "$shell" != */nologin && "$shell" != */false ]] || continue
    write_one_ssh_config "$user" "$home"
  done < /etc/passwd
}

write_machine_ip_list() {
  local i
  {
    for i in "${!MACHINE_NAMES[@]}"; do
      printf "%-16s %-16s %s\n" "${MACHINE_NAMES[$i]}" "${MACHINE_IPS[$i]}" "${MACHINE_MACS[$i]}"
    done
  } > "$MACHINE_IP_LIST_FILE"

  log "机器/IP/MAC 清单已保存: $MACHINE_IP_LIST_FILE"
}

choose_image_interactive() {
  local input
  echo "可安装的系统类型:"
  echo "  1) kylin-v10   麒麟 V10 SP3"
  echo "  2) ubuntu      Ubuntu 22.04"
  while true; do
    read -r -p "请选择系统类型 [序号/名称, 回车=1 kylin-v10]: " input
    input="${input:-1}"
    case "$input" in
      1|kylin|kylin-v10|Kylin|KYLIN) SELECTED_IMAGE="kylin-v10"; return 0 ;;
      2|ubuntu|Ubuntu|UBUNTU)        SELECTED_IMAGE="ubuntu";    return 0 ;;
      *) warn "无效输入: ${input}，请输入 1/2 或 kylin-v10/ubuntu" ;;
    esac
  done
}

# 将 0~1 的资源系数换算为绝对值：vCPU = 宿主机总vCPU数*系数，内存MB = 宿主机总内存MB*系数
# 结果写入全局数组 VM_CPU / VM_MEM_MBS，供 create_vm 使用
resolve_vm_specs() {
  local host_cpu host_mem_mb i r sum_cpu sum_mem
  host_cpu="$(nproc)"
  host_mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)"

  # 校验系数格式与范围（必须为 0~1 之间的小数）
  for i in "${!MACHINE_CPU_RATIOS[@]}"; do
    r="${MACHINE_CPU_RATIOS[$i]}"
    [[ "$r" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "MACHINE_CPU_RATIOS[$i]='${r}' 不是合法数字，必须为 0~1 之间的小数"
    awk -v r="$r" 'BEGIN{exit !(r>0 && r<=1)}' || die "MACHINE_CPU_RATIOS[$i]='${r}' 必须在 0~1 之间"
  done
  for i in "${!MACHINE_MEM_RATIOS[@]}"; do
    r="${MACHINE_MEM_RATIOS[$i]}"
    [[ "$r" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "MACHINE_MEM_RATIOS[$i]='${r}' 不是合法数字，必须为 0~1 之间的小数"
    awk -v r="$r" 'BEGIN{exit !(r>0 && r<=1)}' || die "MACHINE_MEM_RATIOS[$i]='${r}' 必须在 0~1 之间"
  done

  # 按系数换算（四舍五入取整），vCPU 最少 1 核、内存最少 512MB
  VM_CPU=()
  VM_MEM_MBS=()
  for r in "${MACHINE_CPU_RATIOS[@]}"; do
    VM_CPU+=("$(awk -v t="$host_cpu" -v r="$r" 'BEGIN{v=int(t*r+0.5); if(v<1)v=1; print v}')")
  done
  for r in "${MACHINE_MEM_RATIOS[@]}"; do
    VM_MEM_MBS+=("$(awk -v t="$host_mem_mb" -v r="$r" 'BEGIN{v=int(t*r+0.5); if(v<512)v=512; print v}')")
  done

  # 系数之和 > 1 表示超分，仅告警不终止（KVM 支持超分但性能受影响）
  sum_cpu="$(printf '%s\n' "${MACHINE_CPU_RATIOS[@]}" | awk '{s+=$1} END{printf "%.4f", s}')"
  sum_mem="$(printf '%s\n' "${MACHINE_MEM_RATIOS[@]}" | awk '{s+=$1} END{printf "%.4f", s}')"
  awk -v s="$sum_cpu" 'BEGIN{exit !(s>1)}' && warn "CPU 系数之和为 ${sum_cpu}（>1），VM 总 vCPU 超过宿主机 ${host_cpu} 核，存在超分"
  awk -v s="$sum_mem" 'BEGIN{exit !(s>1)}' && warn "内存系数之和为 ${sum_mem}（>1），VM 总内存超过宿主机 ${host_mem_mb}MB，可能触发 OOM"

  log "宿主机资源: ${host_cpu} vCPU / ${host_mem_mb}MB 内存"
  for i in "${!MACHINE_NAMES[@]}"; do
    log "VM ${MACHINE_NAMES[$i]} 规格: CPU 系数 ${MACHINE_CPU_RATIOS[$i]} -> ${VM_CPU[$i]} vCPU；内存系数 ${MACHINE_MEM_RATIOS[$i]} -> ${VM_MEM_MBS[$i]}MB"
  done
}

deploy() {
  local image_choice="${1:-}"
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"

  # KVM 不可用（BIOS 未开启 VT-x 或本机为未开嵌套虚拟化的虚拟机）时终止
  if [[ ! -c /dev/kvm ]]; then
    die "未检测到 /dev/kvm，KVM 硬件虚拟化不可用。纯软件模拟性能极差（慢 10 倍以上），已终止部署。请先在 BIOS 开启 VT-x（Intel Virtualization Technology）后重试"
  fi

  # 未指定镜像类型时交互式选择；非交互环境（stdin 非 TTY）回退默认麒麟 V10
  if [[ -z "$image_choice" ]]; then
    if [[ -t 0 ]]; then
      SELECTED_IMAGE=""
      choose_image_interactive
      image_choice="$SELECTED_IMAGE"
    else
      log "非交互环境，使用默认镜像: 麒麟 V10"
      image_choice="kylin-v10"
    fi
  fi

  select_image "$image_choice"
  log "部署镜像: $IMAGE_LABEL"
  ensure_deps
  ensure_libvirt
  ensure_kvmvapic_rom
  gen_ssh_key
  mkdir -p "$IMG_DIR" "$POOL_DIR" "$WORK_DIR" "$CACHE_DIR"
  download_base_image

  log "部署规划: 普通机 ${WORKER_COUNT} 台 + VIP 机 1 台 = 共 ${#MACHINE_NAMES[@]} 台（机器名/IP/MAC/资源均已自动生成）"

  # 将 0~1 的 CPU/内存系数换算为实际 vCPU 数和内存 MB
  resolve_vm_specs

  # 创建 VM 前先落盘机器/IP/MAC 清单，重复部署或 destroy 时可复用同一批 MAC
  write_machine_ip_list

  local i
  for i in "${!MACHINE_NAMES[@]}"; do
    create_vm "${MACHINE_NAMES[$i]}" "${VM_CPU[$i]}" "${VM_MEM_MBS[$i]}" "${DISK_GB[$i]}" "${MACHINE_MACS[$i]}" "${MACHINE_IPS[$i]}" "${MACHINE_SWAP_GBS[$i]}"
  done

  for i in "${!MACHINE_NAMES[@]}"; do
    wait_vm "${MACHINE_NAMES[$i]}" "${MACHINE_IPS[$i]}"
  done

  for i in "${!MACHINE_NAMES[@]}"; do
    add_hosts "${MACHINE_NAMES[$i]}" "${MACHINE_IPS[$i]}"
  done

  echo
  log "=========== 部署完成 ==========="
  printf "%-16s %-16s %s\n" "VM" "IP" "SSH"
  for i in "${!MACHINE_NAMES[@]}"; do
    printf "%-16s %-16s %s\n" "${MACHINE_NAMES[$i]}" "${MACHINE_IPS[$i]}" "ssh -i $SSH_KEY $IMAGE_USER@${MACHINE_IPS[$i]}"
  done
  write_ssh_config
  echo "================================"
}

status() {
  for name in "${ALL_NAMES[@]}"; do
    if virsh dominfo "$name" >/dev/null 2>&1; then
      local state
      state="$(virsh domstate "$name")"
      printf "%-16s %s\n" "$name" "$state"
    else
      printf "%-16s 未部署\n" "$name"
    fi
  done
}

# 从已生成的 cloud-init user-data 中检测部署时使用的 VM 用户（root/ubuntu）
detect_image_user() {
  local f u
  for f in "$WORK_DIR"/*/user-data; do
    [[ -f "$f" ]] || continue
    u="$(awk '/^users:/{in_users=1; next} in_users && /^[[:space:]]*-[[:space:]]*name:/ { sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, ""); print; exit }' "$f")"
    if [[ -n "$u" ]]; then
      IMAGE_USER="$u"
      return 0
    fi
  done
  return 1
}

configure_ssh_only() {
  local choice="${1:-}"
  if [[ -n "$choice" ]]; then
    select_image "$choice"
  elif detect_image_user; then
    log "从 cloud-init 配置检测到 VM 用户: $IMAGE_USER"
  else
    log "未检测到已部署 VM 的用户信息，按默认用户 root（麒麟 V10）处理"
    IMAGE_USER="root"
  fi
  gen_ssh_key
  write_ssh_config
}

destroy() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"
  command -v virsh >/dev/null 2>&1 || die "缺少 virsh，请先安装 libvirt-clients"

  local shutdown_timeout="${VM_DESTROY_SHUTDOWN_TIMEOUT:-0}"
  [[ "$shutdown_timeout" =~ ^[0-9]+$ ]] || die "VM_DESTROY_SHUTDOWN_TIMEOUT 必须是非负整数秒"

  local -a domains=()
  local name state elapsed active_count i

  # 仅清理本脚本部署的 VM（deploy_vms.env 中 MACHINE_NAMES），不触碰宿主机上其他 libvirt VM
  for name in "${MACHINE_NAMES[@]}"; do
    if virsh --connect qemu:///system dominfo "$name" >/dev/null 2>&1; then
      domains+=("$name")
    fi
  done
  if [[ "${#domains[@]}" -eq 0 ]]; then
    log "未发现本脚本部署的 VM（${MACHINE_NAMES[*]}），无需清理。"
    return 0
  fi

  echo
  warn "危险操作：即将停止并删除 ${#domains[@]} 台本脚本部署的 VM。"
  warn "将删除的 VM: ${domains[*]}"
  warn "要点：删除前注意保存重要数据！！！"
  warn "该操作会取消定义 VM，并尝试删除其 libvirt 关联存储，执行后不可恢复。"
  read -r -p "确认继续请输入 yes: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "已取消 destroy 操作，未做任何更改。"
    return 0
  fi
  echo

  log "准备停止并删除 ${#domains[@]} 台 libvirt VM: ${domains[*]}"

  # 先对正在运行的 VM 发起优雅关机；非 running 状态后续直接进入强制停止/undefine 阶段。
  for name in "${domains[@]}"; do
    state="$(virsh --connect qemu:///system domstate "$name" 2>/dev/null || true)"
    if [[ "$state" == "running" ]]; then
      log "优雅关闭 VM: $name"
      virsh --connect qemu:///system shutdown "$name" >/dev/null 2>&1 || warn "VM $name 优雅关机命令失败，将在等待后尝试强制停止"
    fi
  done

  # 等待一小段时间，让支持 ACPI 的客户机有机会正常退出。
  elapsed=0
  while (( elapsed < shutdown_timeout )); do
    active_count=0
    for name in "${domains[@]}"; do
      state="$(virsh --connect qemu:///system domstate "$name" 2>/dev/null || true)"
      [[ -z "$state" || "$state" == "shut off" ]] || active_count=$((active_count + 1))
    done
    (( active_count == 0 )) && break
    sleep 2
    (( elapsed += 2 ))
  done

  for name in "${domains[@]}"; do
    if ! virsh --connect qemu:///system dominfo "$name" >/dev/null 2>&1; then
      continue
    fi

    state="$(virsh --connect qemu:///system domstate "$name" 2>/dev/null || true)"
    if [[ -n "$state" && "$state" != "shut off" ]]; then
      warn "VM $name 仍处于 $state 状态，执行强制停止"
      virsh --connect qemu:///system destroy "$name" >/dev/null 2>&1 || true
    fi

    log "取消定义 VM 并删除其 libvirt 关联存储: $name"
    if ! virsh --connect qemu:///system undefine "$name" --remove-all-storage >/dev/null 2>&1; then
      warn "当前 virsh/libvirt 不支持或无法执行 --remove-all-storage，降级为仅 undefine: $name"
      virsh --connect qemu:///system undefine "$name" >/dev/null 2>&1 || true
    fi
  done

  for i in "${!MACHINE_NAMES[@]}"; do
    cleanup_known_host "${MACHINE_IPS[$i]}" "${MACHINE_NAMES[$i]}"
    virsh net-update default delete ip-dhcp-host \
      "<host mac='${MACHINE_MACS[$i]}' name='${MACHINE_NAMES[$i]}' ip='${MACHINE_IPS[$i]}'/>" \
      --live --config >/dev/null 2>&1 || true
    virsh net-update default delete ip-dhcp-host \
      "<host mac='${MACHINE_MACS[$i]}'/>" \
      --live --config >/dev/null 2>&1 || true
    virsh net-update default delete ip-dhcp-host \
      "<host name='${MACHINE_NAMES[$i]}'/>" \
      --live --config >/dev/null 2>&1 || true
  done

  log "清理完成。仅处理本脚本部署的 VM（${MACHINE_NAMES[*]}）；未扫描或删除其他 libvirt 资源。"
}

case "${1:-deploy}" in
  deploy) deploy "${2:-}" ;;
  status) status ;;
  ssh-config) configure_ssh_only "${2:-}" ;;
  destroy) destroy ;;
  ubuntu|kylin|kylin-v10) deploy "$1" ;;
  *) die "用法: $0 [deploy [ubuntu|kylin-v10]|ubuntu|kylin-v10|status|ssh-config [ubuntu|kylin-v10]|destroy]" ;;
esac
