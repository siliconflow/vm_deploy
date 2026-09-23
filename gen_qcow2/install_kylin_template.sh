#!/usr/bin/env bash
# 使用麒麟 V10 ISO 安装一个 KVM 模板虚拟机，安装目标磁盘为 qcow2。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL_DIR="${POOL_DIR:-/var/lib/libvirt/images}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$POOL_DIR/kylin-template-build}"
SOURCE_ISO="${ISO_FILE:-$SCRIPT_DIR/Kylin-Server-V10-SP3-2403-Release-20240426-X86_64.iso}"
ISO_FILE="$TEMPLATE_DIR/$(basename "$SOURCE_ISO")"
DISK_FILE="${DISK_FILE:-$TEMPLATE_DIR/kylin-v10-sp3-cloud.qcow2}"
FINAL_IMAGE="${FINAL_IMAGE:-$POOL_DIR/kylin-v10-base.qcow2}"
KS_FILE="$TEMPLATE_DIR/ks.cfg"
KS_ISO="$TEMPLATE_DIR/kylin-ks.iso"
VM_NAME="${VM_NAME:-kylin-template}"
DISK_SIZE="${DISK_SIZE:-20G}"
VCPUS="${VCPUS:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
ROOT_PASSWORD="${ROOT_PASSWORD:-Kylin@123456}"
REBUILD="${REBUILD:-1}"

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

ensure_deps() {
  need_cmd qemu-img
  need_cmd virt-install
  need_cmd virsh
  command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1 || die "缺少命令: genisoimage/mkisofs"
}

ensure_libvirt() {
  systemctl enable --now libvirtd >/dev/null 2>&1 || true
  virsh net-start default >/dev/null 2>&1 || true
  virsh net-autostart default >/dev/null 2>&1 || true
}

prepare_files() {
  [[ -f "$SOURCE_ISO" ]] || die "ISO 不存在: $SOURCE_ISO"
  mkdir -p "$TEMPLATE_DIR"

  if [[ "$SOURCE_ISO" != "$ISO_FILE" ]]; then
    log "复制 ISO 到 libvirt 可访问目录: $ISO_FILE"
    cp -f "$SOURCE_ISO" "$ISO_FILE"
  fi

  cat > "$KS_FILE" <<EOF
#version=RHEL8
text
cdrom
eula --agreed
lang zh_CN.UTF-8
keyboard us
timezone Asia/Shanghai --isUtc
rootpw --plaintext $ROOT_PASSWORD
network --bootproto=dhcp --device=link --activate --onboot=yes
bootloader --location=mbr
clearpart --all --initlabel
autopart --type=lvm
poweroff
%packages
@^minimal-environment
cloud-init
openssh-server
NetworkManager
%end
%post --log=/root/ks-post.log
yum install -y cloud-utils-growpart acpid || true
cat > /etc/NetworkManager/system-connections/ens3.nmconnection <<'NMEOF'
[connection]
id=ens3
type=ethernet
interface-name=ens3
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=ignore
NMEOF
chmod 600 /etc/NetworkManager/system-connections/ens3.nmconnection
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable acpid || true
systemctl enable cloud-init-local cloud-init cloud-config cloud-final
sed -i 's/^#\?disable_root:.*/disable_root: false/' /etc/cloud/cloud.cfg || true
sed -i 's/^#\?ssh_pwauth:.*/ssh_pwauth: 1/' /etc/cloud/cloud.cfg || true
cloud-init clean --logs
%end
EOF

  log "生成 kickstart 应答 ISO: $KS_ISO"
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "$KS_ISO" -volid OEMDRV -joliet -rock "$KS_FILE"
  else
    mkisofs -quiet -output "$KS_ISO" -volid OEMDRV -joliet -rock "$KS_FILE"
  fi
}

cleanup_existing() {
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log "清理已存在模板虚拟机: $VM_NAME"
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
  fi

  if [[ "$REBUILD" == "1" ]]; then
    rm -f "$DISK_FILE" "$FINAL_IMAGE"
  fi
}

create_disk() {
  if [[ -f "$DISK_FILE" ]]; then
    log "磁盘已存在: $DISK_FILE"
    return
  fi

  log "创建 qcow2 磁盘: $DISK_FILE ($DISK_SIZE)"
  qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE" >/dev/null
}

start_install() {
  if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    die "虚拟机已存在: $VM_NAME。如需重装，请先执行: virsh destroy $VM_NAME; virsh undefine $VM_NAME"
  fi

  log "启动 ISO 自动安装虚拟机: $VM_NAME"
  virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --vcpus "$VCPUS" \
    --memory "$MEMORY_MB" \
    --disk path="$DISK_FILE",format=qcow2,bus=virtio \
    --disk path="$KS_ISO",device=cdrom,format=raw,bus=sata \
    --cdrom "$ISO_FILE" \
    --boot cdrom,hd \
    --network network=default,model=virtio \
    --graphics vnc,listen=0.0.0.0 \
    --console pty,target_type=serial \
    --os-variant generic \
    --noautoconsole
}

wait_install_done() {
  local i state
  log "等待安装完成并自动关机..."
  for i in $(seq 1 240); do
    state="$(virsh domstate "$VM_NAME" 2>/dev/null || true)"
    if [[ "$state" == "关闭" || "$state" == "shut off" ]]; then
      log "安装完成，虚拟机已关机"
      return
    fi
    sleep 30
  done
  die "等待安装超时。可查看控制台: virsh console $VM_NAME"
}

finalize_image() {
  log "复制模板镜像: $FINAL_IMAGE"
  cp -f "$DISK_FILE" "$FINAL_IMAGE"
  qemu-img info "$FINAL_IMAGE"
  log "模板镜像制作完成: $FINAL_IMAGE"
}

main() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行"
  ensure_deps
  ensure_libvirt
  prepare_files
  cleanup_existing
  create_disk
  start_install
  wait_install_done
  finalize_image
}

main "$@"
