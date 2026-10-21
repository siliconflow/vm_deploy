#!/usr/bin/env bash
# deploy_vms.sh — 本机批量部署 Linux VM（自动适配平台: Linux 走 KVM/libvirt，macOS 走 Lima）
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
# macOS 说明:
#   macOS (Darwin) 上自动走 Lima 实现（本文件内置，原 deploy_vms_mac.sh 已集成），
#   子命令用法与 Linux 一致；额外支持 --dry-run 预览 / --clean 清洁执行 / --yes 免确认，
#   执行 ./deploy_vms.sh --help 查看 Lima 专属说明
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/deploy_vms.env"
CACHE_DIR="$SCRIPT_DIR/cache"

# 平台自动分发: macOS (Darwin) 走本文件内的 Lima 实现（原 deploy_vms_mac.sh 已集成），
# Linux 走本文件的 KVM/libvirt 实现，用法/子命令完全一致

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
  # 拆分起始机器名: 前缀为字母开头的字母/数字/下划线/连字符，末尾为纯数字编号
  # （不用惰性量词正则——macOS 自带 bash 3.2 不支持 *?）
  name_start_num="$(printf '%s' "$MACHINE_NAME_START" | sed -E 's/^([A-Za-z][A-Za-z0-9_-]*)([0-9]+)$/\2/')" \
    || true
  name_prefix="${MACHINE_NAME_START%"$name_start_num"}"
  [[ -n "$name_start_num" && "$name_prefix" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
    || die "MACHINE_NAME_START='$MACHINE_NAME_START' 格式非法，应为如 machine1（主机名前缀+起始编号）"
  name_start_num=$(( 10#$name_start_num ))   # 10# 强制十进制，避免 01/08 被当作八进制

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

# 机器配置生成在 kvm_main 内调用（避免 macOS 上覆盖 Lima 所需的同名数组）

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

# ----------------------------------------------------------------------------
# KVM 子命令入口（仅 Linux 调用）
# ----------------------------------------------------------------------------
kvm_main() {
  generate_machine_config
  ALL_NAMES=("${MACHINE_NAMES[@]}")
  case "${1:-deploy}" in
    deploy) deploy "${2:-}" ;;
    status) status ;;
    ssh-config) configure_ssh_only "${2:-}" ;;
    destroy) destroy ;;
    ubuntu|kylin|kylin-v10) deploy "$1" ;;
    *) die "用法: $0 [deploy [ubuntu|kylin-v10]|ubuntu|kylin-v10|status|ssh-config [ubuntu|kylin-v10]|destroy]" ;;
  esac
}

# ============================================================================
# macOS (Lima) 后端实现（原 deploy_vms_mac.sh 已集成于此，仅 Darwin 平台调用）
# ============================================================================
# ----------------------------------------------------------------------------
# 路径初始化（全部基于脚本所在目录，不依赖调用者 cwd）
# ----------------------------------------------------------------------------
LOG_DIR="$SCRIPT_DIR/logs"
OUTPUT_DIR="$SCRIPT_DIR/output"
STATE_DIR="$SCRIPT_DIR/state"
# Lima 基础镜像缓存目录（相对脚本目录的上级仓库根，与 Linux KVM 共用同一存放位置）
LIMA_IMG_DIR="$BASE_DIR/qcow2s"
LOG_FILE="$LOG_DIR/deploy_vms_mac_$(date '+%Y%m%d_%H%M%S').log"

DRY_RUN=0
CLEAN=0
CONFIRM_YES=0

# ----------------------------------------------------------------------------
# 日志（带时间戳、级别、阶段进度 [当前阶段-总阶段]）
# ----------------------------------------------------------------------------
STAGE_NO=0
STAGE_TOTAL=6

log_msg() { # $1=级别 $2=内容
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$1] [${STAGE_NO}-${STAGE_TOTAL}] $2"
  echo -e "$line"
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}
lima_log()  { log_msg "INFO" "$*"; }
lima_warn() { log_msg "WARN" "$*"; }
err()  { log_msg "ERROR" "$*"; }
lima_die()  { err "$*"; exit 1; }

stage_begin() { STAGE_NO="$1"; lima_log "========== 阶段 $1/$STAGE_TOTAL: $2 =========="; }
stage_end()   { lima_log "---------- 阶段 $1/$STAGE_TOTAL 完成 ----------"; }

# ----------------------------------------------------------------------------
# 配置加载
# ----------------------------------------------------------------------------
load_config() {
  [[ -f "$ENV_FILE" ]] || lima_die "缺少配置文件: $ENV_FILE"
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  VM_TYPE="${VM_TYPE:-vz}"
  TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
  # SSH 登录用户：默认 root（部署后自动为 root 配置密钥免密）
  SSH_USER="${SSH_USER:-root}"
  # 麒麟本地镜像路径在 macOS 配置段使用 MAC_KYLIN_IMG_FILE 命名（Linux 段同名变量指向 Linux 路径）
  KYLIN_IMG_FILE="${MAC_KYLIN_IMG_FILE:-}"
  MACHINE_MD_FILE="$SCRIPT_DIR/虚拟机配置信息.md"

  # 与 Linux (KVM) 相同的配置模型: WORKER_COUNT + RESOURCE_RATIO 自动生成机器配置
  lima_generate_machine_config
}

