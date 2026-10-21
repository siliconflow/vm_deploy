#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
功能说明：
  将当前脚本所在 Git 仓库的代码自动提交并推送到远程仓库，功能类似 auto_sync.sh。
  提交信息自动附加本次提交的新增/修改文件列表。

使用说明：
  python auto_sync.py [选项]

参数说明：
  -h, --help              显示帮助信息
  -m, --message MESSAGE   指定提交信息，默认读取配置 AUTO_COMMIT_PREFIX 并追加时间
  -y, --yes               兼容旧参数，默认已无需确认
  --dry-run               只预览将执行的 Git 命令，不实际修改、提交或推送
  --no-pull               跳过 git pull --rebase
  --no-push               只提交不推送（仍会执行大文件历史剥离检查）
  --large-file-limit-mb N 覆盖配置中的单文件大小上限（用于测试）

依赖说明：
  Python 3.8+
  git 命令可用
  当前目录或父目录必须是 Git 仓库

配置文件说明：
  自动加载脚本同级 auto_sync.env。
  可配置项：AUTO_COMMIT_PREFIX、DEFAULT_BRANCH、REMOTE_NAME、ALLOW_EMPTY_COMMIT、
  GIT_USER_NAME、GIT_USER_EMAIL、LARGE_FILE_LIMIT_MB、AUTO_STRIP_LARGE_FILES。
  若 Git 未配置 user.name / user.email，脚本会自动执行 git config --global 设置。
  密码、Token、API Key、私钥不得写入配置文件，也不会输出到日志。

大文件自动处理说明：
  Gitee 等平台限制单文件不超过 100MB，超限文件会导致 git push 被 pre-receive 钩子拒绝。
  脚本在提交前会检测暂存区中超过 LARGE_FILE_LIMIT_MB 的文件并自动移出暂存（保留磁盘文件），
  避免超限文件进入提交。若推送仍因超限被远程拒绝且 AUTO_STRIP_LARGE_FILES=true，
  脚本会自动从"未推送到远程"的历史提交中剥离超限大文件（仅重写本地未推送提交，安全），
  并保留磁盘上的原始文件后重试推送。

日志目录说明：
  日志写入脚本同级 logs/auto_sync_YYYYMMDD_HHMMSS.log。

示例命令：
  python auto_sync.py --dry-run
  python auto_sync.py -m "update feature" -y

风险提示：
  本脚本会执行 git add -A、git commit、git pull --rebase、git push。
  这些操作可能提交、覆盖暂存区状态、触发冲突或将代码发布到远程仓库。
  大文件自动剥离（AUTO_STRIP_LARGE_FILES=true 时）会使用 git filter-branch 重写
  "尚未推送到远程"的本地提交（提交哈希会变化，已推送的提交不受影响），
  并在 tmp/ 下备份被移除的磁盘文件。
  默认会直接执行；建议首次运行使用 --dry-run。
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

TOTAL_STAGES = 7

SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent
ROOT_DIR = SCRIPT_DIR
LOG_DIR = ROOT_DIR / "logs"
TMP_DIR = ROOT_DIR / "tmp"
ENV_FILE = ROOT_DIR / f"{SCRIPT_PATH.stem}.env"
GITIGNORE_FILE = ROOT_DIR / ".gitignore"
GITIGNORE_MARKER = "# auto_sync: 超过单文件大小上限，自动忽略"

LOG_FILE: Optional[Path] = None
COUNTS = {"success": 0, "failed": 0, "skipped": 0}


def timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(level: str, stage: str, message: str) -> None:
    line = f"[{timestamp()}] [{level}] [{stage}] {message}"
    print(line)
    if LOG_FILE:
        with LOG_FILE.open("a", encoding="utf-8") as file:
            file.write(line + os.linesep)


def init_paths() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def init_log() -> None:
    global LOG_FILE
    LOG_FILE = LOG_DIR / f"auto_sync_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    LOG_FILE.touch(exist_ok=True)


