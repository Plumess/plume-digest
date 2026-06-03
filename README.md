# plume-digest

从 Claude Code 会话记录(`~/.claude/projects/*/*.jsonl`)生成**每日工作日报**和**主题研究报告**的独立工具。

- **日报** (`/digest daily`):按时间窗口切片当天所有相关会话,汇总成中文日报。
- **研究报告** (`/digest report <主题>`):跨会话按主题关键词检索,综合成一份报告。

数据源是 Claude Code 自己写的 jsonl(逐行带时间戳),按每行时间戳精确切片——既能处理短会话,也能正确处理跨天的超长会话。

> 本仓库从 [plume-skills](https://github.com/Plumess/plume-skills) 的 digest 功能提取而来,**完全独立**:自带 skill + hooks + 安装脚本 + 定时配置。与 plume-skills 可独立或共存安装——装到不同 `.claude` 天然隔离,装进同一个 `.claude` 也互不影响(独立 marker + hooks 增量合并)。

## 安装

```bash
git clone git@github.com:Plumess/plume-digest.git
cd plume-digest
./install.sh                 # 默认 base-level：装到仓库父目录的 .claude/（多 clone 天然隔离）
```

安装做了 5 件事:写 `digest_root` 到 config、建 `data/{journal,reports}`、把 digest skill 软链进目标 `.claude/skills/`、把 DIGEST_ROOT 注入 hooks **增量合并**进目标 `.claude/settings.json`、写独立 marker(`.plume-digest-install-state.json`)。

目标 `.claude` 解析优先级(同 plume-skills):`--base <path>/.claude` > `--global ~/.claude` > 默认 base-level(仓库父目录/.claude)。

```bash
./install.sh --global          # 装到 ~/.claude/（全局可用）
./install.sh --base <path>     # 装到 <path>/.claude/
./install.sh --uninstall       # 卸载（只移除自己的 skill/hooks/marker/cron；data/ 与 config 保留）
./install.sh --dry-run         # 只打印不落盘
```

### 与 plume-skills 共存

本工具用**独立 marker** + **hooks 增量合并**,可与 [plume-skills](https://github.com/Plumess/plume-skills) 装进**同一个** `.claude`:两套 skill 共享 `skills/` 目录、两边 hooks 并存(各注入各的信号 `DIGEST_ROOT` / `PLUME_ROOT`)、各自 marker 互不抢占。先装谁、卸载谁都不影响对方。装到不同 scope(不同 `--base`)则天然隔离。

## 用法

在装好的目录里启动 Claude Code,然后:

| 命令 | 作用 |
|---|---|
| `/digest daily [YYYY-MM-DD] [--scope kw]` | 生成日报(默认今天)。落盘 `data/journal/YYYY-MM-DD.md` |
| `/digest report <主题>` | 生成研究报告。落盘 `data/reports/<slug>.md` |
| `/digest status` | 显示作用域、命中项目、今日会话、日报是否已生成 |

**scope**(作用域):只检索 `~/.claude/projects/` 中 slug **包含**该关键词的项目,用来隔离不同工作线。优先级:`--scope` 参数 > `config.yml` 的 `default_scope`。

## 定时日报(cron)

```bash
./install.sh cron            # 读 config.yml 的 cron_time / default_scope 写 crontab
./install.sh cron 07:30      # 同时把 cron_time 改成 07:30
```

生成的 crontab 行形如(`cd` 进本仓根、输出落本仓 `data/`,与其他工具的 cron 用独立 marker 区分):

```
0 15 * * * cd <部署目录> && claude -p "/digest daily $(...) --scope <scope>" ... >> <repo>/data/cron.log 2>&1 # plume-digest:<scope>
```

cron_time 用 config 时区(默认 `Asia/Shanghai`)书写,脚本自动换算成本机时区写入 crontab。

## 配置 `config.yml`

```yaml
digest_root: ""              # install.sh 自动写入本仓库绝对路径，digest 输出落在此目录的 data/ 下
locale:
  timezone: "Asia/Shanghai" # 影响时间戳、日报日期边界、cron 触发时间换算
  language: "zh-CN"          # 生成文档语言
digest:
  default_scope: "plume"     # 日报默认作用域
  cron_time: "06:00"         # 自动生成时间（config 时区）
```

## 目录结构

```
plume-digest/
├── install.sh                # 安装 / 卸载 / cron
├── config.yml
├── skills/digest/SKILL.md    # 技能定义（日报 + 研究报告逻辑）
├── templates/                # daily-report.md / research-report.md
├── hooks/                    # SessionStart + UserPromptSubmit 注入 [DIGEST_ROOT]
└── data/{journal,reports}/   # 产出（gitignore，不入库）
```

## 路径解析说明

digest 输出落在 `$DIGEST_ROOT/data/` 下。`$DIGEST_ROOT` = 本仓库根,由 hooks 在会话启动时注入 `[DIGEST_ROOT: …]`,**与 cwd 无关**——所以即使 cron 从部署目录(可能是父目录)启动,digest 也用注入值而非工作目录解析路径。cron 的 `cd` 指向部署目录(目标 `.claude` 所在),让 skill+hook 生效。SKILL.md 另有写盘前 `ls` 自检兜底:若 `$DIGEST_ROOT/data/journal/` 为空(非全新装)说明解析错了。

## License

[Apache-2.0](LICENSE)