# ============ 机器配置自动生成（与 Linux KVM 的 generate_machine_config 对齐） ============
# 配置文件只指定 WORKER_COUNT / RESOURCE_RATIO / DISK_GB / MACHINE_NAME_START / BASE_SSH_PORT，
# 其余全部自动生成:
#   机器名: 从 MACHINE_NAME_START 起统一编号排列，最后一台为 VIP 机（共 WORKER_COUNT+1 台）
#   CPU/内存: 按 RESOURCE_RATIO（普通机份额:VIP机份额）分摊宿主机资源，系数之和恒为 1
#   磁盘: 普通机取 DISK_GB，VIP 机按比例反向缩放（VIP 磁盘 = DISK_GB × 普通份额/VIP份额）
#   SSH 端口: 从 BASE_SSH_PORT（默认 60001）起每台递增 1
#   （无静态 IP/DHCP/MAC/swap 概念——Lima NAT 网络由 Lima 自动管理）
lima_generate_machine_config() {
  WORKER_COUNT="${WORKER_COUNT:-2}"
  RESOURCE_RATIO="${RESOURCE_RATIO:-2:1}"
  DISK_GB="${DISK_GB:-100}"
  MACHINE_NAME_START="${MACHINE_NAME_START:-machine1}"
  BASE_SSH_PORT="${BASE_SSH_PORT:-60001}"

  [[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] || lima_die "WORKER_COUNT='$WORKER_COUNT' 必须为正整数（deploy_vms.env）"
  [[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]] || lima_die "DISK_GB='$DISK_GB' 必须为正整数"
  [[ "$BASE_SSH_PORT" =~ ^[0-9]+$ ]] || lima_die "BASE_SSH_PORT='$BASE_SSH_PORT' 必须为正整数"

  # 解析资源比例（普通机份额:VIP机份额，支持小数，如 2:1、2.5:1）
  local worker_shares vip_shares
  [[ "$RESOURCE_RATIO" =~ ^([0-9]+(\.[0-9]+)?):([0-9]+(\.[0-9]+)?)$ ]] \
    || lima_die "RESOURCE_RATIO='$RESOURCE_RATIO' 格式非法，应为如 2:1 或 2.5:1（普通机份额:VIP机份额，正数）"
  worker_shares="${BASH_REMATCH[1]}"
  vip_shares="${BASH_REMATCH[3]}"
  awk -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{exit !(w>0 && v>0)}' \
    || lima_die "RESOURCE_RATIO='$RESOURCE_RATIO' 两项份额都必须大于 0"

  # 解析起始机器名（如 machine1 → 前缀 machine + 起始编号 1）
  # （不用惰性量词正则——macOS 自带 bash 3.2 不支持 *?）
  local name_prefix name_start_num
  name_start_num="$(printf '%s' "$MACHINE_NAME_START" | sed -E 's/^([A-Za-z][A-Za-z0-9_-]*)([0-9]+)$/\2/')" \
    || true
  name_prefix="${MACHINE_NAME_START%"$name_start_num"}"
  [[ -n "$name_start_num" && "$name_prefix" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
    || lima_die "MACHINE_NAME_START='$MACHINE_NAME_START' 格式非法，应为如 machine1（主机名前缀+起始编号）"
  name_start_num=$(( 10#$name_start_num ))   # 10# 强制十进制，避免 01/08 被当作八进制

  MACHINE_NAMES=()
  MACHINE_CPU=()
  MACHINE_MEM_GBS=()
  local -a disks=()
  MACHINE_SSH_PORTS=()

  # 宿主机资源总量: CPU 系数换算为整数 vCPU，内存系数换算为整数 GiB
  # （Lima vz 引擎要求 cpus 为整数；小数 GiB 内存换算成 MB 后不是 1MiB 整数倍会被拒绝）
  local host_cpu host_mem_gb
  host_cpu="$(sysctl -n hw.ncpu)"
  host_mem_gb="$(awk -v k="$(sysctl -n hw.memsize)" 'BEGIN{printf "%d", k/1024/1024/1024}')"

  # CPU/内存按份分配（系数之和恒为 1，正好用满宿主机资源不超分）；
  # 磁盘反向缩放: VIP 磁盘 = DISK_GB × 普通份额/VIP份额
  local total=$((WORKER_COUNT + 1)) i ratio cpu_v mem_v disk
  local total_shares
  total_shares="$(awk -v n="$WORKER_COUNT" -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{printf "%.6f", n*w+v}')"
  for ((i = 1; i <= total; i++)); do
    MACHINE_NAMES+=("${name_prefix}$((name_start_num + i - 1))")
    MACHINE_SSH_PORTS+=("$((BASE_SSH_PORT + i - 1))")
    if (( i <= WORKER_COUNT )); then
      ratio="$(awk -v s="$worker_shares" -v t="$total_shares" 'BEGIN{printf "%.6g", s/t}')"
      disk="$DISK_GB"
    else
      ratio="$(awk -v s="$vip_shares" -v t="$total_shares" 'BEGIN{printf "%.6g", s/t}')"
      disk="$(awk -v d="$DISK_GB" -v w="$worker_shares" -v v="$vip_shares" 'BEGIN{printf "%d", d*w/v}')"
      (( disk < 1 )) && disk=1
    fi
    # 系数 → 绝对值（四舍五入），vCPU 最少 1 核、内存最少 1GiB
    cpu_v="$(awk -v t="$host_cpu" -v r="$ratio" 'BEGIN{v=int(t*r+0.5); if(v<1)v=1; print v}')"
    mem_v="$(awk -v t="$host_mem_gb" -v r="$ratio" 'BEGIN{v=int(t*r+0.5); if(v<1)v=1; print v}')"
    MACHINE_CPU+=("$cpu_v")
    MACHINE_MEM_GBS+=("$mem_v")
    disks+=("$disk")
  done
  MAC_DISK_GB=("${disks[@]}")
  DISK_GB=("${disks[@]}")
}

check_config() {
  local n="${#MACHINE_NAMES[@]}"
  if [[ "$n" -eq 0 ]]; then
    lima_die "配置错误: MACHINE_NAMES 为空，请检查 $ENV_FILE"
  fi
}

# ----------------------------------------------------------------------------
# 参数解析与帮助
# ----------------------------------------------------------------------------
usage() {
  cat <<'EOF'
deploy_vms.sh (macOS/Lima) — 基于 Lima 批量部署 Linux 虚拟机

用法:
  ./deploy_vms.sh                          # 交互式选择镜像后部署（默认麒麟 V10）
  ./deploy_vms.sh deploy kylin-v10         # 使用麒麟 V10 镜像部署
  ./deploy_vms.sh deploy ubuntu            # 使用 Ubuntu 22.04 镜像部署
  ./deploy_vms.sh status                   # 查看 VM 状态
  ./deploy_vms.sh ssh-config               # 仅配置本机 SSH 免密别名
  ./deploy_vms.sh destroy                  # 销毁配置中定义的全部 VM（有确认）

子命令:
  deploy [kylin-v10|ubuntu]   部署全部 VM（不指定镜像时交互式选择，非终端默认 kylin-v10）
  status                      查看 VM 状态
  ssh-config                  给本机用户配置 VM 免密 SSH 别名
  destroy                     销毁 deploy_vms.env 中定义的全部 VM

全局选项:
  -h, --help                  显示本帮助
  --dry-run                   预览模式：只打印将执行的危险操作，不实际执行
  --clean                     清洁执行：部署前先删除已有 VM 与状态文件
  --yes                       destroy 免确认（配合自动化）

依赖:
  limactl (brew install lima)、qemu-img（brew install qemu）、macOS 13+

日志/产物:
  logs/      执行日志（deploy_vms_mac_*.log）
  output/    生成的 Lima YAML 模板
  ../qcow2s/ 基础镜像缓存（仓库根目录，相对脚本位置）
  state/     断点续跑状态文件

风险提示:
  destroy / --clean 会强制停止并删除 VM 及其磁盘数据，不可恢复。
EOF
}

parse_args() {
  ACTION="deploy"
  IMAGE_CHOICE="kylin-v10"
  IMAGE_SPECIFIED=0
  local arg
  # 允许全局选项与子命令以任意顺序出现
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY_RUN=1 ;;
      --clean)   CLEAN=1 ;;
      --yes)     CONFIRM_YES=1 ;;
      deploy)    ACTION="deploy" ;;
      status)    ACTION="status" ;;
      ssh-config) ACTION="ssh-config" ;;
      destroy)   ACTION="destroy" ;;
      ubuntu|Ubuntu|UBUNTU) ACTION="deploy"; IMAGE_CHOICE="ubuntu"; IMAGE_SPECIFIED=1 ;;
      kylin|kylin-v10|Kylin|KYLIN) ACTION="deploy"; IMAGE_CHOICE="kylin-v10"; IMAGE_SPECIFIED=1 ;;
      *)         err "未知参数: $arg"; usage; exit 1 ;;
    esac
  done
}

