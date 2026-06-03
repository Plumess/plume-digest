#!/usr/bin/env bash
# plume-digest installer — 独立日报 / 研究报告工具
#
# 用法:
#   ./install.sh [--base <path> | --global]     安装/更新 digest skill + DIGEST_ROOT hooks
#   ./install.sh cron [HH:MM]                    写日报定时任务到 crontab
#   ./install.sh --uninstall [--base <p>|--global]  卸载 digest skill + 自己的 hooks + cron
#   附加: --dry-run 只打印不落盘
#
# 目标 .claude 解析优先级(同 plume-skills): --base <path>/.claude > --global (~/.claude)
#   > 默认 base-level (本仓库父目录/.claude)。
# 默认走 base-level 的原因同 plume-skills: user-level 会覆盖 project-level 同名 skill。
#
# 与 plume-skills 共存: 本脚本用独立 marker(.plume-digest-install-state.json)且 hooks 采用
#   增量合并(只追加/移除自己的条目),因此可与 plume-skills 装进同一个 .claude 互不干扰。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO_ROOT/config.yml"
MARKER_NAME=".plume-digest-install-state.json"
SKILL_NAME="digest"

# ─── 日志 ───────────────────────────────────────────────
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
info(){ echo "${c_blu}ℹ${c_rst} $*"; }
ok(){   echo "${c_grn}✓${c_rst} $*"; }
warn(){ echo "${c_yel}⚠${c_rst} $*" >&2; }
err(){  echo "${c_red}✗${c_rst} $*" >&2; }
usage(){ sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

# ─── 参数 ───────────────────────────────────────────────
CMD="install"; USE_GLOBAL=false; BASE_DIR=""; CRON_TIME=""; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --global)    USE_GLOBAL=true; shift;;
    --base)      BASE_DIR="$2"; shift 2;;
    --uninstall) CMD="uninstall"; shift;;
    --dry-run)   DRY_RUN=true; shift;;
    cron)        CMD="cron"; shift
                 if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then CRON_TIME="$1"; shift; fi;;
    -h|--help)   usage; exit 0;;
    *)           err "未知参数: $1"; usage; exit 1;;
  esac
done

# ─── 路径解析 ───────────────────────────────────────────
claude_dir(){
  if   [ -n "$BASE_DIR" ]; then echo "$(cd "$BASE_DIR" 2>/dev/null && pwd || echo "$BASE_DIR")/.claude"
  elif $USE_GLOBAL;        then echo "$HOME/.claude"
  else                          echo "$(dirname "$REPO_ROOT")/.claude"; fi
}
# cron 的工作目录 = 目标 .claude 所在目录(让该 .claude 的 skill+hook 生效)
deploy_base_dir(){
  if   [ -n "$BASE_DIR" ]; then echo "$(cd "$BASE_DIR" 2>/dev/null && pwd || echo "$BASE_DIR")"
  elif $USE_GLOBAL;        then echo "$HOME"
  else                          echo "$(dirname "$REPO_ROOT")"; fi
}
marker_file(){ echo "$(claude_dir)/$MARKER_NAME"; }
scope_flag_hint(){ if [ -n "$BASE_DIR" ]; then echo "--base $BASE_DIR"; elif $USE_GLOBAL; then echo "--global"; else echo ""; fi; }

# ─── Scope guard(只认自己的 marker,不碰 plume-skills 的)───
scope_guard(){
  local mf; mf="$(marker_file)"
  [ -f "$mf" ] || return 0
  local prev; prev="$(jq -r '.digest_root // empty' "$mf" 2>/dev/null || true)"
  if [ -n "$prev" ] && [ "$prev" != "$REPO_ROOT" ]; then
    err "该 scope 的 plume-digest 已被另一份仓库占用:"
    err "   现有 marker digest_root: $prev"
    err "   本次仓库:                $REPO_ROOT"
    err "   先在那份下卸载: cd $prev && ./install.sh --uninstall $(scope_flag_hint)"
    err "   或换 scope:     ./install.sh --base /opt/another"
    exit 1
  fi
}

write_marker(){
  local mf; mf="$(marker_file)"; local cd; cd="$(claude_dir)"
  $DRY_RUN && { info "  将写入 marker $mf"; return 0; }
  command -v jq &>/dev/null || { warn "  无 jq,跳过 marker"; return 0; }
  mkdir -p "$cd"
  jq -n --arg deploy "$cd" --arg base "$BASE_DIR" --arg root "$REPO_ROOT" \
    '{deploy_root:$deploy, base:$base, digest_root:$root, tool:"plume-digest", installed_skills:["digest"], installed_hooks:["SessionStart","UserPromptSubmit"]}' > "$mf"
  ok "  marker: $mf"
}

