#!/usr/bin/env bash
# plume-digest installer — 独立日报 / 研究报告工具
#
# 用法:
#   ./install.sh [--global | --base <path>]    安装/更新 digest skill + PLUME_ROOT hooks
#   ./install.sh cron [HH:MM]                   写日报定时任务到 crontab
#   ./install.sh --uninstall [--global|--base]  卸载 skill + hooks
#   附加: --dry-run 只打印不落盘
#
# 目标 .claude 解析优先级: --base <path>/.claude > --global (~/.claude) > 默认仓库级 ($PLUME_ROOT/.claude)
set -euo pipefail

PLUME_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$PLUME_ROOT/config.yml"

# ─── 日志 ───────────────────────────────────────────────
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
info(){ echo "${c_blu}ℹ${c_rst} $*"; }
ok(){   echo "${c_grn}✓${c_rst} $*"; }
warn(){ echo "${c_yel}⚠${c_rst} $*" >&2; }
err(){  echo "${c_red}✗${c_rst} $*" >&2; }

usage(){ sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

# ─── 参数 ───────────────────────────────────────────────
CMD="install"; GLOBAL=false; BASE_DIR=""; CRON_TIME=""; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --global)    GLOBAL=true; shift;;
    --base)      BASE_DIR="$2"; shift 2;;
    --uninstall) CMD="uninstall"; shift;;
    --dry-run)   DRY_RUN=true; shift;;
    cron)        CMD="cron"; shift
                 if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then CRON_TIME="$1"; shift; fi;;
    -h|--help)   usage; exit 0;;
    *)           err "未知参数: $1"; usage; exit 1;;
  esac
done

resolve_target(){
  if   [ -n "$BASE_DIR" ]; then echo "$(cd "$BASE_DIR" 2>/dev/null && pwd || echo "$BASE_DIR")/.claude"
  elif $GLOBAL;            then echo "$HOME/.claude"
  else                          echo "$PLUME_ROOT/.claude"; fi
}

# ─── 写 plume_root 到 config ────────────────────────────
write_plume_root(){
  if $DRY_RUN; then info "  将写入 plume_root=$PLUME_ROOT 到 config.yml"; return 0; fi
  sed -i "s|^plume_root:.*|plume_root: \"$PLUME_ROOT\"|" "$CONFIG"
  ok "  plume_root = $PLUME_ROOT"
}

ensure_data_dirs(){
  if $DRY_RUN; then info "  将创建 data/journal data/reports"; return 0; fi
  mkdir -p "$PLUME_ROOT/data/journal" "$PLUME_ROOT/data/reports"
  ok "  data/{journal,reports} 就位"
}

# ─── 装 skill 软链 ──────────────────────────────────────
install_skill(){
  local target="$1"
  if $DRY_RUN; then info "  将软链 $target/skills/digest → $PLUME_ROOT/skills/digest"; return 0; fi
  mkdir -p "$target/skills"
  ln -sfn "$PLUME_ROOT/skills/digest" "$target/skills/digest"
  ok "  skill 软链: $target/skills/digest"
}

# ─── 合并 hooks 到 settings.json（替换 hooks 字段，保留其他）──
sync_hooks(){
  local settings="$1"
  local hooks_resolved; hooks_resolved="$(sed "s|__PLUME_ROOT__|$PLUME_ROOT|g" "$PLUME_ROOT/hooks/hooks.json")"

  if [ ! -f "$settings" ]; then
    if $DRY_RUN; then info "  将创建 $settings（含 hooks）"; else
      mkdir -p "$(dirname "$settings")"; echo "$hooks_resolved" > "$settings"; ok "  已创建 $settings（含 hooks）"; fi
    return 0
  fi
  if ! command -v jq &>/dev/null; then
    warn "  未找到 jq — 请手动把 hooks/hooks.json 合并进 $settings"; return 0; fi
  if $DRY_RUN; then info "  将合并 hooks 到 $settings"; return 0; fi
  local tmp; tmp="$(mktemp)"
  jq -s '.[0] * { hooks: .[1].hooks }' "$settings" <(echo "$hooks_resolved") > "$tmp" && mv "$tmp" "$settings"
  ok "  hooks 已合并进 $settings"
}

# ─── 命令: install ──────────────────────────────────────
cmd_install(){
  local target; target="$(resolve_target)"
  info "安装 plume-digest → $target"
  write_plume_root
  ensure_data_dirs
  install_skill "$target"
  sync_hooks "$target/settings.json"
  echo ""
  ok "安装完成。"
  info "下一步: ./install.sh cron  配置定时日报（读 config.yml 的 cron_time / default_scope）"
}

