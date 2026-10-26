# vm_deploy — KVM/Lima 虚拟机一键部署工具（Linux / macOS 双平台）

基于 cloud-init 在本机批量部署麒麟 V10（或 Ubuntu 22.04）虚拟机，自动完成静态 IP、SSH 免密、hosts 解析、根分区扩容等初始化配置。

- **Linux**：KVM/libvirt + 静态 IP（DHCP host 按 MAC 绑定），入口 [deploy_vms.sh](deploy_vms.sh)
- **macOS (Apple Silicon)**：Lima + 固定 SSH 端口转发（Lima 实现已集成进 [deploy_vms.sh](deploy_vms.sh)，按平台自动分发）
- **平台自动分发**：`deploy_vms.sh` / `manage_vms.sh` 均自动检测平台——macOS 上自动转交 Lima 实现，用法与 Linux 完全一致，无需手动区分

## 功能特性

- 一键批量部署多台 VM（Linux 按 `WORKER_COUNT` 自动生成机器名/IP/MAC/规格；macOS 按数组逐台配置）
- CPU/内存按 `RESOURCE_RATIO`（默认 2:1）分摊：资源共 `台数*普通份额+VIP份额` 份，系数之和恒为 1，正好用满不超分；磁盘/swap 也按此比例缩放
- 自动追加 1 台 VIP 机（`DEPLOY_VIP=1` 默认开启，设 `DEPLOY_VIP=0` 可关闭），机器名统一按 `machine1`、`machine2`… 编号（VIP 机为最后一台），资源按比例小于普通机
- cloud-init 自动初始化：主机名、时区、用户、SSH 公钥、静态 IP
- libvirt default 网络静态 IP 绑定（DHCP host 按 MAC 固定分配）
- 自动配置宿主机与 VM 的 SSH 免密（RSA 密钥），所有本地普通用户均可通过 `machine1` 等别名直连
- 自动写入 `/etc/hosts`；Linux 生成机器/IP/MAC 对照清单（上级目录 `machine_and_ip_list.txt`），macOS 生成 `vm_deploy/虚拟机配置信息.md`
- VM 首次启动自动扩展根分区（`/`）到磁盘全量
- 支持 `destroy` 一键销毁全部 VM（带确认提示）

## 目录结构

```
vm_deploy/
├── deploy_vms.env                        # 部署配置（Linux 段 + macOS 段，按平台各自读取）
├── deploy_vms.sh                         # 主入口：Linux 走 KVM/libvirt，macOS 内置 Lima 实现（自动按平台分发）
├── manage_vms.sh                        # 批量启动/停止/状态查看/重启虚拟机（manage_vms.sh start|stop|status|restart，自动适配平台，stop 支持 --force）
├── backup_vms.sh                        # VM 备份脚本
├── auto_sync.py                         # 仓库 Git 自动同步脚本
├── docker_service.sh / docker_service.env  # macOS: colima + Docker 服务管理
├── kvm_usage.md                         # Linux: virsh 常用命令速查
├── lima_usage.md                        # macOS: limactl 常用命令速查
├── 虚拟机自定义镜像支持情况.md           # macOS 上 Multipass/Lima 镜像支持调研记录
├── images/                              # 下载的基础镜像（ubuntu-22.04-server-cloudimg-amd64.qcow2 / 麒麟 qcow2），随项目整体迁移
└── gen_qcow2/
    ├── install_kylin_template.sh        # 用麒麟 ISO + kickstart 制作基础 qcow2 模板
    ├── input_iso/                       # 麒麟安装 ISO
    └── output_qcow2/
        └── Kylin-Server-V10-SP3-2403-Release-20240426-X86_64.qcow2         # 制作好的麒麟基础镜像（模板）
```

## 前置要求

**Linux（KVM/libvirt）**

- Linux 宿主机（脚本基于 apt 安装依赖，适用于 Ubuntu/Debian），以 **root** 运行
- 已在 BIOS 开启 VT-x（脚本检测不到 `/dev/kvm` 会直接终止）
- 依赖（脚本会自动安装）：`qemu-kvm`、`libvirt-daemon-system`、`libvirt-clients`、`virtinst`、`cloud-image-utils`、`genisoimage`

**macOS（Lima）**

- macOS 13+（Apple Silicon，arm64），无需 root
- 依赖：`brew install lima qemu`
- 注意：Mac 上只能运行 **arm64** 架构镜像；麒麟 V10 官方公开云镜像仅 x86_64，需自行从麒麟官方/授权渠道获取 aarch64 qcow2 云镜像

