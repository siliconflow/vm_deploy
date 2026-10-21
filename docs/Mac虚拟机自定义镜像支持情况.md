# 虚拟机自定义镜像支持情况

> 记录时间：2026-10-20
> 环境：macOS（Apple Silicon，aarch64）+ Multipass + colima/Lima（limactl 2.2.0）

## 结论

**需要安装指定镜像（如麒麟 V10）的虚拟机时：Lima 可以，Multipass 不行。**

| 工具 | 是否支持自定义镜像 | 说明 |
|---|---|---|
| Multipass | 不支持 | 仅提供 Ubuntu 官方镜像（`multipass find`），无镜像导入机制 |
| Lima（colima 底层引擎） | 支持 | 通过模板 YAML 指定任意云镜像（qcow2/raw），配合 cloud-init 初始化 |

## 两者定位

| | Multipass | Lima / colima |
|---|---|---|
| 虚拟化引擎 | Apple Virtualization Framework | Lima（底层同为 Virtualization Framework） |
| 镜像来源 | 仅 Ubuntu 官方镜像 | 任意 qcow2/raw 云镜像 |
| 适用场景 | 快速搭建 Ubuntu 开发/K8s 节点 | 需要国产化/自定义系统镜像的场景 |

## 麒麟 V10 做法（Lima）

前置条件：麒麟官方/授权渠道获取 ARM64（aarch64）qcow2 云镜像；V10 支持 cloud-init，与 Lima 兼容。

模板示例 `kylin-v10.yaml`：

```yaml
images:
  - location: "https://xxx/kylin-v10-aarch64.qcow2"   # 麒麟云镜像地址
    arch: "aarch64"
cpus: 2
memory: "4GiB"
disk: "20GiB"
containerd:
  system: false   # 纯 VM 用途关闭 containerd
  user: false
```

命令：

```bash
limactl create ./kylin-v10.yaml --name kylin
limactl start kylin
limactl shell kylin
```

## 备注

- 本机现有虚拟机分工：Multipass 管理 K3s 集群（k3s-master/worker1/worker2），colima 管理 Docker（容器 openclaw-webui）。
- 如需将麒麟 VM 的创建/启停/删除固化成脚本，可参照仓库脚本规范新增 `lima_manager.sh`。