# ----------------------------------------------------------------------------
# 前置检查：依赖、架构、端口占用、目录可写
# ----------------------------------------------------------------------------
lima_ensure_deps() {
  command -v limactl >/dev/null 2>&1 || lima_die "缺少 limactl，请先执行: brew install lima"
  command -v qemu-img >/dev/null 2>&1 || lima_warn "缺少 qemu-img（vz 引擎转换 qcow2 镜像时需要），如创建 VM 报错请执行: brew install qemu"
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || lima_warn "缺少 curl/wget，在线下载镜像将失败"
  [[ "$(uname -s)" == "Darwin" ]] || lima_die "本脚本仅适用于 macOS"
  [[ "$(uname -m)" == "arm64" ]] || lima_warn "当前架构非 arm64，请确认镜像为对应架构"
}

check_ports_free() {
  local i port
  for i in "${!MACHINE_NAMES[@]}"; do
    port="${MACHINE_SSH_PORTS[$i]}"
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      lima_warn "端口 $port 已被占用（VM ${MACHINE_NAMES[$i]} 创建后可能无法 SSH）"
    fi
  done
}

ensure_dirs() {
  local d
  for d in "$LOG_DIR" "$OUTPUT_DIR" "$LIMA_IMG_DIR" "$STATE_DIR"; do
    mkdir -p "$d" 2>/dev/null || lima_die "目录不可创建: $d"
    [[ -w "$d" ]] || lima_die "目录不可写: $d"
  done
}