ensure_config(){
  [ -f "$CONFIG" ] && return 0
  if $DRY_RUN; then info "  将从 config.yml.example 生成 config.yml"; return 0; fi
  cp "${CONFIG}.example" "$CONFIG"; ok "  已从 config.yml.example 生成 config.yml"
}

write_digest_root(){
  if $DRY_RUN; then info "  将写入 digest_root=$REPO_ROOT 到 config.yml"; return 0; fi
  sed -i "s|^digest_root:.*|digest_root: \"$REPO_ROOT\"|" "$CONFIG"
  ok "  digest_root = $REPO_ROOT"
}

ensure_data_dirs(){
  if $DRY_RUN; then info "  将创建 data/journal data/reports"; return 0; fi
  mkdir -p "$REPO_ROOT/data/journal" "$REPO_ROOT/data/reports"; ok "  data/{journal,reports} 就位"
}

install_skill(){
  local target="$1"
  if $DRY_RUN; then info "  将软链 $target/skills/$SKILL_NAME → $REPO_ROOT/skills/$SKILL_NAME"; return 0; fi
  mkdir -p "$target/skills"
  ln -sfn "$REPO_ROOT/skills/$SKILL_NAME" "$target/skills/$SKILL_NAME"
  ok "  skill 软链: $target/skills/$SKILL_NAME"
}