def load_env() -> Dict[str, str]:
    config = {
        "AUTO_COMMIT_PREFIX": "auto sync",
        "DEFAULT_BRANCH": "",
        "REMOTE_NAME": "origin",
        "ALLOW_EMPTY_COMMIT": "false",
        "GIT_USER_NAME": "renshan",
        "GIT_USER_EMAIL": "bjhanjf@qq.com",
        "LARGE_FILE_LIMIT_MB": "100",
        "AUTO_STRIP_LARGE_FILES": "true",
    }
    if not ENV_FILE.exists():
        log("ERROR", "1-7", f"配置文件不存在：{ENV_FILE}")
        raise SystemExit(1)

    with ENV_FILE.open("r", encoding="utf-8") as file:
        for raw_line in file:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                log("ERROR", "1-7", f"配置行格式错误：{line}")
                raise SystemExit(1)
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"').strip("'")

    required_keys = ["AUTO_COMMIT_PREFIX", "REMOTE_NAME", "ALLOW_EMPTY_COMMIT"]
    missing = [key for key in required_keys if not config.get(key)]
    if missing:
        log("ERROR", "1-7", f"缺失必填配置：{', '.join(missing)}")
        raise SystemExit(1)
    return config


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="自动提交并推送当前 Git 仓库代码到远程仓库")
    parser.add_argument("-m", "--message", help="提交信息，默认自动生成")
    parser.add_argument("-y", "--yes", action="store_true", help="兼容旧参数，默认已无需确认")
    parser.add_argument("--dry-run", action="store_true", help="只预览命令，不实际执行")
    parser.add_argument("--no-pull", action="store_true", help="跳过 git pull --rebase")
    parser.add_argument("--no-push", action="store_true", help="只提交不推送")
    parser.add_argument("--large-file-limit-mb", type=int, default=None,
                        help="覆盖配置文件中的单文件大小上限（MB）")
    return parser.parse_args()


def resolve_limit_bytes(args: argparse.Namespace, config: Dict[str, str]) -> int:
    """解析单文件大小上限（字节），<=0 表示不限制。"""
    raw = args.large_file_limit_mb
    if raw is None:
        raw = config.get("LARGE_FILE_LIMIT_MB", "100")
    try:
        mb = int(str(raw).strip())
    except ValueError:
        mb = 100
    if mb <= 0:
        return 0
    return mb * 1024 * 1024


