# 日报 YYYY-MM-DD
<!-- scope: scope-keyword -->
<!-- sessions: N (ProjectA: X, ProjectB: Y) -->

## 今日成果
1. [项目简称] 一句话概括成果
2. [项目简称] 一句话概括成果

## 工作详情
### [项目简称] 主题描述
- HH:MM 具体工作内容
- 关键决策：选择了 A 方案，因为 xxx

### [项目简称] 主题描述
- HH:MM 具体工作内容

## 明日计划
1. [项目简称] 计划项
2. [项目简称] 计划项

<!--
TEMPLATE NOTES
==============
- **Language**: config.yml → locale.language (default: zh-CN)
- **Timezone**: config.yml → locale.timezone (default: Asia/Shanghai)
- **时间窗口**: YYYY-MM-DD cron_time ~ 次日 cron_time（config 时区，默认 06:00~06:00）
- **会话匹配**: 区间重叠（session_start <= 窗口末 AND mtime >= 窗口初），跨天会话会出现在多天日报中
- **定位**: 给领导和同事快速了解工作内容，简明扼要
- **今日成果**: 每项一句话，最重要的排前面
- **工作详情**: 按主题组织（不按时间流水），每个主题下按时间列工作点
  - 单项目时省略 [项目简称] 前缀
  - 关键决策只写结论和原因，不展开讨论过程
  - 技术细节点到为止，不贴大段代码
- **明日计划**: 从最新 session snapshot 的 Current State / Open Questions 提取
- 所有章节必填，无内容写"无"
- 文件已存在时智能合并（见 digest SKILL.md 说明）
-->
