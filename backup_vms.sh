#!/bin/bash
#===============================================================================
# 脚本名称: backup_vms.sh
# 功能说明: 备份/恢复本机 libvirt(KVM) 虚拟机
#           备份模式（默认）:
#           - 自动发现本机所有虚机（virsh list --all），无需手动指定
#           - 备份前强制检查：存在运行中的虚机时打印提醒并中断脚本，
#             需先停止虚机（virsh shutdown/destroy）后再执行备份
#           - 关机的虚机: qemu-img convert 稀疏拷贝（不压缩），实时打印进度百分比
#           - 每台虚机同时保存 XML 定义(domain.xml)和 seed.iso
#           恢复模式（--restore）:
#           - 从指定（或最新）备份集恢复虚机：还原磁盘到原始路径、
#             还原 seed.iso、virsh define 重新定义虚机
#           - 恢复前虚机必须处于关闭状态，脚本会先 undefine 再还原
# 使用说明: ./backup_vms.sh [模式] [选项]
# 参数说明:
#   备份模式（默认，不带 --restore）:
#   -h, --help          显示帮助
#   --vms "a b c"       只备份指定的虚机（默认自动发现全部虚机）
#   --dry-run           预览模式，只打印将执行的操作，不实际备份
#   --clean             清洁执行：清空本脚本管理的备份目录后重新完整备份
#   --yes               非交互模式，自动确认所有二次确认
#   恢复模式:
#   --restore           进入恢复模式
#   --set <set_id>      指定要恢复的备份集 ID（如 set_20261014_141905），默认用最新
#   --vms "a b c"       只恢复指定的虚机（默认恢复备份集中的全部虚机）
#   --start             恢复完成后自动启动虚机（virsh start）
#   通用:
#   --list              列出所有备份集及内容后退出
# 依赖说明: virsh, qemu-img, awk, df
# 配置文件: 同目录 backup_vms.env（自动加载，可修改备份目录/保留策略等）
# 日志目录: 同目录 logs/，文件名 backup_vms_YYYYMMDD_HHMMSS.log
# 产物目录: BACKUP_DIR/set_YYYYMMDD_HHMMSS/<虚机名>/ 下包含:
#           - <磁盘目标名>.qcow2   磁盘镜像备份（如 vda.qcow2）
#           - domain.xml           虚机 XML 定义（virsh define 恢复用）
#           - seed.iso             cloud-init 种子盘
#           - 临时文件放同目录 tmp/；断点状态放同目录 state/backup_vms/
# 示例命令:
#   ./backup_vms.sh                              # 自动发现并备份全部虚机
#   ./backup_vms.sh --vms "machine2"             # 只备份指定虚机
#   ./backup_vms.sh --dry-run                    # 预览将执行的操作
#   ./backup_vms.sh --list                       # 查看已有备份集
#   ./backup_vms.sh --restore                    # 从最新备份集恢复全部虚机
#   ./backup_vms.sh --restore --set set_20261014_141905 --vms "machine1" --start
#   ./backup_vms.sh --clean --yes                # 清空旧备份后重新备份
# 风险提示:
#   1. 保留策略会删除超出 RETENTION_COUNT 的旧备份集（目录级删除），非交互环境
#      必须配合 --yes 才会执行删除
#   2. --clean 会清空 BACKUP_DIR 下所有备份集，属于危险操作，需二次确认
#   3. 恢复模式会覆盖虚机原始磁盘文件并 undefine 现有虚机定义，属于危险操作，
#      需二次确认；恢复前虚机必须处于关闭状态
#   4. 备份要求所有虚机处于关闭状态，存在运行中虚机时脚本会中断
#   5. 备份过程会占用磁盘 IO，属离线操作不影响虚机内业务
#===============================================================================
set -o pipefail

#---------------------------------------
# 1. 路径初始化（全部基于脚本所在目录）
#---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LOG_DIR="$ROOT_DIR/logs"
TMP_DIR="$ROOT_DIR/tmp"
STATE_DIR="$ROOT_DIR/state/backup_vms"
ENV_FILE="$ROOT_DIR/$(basename "${BASH_SOURCE[0]%.*}").env"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