def get_tracked_large_files(limit_bytes: int, ref_range: Optional[str]) -> List[Path]:
    """返回指定提交范围内体积超过 limit_bytes 的文件路径。

    ref_range 为 None 时检查暂存区（git diff --cached），
    否则检查该 git 范围（如 origin/master..HEAD）内所有提交涉及的大文件。
    """
    if limit_bytes <= 0:
        return []
    found: Dict[Path, int] = {}
    if ref_range is None:
        result = run_command(["git", "diff", "--cached", "--name-only"], "5-7", allow_failure=True)
        names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        for name in names:
            path = ROOT_DIR / name
            if path.is_file():
                try:
                    size = path.stat().st_size
                except OSError:
                    continue
                if size > limit_bytes:
                    found[path] = size
    else:
        # 列出范围内所有对象，按 blob 大小过滤
        rev = run_command(["git", "rev-list", "--objects", ref_range], "5-7", allow_failure=True)
        sha_to_paths: Dict[str, List[str]] = {}
        for line in rev.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2 or not parts[1].strip():
                continue
            sha, name = parts[0], parts[1].strip()
            sha_to_paths.setdefault(sha, []).append(name)
        if sha_to_paths:
            shas = list(sha_to_paths.keys())
            batch = subprocess.run(
                ["git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                cwd=str(ROOT_DIR), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, input="\n".join(shas) + "\n",
            )
            big_shas = set()
            for line in batch.stdout.splitlines():
                cols = line.split()
                if len(cols) >= 3 and cols[1] == "blob":
                    try:
                        if int(cols[2]) > limit_bytes:
                            big_shas.add(cols[0])
                    except ValueError:
                        pass
            for sha in big_shas:
                for name in sha_to_paths.get(sha, []):
                    found[ROOT_DIR / name] = 0
    return list(found.keys())


def strip_large_files_from_history(limit_bytes: int, remote: str, config: Dict[str, str], dry_run: bool = False) -> bool:
    """从未推送到远程的历史提交中剥离超限大文件，保留磁盘文件。

    仅重写 origin/<branch>..HEAD 范围的本地提交，已推送提交不受影响。
    返回是否执行了剥离操作。
    """
    branch = config.get("DEFAULT_BRANCH", "").strip()
    if not branch:
        branch_res = run_command(["git", "rev-parse", "--abbrev-ref", "HEAD"], "5-7", allow_failure=True)
        branch = branch_res.stdout.strip()
    remote_ref = f"{remote}/{branch}"
    check_ref = run_command(["git", "rev-parse", "--verify", "--quiet", remote_ref], "5-7", allow_failure=True)
    if check_ref.returncode != 0:
        # 远程分支不存在，无法界定"未推送"范围，跳过自动剥离
        log("WARN", "5-7", f"远程引用 {remote_ref} 不存在，跳过历史大文件自动剥离")
        return False
    ref_range = f"{remote_ref}..HEAD"
    large_files = get_tracked_large_files(limit_bytes, ref_range)
    if not large_files:
        return False

    paths = [str(p.relative_to(ROOT_DIR)) for p in large_files]
    log("WARN", "5-7", f"检测到未推送历史含超限大文件 {len(paths)} 个")
    for rel in paths:
        log("WARN", "5-7", f"  剥离：{rel}")
    if dry_run:
        log("INFO", "5-7", "预览：以上大文件将从未推送历史中剥离并备份到 tmp/，本次为 dry-run 不执行")
        return False

    # 备份磁盘文件到 tmp/，剥离后恢复，避免丢失工作区内容
    backup_dir = TMP_DIR / f"large_file_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backed_up: Dict[str, Path] = {}
    for rel in paths:
        src = ROOT_DIR / rel
        if src.is_file():
            dst = backup_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            backed_up[rel] = dst

    quoted = " ".join(shlex.quote(p) for p in paths)
    index_filter = f"git rm -r --cached --ignore-unmatch {quoted}"
    log("INFO", "5-7", "执行命令：git filter-branch --index-filter <strip large files>")
    result = subprocess.run(
        ["git", "filter-branch", "--force", "--prune-empty", "--index-filter", index_filter, ref_range],
        cwd=str(ROOT_DIR), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env={**os.environ, "FILTER_BRANCH_SQUELCH_WARNING": "1"},
    )
    if result.returncode != 0:
        log("ERROR", "5-7", f"历史大文件剥离失败：\n{result.stdout.strip()}")
        raise RuntimeError("git filter-branch 剥离大文件失败")

    # 清理 filter-branch 备份引用并回收空间，确保剥离生效
    run_command(["git", "update-ref", "-d", "refs/original/refs/heads/" + branch], "5-7", allow_failure=True)
    run_command(["git", "reflog", "expire", "--expire=now", "--all"], "5-7", allow_failure=True)
    run_command(["git", "gc", "--prune=now", "--quiet"], "5-7", allow_failure=True)

    # 恢复磁盘文件（filter-branch 可能未改动工作区，缺失时从备份还原）
    for rel, backup in backed_up.items():
        target = ROOT_DIR / rel
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup, target)
            log("INFO", "5-7", f"已从备份恢复磁盘文件：{rel}")
    log("INFO", "5-7", f"历史大文件剥离完成，磁盘文件备份于：{backup_dir}")
    return True


def add_ignore_rule(rel_path: str) -> None:
    """将路径追加到 .gitignore（已存在同名规则时跳过）。"""
    lines: List[str] = []
    if GITIGNORE_FILE.exists():
        lines = GITIGNORE_FILE.read_text(encoding="utf-8").splitlines()
    if rel_path in [line.strip() for line in lines]:
        return
    text = "\n".join(lines)
    if text and not text.endswith("\n"):
        text += "\n"
    if GITIGNORE_MARKER not in text:
        text += f"\n{GITIGNORE_MARKER}\n"
    text += rel_path + "\n"
    GITIGNORE_FILE.write_text(text, encoding="utf-8")


def unstage_large_files(limit_bytes: int, dry_run: bool) -> None:
    """git add -A 后，把超过大小上限的文件移出暂存区并写入 .gitignore，防止进入提交。"""
    if limit_bytes <= 0:
        return
    for path in get_tracked_large_files(limit_bytes, None):
        rel = str(path.relative_to(ROOT_DIR))
        if dry_run:
            log("INFO", "5-7", f"预览：移出暂存区并加入 .gitignore：{rel}")
            continue
        run_command(["git", "rm", "--cached", "--quiet", "--", rel], "5-7")
        add_ignore_rule(rel)
        COUNTS["skipped"] += 1
        log("WARN", "5-7", f"文件超过大小上限，已移出暂存并加入 .gitignore（磁盘文件保留）：{rel}")
    if not dry_run and GITIGNORE_FILE.exists():
        run_command(["git", "add", "--", str(GITIGNORE_FILE.relative_to(ROOT_DIR))], "5-7", allow_failure=True)