# ----------------------------------------------------------------------------
# 镜像选择与准备（幂等：缓存中已存在则跳过）
# ----------------------------------------------------------------------------
IMAGE_USER=""
BASE_IMG=""
IMAGE_SPECIFIED=0

lima_select_image() {
  # 未通过命令行参数指定镜像时，在终端交互式选择；非终端环境使用默认 kylin-v10
  if [[ "$IMAGE_SPECIFIED" -ne 1 ]]; then
    if [[ -t 0 ]]; then
      echo "请选择部署镜像:"
      echo "  1) 麒麟 V10 (arm64) [默认]"
      echo "  2) Ubuntu 22.04 (arm64)"
      local choice=""
      read -r -p "请输入 [1/2]（回车默认 1）: " choice </dev/tty || choice=""
      case "$choice" in
        2) IMAGE_CHOICE="ubuntu" ;;
        *) IMAGE_CHOICE="kylin-v10" ;;
      esac
    else
      lima_log "未指定镜像参数且非交互终端，使用默认镜像: kylin-v10"
    fi
  fi
  case "$IMAGE_CHOICE" in
    ubuntu|Ubuntu|UBUNTU|1)
      IMAGE_CHOICE="ubuntu"
      IMAGE_USER="ubuntu"
      BASE_IMG="$LIMA_IMG_DIR/ubuntu-22.04-arm64-base.qcow2"
      lima_log "部署镜像: Ubuntu 22.04 (arm64)"
      ;;
    kylin|kylin-v10|Kylin|KYLIN|2)
      IMAGE_CHOICE="kylin-v10"
      IMAGE_USER="kylin"
      BASE_IMG="$LIMA_IMG_DIR/kylin-v10-arm64-base.qcow2"
      lima_log "部署镜像: 麒麟 V10 (arm64)"
      ;;
    *)
      lima_die "未知镜像类型: ${IMAGE_CHOICE}（可选: ubuntu, kylin-v10）"
      ;;
  esac
}

download_file() { # $1=url $2=目标文件
  local url="$1" dst="$2"
  lima_log "下载: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 -o "$dst.part" "$url" && mv -f "$dst.part" "$dst"
  else
    wget -q -O "$dst.part" "$url" && mv -f "$dst.part" "$dst"
  fi
}

prepare_base_image() {
  if [[ -f "$BASE_IMG" ]]; then
    lima_log "基础镜像已存在，跳过: $BASE_IMG"
    return 0
  fi

  if [[ "$IMAGE_CHOICE" == "kylin-v10" ]]; then
    if [[ -n "${KYLIN_IMG_FILE:-}" && -f "$KYLIN_IMG_FILE" ]]; then
      lima_log "使用本地麒麟镜像: $KYLIN_IMG_FILE"
      cp "$KYLIN_IMG_FILE" "$BASE_IMG"
      return 0
    fi
    if [[ -n "${KYLIN_IMG_URL:-}" ]]; then
      download_file "$KYLIN_IMG_URL" "$BASE_IMG" && return 0
      lima_warn "麒麟镜像下载失败: $KYLIN_IMG_URL"
    fi
    lima_die "未找到麒麟 arm64 镜像。请在 $ENV_FILE 中将 KYLIN_IMG_FILE 指向本地 aarch64 qcow2 云镜像，或配置 KYLIN_IMG_URL 后重试"
  fi

  # ubuntu 22.04 arm64
  local img_name="jammy-server-cloudimg-arm64.img"
  download_file "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/jammy/current/$img_name" "$BASE_IMG" \
    || download_file "https://cloud-images.ubuntu.com/jammy/current/$img_name" "$BASE_IMG" \
    || lima_die "Ubuntu 基础镜像下载失败"
}

# ----------------------------------------------------------------------------
# 生成 Lima YAML 模板
# ----------------------------------------------------------------------------
gen_vm_yaml() { # $1=vm名 $2=cpu $3=memGiB $4=diskGiB $5=sshPort
  local name="$1" cpu="$2" mem="$3" disk="$4" port="$5"
  local yaml="$OUTPUT_DIR/$name.yaml"
  cat > "$yaml" <<EOF
# 由 deploy_vms.sh 生成，勿手工修改
vmType: $VM_TYPE
os: Linux
arch: aarch64
images:
  - location: "file://$BASE_IMG"
    arch: "aarch64"
cpus: $cpu
memory: "${mem}GiB"
disk: "${disk}GiB"
timezone: $TIMEZONE
ssh:
  localPort: $port
mounts: []
containerd:
  system: false
  user: false
user:
  name: $IMAGE_USER
  comment: vm-deploy user
  home: /home/$IMAGE_USER
  shell: /bin/bash
  passwordlessSudo: true
EOF
  echo "$yaml"
}

