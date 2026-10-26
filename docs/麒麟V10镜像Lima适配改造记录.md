# 麒麟 V10 镜像 Lima 适配改造记录

> 记录时间：2026-10-26 / 2026-10-27
> 环境：macOS 26.3.2（Apple Silicon，aarch64，16GiB 内存）+ Lima 2.2.0（vz 引擎）
> 产物：`qcow2s/Kylin-Desktop-V10-SP1-2503-Release-20250417-ARM64-lima.qcow2`

## 一、结论速览

| 项目 | 内容 |
|------|------|
| 改造目标 | 让本地麒麟装机版镜像能够被 Lima 自动化部署 |
| 原始镜像 | 银河麒麟桌面操作系统 V10 SP1（Build 20250417，100GiB 虚拟容量） |
| 原始镜像下载地址 | `http://vdi.doracloud.cn:9000/repo/libvirt/aarch64/KylinV10.qcow2` |
| 产物镜像 | `Kylin-Desktop-V10-SP1-2503-Release-20250417-ARM64-lima.qcow2`（约 6.03GiB） |
| 改造手段 | 安装 sshd + cloud-init、创建部署用户、注入公钥、适配网卡、关闭 KySec |
| 验证结果 | deploy_vms.sh 6 个阶段全部通过，`ssh machine1` root 免密登录成功 |
| 关键风险 | 产物已关闭麒麟 KySec 强制访问控制，仅建议用于测试/开发环境 |

## 二、问题背景

### 2.1 现象

使用本地麒麟镜像执行 `./deploy_vms.sh` 时，前 4 个阶段正常，第 5 阶段「启动并等待就绪」卡死直至 20 分钟超时：

```
[INFO] [5-6] 启动 VM: machine1（当前状态: Stopped，启动超时 20m）
[ERROR] [5-6] 启动 VM 失败: machine1
```

串口日志只停在登录提示，主机名未变，SSH 端口始终不通：

```
Kylin V10 SP1 Administrator-pc hvc0

Administrator-pc login:
```

### 2.2 根因定位

将镜像挂载进 `builder` VM 后逐项核查，确认镜像缺少 Lima 启动判定的全部前提条件：

| 检查项 | 原镜像状态 | Lima 要求 |
|--------|-----------|-----------|
| EFI 引导 | 存在 `EFI/BOOT/BOOTAA64.EFI`、`grubaa64.efi` | 需要 |
| 系统可启动 | 可以（能到登录提示） | 需要 |
| **cloud-init** | **无** `/etc/cloud`、无 `/usr/bin/cloud-init` | 必须 |
| **openssh-server** | **无** `/usr/sbin/sshd`，仅有 ssh 客户端 | 必须 |
| 可用用户 | 仅 `Administrator`（uid 1000） | 需要 `kylin` 或由 cloud-init 创建 |
| 网卡配置 | NetworkManager profile 绑死 `enp1s0` | Lima 使用 `eth0` |

该镜像是「装机完成后的系统盘」（主机名 `Administrator-pc`，LVM 布局），不是云镜像，因此 Lima 的 cloud-init 注入链路对其完全无效。

### 2.3 排除项

同期验证确认问题不在 Lima 侧：

- 镜像下载、qcow2→raw 转换、磁盘扩容、VZ 启动、端口转发、seed ISO 生成均正常
- 另一台实例 `kylin20`（使用不同的麒麟 qcow2）症状完全一致（串口 0 字节、SSH `Connection reset`）

## 三、镜像结构说明

改造前需先了解镜像内部分区与挂载关系，这直接决定了公钥应该写到哪里。

| 分区 | 大小 | 类型 | 用途 |
|------|------|------|------|
| p1 | 512M | vfat（ESP） | EFI 引导 |
| p2 | 2G | ext4（SYSBOOT） | `/boot` |
| p3 | 97.5G | LVM2_member（SYSROOT） | 承载 LVM 卷组 `kylin-vg` |

LVM 卷组 `kylin-vg` 含三个逻辑卷：

