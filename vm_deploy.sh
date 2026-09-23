#!/usr/bin/env bash
# vm_deploy.sh — 使用 KVM 在本机部署 5 台 VM（machine1-machine5）
# 用法:
#   ./vm_deploy.sh                         # 使用麒麟 V10 镜像部署（默认，无交互）
#   ./vm_deploy.sh deploy ubuntu           # 使用 Ubuntu 22.04 镜像部署
#   ./vm_deploy.sh deploy kylin-v10        # 使用麒麟 V10 镜像部署
#   ./vm_deploy.sh status                  # 查看 VM 状态
#   ./vm_deploy.sh ssh-config              # 给 root 和所有本地普通用户配置 VM 免密 SSH
#   ./vm_deploy.sh destroy                 # 销毁全部 VM 及相关文件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/vm_deploy.env"

[[ -f "$ENV_FILE" ]] || { echo -e "\033[31m[ERROR]\033[0m 缺少配置文件: $ENV_FILE"; exit 1; }
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

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

ALL_NAMES=("${MACHINE_NAMES[@]}")

select_image() {
  local choice="${1:-}"

  if [[ -z "$choice" ]]; then
    choice="kylin-v10"
  fi

  case "$choice" in
    1|ubuntu|Ubuntu|UBUNTU)
      local ubuntu_ver="jammy"
      IMAGE_TYPE="ubuntu"
      IMAGE_LABEL="Ubuntu 22.04"
      IMAGE_USER="ubuntu"
      OS_VARIANT="ubuntu22.04"
      IMG_NAME="${ubuntu_ver}-server-cloudimg-amd64.img"
      IMG_URLS=(
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/${ubuntu_ver}/current/${IMG_NAME}"
        "https://cloud-images.ubuntu.com/${ubuntu_ver}/current/${IMG_NAME}"
      )
      BASE_IMG="${POOL_DIR}/${ubuntu_ver}-base.qcow2"
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
      BASE_IMG="${POOL_DIR}/kylin-v10-base.qcow2"
      ;;
    *)
      die "未知镜像类型: $choice（可选: ubuntu, kylin-v10）"
      ;;
  esac

  log "部署镜像: $IMAGE_LABEL"
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
  local name="$1" ip="$2" mac="$3"
  local dir="$WORK_DIR/$name"
  local ssh_home ssh_dir ssh_identity
  mkdir -p "$dir"

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
  - grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  - sed -i 's/^AllowTcpForwarding[[:space:]].*/AllowTcpForwarding yes/; s/^AllowAgentForwarding[[:space:]].*/AllowAgentForwarding yes/' /etc/ssh/sshd_config
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
      - to: default
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
  local name="$1" cpu="$2" mem="$3" disk="$4" mac="$5" ip="$6"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    warn "VM $name 已存在，跳过创建（如需重建: $0 destroy）"
    return
  fi
  log "创建 VM: $name (CPU=$cpu MEM=${mem}MB DISK=${disk}GB IP=$ip)"

  ensure_dhcp_host "$name" "$mac" "$ip"
  write_cloud_init "$name" "$ip" "$mac"

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

  virt-install --connect qemu:///system \
    --name "$name" --vcpus "$cpu" --memory "$mem" \
    --cpu host-passthrough \
    --disk path="$POOL_DIR/$name.qcow2",format=qcow2,bus=virtio \
    --disk path="$WORK_DIR/$name/seed.iso",device=cdrom,format=raw,bus=sata \
    --network network=default,model=virtio,mac="$mac" \
    --import --noautoconsole --graphics none \
    --console pty,target_type=serial \
    --os-variant "$osv"
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
      printf "%-16s %s\n" "${MACHINE_NAMES[$i]}" "${MACHINE_IPS[$i]}"
    done
  } > "$MACHINE_IP_LIST_FILE"

  log "机器/IP 清单已保存: $MACHINE_IP_LIST_FILE"
}

deploy() {
  local image_choice="${1:-}"
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"

  # KVM 不可用（BIOS 未开启 VT-x 或本机为未开嵌套虚拟化的虚拟机）时终止
  if [[ ! -c /dev/kvm ]]; then
    die "未检测到 /dev/kvm，KVM 硬件虚拟化不可用。纯软件模拟性能极差（慢 10 倍以上），已终止部署。请先在 BIOS 开启 VT-x（Intel Virtualization Technology）后重试"
  fi

  select_image "$image_choice"
  ensure_deps
  ensure_libvirt
  gen_ssh_key
  mkdir -p "$POOL_DIR" "$WORK_DIR"
  download_base_image

  if [[ "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_MEM_MBS[@]}" \
    || "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_MACS[@]}" \
    || "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_IPS[@]}" \
    || "${#MACHINE_NAMES[@]}" -ne "${#MACHINE_CPU[@]}" \
    || "${#MACHINE_NAMES[@]}" -ne "${#DISK_GB[@]}" ]]; then
    die "配置错误: MACHINE_NAMES、MACHINE_CPU、MACHINE_MEM_MBS、DISK_GB、MACHINE_MACS、MACHINE_IPS 数组长度必须一致(当前 ${#MACHINE_NAMES[@]}/${#MACHINE_CPU[@]}/${#MACHINE_MEM_MBS[@]}/${#DISK_GB[@]}/${#MACHINE_MACS[@]}/${#MACHINE_IPS[@]})，请检查 $ENV_FILE"
  fi

  local i
  for i in "${!MACHINE_NAMES[@]}"; do
    create_vm "${MACHINE_NAMES[$i]}" "${MACHINE_CPU[$i]}" "${MACHINE_MEM_MBS[$i]}" "${DISK_GB[$i]}" "${MACHINE_MACS[$i]}" "${MACHINE_IPS[$i]}"
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
  write_machine_ip_list
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

configure_ssh_only() {
  select_image "kylin-v10"
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

  mapfile -t domains < <(virsh --connect qemu:///system list --all --name | awk 'NF { print }')
  if [[ "${#domains[@]}" -eq 0 ]]; then
    log "未发现 libvirt VM，无需清理。"
    return 0
  fi

  echo
  warn "危险操作：即将停止并删除 ${#domains[@]} 台 libvirt VM。"
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
      [[ -z "$state" || "$state" == "shut off" ]] || ((active_count++))
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

  log "清理完成。仅处理 virsh 可见的 libvirt VM；未扫描或删除非 libvirt 资源。"
}

case "${1:-deploy}" in
  deploy) deploy "${2:-}" ;;
  status) status ;;
  ssh-config) configure_ssh_only ;;
  destroy) destroy ;;
  ubuntu|kylin|kylin-v10) deploy "$1" ;;
  *) die "用法: $0 [deploy [ubuntu|kylin-v10]|ubuntu|kylin-v10|status|ssh-config|destroy]" ;;
esac