DEFAULT_BACKUP_DIR="/data/kvm/backups"

#---------------------------------------
# 日志函数（统一时间戳格式）
#---------------------------------------
TS() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "[$(TS)] [INFO] $*"; }
log_warn()  { echo "[$(TS)] [WARN] $*"; }
log_error() { echo "[$(TS)] [ERROR] $*"; }

#---------------------------------------
# 2. 配置加载
#---------------------------------------
if [ -f "$ENV_FILE" ]; then
    log_info "加载配置文件: $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    log_warn "配置文件不存在: $ENV_FILE，使用内置默认值"
fi

BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
RETENTION_COUNT="${RETENTION_COUNT:-2}"
VERIFY_BACKUP="${VERIFY_BACKUP:-1}"
SPACE_MARGIN_PERCENT="${SPACE_MARGIN_PERCENT:-20}"

# 运行期变量
MODE="backup"        # backup | restore | list
DRY_RUN=0
CLEAN_RUN=0
ASSUME_YES=0
START_AFTER_RESTORE=0
CLI_VM_FILTER=""
RESTORE_SET_ID=""
SET_ID=""
SET_DIR=""
TOTAL_OK=0; TOTAL_FAIL=0; TOTAL_SKIP=0
FAIL_DETAILS=()

#---------------------------------------
# 3. 参数解析
#---------------------------------------
usage() {
    grep -E '^# (使用说明|参数说明|示例命令):' -A 25 "$0" 2>/dev/null | sed 's/^# \{0,1\}//' | head -45
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --restore) MODE="restore" ;;
        --list)    MODE="list" ;;
        --set)     shift; RESTORE_SET_ID="$1" ;;
        --start)   START_AFTER_RESTORE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --clean)   CLEAN_RUN=1 ;;
        --yes)     ASSUME_YES=1 ;;
        --vms)     shift; CLI_VM_FILTER="$1" ;;
        *)         log_error "未知参数: $1"; usage; exit 1 ;;
    esac
    shift
done

#---------------------------------------
# 确认函数（危险操作二次确认；--yes 或 --dry-run 时跳过）
#---------------------------------------
confirm() {
    local msg="$1"
    if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    read -r -p "$(echo -e "$msg [y/N]: ")" answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

#---------------------------------------
# 通用辅助: 虚机磁盘列表 / XML 解析 / 空间预估
#---------------------------------------
# 用法: vm_disk_list <虚机名>  输出: TAB 分隔的 磁盘目标名<TAB>源路径
vm_disk_list() {
    virsh domblklist "$1" --details 2>/dev/null \
        | awk '$1=="file" && $2=="disk" {print $3"\t"$4}'
}

# 用法: vm_state <虚机名>  输出: 运行状态
vm_state() {
    virsh domstate "$1" 2>/dev/null || echo unknown
}

# 用法: parse_disk_map <domain.xml>  输出: TAB 分隔的 磁盘目标名<TAB>源路径
parse_disk_map() {
    awk '
        /<disk /              { in_disk=1; dev=""; src=""; is_data_disk=0 }
        in_disk && /device=.disk./   { is_data_disk=1 }
        in_disk && /<target/  { if (match($0, /dev=.[^'\'']+./)) dev=substr($0, RSTART+5, RLENGTH-6) }
        in_disk && /<source/  { if (match($0, /file=.[^'\'']+./)) src=substr($0, RSTART+6, RLENGTH-7) }
        in_disk && /<\/disk>/ { if (is_data_disk && dev!="" && src!="") print dev"\t"src; in_disk=0 }
    ' "$1"
}

# 用法: parse_cdrom_src <domain.xml>  输出: cdrom 源路径（可能为空）
parse_cdrom_src() {
    awk '
        /<disk /                    { in_disk=1; src=""; is_cdrom=0 }
        in_disk && /device=.cdrom./ { is_cdrom=1 }
        in_disk && /<source/        { if (match($0, /file=.[^'\'']+./)) src=substr($0, RSTART+6, RLENGTH-7) }
        in_disk && /<\/disk>/       { if (is_cdrom && src!="") print src; in_disk=0 }
    ' "$1" | head -1
}

# 用法: estimate_vm_space_mb <虚机名>  输出: 预估所需空间(MB)
estimate_vm_space_mb() {
    local vm="$1" total=0 actual
    while IFS=$'\t' read -r _target src; do
        [ -z "$src" ] && continue
        actual=$(qemu-img info --output=json "$src" 2>/dev/null \
            | grep -o '"actual-size": [0-9]*' | tail -1 | tr -dc 0-9)
        total=$(( total + ${actual:-0} / 1024 / 1024 ))
    done < <(vm_disk_list "$vm")
    echo "$total"
}

#---------------------------------------
# 4. 前置检查
#---------------------------------------
check_dep() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "缺少依赖命令: $1，请先安装"
        exit 1
    fi
}