| 逻辑卷 | 大小 | 挂载点 |
|--------|------|--------|
| `kylin-vg-root` | 57.1G | `/` |
| `kylin-vg-data` | 38.1G | `/data` |
| `kylin-vg-swap` | 2.3G | swap |

**关键点 1：`/home` 与 `/root` 是 `/data` 的 bind mount。** `fstab` 中存在：

```
/data/home      /home           none            defaults,bind           0 0
/data/root      /root           none            defaults,bind           0 0
```

因此 SSH 公钥必须写入 `/data/root/.ssh/` 与 `/data/home/kylin/.ssh/`。若只写入 `/root/.ssh/`，开机后会被 bind mount 覆盖，导致公钥丢失、登录失败。

**关键点 2：`/data` 卷初始挂载为只读属性位。** 挂载后需确认可写再写入文件。

## 四、改造步骤

### 4.1 准备工作环境

改造在 `builder` VM 内完成（该 VM 已装 `qemu-img`，且挂载了宿主机目录可交换文件）。

```bash
# 宿主机：下载原始镜像（若本地尚无）
curl -fL -o qcow2s/KylinV10.qcow2 \
  http://vdi.doracloud.cn:9000/repo/libvirt/aarch64/KylinV10.qcow2

# 宿主机：创建改造副本，保留原镜像不动
cp qcow2s/KylinV10.qcow2 tmp/kylin-debug/kylinv10-lima.qcow2

# builder 内：加载 nbd 模块并挂载镜像
limactl shell builder -- sudo sh -c '
  modprobe nbd max_part=16
  qemu-nbd -c /dev/nbd0 /Users/hanjunfeng/code/deploy-test/tmp/kylin-debug/kylinv10-lima.qcow2
  sleep 2
  vgchange -ay kylin-vg
  mount /dev/mapper/kylin--vg-root /mnt/root
  mount /dev/nbd0p1 /mnt/efi
  mount /dev/nbd0p2 /mnt/boot
  mount /dev/mapper/kylin--vg-data /mnt/data
'
```

进入 chroot 前需绑定必要目录：

```bash
limactl shell builder -- sudo sh -c '
  mount --bind /dev  /mnt/root/dev
  mount --bind /proc /mnt/root/proc
  mount --bind /sys  /mnt/root/sys
  mount --bind /run  /mnt/root/run
  cp /etc/resolv.conf /mnt/root/etc/resolv.conf
'
```

确认镜像身份：

```bash
chroot /mnt/root /bin/bash -c 'cat /etc/os-release | head -3; uname -m'
# → 银河麒麟桌面操作系统V10 SP1 / aarch64
```

### 4.2 验证软件源可达

镜像使用 apt，源地址为 `archive.kylinos.cn`。

```bash
chroot /mnt/root /bin/bash -c 'apt-get update'
# → Fetched 30.6 MB in 4s

chroot /mnt/root /bin/bash -c 'apt-cache policy openssh-server cloud-init'
# → openssh-server: 1:8.2p1-4kylin3k1.4update5  (10.1-kylin-2503/universe)
# → cloud-init:    24.4.1-0kylin0~20.04.3+esm1  (10.1-kylin/main)
```

两个包均可用，继续。

### 4.3 安装 openssh-server

```bash
chroot /mnt/root /bin/bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server'
```

安装过程自动完成：
- 生成 SSH host key（ED25519）
- 创建 `sshd.service` 软链至 `multi-user.target.wants`（开机自启）

### 4.4 创建部署用户

镜像内 uid 1000 已被 `Administrator` 占用，故使用 uid 501（与 Lima cloud-config 中的 `uid: "501"` 保持一致）。

```bash
chroot /mnt/root /bin/bash -c '
  groupadd -g 501 kylin
  useradd -m -u 501 -g 501 -s /bin/bash -c "vm-deploy user" kylin
  usermod -aG sudo kylin
  passwd -l kylin          # 锁定密码，仅允许密钥登录
'
```

### 4.5 注入 SSH 公钥