## 配置说明（deploy_vms.env）

配置文件只需指定普通机台数，机器名/MAC/IP/CPU/内存/磁盘/swap 全部自动生成：

```bash
# 是否部署 VIP 机（1=部署，0=不部署）
DEPLOY_VIP=1

# 普通 VM 台数（正整数）。DEPLOY_VIP=1 时实际部署台数 = 台数 + 1（额外 1 台 VIP 机）
# 例：填 3 实际部署 4 台（3 普通 + 1 VIP）；DEPLOY_VIP=0 时填 3 只部署 3 台
WORKER_COUNT=2
```

普通 VM 规格（每项只填一个值，VIP 机自动按比例缩放）：

```bash
RESOURCE_RATIO="2:1"     # 普通 VM 与 VIP 机的资源比例（普通机份额:VIP机份额，支持小数如 2.5:1）
DISK_GB=100              # 磁盘大小（GB，qcow2 精简置备）
MACHINE_SWAP_GB=16       # swap 大小（GB，虚机内创建 /swapfile）；0=不创建
IP_START="192.168.122.10" # 自动分配 IP 的起始地址，往后顺序递增
MACHINE_NAME_START="machine1" # 起始机器名（前缀可自定义，如 node5 → node5、node6...）
```

CPU/内存按 `RESOURCE_RATIO` 按份自动分配（支持小数份额）：资源共分成 `台数*普通份额+VIP份额` 份（`DEPLOY_VIP=0` 时为 `台数*普通份额` 份，普通机均分）。例：填 3 台 + 比例 2:1 → 4 台分 7 份，普通机各占 2/7、VIP 机占 1/7，系数之和恰为 1，正好用满宿主机资源不超分。磁盘/swap 也按此比例缩放（VIP 机 = 普通机 × VIP份额/普通份额）。

自动生成规则：

| 项目 | 规则 |
|------|------|
| 机器名 | 从 `MACHINE_NAME_START`（默认 `machine1`，前缀可自定义）起统一编号排列，`DEPLOY_VIP=1` 时最后一台为 VIP 机 |
| CPU/内存 | 按 `RESOURCE_RATIO` 按份分摊（系数之和恒为 1） |
| 静态 IP | 从 `IP_START`（默认 `192.168.122.10`）起顺序递增 |
| MAC | 随机生成（`52:54:00` 前缀，自动去重）；重复部署从清单文件复用旧 MAC |

其他关键配置：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `SSH_KEY` | 免密登录用的 RSA 私钥（不存在则自动生成） | `/root/.ssh/id_rsa` |
| `IMG_DIR` | 下载的基础镜像存放目录（ubuntu/kylin qcow2） | `/data/vm_deploy/images` |
| `POOL_DIR` | VM 磁盘镜像存放目录 | `/data/kvm/images` |
| `WORK_DIR` | cloud-init 配置（user-data/meta-data/network-config/seed.iso）存放目录 | `$POOL_DIR/seeds` |
| `NET_GW` | libvirt default NAT 网段网关 | `192.168.122.1` |
| `KYLIN_IMG_FILE` | 本地麒麟 qcow2 镜像路径，存在则直接使用，不再下载 | — |

## 使用方法

Linux 与 macOS 用法完全一致（脚本自动适配平台）：

```bash
cd /data/vm_deploy          # macOS 上为项目所在目录

# 部署（默认使用麒麟 V10 镜像；终端交互时弹出镜像选择菜单）
./deploy_vms.sh

# 指定镜像部署
./deploy_vms.sh deploy kylin-v10     # 麒麟 V10
./deploy_vms.sh deploy ubuntu        # Ubuntu 22.04

# 查看部署状态
./deploy_vms.sh status

# 单独配置宿主机 SSH 免密（Linux: root + 所有本地普通用户；macOS: 当前用户，sudo -E 可覆盖全部用户）
./deploy_vms.sh ssh-config

# 销毁全部 VM（有危险提示，需输入 yes 确认；macOS 支持 --dry-run 预览 / --clean 清洁执行 / --yes 免确认）
./deploy_vms.sh destroy

# 启动/停止/状态/重启所有 VM
./manage_vms.sh start
./manage_vms.sh stop          # --force 强制断电、--dry-run 预览
./manage_vms.sh status        # 只读查看各 VM 运行状态与 SSH 就绪情况
./manage_vms.sh restart       # 等价于先 stop 再 start（支持 --dry-run 预览）
```

