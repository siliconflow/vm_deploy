# vm_deploy — KVM 虚拟机一键部署工具

基于 KVM/libvirt + cloud-init 批量部署虚拟机，支持麒麟 V10 和 Ubuntu 22.04，自动完成静态 IP、SSH 免密、hosts 解析、根分区扩容等初始化配置。

## 功能特性

- 批量创建多台 VM，名称、CPU、内存、磁盘、MAC、IP 均可独立配置
- 支持麒麟 V10、Ubuntu 22.04 两类基础镜像
- cloud-init 初始化主机名、时区、用户、SSH 公钥、静态网络
- libvirt `default` NAT 网络绑定 MAC/IP，保证地址稳定
- 自动配置宿主机 root 与本地普通用户 SSH 免密别名
- 自动写入 `/etc/hosts`，生成机器/IP 清单
- 首次启动自动扩展根分区到配置的磁盘容量
- 支持查看状态、批量启动/停止、一键销毁

## 目录结构

```text
vm_deploy/
├── README.md
├── .gitignore
├── vm_deploy.env                         # 部署配置
├── vm_deploy.sh                          # 主脚本：部署/状态/SSH 配置/销毁
├── start_vms.sh                          # 启动所有 libvirt VM
├── stop_vms.sh                           # 优雅关闭所有 libvirt VM
├── kvm_usage.md                          # virsh 常用命令速查
└── gen_qcow2/
    ├── install_kylin_template.sh         # 使用麒麟 ISO 制作 qcow2 模板
    ├── input_iso/                        # 放置本地 ISO（不入库）
    └── output_qcow2/                     # 输出 qcow2 模板（不入库）
```

> ISO、qcow2、img 等大文件已通过 `.gitignore` 排除，请不要直接提交到仓库。

## 前置要求

- Linux 宿主机，建议 Ubuntu/Debian
- 使用 root 运行脚本
- BIOS/宿主机已开启硬件虚拟化，且存在 `/dev/kvm`
- 可访问 libvirt `qemu:///system`
- 依赖命令：`qemu-kvm`、`libvirt-daemon-system`、`libvirt-clients`、`virtinst`、`cloud-image-utils`、`genisoimage`

主部署脚本会在缺少 `virt-install` 时尝试通过 `apt-get` 自动安装依赖。

## 配置说明

编辑 `vm_deploy.env`：

```bash
MACHINE_NAMES=("machine1" "machine2")
MACHINE_CPU=(5 5)
MACHINE_MEM_MBS=(30720 30720)
DISK_GB=(50 50)
MACHINE_MACS=("52:54:00:12:34:38" "52:54:00:12:34:39")
MACHINE_IPS=("192.168.122.38" "192.168.122.39")

SSH_KEY="/root/.ssh/id_rsa"
POOL_DIR="/data/kvm/images"
WORK_DIR="$POOL_DIR/seeds"
NET_GW="192.168.122.1"
KYLIN_IMG_FILE="/data/vm_deploy/gen_qcow2/output_qcow2/kylin-v10-base.qcow2"
```

数组配置必须一一对应，长度保持一致：

| 变量 | 说明 |
|------|------|
| `MACHINE_NAMES` | VM 名称列表，数组长度决定部署数量 |
| `MACHINE_CPU` | 每台 VM 的 vCPU 数 |
| `MACHINE_MEM_MBS` | 每台 VM 的内存，单位 MB |
| `DISK_GB` | 每台 VM 的磁盘容量，单位 GB |
| `MACHINE_MACS` | 每台 VM 的 MAC 地址 |
| `MACHINE_IPS` | 每台 VM 的静态 IP |
| `SSH_KEY` | 用于免密登录 VM 的 SSH 私钥 |
| `POOL_DIR` | VM 磁盘镜像存放目录 |
| `WORK_DIR` | cloud-init seed 文件存放目录 |
| `NET_GW` | libvirt default 网络网关 |
| `KYLIN_IMG_FILE` | 本地麒麟 qcow2 基础镜像路径 |

## 使用方法

```bash
# 默认部署麒麟 V10
sudo ./vm_deploy.sh

# 显式指定镜像
sudo ./vm_deploy.sh deploy kylin-v10
sudo ./vm_deploy.sh deploy ubuntu

# 查看配置中 VM 的部署状态
sudo ./vm_deploy.sh status

# 仅配置 SSH 免密别名
sudo ./vm_deploy.sh ssh-config

# 销毁配置中的全部 VM（需输入 yes 确认）
sudo ./vm_deploy.sh destroy

# 启动/停止当前 libvirt 中的全部 VM
sudo ./start_vms.sh
sudo ./stop_vms.sh
```

部署完成后可直接登录：

```bash
ssh machine1
ssh root@192.168.122.38
```

机器/IP 清单会写入项目上级目录的 `machine_and_ip_list.txt`。

## 镜像准备

### 方式一：使用已有 qcow2 镜像

将 `KYLIN_IMG_FILE` 配置为本地 qcow2 路径：

```bash
KYLIN_IMG_FILE=/path/to/kylin-v10-base.qcow2 sudo ./vm_deploy.sh deploy kylin-v10
```

### 方式二：在线下载基础镜像

不配置 `KYLIN_IMG_FILE` 时，脚本会尝试下载麒麟官方 cloud image。Ubuntu 会优先使用清华镜像源，失败后回退到 Ubuntu 官方源。

### 方式三：用麒麟 ISO 制作模板

将麒麟安装 ISO 放入 `gen_qcow2/input_iso/`，或通过 `ISO_FILE` 指定路径，然后执行：

```bash
cd gen_qcow2
sudo ISO_FILE=input_iso/Kylin-Server-V10-SP3-2403-Release-20240426-X86_64.iso \
  FINAL_IMAGE=output_qcow2/kylin-v10-base.qcow2 \
  ./install_kylin_template.sh
```

生成的 qcow2 模板可配置到 `KYLIN_IMG_FILE` 后用于部署。

## 大文件与 Git 忽略规则

以下文件默认不入库：

- `*.iso`、`*.qcow2`、`*.img`、`*.raw`、`*.vmdk`、`*.vdi`
- `gen_qcow2/input_iso/` 下的安装介质
- `gen_qcow2/output_qcow2/` 下的镜像模板
- cloud-init 生成的 `user-data`、`meta-data`、`network-config`、`seed.iso`
- 下载临时文件、日志和本地环境文件

如果大文件已经被 Git 跟踪，需要先从索引中移除但保留本地文件：

```bash
git rm --cached path/to/file.iso
git rm --cached path/to/file.qcow2
```

## 网络说明

- VM 使用 libvirt `default` NAT 网络，默认网段为 `192.168.122.0/24`
- 脚本通过 `virsh net-update` 写入 DHCP host，按 MAC 固定 IP
- VM 内网卡通过 cloud-init 按 MAC 匹配并命名为 `ens3`
- 默认 DNS：`223.5.5.5`、`114.114.114.114`

## 常用运维

```bash
# 查看所有 VM
virsh list --all

# 查看单台 VM 状态
virsh domstate machine1

# 进入控制台
virsh console machine1

# 强制关闭单台 VM
virsh destroy machine1
```

更多命令见 `kvm_usage.md`。

## 注意事项

- `destroy` 会停止并删除配置中的 VM 及关联存储，执行前请确认数据已备份
- VM 名称、MAC、IP 不要与现有 libvirt 资源冲突
- 修改数组配置后，运行部署前请确认所有数组长度一致
- 麒麟 VM 的自动扩容逻辑依赖模板中的 LVM 根分区布局