# ----------------------------------------------------------------------------
# VM 状态查询（返回状态字符串，未创建返回空）
# ----------------------------------------------------------------------------
vm_state() { # $1=vm名
  limactl list --format '{{ .Status }}' "$1" 2>/dev/null || true
}

vm_exists() {
  [[ -n "$(vm_state "$1")" ]]
}

mark_state() { # $1=vm名 $2=标记(created/configured)
  echo "$2" > "$STATE_DIR/$1.$2.state"
}

# 记录/读取部署时选定的镜像用户与 SSH 登录用户（供 ssh-config 等 after 阶段使用，避免二次选择出错）
save_image_user() {
  echo "$IMAGE_USER" > "$STATE_DIR/image_user.state"
  echo "$SSH_USER" > "$STATE_DIR/ssh_user.state"
}

load_image_user() {
  if [[ -f "$STATE_DIR/image_user.state" ]]; then
    IMAGE_USER="$(cat "$STATE_DIR/image_user.state")"
    IMAGE_CHOICE="from-state"
    if [[ -f "$STATE_DIR/ssh_user.state" ]]; then
      SSH_USER="$(cat "$STATE_DIR/ssh_user.state")"
    fi
    lima_log "使用部署时记录的镜像用户: ${IMAGE_USER}，SSH 登录用户: ${SSH_USER}（状态文件: $STATE_DIR/image_user.state）"
    return 0
  fi
  return 1
}

# ----------------------------------------------------------------------------
# 创建 VM（幂等：已存在跳过）
# ----------------------------------------------------------------------------
create_vms() {
  local i name cpu mem disk port yaml
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"; cpu="${MACHINE_CPU[$i]}"; mem="${MACHINE_MEM_GBS[$i]}"
    disk="${DISK_GB[$i]}"; port="${MACHINE_SSH_PORTS[$i]}"

    if vm_exists "$name"; then
      lima_log "VM $name 已存在，跳过创建（如需重建: $0 destroy 后重新部署）"
      continue
    fi

    yaml="$(gen_vm_yaml "$name" "$cpu" "$mem" "$disk" "$port")"
    lima_log "创建 VM: $name (CPU=$cpu MEM=${mem}GiB DISK=${disk}GiB SSH端口=$port 镜像=$BASE_IMG)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      lima_log "[dry-run] 将执行: limactl create --name=$name --tty=false $yaml"
      continue
    fi
    limactl create --tty=false --name="$name" "$yaml" || lima_die "创建 VM 失败: $name"
    mark_state "$name" "created"
  done
}

# ----------------------------------------------------------------------------
# 启动 VM 并等待 SSH 端口就绪（幂等：Running 跳过）
# ----------------------------------------------------------------------------
port_ready() { # $1=127.0.0.1端口
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}

start_and_wait_vms() {
  local i name port state attempt
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"; port="${MACHINE_SSH_PORTS[$i]}"
    state="$(vm_state "$name")"
    if [[ "$state" == "Running" ]]; then
      lima_log "VM $name 已在运行，跳过启动"
    else
      lima_log "启动 VM: ${name}（当前状态: ${state:-未创建}）"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        lima_log "[dry-run] 将执行: limactl start --tty=false $name"
        continue
      fi
      limactl start --tty=false "$name" || lima_die "启动 VM 失败: $name"
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
      lima_log "等待 ${name} SSH 端口就绪 (127.0.0.1:${port}，首次启动约 2-5 分钟)..."
      for attempt in $(seq 1 100); do
        if port_ready "$port"; then
          lima_log "$name 已就绪: ssh $name"
          break
        fi
        [[ "$attempt" -eq 100 ]] && lima_warn "$name 等待 SSH 超时，可稍后手动检查: limactl shell $name"
        sleep 3
      done
    fi
  done
}

# ----------------------------------------------------------------------------
# 后置配置：VM 内 /etc/hosts 互解析、机器/IP 清单、SSH 免密别名
# ----------------------------------------------------------------------------
resolve_guest_ip() { # $1=vm名，输出 IP（失败输出空）
  local ip=""
  ip="$(limactl shell "$1" -- hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$ip" ]]; then
    ip="$(limactl shell "$1" -- sh -c "ip -4 addr show scope global 2>/dev/null" 2>/dev/null \
      | awk '/inet /{split($2,a,"/"); print a[1]; exit}')" || true
  fi
  echo "$ip"
}