# ─── hooks 增量合并(追加自己的条目,按 command 去重,保留他人的)──
sync_hooks_additive(){
  local settings="$1"
  local tmpl; tmpl="$(sed "s|__DIGEST_ROOT__|$REPO_ROOT|g" "$REPO_ROOT/hooks/hooks.json")"
  if [ ! -f "$settings" ]; then
    if $DRY_RUN; then info "  将创建 $settings(含 hooks)"; else
      mkdir -p "$(dirname "$settings")"; echo "$tmpl" > "$settings"; ok "  已创建 $settings(含 hooks)"; fi
    return 0
  fi
  if ! command -v jq &>/dev/null; then warn "  无 jq,请手动把 hooks/hooks.json 合并进 $settings"; return 0; fi
  if $DRY_RUN; then info "  将增量合并 hooks 到 $settings(保留既有)"; return 0; fi
  local tmp; tmp="$(mktemp)"
  jq -s '
    .[0] as $cur | .[1] as $tmpl |
    ($cur // {}) * { hooks:
      ( reduce ($tmpl.hooks | keys[]) as $ev ( ($cur.hooks // {}) ;
          .[$ev] = ( ((.[$ev] // []) + $tmpl.hooks[$ev]) | unique_by(.hooks[0].command) ) ) )
    }' "$settings" <(echo "$tmpl") > "$tmp" && mv "$tmp" "$settings"
  ok "  hooks 已增量合并进 $settings(plume-skills 等他人 hooks 保留)"
}

remove_own_hooks(){
  local settings="$1"
  [ -f "$settings" ] || return 0
  command -v jq &>/dev/null || { warn "  无 jq,无法自动移除 hooks"; return 0; }
  $DRY_RUN && { info "  将从 $settings 移除本仓库的 hooks 条目"; return 0; }
  local tmp; tmp="$(mktemp)"
  jq --arg root "$REPO_ROOT" '
    if .hooks then .hooks |= ( to_entries
      | map( .value |= map(select((.hooks[0].command // "") | contains($root) | not)) )
      | map(select((.value | length) > 0)) | from_entries )
    else . end' "$settings" > "$tmp" && mv "$tmp" "$settings"
  ok "  已移除本仓库 hooks 条目(他人保留)"
}

# ─── 命令: install ──────────────────────────────────────
cmd_install(){
  command -v jq &>/dev/null || warn "未找到 jq — marker / hooks 增量合并将退化,建议安装 jq"
  local target; target="$(claude_dir)"
  scope_guard
  info "安装 plume-digest → $target"
  ensure_config
  write_digest_root
  ensure_data_dirs
  install_skill "$target"
  sync_hooks_additive "$target/settings.json"
  write_marker
  echo ""; ok "安装完成。"
  info "下一步: ./install.sh cron  配置定时日报(读 config.yml 的 cron_time / default_scope)"
}

# ─── 命令: uninstall ────────────────────────────────────
cmd_uninstall(){
  local target; target="$(claude_dir)"
  info "卸载 plume-digest ← $target"
  if [ -L "$target/skills/$SKILL_NAME" ]; then $DRY_RUN || rm -f "$target/skills/$SKILL_NAME"; ok "  移除 skill 软链"; fi
  remove_own_hooks "$target/settings.json"
  [ -f "$(marker_file)" ] && { $DRY_RUN || rm -f "$(marker_file)"; ok "  移除 marker"; }
  local scope; scope="$(grep -oP '^\s*default_scope:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || true)"
  if [ -n "$scope" ] && command -v crontab &>/dev/null; then
    $DRY_RUN || { crontab -l 2>/dev/null | grep -v "# plume-digest:$scope" | crontab - 2>/dev/null || true; }
    ok "  移除 cron(scope: $scope)"
  fi
  ok "卸载完成(data/ 与 config.yml 保留)。"
}

# ─── 命令: cron ─────────────────────────────────────────
cmd_cron(){
  command -v python3 &>/dev/null || { err "需要 python3 做时区转换"; exit 1; }
  command -v crontab &>/dev/null || { err "未找到 crontab。安装: sudo apt install cron / sudo dnf install cronie"; exit 1; }
  ensure_config
  local scope; scope="$(grep -oP '^\s*default_scope:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || true)"
  [ -z "$scope" ] && { err "config.yml 中 digest.default_scope 为空。先编辑 config.yml 或运行 ./install.sh"; exit 1; }

  local config_cron; config_cron="$(grep -oP '^\s*cron_time:\s*"\K[^"]*' "$CONFIG" 2>/dev/null || echo "06:00")"
  local use_time="${CRON_TIME:-$config_cron}"
  local target_hour="$((10#${use_time%%:*}))"; local target_min="$((10#${use_time##*:}))"
  if [ -n "$CRON_TIME" ] && [ "$CRON_TIME" != "$config_cron" ]; then
    $DRY_RUN || sed -i "s|^\(\s*cron_time:\).*|\1 \"$CRON_TIME\"|" "$CONFIG"; ok "config.yml cron_time = \"$CRON_TIME\""
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
  if [ -z "$cron_result" ] || echo "$cron_result" | grep -q "Traceback\|Error"; then err "时区转换失败: $cron_result"; exit 1; fi
  local cron_time tz_name tz_note; IFS='|' read -r cron_time tz_name tz_note <<< "$cron_result"

  local date_cmd
  if [[ "$(uname)" == "Darwin" ]]; then date_cmd="\$(TZ=$tz_name date -v-1d +\\%Y-\\%m-\\%d)"
  else date_cmd="\$(TZ=$tz_name date -d yesterday +\\%Y-\\%m-\\%d)"; fi
  local claude_bin; claude_bin="$(command -v claude 2>/dev/null || true)"
  [ -z "$claude_bin" ] && { err "未找到 claude CLI"; exit 1; }

  # cwd = 目标 .claude 所在目录(让 digest skill+hook 生效);DIGEST_ROOT 由 hook 注入,数据落本仓 data/
  local proj_dir; proj_dir="$(deploy_base_dir)"
  local marker="# plume-digest:$scope"
  local cron_line="$cron_time * * * cd $proj_dir && $claude_bin -p \"/digest daily $date_cmd --scope $scope\" --allowedTools \"Write Read Glob Grep Bash(head:*) Bash(stat:*) Bash(ls:*) Bash(mkdir:*) Bash(find:*)\" --output-format text >> $REPO_ROOT/data/cron.log 2>&1 $marker"

  echo ""; info "日报 cron — scope: $scope($tz_note)"
  if $DRY_RUN; then info "将写入 crontab:"; echo "  $cron_line"; return 0; fi
  local existing filtered
  existing="$(crontab -l 2>/dev/null || true)"; filtered="$(echo "$existing" | grep -v "$marker" || true)"
  echo "${filtered:+$filtered
}$cron_line" | crontab -
  ok "crontab 已更新:"; echo "  $cron_line"
  if command -v systemctl &>/dev/null; then
    systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null || warn "cron 服务未运行。启动: sudo systemctl start cron"
  fi
}

case "$CMD" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  cron)      cmd_cron ;;
esac
