# plume-digest

从 Claude Code 会话记录(`~/.claude/projects/*/*.jsonl`)生成**每日工作日报**和**主题研究报告**的独立工具。

- **日报** (`/digest daily`):按时间窗口切片当天所有相关会话,汇总成中文日报。
- **研究报告** (`/digest report <主题>`):跨会话按主题关键词检索,综合成一份报告。

数据源是 Claude Code 自己写的 jsonl(逐行带时间戳),按每行时间戳精确切片——既能处理短会话,也能正确处理跨天的超长会话。

> 本仓库从 [plume-skills](https://github.com/Plumess/plume-skills) 的 digest 功能提取而来,**完全独立**:自带 skill + hooks + 安装脚本 + 定时配置,与 plume-skills 装在各自的 `.claude/` 下、互不影响、可共存。

## 安装

```bash
git clone git@github.com:Plumess/plume-digest.git
cd plume-digest
./install.sh                 # 默认装到本仓库 .claude/（仓库级，自包含）
```

安装做了 4 件事:写 `plume_root` 到 config、建 `data/{journal,reports}`、把 digest skill 软链进 `.claude/skills/`、把 PLUME_ROOT 注入 hooks 合并进 `.claude/settings.json`。

可选目标位置:

```bash
./install.sh --global          # 装到 ~/.claude/（全局可用）
./install.sh --base <path>     # 装到 <path>/.claude/
./install.sh --uninstall       # 卸载（保留 data/ 与 config.yml）
./install.sh --dry-run         # 只打印不落盘
```

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
0 15 * * * cd <repo> && claude -p "/digest daily $(...) --scope <scope>" ... >> <repo>/data/cron.log 2>&1 # plume-digest:<scope>
```

cron_time 用 config 时区(默认 `Asia/Shanghai`)书写,脚本自动换算成本机时区写入 crontab。

## 配置 `config.yml`

```yaml
plume_root: ""              # install.sh 自动写入本仓库绝对路径，digest 输出落在此目录的 data/ 下
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
├── hooks/                    # SessionStart + UserPromptSubmit 注入 [PLUME_ROOT]
└── data/{journal,reports}/   # 产出（gitignore，不入库）
```

## 路径解析说明

digest 输出落在 `$PLUME_ROOT/data/` 下,`$PLUME_ROOT` = `config.yml` 的 `plume_root`(本仓库根),由 hooks 注入到会话上下文。cron 用 `cd <repo>` 让工作目录与 `$PLUME_ROOT` 对齐,避免把路径误解析到父目录。SKILL.md 内置写盘前 `ls` 自检兜底。

## License

[Apache-2.0](LICENSE)