write_guest_hosts() {
  # 先统一解析所有 VM 的 guest IP
  GUEST_IPS=()
  local i name ip
  for i in "${!MACHINE_NAMES[@]}"; do
    GUEST_IPS+=("")
  done
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"
    ip="$(resolve_guest_ip "$name")"
    GUEST_IPS[$i]="$ip"
    if [[ -z "$ip" ]]; then
      lima_warn "无法获取 $name 的 guest IP（VM 内 hosts 互解析将不完整）"
    else
      lima_log "VM $name guest IP: $ip"
    fi
  done
  # 写入每台 VM 的 /etc/hosts
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"
    [[ -n "${GUEST_IPS[$i]}" ]] || continue
    local hosts_line=""
    for j in "${!MACHINE_NAMES[@]}"; do
      [[ -n "${GUEST_IPS[$j]}" ]] || continue
      hosts_line="${hosts_line}${GUEST_IPS[$j]} ${MACHINE_NAMES[$j]}"$'\n'
    done
    lima_log "写入 $name 的 VM 内 /etc/hosts"
    printf '%s' "$hosts_line" | limactl shell "$name" -- sudo sh -c '
      sed -i "/[[:space:]]machine[0-9]\+$/d" /etc/hosts
      cat >> /etc/hosts
    ' >/dev/null 2>&1 || lima_warn "写入 $name VM 内 hosts 失败（不影响部署）"
    mark_state "$name" "configured"
  done
}

# ----------------------------------------------------------------------------
# 为 SSH_USER 配置 VM 内免密（默认 root）：写入 Lima 公钥并放开密钥登录
# 幂等：重复执行结果一致
# ----------------------------------------------------------------------------
setup_ssh_user() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$SSH_USER" == "$IMAGE_USER" ]] && return 0   # 登录用户即初始化用户，无需额外配置
  local i name
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"
    lima_log "为 $name 配置 SSH 登录用户 ${SSH_USER}（基于 ${IMAGE_USER} 的密钥）"
    limactl shell "$name" -- sudo sh -c '
      set -e
      login_user="'"$SSH_USER"'"
      home_dir="$(getent passwd "$login_user" | cut -d: -f6)"
      [ -n "$home_dir" ] || { echo "用户不存在: $login_user" >&2; exit 1; }
      mkdir -p "$home_dir/.ssh"
      for u in '"$IMAGE_USER"' '"$SSH_USER"'; do
        u_home="$(getent passwd "$u" | cut -d: -f6)"
        [ -n "$u_home" ] && [ -s "$u_home/.ssh/authorized_keys" ] && cat "$u_home/.ssh/authorized_keys"
      done | sort -u > "$home_dir/.ssh/authorized_keys"
      chown -R "$login_user" "$home_dir/.ssh"
      chmod 700 "$home_dir/.ssh"
      chmod 600 "$home_dir/.ssh/authorized_keys"
      if [ "$login_user" = "root" ]; then
        if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
          sed -i "s/^PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
        else
          echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
        fi
      fi
      systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true
    ' >/dev/null 2>&1 || lima_warn "为 ${SSH_USER} 配置免密失败: ${name}（可重跑 ./deploy_vms.sh deploy 补配）"
  done
}

lima_write_machine_md() {
  local i name cpu mem disk port ip
  {
    echo "# 虚拟机配置信息（macOS / Lima）"
    echo
    echo "> 由 deploy_vms.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "| 机器名 | guest IP | CPU | 内存 | 磁盘 | SSH 端口 | 登录方式 |"
    echo "|--------|----------|-----|------|------|----------|----------|"
    for i in "${!MACHINE_NAMES[@]}"; do
      name="${MACHINE_NAMES[$i]}"; cpu="${MACHINE_CPU[$i]}"; mem="${MACHINE_MEM_GBS[$i]}"
      disk="${DISK_GB[$i]}"; port="${MACHINE_SSH_PORTS[$i]}"; ip="${GUEST_IPS[$i]:-待获取}"
      printf "| %s | %s | %s 核 | %sGiB | %sGiB | %s | ssh %s (用户: %s) |\n" \
        "$name" "$ip" "$cpu" "$mem" "$disk" "$port" "$name" "$SSH_USER"
    done
    echo
    echo "镜像类型: ${IMAGE_CHOICE}；VM 类型: ${VM_TYPE}"
  } > "$MACHINE_MD_FILE"
  lima_log "机器配置信息已保存: $MACHINE_MD_FILE"
}

# ----------------------------------------------------------------------------
# SSH 免密别名（本机当前用户 + 可提权时覆盖所有可登录用户）
# ----------------------------------------------------------------------------
# 当前用户使用的 Lima 私钥；为其他用户写入时通过 VM_DEPLOY_IDENTITY 覆盖为其目录内的副本
LIMA_IDENTITY="${VM_DEPLOY_IDENTITY:-$HOME/.lima/_config/user}"