#---------------------------------------
# 5. 日志初始化
#---------------------------------------
mkdir -p "$LOG_DIR" "$TMP_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/backup_vms_$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info "=============================================="
log_info "脚本启动: $SCRIPT_NAME （模式: $MODE）"
log_info "日志文件: $LOG_FILE"
log_info "运行参数: dry_run=$DRY_RUN clean=$CLEAN_RUN assume_yes=$ASSUME_YES vm_filter=[$CLI_VM_FILTER] restore_set=[$RESTORE_SET_ID]"

#---------------------------------------
# 6. 依赖与权限检查
#---------------------------------------
log_info "[1-6] 开始依赖与权限检查"
if [ "$(id -u)" -ne 0 ]; then
    log_error "[1-6] 必须以 root 身份运行（libvirt 系统级连接需要权限）"
    exit 1
fi
check_dep virsh
check_dep qemu-img
check_dep awk
check_dep tee
if [ "$RETENTION_COUNT" -lt 1 ] 2>/dev/null; then
    log_error "[1-6] RETENTION_COUNT 配置非法: $RETENTION_COUNT（必须 >= 1）"
    exit 1
fi
log_info "[1-6] 依赖与权限检查通过"

#---------------------------------------
# --list 模式: 列出备份集
#---------------------------------------
if [ "$MODE" = "list" ]; then
    log_info "备份集清单（$BACKUP_DIR）:"
    found_any=0
    for d in "$BACKUP_DIR"/set_*; do
        [ -d "$d" ] || continue
        found_any=1
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        vms=$(ls -1 "$d" 2>/dev/null | tr '\n' ' ')
        complete="未完成"
        [ -f "$d/.complete" ] && complete="已完成"
        log_info "  $(basename "$d")  [${complete}]  大小: ${size}  虚机: ${vms:-无}"
    done
    [ "$found_any" -eq 0 ] && log_info "  （没有任何备份集）"
    exit 0
fi