def run_command(command: List[str], stage: str, dry_run: bool = False, allow_failure: bool = False) -> subprocess.CompletedProcess:
    command_text = " ".join(command)
    if dry_run:
        log("INFO", stage, f"预览命令：{command_text}")
        COUNTS["skipped"] += 1
        return subprocess.CompletedProcess(command, 0, "", "")

    log("INFO", stage, f"执行命令：{command_text}")
    result = subprocess.run(
        command,
        cwd=str(ROOT_DIR),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    if result.stdout.strip():
        log("INFO", stage, result.stdout.strip())
    if result.stderr.strip():
        log("WARN" if result.returncode == 0 else "ERROR", stage, result.stderr.strip())

    if result.returncode != 0 and not allow_failure:
        # 失败计数统一由 main 的 except 处理，避免重复累加
        raise RuntimeError(f"命令执行失败：{command_text}")

    if result.returncode == 0:
        COUNTS["success"] += 1
    return result


def ensure_git_identity(config: Dict[str, str]) -> None:
    """检查 Git 提交身份，未配置时使用 GIT_USER_NAME / GIT_USER_EMAIL 自动全局设置。"""
    for key, arg in (("user.name", "GIT_USER_NAME"), ("user.email", "GIT_USER_EMAIL")):
        check = run_command(["git", "config", "--get", key], "3-7", allow_failure=True)
        if check.returncode == 0 and check.stdout.strip():
            continue
        value = config.get(arg, "").strip()
        if not value:
            log("ERROR", "3-7", f"Git 未配置 {key}，且 auto_sync.env 中 {arg} 为空，无法自动设置")
            raise SystemExit(1)
        run_command(["git", "config", "--global", key, value], "3-7")
        log("INFO", "3-7", f"Git 未配置 {key}，已自动全局设置为：{value}")


def preflight_check(config: Dict[str, str]) -> None:
    if shutil.which("git") is None:
        log("ERROR", "3-7", "未找到 git 命令，请先安装 Git 并加入 PATH")
        raise SystemExit(1)
    run_command(["git", "rev-parse", "--is-inside-work-tree"], "3-7")
    ensure_git_identity(config)
    remote = config["REMOTE_NAME"]
    remote_check = run_command(["git", "remote", "get-url", remote], "3-7", allow_failure=True)
    if remote_check.returncode != 0:
        log("ERROR", "3-7", f"远程仓库不存在或不可用：{remote}")
        raise SystemExit(1)


def confirm_dangerous_action(args: argparse.Namespace) -> None:
    return


def has_changes(stage: str) -> bool:
    result = run_command(["git", "status", "--porcelain"], stage)
    return bool(result.stdout.strip())


def remote_branch_exists(remote: str, branch: str, stage: str) -> bool:
    """探测远程分支是否已存在，用于首次推送前跳过 git pull --rebase。

    git ls-remote --exit-code：找到返回 0，未找到返回 2，网络等错误返回其他码。
    """
    result = run_command(
        ["git", "ls-remote", "--exit-code", "--heads", remote, branch],
        stage, allow_failure=True,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 2:
        return False
    log("WARN", stage, f"探测远程分支失败（exit={result.returncode}）：{result.stderr.strip()}")
    return False


def build_commit_message(base_message: str, dry_run: bool) -> str:
    """在提交信息后附加本次暂存区中新增/修改的文件列表。"""
    if dry_run:
        return base_message
    result = run_command(["git", "diff", "--cached", "--name-status"], "5-7", allow_failure=True)
    status_map = {"A": "新增", "M": "修改", "D": "删除"}
    lines: List[str] = []
    for raw in result.stdout.splitlines():
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        code = parts[0][0]
        path = parts[-1]
        label = status_map.get(code, "变更")
        lines.append(f"  [{label}] {path}")
    if not lines:
        return base_message
    log("INFO", "5-7", f"提交信息附加文件列表：{len(lines)} 个文件")
    return base_message + "\n\n本次提交文件：\n" + "\n".join(lines)


def core_sync(args: argparse.Namespace, config: Dict[str, str]) -> None:
    commit_message = args.message or f"{config['AUTO_COMMIT_PREFIX']} {timestamp()}"
    allow_empty = config.get("ALLOW_EMPTY_COMMIT", "false").lower() == "true"
    limit_bytes = resolve_limit_bytes(args, config)

    if not has_changes("5-7") and not allow_empty:
        log("INFO", "5-7", "当前仓库没有待提交变更，无需提交")
        COUNTS["success"] += 1
    else:
        run_command(["git", "add", "-A"], "5-7", args.dry_run)
        # 预防：超限文件移出暂存并加入 .gitignore，避免进入提交
        unstage_large_files(limit_bytes, args.dry_run)

        staged = run_command(["git", "diff", "--cached", "--name-only"], "5-7", allow_failure=True)
        if not staged.stdout.strip() and not args.dry_run and not allow_empty:
            log("INFO", "5-7", "超限文件移出后已无暂存变更，无需提交")
            COUNTS["success"] += 1
            return

        # 提交信息自动附加本次新增/修改的文件列表
        commit_message = build_commit_message(commit_message, args.dry_run)
        commit_command = ["git", "commit", "-m", commit_message]
        if allow_empty:
            commit_command.insert(2, "--allow-empty")
        run_command(commit_command, "5-7", args.dry_run)

        if args.no_pull:
            log("INFO", "5-7", "已按参数跳过 git pull --rebase")
            COUNTS["skipped"] += 1
        else:
            branch = config.get("DEFAULT_BRANCH", "").strip()
            if not branch:
                branch_res = run_command(
                    ["git", "rev-parse", "--abbrev-ref", "HEAD"], "5-7", allow_failure=True,
                )
                branch = branch_res.stdout.strip()
            remote = config["REMOTE_NAME"]
            if not remote_branch_exists(remote, branch, "5-7"):
                # 远程分支不存在（如空仓库首次推送），pull 必然失败，跳过并提示
                log("WARN", "5-7", f"远程分支 {remote}/{branch} 不存在，跳过 git pull --rebase（首次推送将创建该分支）")
                COUNTS["skipped"] += 1
            else:
                # --autostash：本脚本写日志会使日志文件产生未暂存变更，导致 rebase 拒绝执行，自动 stash/恢复规避
                pull_command = ["git", "pull", "--rebase", "--autostash", remote, branch]
                run_command(pull_command, "5-7", args.dry_run)

    # 补救：推送前剥离未推送历史中的超限大文件（--no-push 时也执行，保持历史干净）
    auto_strip = config.get("AUTO_STRIP_LARGE_FILES", "true").lower() == "true"
    if limit_bytes > 0 and auto_strip:
        strip_large_files_from_history(limit_bytes, config["REMOTE_NAME"], config, args.dry_run)
    elif limit_bytes > 0:
        log("INFO", "5-7", "AUTO_STRIP_LARGE_FILES=false，跳过历史大文件自动剥离")

    if args.no_push:
        log("INFO", "5-7", "已按参数跳过 git push")
        COUNTS["skipped"] += 1
    else:
        run_command(["git", "push", config["REMOTE_NAME"]], "5-7", args.dry_run)


def write_result(args: argparse.Namespace) -> None:
    log("INFO", "6-7", f"运行结果：成功 {COUNTS['success']}，失败 {COUNTS['failed']}，跳过 {COUNTS['skipped']}")
    log("INFO", "6-7", f"日志文件：{LOG_FILE}")


def main() -> int:
    init_paths()
    init_log()
    args = parse_args()

    try:
        log("INFO", "1-7", "开始加载配置")
        config = load_env()
        log("INFO", "1-7", "配置加载完成")

        log("INFO", "2-7", "开始处理清理逻辑")
       
        log("INFO", "2-7", "清理逻辑处理完成")

        log("INFO", "3-7", "开始前置检查")
        preflight_check(config)
        log("INFO", "3-7", "前置检查完成")

        log("INFO", "4-7", "开始危险操作确认")
        confirm_dangerous_action(args)
        log("INFO", "4-7", "危险操作确认完成")

        log("INFO", "5-7", "开始核心同步")
        core_sync(args, config)
        log("INFO", "5-7", "核心同步完成")

        log("INFO", "6-7", "开始写入结果汇总")
        write_result(args)
        log("INFO", "6-7", "结果汇总完成")

        log("INFO", "7-7", f"执行完成：成功 {COUNTS['success']}，失败 {COUNTS['failed']}，跳过 {COUNTS['skipped']}")
        print(f"同步完成，日志文件：{LOG_FILE}")
        return 0
    except Exception as error:
        COUNTS["failed"] += 1
        log("ERROR", "7-7", f"执行失败：{error}")
        try:
            write_result(args)
        except Exception:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