lima_write_one_ssh_config() { # $1=home目录 $2=该用户使用的私钥路径
  # 注意：不能在同一行 local 里先定义后引用（set -u 下会报 unbound variable）
  local home="$1" identity="$2" tmp i
  local ssh_dir="$home/.ssh"
  local ssh_config="$home/.ssh/config"
  mkdir -p "$ssh_dir" 2>/dev/null || { lima_warn "无法创建 ${ssh_dir}，跳过该用户"; return 0; }
  touch "$ssh_config" || { lima_warn "无法写入 ${ssh_config}，跳过该用户"; return 0; }

  tmp="$(mktemp)"
  awk '
    /^# BEGIN vm_deploy$/ { skip=1; next }
    /^# END vm_deploy$/   { skip=0; next }
    /^Host machine[0-9]+/ { skip_legacy=1; next }
    /^Host / && skip_legacy { skip_legacy=0 }
    !skip && !skip_legacy { print }
  ' "$ssh_config" > "$tmp"

  {
    cat "$tmp"
    echo "# BEGIN vm_deploy"
    for i in "${!MACHINE_NAMES[@]}"; do
      printf "Host %s %s@%s\n" "${MACHINE_NAMES[$i]}" "$SSH_USER" "${MACHINE_NAMES[$i]}"
      printf "  HostName 127.0.0.1\n"
      printf "  Port %s\n" "${MACHINE_SSH_PORTS[$i]}"
      printf "  User %s\n" "$SSH_USER"
      printf "  IdentityFile %s\n" "$identity"
      printf "  StrictHostKeyChecking no\n"
      printf "  UserKnownHostsFile /dev/null\n\n"
    done
    echo "# END vm_deploy"
  } > "$ssh_config"
  rm -f "$tmp"
}

lima_write_ssh_config() {
  [[ -f "$LIMA_IDENTITY" ]] || lima_warn "Lima 用户密钥尚未生成: ${LIMA_IDENTITY}（首次创建 VM 后自动生成，可稍后重跑 ssh-config）"

  lima_write_one_ssh_config "$HOME" "$LIMA_IDENTITY"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
  lima_log "SSH 免密别名已写入: $HOME/.ssh/config"

  # 尝试覆盖其他本地可登录用户（需要无交互 sudo 权限；密钥需复制到各用户目录）
  if sudo -n true 2>/dev/null; then
    while IFS=: read -r user _ uid _ _ home shell; do
      [[ "$user" == "$USER" ]] && continue
      [[ "$uid" -ge 501 ]] || continue
      [[ -d "$home" ]] || continue
      [[ "$shell" != */false && "$shell" != */usr/bin/false && "$shell" != */nologin ]] || continue
      local user_identity="$home/.ssh/id_rsa_vm_deploy"
      sudo mkdir -p "$home/.ssh" 2>/dev/null || { lima_warn "无法创建 $home/.ssh，跳过用户 $user"; continue; }
      if [[ -f "$LIMA_IDENTITY" ]]; then
        sudo cp "$LIMA_IDENTITY" "$user_identity" 2>/dev/null || { lima_warn "复制密钥到 $user_identity 失败，跳过用户 $user"; continue; }
        sudo chown "$user" "$user_identity" "$home/.ssh" 2>/dev/null || true
        sudo chmod 600 "$user_identity" 2>/dev/null || true
      fi
      # 以该用户身份重跑本脚本 ssh-config（写入其 $home/.ssh/config，并指向其目录内的密钥副本）
      if sudo -u "$user" -H VM_DEPLOY_IDENTITY="$user_identity" bash "$0" ssh-config >/dev/null 2>&1; then
        lima_log "SSH 免密别名已写入: $home/.ssh/config (用户 $user)"
      else
        lima_warn "写入用户 $user 的 ssh config 失败，可手动为其执行: sudo -u $user $0 ssh-config"
      fi
    done < /etc/passwd
  else
    lima_warn "无无交互 sudo 权限，仅配置了当前用户；如需所有本地用户免密，请用 sudo 重跑: sudo -E $0 ssh-config"
  fi
}

cleanup_ssh_config() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local home
  for home in "$HOME"; do
    [[ -f "$home/.ssh/config" ]] || continue
    grep -q "^# BEGIN vm_deploy" "$home/.ssh/config" || continue
    awk '
      /^# BEGIN vm_deploy$/ { skip=1; next }
      /^# END vm_deploy$/   { skip=0; next }
      !skip { print }
    ' "$home/.ssh/config" > "$home/.ssh/config.tmp" \
      && mv "$home/.ssh/config.tmp" "$home/.ssh/config"
  done
  lima_log "已清理本机 ssh config 中的 vm_deploy 别名"
}

# ----------------------------------------------------------------------------
# 结果汇总
# ----------------------------------------------------------------------------
summary() {
  local i
  echo
  lima_log "=========== 部署完成 ==========="
  printf "%-16s %-18s %-14s %s\n" "VM" "IP" "SSH端口" "登录方式"
  for i in "${!MACHINE_NAMES[@]}"; do
    printf "%-16s %-18s %-14s %s\n" "${MACHINE_NAMES[$i]}" "${GUEST_IPS[$i]:-待获取}" "${MACHINE_SSH_PORTS[$i]}" "ssh ${MACHINE_NAMES[$i]}  (用户: ${SSH_USER})"
  done
  echo "================================"
}