# ─── 命令: uninstall ────────────────────────────────────
cmd_uninstall(){
  local target; target="$(resolve_target)"
  info "卸载 plume-digest ← $target"
  if [ -L "$target/skills/digest" ]; then
    $DRY_RUN || rm -f "$target/skills/digest"; ok "  移除 skill 软链"
  fi
  if [ -f "$target/settings.json" ] && command -v jq &>/dev/null; then
    if ! $DRY_RUN; then
      local tmp; tmp="$(mktemp)"
      jq 'del(.hooks)' "$target/settings.json" > "$tmp" && mv "$tmp" "$target/settings.json"
    fi
    ok "  移除 settings.json 的 hooks 字段"
  fi
  local scope; scope="$(grep -oP '^\s*default_scope:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || true)"
  if [ -n "$scope" ] && command -v crontab &>/dev/null; then
    $DRY_RUN || { crontab -l 2>/dev/null | grep -v "# plume-digest:$scope" | crontab - 2>/dev/null || true; }
    ok "  移除 cron（scope: $scope）"
  fi
  ok "卸载完成（data/ 与 config.yml 保留）。"
}

# ─── 命令: cron ─────────────────────────────────────────
cmd_cron(){
  command -v python3 &>/dev/null || { err "需要 python3 做时区转换"; exit 1; }
  command -v crontab &>/dev/null || { err "未找到 crontab。安装: sudo apt install cron / sudo dnf install cronie"; exit 1; }

  local scope; scope="$(grep -oP '^\s*default_scope:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || true)"
  [ -z "$scope" ] && { err "config.yml 中 digest.default_scope 为空。先编辑 config.yml 或运行 ./install.sh"; exit 1; }

  local config_cron; config_cron="$(grep -oP '^\s*cron_time:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || echo "06:00")"
  local use_time="${CRON_TIME:-$config_cron}"
  local target_hour="$((10#${use_time%%:*}))"
  local target_min="$((10#${use_time##*:}))"
  if [ -n "$CRON_TIME" ] && [ "$CRON_TIME" != "$config_cron" ]; then
    $DRY_RUN || sed -i "s|^\(\s*cron_time:\).*|\1 \"$CRON_TIME\"|" "$CONFIG"
    ok "config.yml cron_time = \"$CRON_TIME\""
  fi

  local cron_result
  cron_result="$(python3 -c "
import datetime
try:
    from zoneinfo import ZoneInfo
except ImportError:
    from backports.zoneinfo import ZoneInfo
tz_name='Asia/Shanghai'
try:
    import yaml
    tz_name=(yaml.safe_load(open('$CONFIG')) or {}).get('locale',{}).get('timezone','Asia/Shanghai')
except Exception:
    pass
target_tz=ZoneInfo(tz_name)
local_tz=datetime.datetime.now().astimezone().tzinfo
dt=datetime.datetime.combine(datetime.date.today(), datetime.time($target_hour,$target_min), tzinfo=target_tz)
ld=dt.astimezone(local_tz)
dd=(ld.date()-dt.date()).days
note=(f'跨天: {tz_name} {$target_hour:02d}:{$target_min:02d} = 本机前一天 '+ld.strftime('%H:%M')) if dd!=0 else (f'{tz_name} {$target_hour:02d}:{$target_min:02d} = 本机 '+ld.strftime('%H:%M'))
print(f'{ld.minute} {ld.hour}|{tz_name}|{note}')
" 2>&1)"
  if [ -z "$cron_result" ] || echo "$cron_result" | grep -q "Traceback\|Error"; then
    err "时区转换失败: $cron_result"; exit 1; fi

  local cron_time tz_name tz_note
  IFS='|' read -r cron_time tz_name tz_note <<< "$cron_result"

  local date_cmd
  if [[ "$(uname)" == "Darwin" ]]; then
    date_cmd="\$(TZ=$tz_name date -v-1d +\\%Y-\\%m-\\%d)"
  else
    date_cmd="\$(TZ=$tz_name date -d yesterday +\\%Y-\\%m-\\%d)"
  fi

  local claude_bin; claude_bin="$(command -v claude 2>/dev/null || true)"
  [ -z "$claude_bin" ] && { err "未找到 claude CLI"; exit 1; }

  # cwd = PLUME_ROOT（仓库根），与 $PLUME_ROOT 对齐，data/ 就在脚下 —— 消除路径歧义
  local marker="# plume-digest:$scope"
  local cron_line="$cron_time * * * cd $PLUME_ROOT && $claude_bin -p \"/digest daily $date_cmd --scope $scope\" --allowedTools \"Write Read Glob Grep Bash(head:*) Bash(stat:*) Bash(ls:*) Bash(mkdir:*) Bash(find:*)\" --output-format text >> $PLUME_ROOT/data/cron.log 2>&1 $marker"

  echo ""
  info "日报 cron — scope: $scope（$tz_note）"
  if $DRY_RUN; then info "将写入 crontab:"; echo "  $cron_line"; return 0; fi

  local existing filtered
  existing="$(crontab -l 2>/dev/null || true)"
  filtered="$(echo "$existing" | grep -v "$marker" || true)"
  echo "${filtered:+$filtered
}$cron_line" | crontab -
  ok "crontab 已更新:"; echo "  $cron_line"

  if command -v systemctl &>/dev/null; then
    if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
      warn "cron 服务未运行。启动: sudo systemctl start cron"; fi
  fi
}

case "$CMD" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  cron)      cmd_cron ;;
esac
