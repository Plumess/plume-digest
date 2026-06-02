---
name: digest
description: "Use when user requests /digest, a daily summary, or a research report of session work."
---

# Digest

Generates daily reports and research reports. Both source directly from jsonl — daily by per-line timestamp slicing, research by topic keyword scanning (main Claude reads jsonl itself, no sub-agent delegation). MEMORY.md provides background context.

Read `$PLUME_ROOT/config.yml` for `locale` (timezone, language), `digest` (default_scope).

> A report MUST cover ALL active sessions within scope. Always read source files — never summarize from memory alone.

> **Ask-Before-Persist interaction**: digest's output paths are pre-configured via `config.yml` and fixed by convention (`data/journal/YYYY-MM-DD.md`, `data/reports/<slug>.md`). Treat this as the user having pre-confirmed the write destination at install time — no per-invocation path confirmation needed. The `/digest` command is itself the explicit trigger; cron / `-p` mode cannot confirm interactively anyway. The Report Update prompt (merge / overwrite / save-as-new / cancel) serves as the per-invocation gate for overwrites.

---

## /digest daily [YYYY-MM-DD] [--scope keyword]

Generate a daily report. Default date: today.

### Scope

Resolution: `--scope` arg > `config.yml default_scope` > ask user.
Matching: Claude project slug **contains** scope keyword as substring.

### Steps

**Step 1 — Enumerate main session jsonls (top-level only)**

First **discover scoped project dirs** in `~/.claude/projects/`, then for each matched project enumerate **only top-level `*.jsonl`** as main session files. Do NOT recurse — `subagents/agent-*.jsonl` are sub-agent traces and must be excluded.

> ⚠️ Do NOT use the Glob tool for **either** the dir-discovery step or the jsonl-enumeration step. Glob recurses into subdirectories and has a result cap; projects with many subagent files (one project can have dozens) will eat the cap and silently drop sibling project dirs from discovery AND drop the most recent main session jsonls from enumeration. Both layers have the same failure mode. Always use non-recursive `ls` / `os.listdir`:
>
> ```bash
> # Discover scoped project dirs (non-recursive, grep by slug substring)
> ls -1 ~/.claude/projects/ | grep -i <scope>
> ```
>
> If sandbox rejects the pipe as multi-op, split into two steps or use `python3 -c "import os; [print(p) for p in os.listdir(...) if '<scope>' in p.lower()]"`. **Never** fall back to `Glob` — a truncated list is indistinguishable from a complete one if you don't look for the truncation marker.
>
> Then, for each matched project, enumerate its jsonls non-recursively:

```bash
# Preferred: one-shot enumeration with start timestamp + mtime, sorted by mtime desc
for f in ~/.claude/projects/<slug>/*.jsonl; do
  start=$(head -1 "$f" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp',''))")
  mtime=$(stat --format=%Y "$f")
  echo "$mtime $start $(basename $f)"
done | sort -rn
```

For each main session jsonl, determine if the session was **active on the target date** using interval overlap:

1. **session_start**: first line `timestamp` field (ISO 8601 UTC)
2. **session_end**: file mtime (`stat --format=%Y` or `os.path.getmtime()`)
3. **target window**: read `digest.cron_time` from config (default `06:00`). Window = target date `cron_time` ~ next day `cron_time` (in config timezone, converted to UTC)
4. **Match condition**: `session_start < target_end AND session_end >= target_start`

This correctly captures cross-day sessions. Do NOT rely on mtime alone — it misses sessions that started on the target date but are still active later.

**Sanity checks** (both required):

1. **Scoped dir count**: re-run the dir-discovery command (`ls -1 ~/.claude/projects/ | grep -i <scope>`) and confirm the matched slug list matches what you're about to process. If you didn't obtain the list by the dir-discovery command above (e.g. you inferred it from some other output), redo it now — inferred lists are suspect.
2. **Per-project jsonl count**: for each matched slug, verify the jsonl count matches a direct directory listing (`ls ~/.claude/projects/<slug>/*.jsonl | wc -l`). If a session you'd expect (e.g. the current one) is missing, re-enumerate — never trust a partial list.

Display matched projects + session counts to user for confirmation (skip if cron/`-p` mode).

**Step 2 — Slice each session by timestamp window**

**jsonl is the authoritative source. Always read it.** Main Claude slices directly — do not delegate. Each line in a jsonl carries its own `timestamp` field. The jsonl is append-only and contains the complete session history from first message to last — a cross-day session naturally appears in multiple daily reports with disjoint slices. **Tail-based reading is wrong for cross-day sessions.** Per-line timestamp filtering is the only correct mechanism.

For each active session:

1. **Filter the jsonl** to lines whose `timestamp` falls within the target window `[target_start, target_end)`. This slice belongs to the target date's report.
2. Summarize from the slice. Focus on user requests, decisions, files modified, outcomes.
3. **Cross-check files actually modified**: if the slice mentions writing files, verify with `stat` that mtimes fall within the window. Catches anything the slice paraphrasing missed.

