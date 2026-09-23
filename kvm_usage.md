# KVM 虚拟机常用命令

## 查看虚拟机

```bash
# 查看所有虚拟机
virsh list --all

# 只查看正在运行的虚拟机
virsh list

# 查看单台虚拟机状态
virsh domstate machine1
```

## 启动虚拟机

```bash
# 启动单台虚拟机
virsh start machine1

# 使用脚本启动所有虚拟机
./start_vms.sh
```

## 停止虚拟机

```bash
# 优雅关机单台虚拟机
virsh shutdown machine1

# 使用脚本停止所有虚拟机
./stop_vms.sh
```

## 重启虚拟机

```bash
virsh reboot machine1
```

## 查看虚拟机详情

```bash
virsh dominfo machine1
```

## 删除虚拟机

删除前注意保存重要数据！！！

```bash
# 如果虚拟机正在运行，先优雅关机
virsh shutdown machine1

# 如果无法正常关机，可强制断电
virsh destroy machine1

# 删除虚拟机定义，并删除关联存储
virsh undefine machine1 --remove-all-storage
```

也可以使用项目脚本删除全部虚拟机：

```bash
./vm_deploy.sh destroy
```

执行前会有危险提示和确认，输入 `yes` 才会继续。

## 进入控制台

```bash
virsh console machine1
```