#---------------------------------------
# 7. 模式分支: 恢复 / 备份
#---------------------------------------
if [ "$MODE" = "restore" ]; then
    #===============================================
    # 恢复流程
    #===============================================
    log_info "[2-6] 恢复模式: 定位备份集"

    # 确定备份集
    if [ -n "$RESTORE_SET_ID" ]; then
        SET_ID="$RESTORE_SET_ID"
    else
        SET_ID=$(ls -1d "$BACKUP_DIR"/set_* 2>/dev/null | sort | tail -1 | xargs basename 2>/dev/null || true)
        if [ -z "$SET_ID" ]; then
            log_error "[2-6] $BACKUP_DIR 下没有任何备份集，无法恢复"
            exit 1
        fi
        log_info "[2-6] 未指定 --set，使用最新备份集: $SET_ID"
    fi
    SET_DIR="$BACKUP_DIR/$SET_ID"
    if [ ! -d "$SET_DIR" ]; then
        log_error "[2-6] 备份集不存在: $SET_DIR"
        exit 1
    fi

    # 收集备份集中可恢复的虚机（有 domain.xml 的），再按 --vms 过滤
    RESTORE_VMS=""
    for d in "$SET_DIR"/*/; do
        name=$(basename "$d")
        [ -f "$d/domain.xml" ] || { log_warn "[2-6] 跳过 $name: 缺少 domain.xml"; continue; }
        if [ -n "$CLI_VM_FILTER" ]; then
            echo "$CLI_VM_FILTER" | grep -qw "$name" || continue
        fi
        RESTORE_VMS="$RESTORE_VMS $name"
    done
    RESTORE_VMS="${RESTORE_VMS# }"
    if [ -z "$RESTORE_VMS" ]; then
        log_error "[2-6] 备份集中没有匹配的虚机可恢复（备份集: $SET_ID，过滤: [$CLI_VM_FILTER]）"
        exit 1
    fi

    # 前置检查: 待恢复虚机必须已关机（存在时）
    for vm in $RESTORE_VMS; do
        st=$(vm_state "$vm")
        if [ "$st" != "shut off" ] && [ "$st" != "关闭" ] && [ "$st" != "unknown" ]; then
            log_error "[2-6] 虚机 $vm 当前状态为 [$st]，恢复前必须先关闭（virsh shutdown/destroy ${vm}）"
            exit 1
        fi
    done

    # 预览恢复计划
    log_info "[2-6] 恢复计划:"
    for vm in $RESTORE_VMS; do
        log_info "  虚机: $vm  <-  $SET_DIR/$vm"
        while IFS=$'\t' read -r dev src; do
            log_info "    磁盘 $dev -> $src"
        done < <(parse_disk_map "$SET_DIR/$vm/domain.xml")
    done

    # 危险操作二次确认
    log_warn "[2-6] 恢复操作将: undefine 现有同名虚机（如有）、覆盖虚机原始磁盘文件！"
    if ! confirm "[2-6] 确认执行以上恢复计划?"; then
        log_error "[2-6] 用户取消恢复操作"
        exit 1
    fi

    log_info "[3-6] 开始逐虚机恢复"
    VM_TOTAL=$(echo "$RESTORE_VMS" | wc -w)
    VM_IDX=0
    for vm in $RESTORE_VMS; do
        VM_IDX=$(( VM_IDX + 1 ))
        vm_dir="$SET_DIR/$vm"
        log_info "[$VM_IDX-$VM_TOTAL vm] 恢复虚机: $vm"

        # undefine 现有定义（存在时）
        if virsh dominfo "$vm" >/dev/null 2>&1; then
            log_info "    [undefine] 虚机已存在，先移除定义: $vm"
            if [ "$DRY_RUN" -eq 0 ]; then
                if ! virsh undefine "$vm" >/dev/null 2>&1; then
                    if ! virsh undefine --nvram "$vm" >/dev/null 2>&1; then
                        log_error "    [失败] virsh undefine 失败: $vm"
                        FAIL_DETAILS+=("$vm: undefine 失败")
                        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
                        continue
                    fi
                fi
            fi
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log_info "    [预览] 将还原磁盘并 define 虚机 $vm"
            TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
            continue
        fi

        # 还原磁盘: qemu-img convert 回原始路径
        vm_ok=1
        while IFS=$'\t' read -r dev src; do
            bak_file="$vm_dir/$dev.qcow2"
            if [ ! -f "$bak_file" ]; then
                log_error "    [失败] 备份文件缺失: $bak_file"
                FAIL_DETAILS+=("$vm: 缺少 $dev 备份文件")
                vm_ok=0
                continue
            fi
            mkdir -p "$(dirname "$src")"
            log_info "    [还原] $bak_file -> $src"
            if ! qemu-img convert -p -S 4k -O qcow2 "$bak_file" "$src"; then
                log_error "    [失败] 磁盘还原失败: $vm/$dev"
                FAIL_DETAILS+=("$vm: 磁盘 $dev 还原失败")
                vm_ok=0
            fi
        done < <(parse_disk_map "$vm_dir/domain.xml")

        # 还原 seed.iso（原始路径缺失且备份集中存在时）
        cdrom_src=$(parse_cdrom_src "$vm_dir/domain.xml")
        if [ -n "$cdrom_src" ] && [ ! -f "$cdrom_src" ] && [ -f "$vm_dir/seed.iso" ]; then
            mkdir -p "$(dirname "$cdrom_src")"
            cp -f "$vm_dir/seed.iso" "$cdrom_src" \
                && log_info "    [还原] seed.iso -> $cdrom_src" \
                || { log_error "    [失败] seed.iso 还原失败: $cdrom_src"; vm_ok=0; }
        fi

        # 重新定义虚机
        if [ "$vm_ok" -eq 1 ]; then
            if virsh define "$vm_dir/domain.xml" >/dev/null 2>&1; then
                log_info "    [define] 虚机定义已恢复: $vm"
            else
                log_error "    [失败] virsh define 失败: $vm"
                FAIL_DETAILS+=("$vm: define 失败")
                vm_ok=0
            fi
        fi

        if [ "$vm_ok" -eq 1 ]; then
            TOTAL_OK=$(( TOTAL_OK + 1 ))
            log_info "    [成功] $vm 恢复完成"
            if [ "$START_AFTER_RESTORE" -eq 1 ]; then
                if virsh start "$vm" >/dev/null 2>&1; then
                    log_info "    [启动] $vm 已启动"
                else
                    log_warn "    [启动] $vm 启动失败，请手动检查（不影响恢复结果）"
                fi
            fi
        else
            TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
        fi
    done

    log_info "[4-6] 恢复模式无需校验与保留策略，跳过（阶段 4/5）"
    log_info "[6-6] 恢复结果汇总"
    log_info "[6-6] 成功: $TOTAL_OK  失败: $TOTAL_FAIL  跳过(含预览): $TOTAL_SKIP"
    if [ ${#FAIL_DETAILS[@]} -gt 0 ]; then
        log_error "[6-6] 失败项详细信息:"
        for d in "${FAIL_DETAILS[@]}"; do log_error "    - $d"; done
    fi
    log_info "脚本结束: $SCRIPT_NAME"
    [ "$TOTAL_FAIL" -gt 0 ] && exit 1
    exit 0
fi

#===============================================
# 备份流程（默认模式）
#===============================================

#---------------------------------------
# 阶段2-6: 自动发现虚机
#---------------------------------------
log_info "[2-6] 自动发现本机所有虚机"
DISCOVERED_VMS=$(virsh list --all --name 2>/dev/null | sed '/^$/d')
if [ -z "$DISCOVERED_VMS" ]; then
    log_error "[2-6] 未发现任何虚机（virsh list --all 为空）"
    exit 1
fi
log_info "[2-6] 发现虚机: $(echo "$DISCOVERED_VMS" | tr '\n' ' ')"

VM_LIST="$DISCOVERED_VMS"
if [ -n "$CLI_VM_FILTER" ]; then
    VM_LIST=""
    for f in $CLI_VM_FILTER; do
        if echo "$DISCOVERED_VMS" | grep -qw "$f"; then
            VM_LIST="$VM_LIST $f"
        else
            log_error "[2-6] --vms 指定的虚机不存在: $f"
            exit 1
        fi
    done
    VM_LIST="${VM_LIST# }"
fi
log_info "[2-6] 待备份虚机: $(echo "$VM_LIST" | tr '\n' ' ')"

# 强制检查: 所有待备份虚机必须处于关闭状态，否则提醒并中断
RUNNING_VMS=""
for vm in $VM_LIST; do
    st="$(vm_state "$vm")"
    if [ "$st" != "shut off" ] && [ "$st" != "关闭" ]; then
        RUNNING_VMS="$RUNNING_VMS $vm($st)"
    fi
done
if [ -n "$RUNNING_VMS" ]; then
    log_warn "[2-6] 以下虚机未停止，无法执行备份:"
    for rv in $RUNNING_VMS; do
        log_warn "      - $rv"
    done
    log_warn "[2-6] 请先停止虚机后再执行备份，停止方式:"
    log_warn "      一键停止全部虚机: ./manage_vms.sh stop"
    log_warn "      或逐台优雅关机:"
    for vm in $RUNNING_VMS; do
        log_warn "      virsh shutdown $(echo "$vm" | cut -d'(' -f1)"
    done
    log_warn "      （或 virsh destroy <虚机名> 强制断电；关机后重新运行本脚本）"
    log_error "[2-6] 存在运行中的虚机，脚本中断"
    exit 1
fi
log_info "[2-6] 虚机状态检查通过: 所有待备份虚机均已关闭"

# 校验每台虚机的磁盘
for vm in $VM_LIST; do
    if [ -z "$(vm_disk_list "$vm")" ]; then
        log_error "[2-6] 虚机 $vm 没有可备份的 qcow2 磁盘（domblklist 为空）"
        exit 1
    fi
    while IFS=$'\t' read -r _t src; do
        if [ ! -f "$src" ]; then
            log_error "[2-6] 虚机 $vm 磁盘文件不存在: $src"
            exit 1
        fi
    done < <(vm_disk_list "$vm")
done

#---------------------------------------
# 阶段3-6: 前置检查（目录、清洁执行、空间、断点续跑）
#---------------------------------------
log_info "[3-6] 开始前置检查"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR" || { log_error "[3-6] 备份目录创建失败: $BACKUP_DIR"; exit 1; }
    if [ ! -w "$BACKUP_DIR" ]; then
        log_error "[3-6] 备份目录不可写: $BACKUP_DIR"
        exit 1
    fi
fi

# 清洁执行
if [ "$CLEAN_RUN" -eq 1 ]; then
    log_warn "[3-6] --clean 模式: 将清理以下路径（仅限本脚本管理的目录）:"
    log_warn "      1) $BACKUP_DIR/set_* （全部历史备份集）"
    log_warn "      2) $STATE_DIR （断点状态文件）"
    if confirm "[3-6] 确认清空以上路径并重新完整备份?"; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -rf "${BACKUP_DIR:?}"/set_* "$STATE_DIR"
            mkdir -p "$BACKUP_DIR" "$STATE_DIR"
        fi
        log_info "[3-6] 清理完成"
    else
        log_error "[3-6] 用户取消 --clean 操作"
        exit 1
    fi
fi

# 断点续跑: 上次未完成的备份集存在时复用，跳过已完成虚机
SET_ID=""
last_set=$(cat "$STATE_DIR/latest_set" 2>/dev/null || true)
if [ -n "$last_set" ] && [ -d "$BACKUP_DIR/$last_set" ] && [ ! -f "$BACKUP_DIR/$last_set/.complete" ]; then
    SET_ID="$last_set"
    log_warn "[3-6] 发现未完成的备份集 $SET_ID，本次将续跑（已完成虚机自动跳过）"
fi
if [ -z "$SET_ID" ]; then
    SET_ID="set_$(date '+%Y%m%d_%H%M%S')"
fi
SET_DIR="$BACKUP_DIR/$SET_ID"

# 空间预估
ESTIMATE_MB=0
for vm in $VM_LIST; do
    est=$(estimate_vm_space_mb "$vm")
    log_info "[3-6] $vm 预估备份空间: ${est}MB"
    ESTIMATE_MB=$(( ESTIMATE_MB + est ))
done
ESTIMATE_MB=$(( ESTIMATE_MB * (100 + SPACE_MARGIN_PERCENT) / 100 ))
df_target="$BACKUP_DIR"
while [ ! -d "$df_target" ] && [ "$df_target" != "/" ]; do
    df_target="$(dirname "$df_target")"
done
AVAIL_MB=$(df -Pm "$df_target" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAIL_MB" ] && [ "$ESTIMATE_MB" -gt "$AVAIL_MB" ]; then
    log_error "[3-6] 磁盘空间不足: 预估需要 ${ESTIMATE_MB}MB（含 ${SPACE_MARGIN_PERCENT}% 余量），可用仅 ${AVAIL_MB}MB"
    exit 1
fi
log_info "[3-6] 空间检查通过: 预估需要 ${ESTIMATE_MB}MB，可用 ${AVAIL_MB:-未知}MB"

#---------------------------------------
# 阶段4-6: 逐虚机备份（打印进度、幂等续跑）
#---------------------------------------
log_info "[4-6] 开始逐虚机备份（备份集: $SET_ID）"
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$SET_DIR"
    echo "$SET_ID" > "$STATE_DIR/latest_set"
fi

VM_TOTAL=$(echo "$VM_LIST" | wc -w)
VM_IDX=0
for vm in $VM_LIST; do
    VM_IDX=$(( VM_IDX + 1 ))
    vm_state_now="$(vm_state "$vm")"
    out_dir="$SET_DIR/$vm"
    log_info "[$VM_IDX-$VM_TOTAL vm] 处理虚机: $vm （状态: ${vm_state_now}）"

    # 断点续跑: 已完成则跳过
    if [ -f "$STATE_DIR/${SET_ID}.done" ] && grep -qw "$vm" "$STATE_DIR/${SET_ID}.done" 2>/dev/null; then
        log_info "    [跳过] $vm 在上次执行中已完成（断点续跑）"
        TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "    [预览] 将创建目录: $out_dir 并保存 XML/seed.iso/磁盘镜像"
        log_info "    [预览] 关机虚机: 将执行 qemu-img convert 稀疏拷贝（不压缩，-p 实时进度）"
        TOTAL_SKIP=$(( TOTAL_SKIP + 1 ))
        continue
    fi

    mkdir -p "$out_dir"

    # 保存 XML 定义与 seed.iso
    if ! virsh dumpxml "$vm" > "$out_dir/domain.xml"; then
        log_error "    [失败] 导出 XML 定义失败: $vm"
        FAIL_DETAILS+=("$vm: dumpxml 失败")
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
        continue
    fi
    while IFS=$'\t' read -r _t src; do
        seed_dir="$(dirname "$src")"
        if [ -f "$seed_dir/seed.iso" ]; then
            cp -f "$seed_dir/seed.iso" "$out_dir/seed.iso"
            log_info "    [保存] seed.iso -> $out_dir/seed.iso"
        fi
        break
    done < <(vm_disk_list "$vm")

    # 执行备份（前置检查已确保所有虚机关闭，此处仅做防御）
    vm_backup_ok=0
    case "$vm_state_now" in
        shut\ off|关闭)
            vm_backup_ok=1
            while IFS=$'\t' read -r target src; do
                [ -z "$target" ] && continue
                dst="$out_dir/${target}.qcow2"
                # 幂等: 已存在且有效则跳过
                if [ -f "$dst" ] && qemu-img check -q "$dst" >/dev/null 2>&1; then
                    log_info "    [跳过] $target 已存在且校验有效（续跑）"
                    continue
                fi
                log_info "    [转换] $src -> $dst （不压缩稀疏拷贝，qemu-img 实时进度见下方输出）"
                if ! qemu-img convert -p -S 4k -O qcow2 "$src" "$dst"; then
                    log_error "    [失败] 磁盘转换失败: $vm/$target"
                    FAIL_DETAILS+=("$vm: 磁盘 $target 转换失败")
                    vm_backup_ok=0
                    break
                fi
                log_info "    [完成] $target 转换完成: $(du -sh "$dst" | awk '{print $1}')"
            done < <(vm_disk_list "$vm")
            ;;
        *)
            log_error "    [失败] 虚机状态异常: ${vm_state_now}（跳过 ${vm}，仅支持关闭状态备份）"
            FAIL_DETAILS+=("$vm: 状态 $vm_state_now 不支持备份")
            ;;
    esac

    if [ "$vm_backup_ok" -eq 1 ]; then
        log_info "    [成功] $vm 备份完成"
        TOTAL_OK=$(( TOTAL_OK + 1 ))
        echo "$vm" >> "$STATE_DIR/${SET_ID}.done"
    else
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    fi
done

#---------------------------------------
# 阶段5-6: 备份校验
#---------------------------------------
log_info "[5-6] 开始备份校验"
if [ "$VERIFY_BACKUP" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    verify_fail=0
    while IFS= read -r img; do
        if qemu-img check -q "$img" >/dev/null 2>&1; then
            log_info "    [通过] $(basename "$(dirname "$img")")/$(basename "$img")"
        else
            log_error "    [不通过] $img"
            FAIL_DETAILS+=("校验失败: $img")
            verify_fail=1
        fi
    done < <(find "$SET_DIR" -name '*.qcow2' 2>/dev/null)
    if [ "$verify_fail" -eq 1 ]; then
        log_error "[5-6] 存在校验失败的镜像，请检查上方详细输出"
        TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    else
        log_info "[5-6] 全部镜像校验通过"
    fi
else
    log_info "[5-6] 校验已关闭或预览模式，跳过"
fi

#---------------------------------------
# 阶段6-6: 保留策略清理 + 结果汇总
#---------------------------------------
if [ "$TOTAL_FAIL" -gt 0 ]; then
    log_warn "[6-6] 本次备份存在失败项，跳过保留策略清理（不删除任何旧备份）"
elif [ "$DRY_RUN" -eq 1 ]; then
    old_sets=$(ls -1d "$BACKUP_DIR"/set_* 2>/dev/null | sort | head -n -"$RETENTION_COUNT")
    if [ -n "$old_sets" ]; then
        log_info "[6-6] [预览] 保留策略将删除以下旧备份集:"
        echo "$old_sets" | while read -r s; do log_info "    - $s"; done
    else
        log_info "[6-6] [预览] 没有超出保留数量的旧备份集"
    fi
else
    old_sets=$(ls -1d "$BACKUP_DIR"/set_* 2>/dev/null | sort | head -n -"$RETENTION_COUNT")
    if [ -n "$old_sets" ]; then
        log_warn "[6-6] 以下旧备份集超出保留数量 $RETENTION_COUNT，将被删除:"
        echo "$old_sets" | while read -r s; do log_warn "    - $s"; done
        if confirm "[6-6] 确认删除以上旧备份集?"; then
            echo "$old_sets" | while read -r s; do
                rm -rf "$s" && log_info "    [已删除] $s" || log_error "    [删除失败] $s"
            done
        else
            log_info "[6-6] 用户取消删除，保留所有旧备份集"
        fi
    else
        log_info "[6-6] 没有超出保留数量的旧备份集"
    fi
    # 全部成功时标记备份集完成，清理 latest_set 断点
    if [ "$TOTAL_FAIL" -eq 0 ]; then
        touch "$SET_DIR/.complete"
        rm -f "$STATE_DIR/latest_set"
    fi
fi

log_info "[6-6] 备份结果汇总"
log_info "[6-6] 备份集目录: $SET_DIR"
log_info "[6-6] 成功: $TOTAL_OK  失败: $TOTAL_FAIL  跳过(含预览/续跑): $TOTAL_SKIP"

if [ ${#FAIL_DETAILS[@]} -gt 0 ]; then
    log_error "[6-6] 失败项详细信息:"
    for d in "${FAIL_DETAILS[@]}"; do
        log_error "    - $d"
    done
fi

if [ "$DRY_RUN" -eq 0 ] && [ -d "$SET_DIR" ]; then
    log_info "[6-6] 备份产物清单:"
    du -sh "$SET_DIR"/* 2>/dev/null | while read -r line; do log_info "    $line"; done
    log_info "[6-6] 总占用: $(du -sh "$SET_DIR" 2>/dev/null | awk '{print $1}')"
    log_info "[6-6] 恢复提示: ./backup_vms.sh --restore --set $SET_ID [--vms \"虚机名\"] [--start]（恢复前需先关闭虚机）"
fi

log_info "脚本结束: $SCRIPT_NAME"
if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