Use `python3 -c "..."` for filtering (already whitelisted). Avoid heredoc (`<<'PY'`) and `#` comments inside `-c` — both trigger sandbox patterns. Scratch files, if needed, go under `$PLUME_ROOT/data/.tmp/digest-<YYYYMMDD-HHMMSS>/` (whitelisted for Write / mkdir / rm); clean up at Step 3 end.

```bash
# Inline filter (one-liner, no comments in the -c string)
python3 -c "import sys,json; path,s,e=sys.argv[1:]; \
[print(l,end='') for l in open(path) \
 if s<=(json.loads(l).get('timestamp','') or '')<e]" "$jsonl" "$start_utc" "$end_utc"
```

Read MEMORY.md for project context (background only).

> Why jsonl with per-line timestamp filtering: jsonl is the system-written ground truth. Tail is a hack that breaks for long sessions. Per-line timestamp slicing is the only mechanism that correctly handles both short single-day sessions and ultra-long multi-day sessions.

**Step 3** — Generate using `$PLUME_ROOT/templates/daily-report.md`. Write to `$PLUME_ROOT/data/journal/YYYY-MM-DD.md`. If file exists → **Report Update**.

> ⚠️ **Path trap — resolve `$PLUME_ROOT` from config, never from the working directory.** `$PLUME_ROOT` is the `plume_root` value in `config.yml` (e.g. `/root/plume/plume-skills`). It is **NOT** the cwd — cron launches from the parent project dir (e.g. `/root/plume`), which biases toward dropping the install subdir. Write the FULL path *including* that subdir; never collapse to `~/<project>/data/...` or `<cwd>/data/...`.
> **Self-check before every `data/` write** (journal AND reports): `ls $PLUME_ROOT/data/journal/` — it must already list prior reports. If it's empty or missing (and this is not a brand-new install), you mis-resolved `$PLUME_ROOT` (almost always a dropped path segment) — re-read `config.yml` `plume_root` and correct the path before writing.

If a scratch directory was created in Step 2, `rm -rf $PLUME_ROOT/data/.tmp/digest-<YYYYMMDD-HHMMSS>/` before exiting.

> **Exclude self-referential digest work**: If a session's slice content is almost entirely a `/digest` command invocation and its execution trace, treat it as noise and omit it from the report — no entry, no count, no mention. The daily report describes user work, not the act of generating itself (e.g. do not emit "自动生成日报" / "Cron 触发 digest" style entries).

---

## /digest report [natural language topic]

Generate a research report on a topic across scoped sessions.

> **Note**: after v3 slim-design removed context-keeper, this command no longer has snapshots/CONTEXT-INDEX to lean on — main Claude scans jsonl directly. Research reports are expected to be used infrequently.

### Steps

**Step 1** — Enumerate scoped jsonls (same as daily Step 1, no window filter — cover all jsonls in scope regardless of date).

**Step 2** — For each jsonl, grep for topic keywords to locate relevant exchanges, then read those line ranges. Read MEMORY.md for background.

If the user gave no argument, surface a short list of topic clusters derived from recent sessions and let the user pick.

**Step 3** — Generate using `$PLUME_ROOT/templates/research-report.md`. Write to `$PLUME_ROOT/data/reports/<topic-slug>.md`. If file exists → **Report Update**.

---

## /digest status

Display: configured scope, matched projects, per-project jsonl count, today's active sessions, daily report existence.

---

## Report Update

When target file exists, present 4 options: Merge / Overwrite / Save as new (`-v2.md`) / Cancel.

Daily merge: 工作详情 append/update → 今日成果 regenerate → 明日计划 use newer.
Research merge: 核心发现 merge → 关键认知 keep all → 结论与建议 regenerate → 参考 union.

---

## Failure Modes

| Failure | Recovery |
|---------|----------|
| No active sessions for date | Report "No activity found." |
| In-window slice exceeds ~1500 lines | Grep the slice for tool calls / file writes / decisions and summarize selectively; don't read the whole slice verbatim |
| Cross-day session: which day owns it? | Both. Each day's report shows that day's timestamp slice; slices are disjoint and complementary |
| Session listing seems suspiciously short | Re-enumerate with non-recursive `ls` + `wc -l` cross-check |
| `Glob` output ends with "Results are truncated" | Immediately abandon Glob for this step — a truncated list is unreliable. Redo with `ls` / `os.listdir`. Applies to both dir-discovery and jsonl-enumeration layers |
| `python3 -c` string gets rejected (sandbox pattern) | Rephrase to avoid `#` comments and heredoc; if still blocked, ask user — do NOT write a helper `.py` to the workspace |
| Write fails | Output report to chat |