部署完成后：

- VM 首次启动约需 2-4 分钟，脚本会轮询等待 22 端口就绪
- 直接 `ssh machine1` 即可免密登录（所有本地普通用户均已配置别名）
- 机器/IP/MAC 对照清单写入 `/data/machine_and_ip_list.txt`

## 麒麟基础镜像制作

若本地没有麒麟 qcow2 基础镜像，可用 ISO 自动制作模板：

```bash
cd gen_qcow2
# 将麒麟 ISO 放入 input_iso/ 后执行
./install_kylin_template.sh
```

脚本通过 kickstart 应答文件（OEMDRV ISO）全自动安装，完成后生成 `output_qcow2/Kylin-Server-V10-SP3-2403-Release-20240426-X86_64.qcow2`。

镜像来源两种方式（二选一）：

1. 本地已有：配置 `KYLIN_IMG_FILE` 指向 qcow2 文件，部署时直接复制使用
2. 在线下载：脚本从麒麟官方源下载 `Kylin-Server-V10-SP3-Cloud-Image.qcow2`

也可在运行时通过环境变量传入本地镜像：

```bash
KYLIN_IMG_FILE=/path/to/kylin.qcow2 ./deploy_vms.sh deploy kylin-v10
```

## 网络说明

- VM 使用 libvirt `default` NAT 网络（192.168.122.0/24）
- 通过 `virsh net-update` 将 MAC/IP 写入 DHCP host 表，保证静态 IP 稳定分配
- VM 内网卡按 MAC 匹配命名为 `ens3`，DNS 使用 223.5.5.5 / 114.114.114.114

## macOS (Lima) 平台说明

macOS 上执行 `./deploy_vms.sh` 会自动走内置的 Lima 实现（与 KVM 实现集成在同一脚本内），与 Linux 版的主要差异：

| 项目 | Linux (KVM) | macOS (Lima) |
|------|-------------|--------------|
| 配置模型 | `WORKER_COUNT` + `DEPLOY_VIP` + `RESOURCE_RATIO` + `DISK_GB` 自动生成机器名/规格（共 `WORKER_COUNT+1` 台，末台 VIP；`DEPLOY_VIP=0` 时共 `WORKER_COUNT` 台） | 与 Linux 完全一致（共用同一批配置项）；macOS 段额外配置 `BASE_SSH_PORT`（首台 SSH 端口，逐台递增）、`VM_TYPE`、镜像路径等 |
| 网络 | libvirt NAT 静态 IP（DHCP host 按 MAC 绑定） | Lima NAT，宿主机走 `127.0.0.1:<固定SSH端口>` 转发；VM 互解析写入 VM 内 `/etc/hosts` |
| 登录方式 | `ssh -i <私钥> user@<IP>` / `ssh machine1` 别名 | `ssh machine1` 别名（固定端口，VM 重启后依然有效）；控制台 `limactl shell machine1` |
| 默认用户 | 麒麟 root / Ubuntu 可配 | `SSH_USER`（默认 root，脚本自动写入 Lima 密钥并放开密钥登录） |
| 额外选项 | — | `--dry-run` 预览、`--clean` 清洁执行、`--yes` 免确认 |
| 日志 | 标准输出 | `logs/` 目录（带时间戳与阶段进度） |
| 断点续跑 | 幂等重跑 | `state/` 状态文件，幂等重跑 |

麒麟镜像：配置 macOS 段的 `MAC_KYLIN_IMG_FILE` 指向本地 aarch64 qcow2 云镜像（或 `KYLIN_IMG_URL` 在线下载）。

```bash
MAC_KYLIN_IMG_FILE=/path/to/kylin-aarch64.qcow2 ./deploy_vms.sh deploy kylin-v10
```

## 常用命令速查

- Linux（virsh）：见 [kvm_usage.md](kvm_usage.md)
- macOS（limactl）：见 [lima_usage.md](lima_usage.md)

## 注意事项

- Linux 上所有脚本需 root 运行；macOS 无需 root，脚本只操作 `deploy_vms.env` 中定义的 VM，不影响 colima/Multipass 等其他虚拟机
- `destroy` 会停止并删除所有本脚本部署的 VM 及其存储，**执行前务必备份重要数据**
- Linux: 麒麟 VM 的磁盘扩容依赖 LVM（`/dev/mapper/klas-root`），首次启动自动完成
- macOS: 与 colima 并存时注意内存配额；Docker 服务管理可用 [docker_service.sh](docker_service.sh)