# ----------------------------------------------------------------------------
# destroy：删除配置中定义的全部 VM（危险操作，需确认 / 支持 dry-run）
# ----------------------------------------------------------------------------
destroy_lima() {
  local i name state found=0
  local -a existing=()
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"
    if vm_exists "$name"; then
      existing+=("$name"); found=$((found+1))
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    lima_log "未发现配置中定义的任何 Lima VM，无需清理。"
    cleanup_ssh_config
    return 0
  fi

  echo
  lima_warn "危险操作：即将停止并删除以下 ${found} 台 Lima VM 及其全部磁盘数据（不可恢复）："
  lima_warn "  ${existing[*]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    lima_log "[dry-run] 将执行: limactl delete -f <上述VM>，并清理 ssh 别名/状态文件"
    return 0
  fi
  if [[ "$CONFIRM_YES" -ne 1 ]]; then
    local confirm
    read -r -p "确认继续请输入 yes: " confirm
    [[ "$confirm" == "yes" ]] || { lima_log "已取消 destroy 操作，未做任何更改。"; return 0; }
  fi

  for name in "${existing[@]}"; do
    state="$(vm_state "$name")"
    lima_log "删除 VM: ${name}（当前状态: ${state}）"
    limactl delete --force "$name" >/dev/null 2>&1 || lima_warn "删除 VM 失败: $name"
    rm -f "$STATE_DIR/$name".*.state "$OUTPUT_DIR/$name.yaml"
  done

  cleanup_ssh_config
  rm -f "$STATE_DIR/image_user.state" "$STATE_DIR/ssh_user.state"
  [[ -f "$MACHINE_MD_FILE" ]] && rm -f "$MACHINE_MD_FILE" && lima_log "已删除机器配置信息: $MACHINE_MD_FILE"
  lima_log "清理完成。基础镜像缓存保留在 ${LIMA_IMG_DIR}（如需彻底清理请手动删除）。"
}

# ----------------------------------------------------------------------------
# clean：清洁执行前的清理（删除 VM + 状态 + 生成物）
# ----------------------------------------------------------------------------
clean_all() {
  lima_log "清洁执行：删除已有 VM、状态文件与生成物后重新部署"
  destroy_lima
}

# ----------------------------------------------------------------------------
# 子命令入口
# ----------------------------------------------------------------------------
do_deploy() {
  stage_begin 1 "加载配置与校验"
  load_config
  check_config
  lima_select_image
  ensure_dirs
  save_image_user
  stage_end 1

  stage_begin 2 "前置检查"
  lima_ensure_deps
  ensure_dirs
  check_ports_free
  [[ "$CLEAN" -eq 1 ]] && clean_all
  stage_end 2

  stage_begin 3 "准备基础镜像"
  prepare_base_image
  stage_end 3

  stage_begin 4 "创建 VM"
  create_vms
  stage_end 4

  stage_begin 5 "启动并等待就绪"
  start_and_wait_vms
  stage_end 5

  stage_begin 6 "后置配置与汇总"
  write_guest_hosts
  setup_ssh_user
  lima_write_machine_md
  lima_write_ssh_config
  summary
  stage_end 6
}

do_status() {
  STAGE_TOTAL=1; STAGE_NO=1
  load_config
  local i name state ip
  printf "%-16s %-12s %-18s %s\n" "VM" "状态" "IP" "SSH端口"
  for i in "${!MACHINE_NAMES[@]}"; do
    name="${MACHINE_NAMES[$i]}"
    state="$(vm_state "$name")"
    if [[ -z "$state" ]]; then
      printf "%-16s %-12s %-18s %s\n" "$name" "未部署" "-" "${MACHINE_SSH_PORTS[$i]}"
    else
      ip="$(resolve_guest_ip "$name" 2>/dev/null || true)"
      printf "%-16s %-12s %-18s %s\n" "$name" "$state" "${ip:-未知}" "${MACHINE_SSH_PORTS[$i]}"
    fi
  done
}

do_ssh_config() {
  STAGE_TOTAL=2
  stage_begin 1 "加载配置"
  load_config
  check_config
  ensure_dirs
  # 优先使用部署时记录的镜像/SSH 用户；无记录时才走镜像选择（非交互终端会退回默认值）
  load_image_user || lima_select_image
  # SSH 登录用户非初始化用户时，先在 VM 内补配免密（幂等）
  setup_ssh_user
  stage_end 1
  stage_begin 2 "写入 SSH 别名"
  lima_write_ssh_config
  stage_end 2
}

do_destroy() {
  STAGE_TOTAL=2
  stage_begin 1 "加载配置"
  load_config
  check_config
  ensure_dirs
  stage_end 1
  stage_begin 2 "销毁 VM"
  destroy_lima
  stage_end 2
}

# ----------------------------------------------------------------------------
# 主入口
# ----------------------------------------------------------------------------
lima_main() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  parse_args "$@"
  lima_log "日志文件: $LOG_FILE"
  [[ "$DRY_RUN" -eq 1 ]] && lima_log "已启用 dry-run 预览模式"
  case "$ACTION" in
    deploy)     do_deploy ;;
    status)     do_status ;;
    ssh-config) do_ssh_config ;;
    destroy)    do_destroy ;;
  esac
}

# ----------------------------------------------------------------------------
# 主入口：按平台分发（macOS → Lima 实现；Linux → KVM/libvirt 实现）
# ----------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  lima_main "$@"
else
  kvm_main "$@"
fi
