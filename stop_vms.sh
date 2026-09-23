#!/usr/bin/env bash
set -euo pipefail

if ! command -v virsh >/dev/null 2>&1; then
  echo "[ERROR] 缺少 virsh，请先安装 libvirt-clients" >&2
  exit 1
fi

mapfile -t vms < <(virsh --connect qemu:///system list --all --name | awk 'NF { print }')

if [[ ${#vms[@]} -eq 0 ]]; then
  echo "[INFO] 未发现任何 libvirt VM"
  exit 0
fi

for vm in "${vms[@]}"; do
  state="$(virsh --connect qemu:///system domstate "$vm" 2>/dev/null || true)"
  if [[ "$state" == "running" || "$state" == "运行" ]]; then
    echo "[INFO] 正在停止 $vm"
    virsh --connect qemu:///system shutdown "$vm" >/dev/null
  else
    echo "[INFO] $vm 已停止，跳过"
  fi
done