Lima 默认公钥文件为 `~/.lima/_config/user.pub`：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuLcFQQPD3DypWFDT+lvfzaIxwhpHcM7m7LUTugM7CU lima
```

**注意写入 `/data` 分区，而非 `/root` / `/home`**（原因见第三章关键点 1）：

```bash
limactl shell builder -- sudo sh -c '
  # root 用户
  install -d -m 700 /mnt/data/root/.ssh
  printf "%s\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuLcFQQPD3DypWFDT+lvfzaIxwhpHcM7m7LUTugM7CU lima" \
    > /mnt/data/root/.ssh/authorized_keys
  chmod 600 /mnt/data/root/.ssh/authorized_keys

  # kylin 用户
  install -d -m 700 -o 501 -g 501 /mnt/data/home/kylin
  install -d -m 700 -o 501 -g 501 /mnt/data/home/kylin/.ssh
  printf "%s\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuLcFQQPD3DypWFDT+lvfzaIxwhpHcM7m7LUTugM7CU lima" \
    > /mnt/data/home/kylin/.ssh/authorized_keys
  chown 501:501 /mnt/data/home/kylin/.ssh/authorized_keys
  chmod 600 /mnt/data/home/kylin/.ssh/authorized_keys
'
```

### 4.6 配置免密 sudo 与 sshd

```bash
chroot /mnt/root /bin/bash -c '
  printf "kylin ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/90-lima-kylin
  chmod 440 /etc/sudoers.d/90-lima-kylin

  cat > /etc/ssh/sshd_config.d/99-lima.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
UseDNS no
EOF

  sshd -t -f /etc/ssh/sshd_config    # 校验配置，返回 rc=0
'
```

`/etc/ssh/sshd_config` 已含 `Include /etc/ssh/sshd_config.d/*.conf`，drop-in 生效。

### 4.7 适配网卡

原 NetworkManager profile 的 `interface-name=enp1s0` 在 Lima 环境下不存在（Lima 注入的是 `eth0`），且未设置自连接。改为不绑定接口名 + 自动连接：

```bash
limactl shell builder -- sudo sh -c '
  f="/mnt/root/etc/NetworkManager/system-connections/有线连接 1.nmconnection"
  cp "$f" /mnt/root/tmp/nm-backup.nmconnection
  sed -i "s/^interface-name=enp1s0/interface-name=/" "$f"
  sed -i "s/^\[connection\]/[connection]\nautoconnect=true\nautoconnect-priority=100/" "$f"
'
```

### 4.8 安装 cloud-init

```bash
chroot /mnt/root /bin/bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-init'
```

安装后自动创建 `cloud-init.target.wants` 下的四个服务软链。数据源已包含 `NoCloud`（Lima 使用 NoCloud seed ISO），无需额外配置。

同时关闭 root 锁定，允许密钥方式登录：

```bash
limactl shell builder -- sudo sh -c '
  sed -i "s/^disable_root: true/disable_root: false/" /mnt/root/etc/cloud/cloud.cfg
'
```

### 4.9 关闭 KySec（关键步骤）

首次测试时 cloud-init 与 sshd 均无法启动，syslog 明确记录 KySec 拦截：

```
audit: denied { execute } for pid=575 name='/usr/lib/systemd/system-generators/cloud-init-generator'
       kysec_status=2 lsm=kysec
audit: denied { execute } name='/usr/bin/cloud-init'   kysec_status=2
audit: denied { execute } name='/usr/sbin/sshd'        kysec_status=2

systemd: cloud-config.service: Failed at step EXEC spawning /usr/bin/cloud-init: Permission denied
systemd: ssh.service: Failed at step EXEC spawning /usr/sbin/sshd: Permission denied
```

麒麟 KySec 会对未登记的可执行文件做执行拦截，新安装的 `cloud-init` 与 `sshd` 不在白名单内。

**仅修改 `/etc/kysec/kysec.conf` 无效**——KySec 由内核参数 `security=kysec` 启用。必须清除 GRUB 中的该参数，涉及三处：

```bash
limactl shell builder -- sudo sh -c '
  # 1. ESP 引导配置
  cp /mnt/efi/boot/grub/grub.cfg /mnt/efi/boot/grub/grub.cfg.bak
  sed -i "s/ security=kysec//g" /mnt/efi/boot/grub/grub.cfg

  # 2. /boot 引导配置
  cp /mnt/boot/grub/grub.cfg /mnt/boot/grub/grub.cfg.bak
  sed -i "s/ security=kysec//g" /mnt/boot/grub/grub.cfg

  # 3. grub 默认参数（避免后续 mkconfig 重新写回）
  sed -i "s/^GRUB_CMDLINE_LINUX_SECURITY=\".*\"/GRUB_CMDLINE_LINUX_SECURITY=\"\"/" \
    /mnt/root/etc/default/grub
'
```

同时修正配置文件（使其与内核参数状态一致）：

```bash
limactl shell builder -- sudo sh -c '
  sed -i "s/security = \"kysec,selinux\"/security = \"selinux\"/" /mnt/root/etc/kysec/kysec.conf
  sed -i "s/kysec_status = 2/kysec_status = 0/" /mnt/root/etc/kysec/kysec.conf
  sed -i "s/kysec_exectl = 2/kysec_exectl = 0/" /mnt/root/etc/kysec/kysec.conf
'
```

### 4.10 绕过被拦截的 cloud-init generator

即使关闭 KySec，仍建议显式建立 cloud-init target 软链，避免因 generator 执行异常导致 cloud-init 链路不启动。

generator 正常工作时会在 `/run` 下动态生成此软链，本步骤将其静态固化到磁盘：

```bash
limactl shell builder -- sudo sh -c '
  ln -snf /lib/systemd/system/cloud-init.target \
    /mnt/root/etc/systemd/system/multi-user.target.wants/cloud-init.target
'
```

### 4.11 卸载与完整性校验

```bash
limactl shell builder -- sudo sh -c '
  sync
  umount /mnt/root/dev /mnt/root/proc /mnt/root/sys /mnt/root/run
  umount /mnt/data /mnt/boot /mnt/efi /mnt/root
  vgchange -an kylin-vg
  qemu-nbd -d /dev/nbd0
'

# 完整性校验
limactl shell builder -- qemu-img check .../kylinv10-lima.qcow2
# → No errors were found on the image.
```

### 4.12 部署到镜像目录并验证

```bash
# 放入镜像目录（使用规范命名）
cp tmp/kylin-debug/kylinv10-lima.qcow2 \
   qcow2s/Kylin-Desktop-V10-SP1-2503-Release-20250417-ARM64-lima.qcow2

# 部署
cd vm_deploy && ./deploy_vms.sh deploy kylin-v10
```

## 五、验证结果

### 5.1 部署日志

```
[INFO] [5-6] machine1 已就绪: ssh machine1
[INFO] [6-6] VM machine1 guest IP: 192.168.5.15
[INFO] [6-6] 写入 machine1 的 VM 内 /etc/hosts
[INFO] [6-6] 为 machine1 配置 SSH 登录用户 root（基于 kylin 的密钥）
[INFO] [6-6] 机器配置信息已保存: vm_deploy/虚拟机配置信息.md
[INFO] [6-6] =========== 部署完成 ===========
```

### 5.2 虚机内核查

```bash
ssh machine1 "hostname; cloud-init status; systemctl is-active ssh; id kylin"
```

| 检查项 | 结果 |
|--------|------|
| 主机名 | `lima-machine1`（cloud-init 已生效） |
| cloud-init | `status: done` |
| sshd | `active` |
| kylin 用户 | `uid=501(kylin) gid=501(kylin) groups=501,27(sudo)` |
| 网络 | `inet 192.168.5.15/24 ... eth0` |
| 根分区 | `/dev/mapper/kylin--vg-root 56G 11G 43G 20% /` |
| 登录 | root 密钥免密登录成功 |

## 六、配套脚本改动

改造过程中同步修复了 `deploy_vms.sh` 的四处缺陷：

| 位置 | 问题 | 修复 |
|------|------|------|
| `lima_select_image` | 按关键字匹配会选中 X86_64 镜像，在 arm64 宿主机上必然失败 | 新增架构过滤，arm64 上自动跳过文件名含 `x86_64` / `amd64` 的镜像 |
| `create_vms` | 磁盘小于镜像虚拟容量时 Lima 报 `specified size smaller than original image size` 并失败 | 新增 `qcow2_virtual_size_gib()` 读取 qcow2 头部虚拟容量，自动上调磁盘并告警 |
| `create_vms` | 创建中断的实例（无 `disk` 文件）被误判为「已存在」而跳过，永远起不来 | 检测到无 `disk` 的实例自动 `limactl delete -f` 后重建 |
| `qcow2_virtual_size_gib` | 宿主机未安装 `qemu-img` | 直接解析 qcow2 头部（魔数 `QFI\xfb`，偏移 24 的 8 字节大端整数），不依赖外部工具 |

## 七、注意事项

### 7.1 安全影响

产物镜像已**关闭 KySec**。麒麟的强制访问控制不再生效，仅建议用于测试、开发、实验环境。生产环境需评估：

- 重新启用 KySec 并为其登记白名单（需研究 `kysec-module-authorize.conf` 的授权机制）
- 或改用官方 SP3 服务器版云镜像（自带 cloud-init 与 sshd，无需关闭安全模块）

### 7.2 镜像定位

| 项目 | 说明 |
|------|------|
| 系统版本 | **桌面版** V10 **SP1**（不是服务器版，也不是 SP3） |
| 架构 | aarch64 ✅ |
| 冗余组件 | 含 55 个 UKUI/MATE 相关包、`lightdm`、`graphical.target` 桌面环境 |
| 适用场景 | 能跑服务的 ARM 测试虚机；非生产服务器首选 |

若需「服务器版 SP3 ARM」，应改用官方云镜像。已尝试的 `Kylin-Server-V10-SP3-2403-Release-20240426-ARM64.qcow2` 在本机 VZ 引擎下无法启动（串口 0 字节输出、内核未起来），不能直接使用。

### 7.3 常用维护命令

```bash
# 查看状态
./deploy_vms.sh status

# 登录
ssh machine1

# 重建（销毁后重新部署）
./deploy_vms.sh destroy && ./deploy_vms.sh deploy kylin-v10

# 校验镜像完整性
limactl shell builder -- qemu-img check qcow2s/Kylin-Desktop-V10-SP1-2503-Release-20250417-ARM64-lima.qcow2
```

### 7.4 已知无害告警

虚机内经 SSH 登录时可能看到 `pulseaudio: alsa-util.c: no soundcards found`。原因是 Lima 默认不分配音频设备（`audio.device: null`），而麒麟桌面版自带 pulseaudio 且 `autospawn = yes`。服务器用途可忽略，不影响任何服务。

## 八、改造清单速查

| 类别 | 具体内容 |
|------|---------|
| 安装包 | `openssh-server` 1:8.2p1-4kylin3k1.4update5、`cloud-init` 24.4.1-0kylin0~20.04.3+esm1 |
| 新建用户 | `kylin` uid 501 gid 501，加入 `sudo` 组，密码锁定 |
| 公钥位置 | `/data/root/.ssh/authorized_keys`、`/data/home/kylin/.ssh/authorized_keys` |
| sudo 配置 | `/etc/sudoers.d/90-lima-kylin`（`NOPASSWD:ALL`） |
| sshd 配置 | `/etc/ssh/sshd_config.d/99-lima.conf`（仅密钥登录） |
| 网卡配置 | `有线连接 1.nmconnection` 解除接口绑定 + 开启 autoconnect |
| cloud-init | `disable_root: false`；静态软链 `multi-user.target.wants/cloud-init.target` |
| 安全模块 | 三处 GRUB 移除 `security=kysec`；`kysec.conf` 降级为 `security="selinux"` |
| 产物大小 | 6474760192 字节（约 6.03GiB），虚拟容量 100GiB |
