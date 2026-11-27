# WorkBuddy 分组（Space）是否出现在 hook payload / env 调研

> Ticket: [#30 调研当前 WorkBuddy hook 是否带出分组](https://github.com/yangxy112683/Agent-Signal-Bar/issues/30)
> Map: [【wayfinder】WorkBuddy 分组名作为括号标签](https://github.com/yangxy112683/Agent-Signal-Bar/issues/29)
> 前置：[#21 Hook payload 目录](./workbuddy-hook-payload-catalog.md)（2026-08）、[#23 Workspace metadata](./workbuddy-workspace-metadata.md)
> 环境：WorkBuddy 5.12.1（`app.asar` 内 `@genie/agent-cli 2.181.0`）/ macOS 24.5.0（Darwin arm64）/ 采集于 2026-11-27 12:00–12:20

## 结论摘要

**问题 1：2026-11 的 WorkBuddy generic hook，payload 与子进程 env 是否带出分组（space_id / 分组名）？**

**否。** 两条通道都不带分组，一个字都没有：

| 通道 | 是否出现 space_id / 分组名 | 实证 |
|------|---------------------------|------|
| hook stdin payload | ❌ 无 | 全部事件只有 `session_id` / `transcript_path` / `cwd` + 事件专属字段；见下文「payload 全字段」 |
| hook 子进程 env | ❌ 无 | `env` 中只有 `CODEBUDDY_PROJECT_DIR` / `CLAUDE_PROJECT_DIR` 指向 cwd；`CODEBUDDY_PROJECT_ID` 是 Teams 工程空间 ID，与分组（spaces）互斥，从不共存 |
| CLI 二进制 | ❌ 不感知 | `codebuddy-lite-wb.mjs` 全文中 `spaceId` 只出现在腾讯文档评论上下文，与本地 spaces 无关；无 `create_folder_path` / `codebuddy.db` 读取 |
| 桌面端（唯一持有方） | ✅ 有 | `~/.workbuddy/workbuddy.db` 的 `spaces` 表存 `id` + `name` + `create_folder_path` + `primary_folder_path` |

**问题 2：cwd 现在有哪些形态？**

四种，且**由分组形态决定**，不是随机：

| 形态 | 样本数（`sessions` 表） | 典型值 | 来源 |
|------|----------------------|--------|------|
| `~/WorkBuddy/spaces/<下划线时间戳>` | 12 | `/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35` | 新建分组且未绑定文件夹 → `spaces.create_folder_path` |
| `~/WorkBuddy/<短横线时间戳>` | 148 | `/Users/dawn80s/WorkBuddy/2026-11-26-16-11-55` | 旧 Playground（`is_playground=1`，142/148）；无 space_id |
| 真实文件夹 | 29（9 个不同路径） | `/Users/dawn80s/Documents/云服务器` | 分组绑定了文件夹 → `spaces.primary_folder_path` |
| `/`、空串、`~/WorkBuddy/Claw` 等 | 3 + 3 | — | 杂项 |

**关键否证：** `~/WorkBuddy/spaces/2026_11_27_11-41-35` 在 hook 里只剩 `lastPathComponent`，即无信息量的时间戳；分组名「电竞联盟系统」只在 sqlite 里。`GenericHookAdapter` 当前输出 `workbuddy(2026_11_27_11-41-35)`——括号里是时间戳，不是分组名。

---

## 1. payload 全字段实测

### 1.1 采集方法（可复现）

用 `/tmp/wb-cap/capture.sh` 作为第二个 hook 与 ASB hook 并存，写入 `/tmp/wb-cap/capture.log`：

```bash
#!/bin/bash
{
  echo "=== $(date -Iseconds) event=$1 ==="
  echo "--- payload ---"; cat
  echo "--- env(selected) ---"
  env | grep -Ei "CODEBUDDY|WORKBUDDY|CLAUDE|SPACE|PWD=" | sort
} >> /tmp/wb-cap/capture.log
```

两条独立采集路径，互为交叉验证：

1. **真实桌面会话（主证据）**：`~/.workbuddy/settings.json` 的 10 个事件各插一条 capture hook，在 WorkBuddy UI 里开分组会话触发。日志见 `~/.workbuddy/logs/2026-11-27/2026_11_27_11-41-35__7374861cc3e493a996dccf3180688026.log:117-120`（`[HookManager] event=SessionStart matched 2 distinct hook entries`）。
2. **CLI 直跑（形状对照）**：`CODEBUDDY_CONFIG_DIR=/tmp/wb-cap/cfg node dist/codebuddy-lite-wb.mjs -p ok --settings '{"hooks":{...}}'`，在 `~/WorkBuddy/spaces/2026_11_27_11-41-35` 下执行，得到同形状 payload，便于确认「cwd 就是分组目录」。

采集完成后 `settings.json` 已按位还原（`diff` 与备份一致）。

### 1.2 实测 payload（CLI 直跑，SessionStart）

```json
{
  "session_id": "01a21b32-ba3e-7e4e-9827-c0a97cd461e5",
  "transcript_path": "/tmp/wb-cap/cfg/projects/Users-dawn80s-WorkBuddy-spaces-2026_11_27_11-41-35/01a21b32-ba3e-7e4e-9827-c0a97cd461e5.jsonl",
  "hook_event_name": "SessionStart",
  "source": "startup",
  "permission_mode": "bypassPermissions",
  "client": "CLI",
  "version": "2.181.0",
  "generation_id": "01a21b32ba657231a831b8165ffc1b79",
  "model": "hy3-preview-ioa"
}
```

`cwd` 字段在同一位置缺省（该路径下 CLI 用进程 cwd 兜底），其余事件均带 `cwd`。

### 1.3 全事件字段清单（源码级确认）

`app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs` 的 `convertToSdkInput()` 是 payload 的唯一出口（字节偏移 4233927 附近）：

```js
convertToSdkInput(t, i, n) {
  let c = {
    hook_event_name: t,
    session_id: i.session_id || "",
    transcript_path: i.transcript_path,
    cwd: i.cwd || gv.PathUtils.getWorkDir(),
    ...i.permission_mode ? { permission_mode: i.permission_mode } : {},
    ...i.tool_use_id || i.call_id ? { tool_use_id: i.tool_use_id || i.call_id } : {},
    ...n && Object.keys(n).length > 0 && { hook_specific_output: n }
  };
  switch (t) {
    case PRE_TOOL_USE: return { ...c, hook_event_name: "PreToolUse", tool_name, tool_input };
    case POST_TOOL_USE: return { ...c, ..., tool_response };
    case NOTIFICATION: return { ...c, message, notification_type };
    case POST_TOOL_USE_FAILURE: return { ...c, tool_name, tool_input, error, is_interrupt };
    case PERMISSION_REQUEST: return { ...c, tool_name, tool_input, permission_suggestions? };
    case USER_PROMPT_SUBMIT: return { ...c, prompt };
    case SESSION_START: return { ...c, source };
    case SESSION_END: return { ...c, reason };
    case STOP: return { ...c, stop_hook_active };
    case SUBAGENT_STOP: return { ...c, stop_hook_active, agent_id?, agent_transcript_path? };
    case SUBAGENT_START: return { ...c, agent_id, agent_type };
    case PRE_COMPACT: return { ...c, trigger, custom_instructions };
    case POST_COMPACT: return { ...c, trigger, compact_summary? };
    case WORKTREE_CREATE: return { ...c, name };
    case WORKTREE_REMOVE: return { ...c, worktree_path };
    default: return c;
  }
}
```

另有两个带路径字段的事件（不常装，但存在）：

```js
// 9290914 附近
executeCwdChangedHooks: { session_id, session, transcript_path, cwd, hook_event_name: "CwdChanged", old_cwd, new_cwd }
executeFileChangedHooks: { session_id, session, transcript_path, cwd, hook_event_name: "FileChanged", file_path, event }
```

**结论：白名单式构造，没有任何 `space*` / `group*` / `workspace_name` 字段。** 桌面端即便持有 space 信息，也没有往 payload 里塞的代码路径。

### 1.4 对 #21 的修正

#21 记录「PreToolUse/PostToolUse 额外字段含 `agent_type` / `client: "WorkBuddy"` / `version` / `generation_id` / `model`」。2026-11 实测：

- `client` / `version` / `generation_id` / `model` **仍在**（CLI 直跑时 `client: "CLI"`，桌面端为 `WorkBuddy`）；
- `agent_type` **已不见**于 `convertToSdkInput` 白名单，实测 payload 也无（改由 `buildAgentTrigger()` 注入 agent 触发信息，不写 `agent_type`）。

不影响本 ticket 结论，但说明 payload schema 有漂移，旧 catalog 的字段表需打折看待。

---

## 2. 子进程 env 实测

### 2.1 真实 hook 子进程 env（关键 12 个）

```
BAGGAGE=codebuddy.session_id=01a21b32-ba3e-...,codebuddy.conversation_request_id=01a21b32ba...
CLAUDE_PROJECT_DIR=/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35
CLAUDE_SESSION_ID=01a21b32-ba3e-7e4e-9827-c0a97cd461e5
CODEBUDDY_CONFIG_DIR=/Users/dawn80s/.workbuddy
CODEBUDDY_CONVERSATION_REQUEST_ID=01a21b32ba657231a831b8165ffc1b79
CODEBUDDY_PROJECT_DIR=/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35
CODEBUDDY_SERVICE_PROXY_URL=http://127.0.0.1:65221/internal/hooks/services/invoke
CODEBUDDY_SESSION_ID=01a21b32-ba3e-7e4e-9827-c0a97cd461e5
WORKBUDDY_APP_NAME=WorkBuddy
WORKBUDDY_APP_PATH=/Applications/WorkBuddy.app/Contents/Resources/app.asar
PWD=/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35
```

**没有 `CODEBUDDY_PROJECT_ID`，没有 `*_SPACE_ID`，没有分组名。**

### 2.2 为什么没有：env 组装链源码

`app.asar` 中 `contributeConversationEnv()`（字节 19965776 附近）是会话 env 的组装点：

```js
async function contributeConversationEnv(e, t, n) {
  let r = {}, i = [];
  try { let n = t.getProjectConversationEnv(e.conversationId, e.projectId); n && Object.assign(r, n); } catch {}
  assignBuddySessionSkillDirEnv(r, e.conversationId, t);
  try { let n = await t.resolveAgentExtraEnv(e.conversationId); n && (Object.assign(r, n.env), i = n.shellEnvironmentKeys ?? []); } catch {}
  try { let e = t.runtimeWarmCache?.get(), n = e ? e.qimei36 : await t.resolveQimei36(); n && (r[Yw] = n); } catch {}
  isDesignConversation(e) && r[tT] === void 0 && (r[tT] = String(eT)), n && Object.assign(r, n);
  let a = r.WORKBUDDY_CONFIG_DIR || O.a();
  if (r[R.C] = R.w(a, e.cwd, r), ...) { ... }
  return { env: r, shellEnvironmentKeys: i };
}
```

`getProjectConversationEnv` → `ProjectResourceManager.getEnvForSession`，而它的 `buildEnv` 只有一行（字节 9205638）：

```js
buildEnv(e, t) {
  let n = {};
  return e.skillDir && (n.CODEBUDDY_SESSION_SKILL_DIRS = e.skillDir), n;
}
```

即**工程空间（project）只贡献一个 skill 目录变量**。而 `spaces` 表与 `project_id` 在数据层面互斥（见 3.3），所以走 spaces 的分组会话连这个变量都没有。

### 2.3 `CODEBUDDY_PROJECT_ID` 的真实来源（修正 #21 的语义）

`app.asar` 字节 10348036 附近：

```js
let S = x && o?.userId && o.userId !== x ? void 0 : o?.projectId,
    C = e.projectId ?? readProjectId(e._meta) ?? S;
C && (e.env = { ...e.env, CODEBUDDY_PROJECT_ID: C });
```

这里的 `projectId` 是 **Teams 工程空间**（形如 `p_449fa5210856455c812fe6dd342cbb47`），不是左侧「分组」。实测交叉表（`~/.workbuddy/workbuddy.db`）：

```sql
select (space_id<>'') has_space, (project_id<>'') has_project, count(*) n from sessions group by 1,2;
-- ||131  |1|24  |1||40      → 两者从不同时出现
select count(*) from sessions where space_id<>'' and project_id<>'';
-- 0
```

所以 #21 记录的 `CODEBUDDY_PROJECT_ID=p_4a72…`（对应 `bblock_for_light`）属于 **Teams 工程空间**这一支，与「左侧分组」是两套并行概念。`/tmp/agent-signal/workbuddy-project-names.json` 的缓存键也印证：既有 `p_4a72…`（Teams），也有 `/Users/dawn80s/WorkBuddy/2026-09-28-17-26-32`（路径式键，来自 `workspace-display-names.json` 的另一条同步链）。

### 2.4 桌面端进程本身有 100+ 个 env 键，但没有一个带 space

对 `codebuddy --serve` 进程（pid 3202）做 `ps eww`，`CODEBUDDY_*` / `WORKBUDDY_*` 键共 73 个，全量与分组相关的为 0：

```
... CLIENT_INFO_PLATFORM CODEBUDDY_CONFIG_DIR CODEBUDDY_HOST CODEBUDDY_HOST_CAPABILITIES
CODEBUDDY_PROJECT_CONFIG_DIR CODEBUDDY_RUNTIME_INSTANCE_ID CODEBUDDY_SESSION_HISTORY_CLEANUP
WORKBUDDY_APP_NAME WORKBUDDY_APP_PATH WORKBUDDY_APP_VERSION WORKBUDDY_CONFIG_DIR ...
```

对 `app.asar` 做全量 env-key 正则扫描（`[A-Z][A-Z0-9_]{6,40}:`），命中的 `CODEBUDDY_*` / `WORKBUDDY_*` 共 ~100 个，**没有 `*SPACE*` 键**（`SPACE_ID` 命中 0 次；`SPACE_NAME` 的 5 次命中全在错误码枚举和 VS Code workspace 变量解析器里，与本主题无关）。

---

## 3. cwd 形态与分组的对应关系

### 3.1 四种形态的完整清单

```sql
-- 数据源：~/.workbuddy/workbuddy.db
select case
  when cwd like '%/WorkBuddy/spaces/%' then 'spaces/<underscore-ts>'
  when cwd glob '*/WorkBuddy/[0-9][0-9][0-9][0-9]-*' then 'WorkBuddy/<dash-ts>'
  when cwd like '%/WorkBuddy/%' then 'WorkBuddy/<other>'
  when cwd = '' then '(empty)'
  else 'real folder' end shape, count(*) n
from sessions group by 1 order by n desc;
```

| shape | n |
|-------|---|
| `WorkBuddy/<dash-ts>` | 148 |
| `real folder` | 29 |
| `spaces/<underscore-ts>` | 12 |
| `WorkBuddy/<other>` | 3 |
| `(empty)` | 3 |

时间边界：`spaces/<underscore-ts>` 最早 2026-11-05 10:39:56，最晚 2026-11-27 11:44:15；`WorkBuddy/<dash-ts>` 最晚 2026-11-26 16:11:55（`is_playground=1` 占 142/148）。**下划线时间戳是 11 月引入的新形态，旧调研（2026-08）里完全没有。**

### 3.2 `spaces` 目录的命名与内容

```
$ ls ~/WorkBuddy/spaces/
2026_11_05_10-36-32  2026_11_09_15-24-04  2026_11_10_16-04-04  2026_11_12_11-19-54
2026_11_13_10-58-33  2026_11_13_16-52-19  2026_11_17_16-13-36  2026_11_25_17-14-22
2026_11_26_16-54-06  2026_11_27_11-41-35
```

父目录是 `spaces`（不是 `WorkBuddy`），日期用**下划线**：`YYYY_MM_DD_HH-MM-SS`。目录内只有 `.workbuddy/memory/<date>.md`（agent 写的笔记），没有 metadata 文件：

```
$ find ~/WorkBuddy/spaces/2026_11_27_11-41-35
.../2026_11_27_11-41-35
.../2026_11_27_11-41-35/.workbuddy
.../2026_11_27_11-41-35/.workbuddy/memory
.../2026_11_27_11-41-35/.workbuddy/memory/2026-11-27.md
```

**目录名与分组名没有任何关联**——「电竞联盟系统」这个名字一个字符都不在文件系统里。

### 3.3 分组 → cwd 的映射（`spaces` 表，唯一权威）

```sql
select name, primary_folder_path, create_folder_path, count(s.id) sessions
from spaces sp left join sessions s on s.space_id = sp.id
where sp.deleted_at = -1 group by sp.id order by sessions desc;
```

| name | primary_folder_path | create_folder_path | sessions |
|------|--------------------|--------------------|----------|
| 腾讯云服务分组 | `/Users/dawn80s/Documents/云服务器` | `.../spaces/2026_11_05_10-36-32` | 7 |
| 为什么要去现场看比赛 | `/Users/dawn80s/Documents/为什么要去现场看比赛` | `.../spaces/2026_11_17_16-13-36` | 6 |
| ai高光时刻 | `/Users/dawn80s/Documents/ai_highlight_prototype` | `.../spaces/2026_11_12_11-19-54` | 4 |
| 精彩时刻剪辑 | `/Users/dawn80s/Documents/game_videocut_wayfinder` | `.../spaces/2026_11_10_16-04-04` | 4 |
| 2026_11_05_10-36-32 | — | `.../spaces/2026_11_05_10-36-32` | 3 |
| 电竞业务 | — | `.../spaces/2026_11_09_15-24-04` | 3 |
| agent-loop | `.../agent_autoloop` | `.../spaces/2026_11_13_10-58-33` | 3 |
| 腾讯电竞公众号自媒体渠道内容调研 | `/Users/dawn80s/Documents/腾讯电竞…` | `.../spaces/2026_11_25_17-14-22` | 2 |
| streamdock | — | `.../spaces/2026_11_26_16-54-06` | 2 |
| 油猴脚本实现 | `/Users/dawn80s/Documents/油猴脚本` | `.../spaces/2026_11_13_16-52-19` | 2 |
| 招聘 | — | `~/WorkBuddy/2026-09-04-14-40-15` | 2 |
| Claw | — | `~/WorkBuddy/Claw` | 1 |
| 电竞联盟系统 | — | `.../spaces/2026_11_27_11-41-35` | 1 |

两个事实值得注意：

1. **13 个活跃分组里 7 个绑了真实文件夹、6 个没绑。** 绑了的，会话 `cwd` 走 `primary_folder_path`；没绑的，走 `create_folder_path`。会话与这两列的对应关系统计：`primary_folder` 命中 26 条、`create_folder` 命中 14 条，**0 条落在其他路径**。
2. **`create_folder_path` 可以重复。** `spaces/2026_11_05_10-36-32` 同时属于「腾讯云服务分组」（`da0ae694…`）和「2026_11_05_10-36-32」（`9324b537…`，`source_kind=seed`）。所以「cwd → 分组」不是单射：

   ```sql
   select create_folder_path, count(*) n, group_concat(name,' | ')
   from spaces where deleted_at=-1 and create_folder_path<>'' group by 1 having n>1;
   -- /Users/dawn80s/WorkBuddy/spaces/2026_11_05_10-36-32 | 2 | 腾讯云服务分组 | 2026_11_05_10-36-32
   ```

   这条 cwd 上的 5 个历史会话分属两个分组，事后无法区分。

### 3.4 「电竞联盟系统」的完整证据链

| 层 | 值 |
|----|-----|
| UI（AX 树） | `[57] AXStaticText value="电竞联盟系统"`（sidebar 分组标题）；会话列表 `[63] "联盟系统按年经营信号数据分析 24分钟前"` |
| `spaces` 行 | `id=eabc3ec9-ae39-4941-a9bb-aa5c09840ecf`, `name=电竞联盟系统`, `create_folder_path=/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35`, `primary_folder_path=''`, `source_kind=user` |
| `sessions` 行 | `id=45c33909-6537-4c1e-b860-272d8db72dd9`, `cwd=/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35`, `space_id=eabc3ec9…`, `is_playground=0`, `title=联盟系统按年经营信号数据分析` |
| hook payload | `cwd` = 同上；**无 space 字段** |
| hook env | `CODEBUDDY_PROJECT_DIR` = 同上；**无 space 变量** |
| transcript | `~/.workbuddy/projects/Users-dawn80s-WorkBuddy-spaces-2026_11_27_11-41-35/45c33909-….jsonl`，全文 `电竞联盟系统` 命中 **0 次** |
| space-history | `~/.workbuddy/space-history/spaces/eabc3ec9-….json`：`{spaceId, snapshots:[{reason:"create", primaryFolderPath:".../spaces/2026_11_27_11-41-35"}]}` |

**唯一能拿到「电竞联盟系统」这四个字的地方，就是 `workbuddy.db` 的 `spaces.name`。** 其余全部只有时间戳。

---

## 4. 对 Agent Signal Bar 当前行为的影响（实测）

用 `agent-signal agent-hook` + `WORKBUDDY_APP_NAME=WorkBuddy` 跑四种 cwd（隔离状态目录 `/tmp/asb-test`）：

| 场景 | cwd | 当前 session key | 当前 agent label |
|------|-----|------------------|------------------|
| A 分组（未绑文件夹） | `.../WorkBuddy/spaces/2026_11_27_11-41-35` | `workbuddy:2026_11_27_11-41-35:sA` | `workbuddy(2026_11_27_11-41-35)` |
| B 旧 Playground | `.../WorkBuddy/2026-11-26-16-11-55` | `sB`（直用 payload.session_id） | `workbuddy` |
| C 分组（绑真实文件夹） | `/Users/dawn80s/Documents/云服务器` | `workbuddy:云服务器:sC` | `workbuddy(云服务器)` |
| D 分组 + `CODEBUDDY_PROJECT_ID` | `.../spaces/2026_11_27_11-41-35` | `workbuddy:2026_11_27_11-41-35:sD` | `workbuddy(2026_11_27_11-41-35)` |

三个结论：

1. **场景 A 的括号是最坏情况**：`workbuddy(2026_11_27_11-41-35)` 对用户零信息量。原因是 `HookAdapters.isWorkBuddyTimestampPlaygroundPath()` 只匹配父目录 `workbuddy` + 短横线/纯数字时间戳（`Sources/AgentSignalLightCore/HookAdapters.swift:609-625`），`spaces` 这个父目录名 + 下划线格式两条都不匹配，于是 fallback 到 `lastPathComponent`。
2. **场景 B 反而是干净的**：`isWorkBuddyTimestampPlaygroundPath` 命中 → 返回 nil → label 退回纯 `workbuddy`。旧格式被正确处理了，新格式漏了。
3. **场景 C 的标签是文件夹名，不是分组名**：「腾讯云服务分组」显示为 `云服务器`（文件夹名）；「油猴脚本实现」会显示 `油猴脚本`；「ai高光时刻」显示 `ai_highlight_prototype`。7 个绑了文件夹的分组里，只有 4 个名字正好等于文件夹名（腾讯电竞…、为什么要去现场看比赛），其余 3 个都错位。

补充：session key 在场景 C 用 `workbuddy:云服务器`，而场景 A 用 `workbuddy:2026_11_27_11-41-35`——两种 key 派生逻辑混在 `workbuddyProjectSessionKey` / `workbuddyDisplayLabel` 两处，若将来引入 space 名需一起改。

---

## 5. 拿分组的可行路径（供 #29 决策，不在本票实现）

| 方案 | 数据源 | 可行性 | 关键约束 |
|------|--------|--------|----------|
| **S1 只读 sqlite** | `~/.workbuddy/workbuddy.db` → `spaces`（`create_folder_path` / `primary_folder_path` → `name`） | ✅ 已验证可查，13 行小表 | 需处理 `create_folder_path` 重复（3.3）；db 有 `-wal`/`-shm`，需只读打开；WorkBuddy 升级可能改表 |
| **S2 让 WorkBuddy 自己带出** | 上游功能请求：env 注入 `CODEBUDDY_SPACE_ID` / payload 加字段 | ❌ 当前完全没有 | 需跨团队；本票范围内不可用 |
| **S3 桌面端同步缓存** | 像 `WorkBuddyProjectNameSynchronizer` 那样，把 `spaces` 同步到 `~/.agent-signal/workbuddy-spaces.json` | ✅ 与现有 `workbuddy-project-names.json` 同构 | hook 侧仍需 sqlite 或缓存二选一；同步延迟窗口 |
| **S4 只修时间戳标签** | 扩展 `isWorkBuddyTimestampPlaygroundPath` 识别 `spaces/<下划线时间戳>` | ✅ 5 行改动 | 只解决「不显示丑时间戳」，分组名仍拿不到 |

**S1 + S3 组合最省事**：hook 侧读缓存（零 sqlite 依赖），桌面端定时/事件驱动刷新；缓存 miss 时降级到 S4。

无论选哪个，都必须先接受两个不可逆事实：

- **`create_folder_path` 不是唯一键**：`spaces/2026_11_05_10-36-32` 一对二，历史会话无法事后消歧。
- **真实文件夹分组的名字可能与文件夹名不同**：`腾讯云服务分组 ↔ Documents/云服务器`、`油猴脚本实现 ↔ Documents/油猴脚本`、`ai高光时刻 ↔ Documents/ai_highlight_prototype`。用文件夹名做标签等于猜。

---

## 6. 与旧结论的差异汇总

| 项 | #21（2026-08） | 本票（2026-11-27） |
|----|----------------|---------------------|
| cwd 形态 | 只有 `~/WorkBuddy/<短横线时间戳>` | 新增 `~/WorkBuddy/spaces/<下划线时间戳>`；真实文件夹形态大量出现（29 条） |
| `is_playground` | Timestamp Playground 主流 | 旧形态仍是主流（142/148），但新会话全部 `is_playground=0` |
| `CODEBUDDY_PROJECT_ID` | 「Teams 工程空间 ID，可用于映射 bblock」 | 语义确认：Teams 工程空间，**与左侧分组互斥**（0 条共存） |
| 工程空间展示名映射 | 疑云端 | 已落地：`spaces.name`（本地 sqlite）+ `workspace-display-names.json`（旧路径式） |
| payload `agent_type` | 记录为存在 | 已从白名单消失 |
| 「分组」概念 | 未区分 | 明确区分 **Teams 工程空间（project_id）** 与 **左侧分组（spaces）** 两套 |

---

## 7. 采集清单（复现用）

```bash
# 1. 分组表
sqlite3 ~/.workbuddy/workbuddy.db "select id,name,primary_folder_path,create_folder_path,source_kind from spaces where deleted_at=-1;"

# 2. 会话 → cwd → space
sqlite3 ~/.workbuddy/workbuddy.db "
select s.id, s.cwd, sp.name, s.is_playground
from sessions s left join spaces sp on sp.id=s.space_id
order by s.created_at desc limit 20;"

# 3. cwd 形态统计
sqlite3 ~/.workbuddy/workbuddy.db "
select case when cwd like '%/WorkBuddy/spaces/%' then 'spaces/ts'
            when cwd glob '*/WorkBuddy/[0-9][0-9][0-9][0-9]-*' then 'WorkBuddy/dash-ts'
            when cwd like '%/WorkBuddy/%' then 'WorkBuddy/other'
            when cwd='' then '(empty)' else 'real folder' end, count(*)
from sessions group by 1;"

# 4. 唯一带分组的 hook 证据（没有分组字段）
#    ~/.workbuddy/logs/2026-11-27/2026_11_27_11-41-35__7374861cc3e493a996dccf3180688026.log:117-120
#    /tmp/wb-cap/capture.log（capture.sh 抓的 payload + env 原文）

# 5. 进程 env（无 space 键）
ps eww -p $(pgrep -f "cli/bin/codebuddy --serve" | head -1) | tr ' ' '\n' | grep -E '^(CODEBUDDY|WORKBUDDY)_'
```

相关源码位置（本次阅读，均为 `app.asar` 内字节偏移）：

| 内容 | 位置 |
|------|------|
| payload 构造白名单 | `app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs:4233927` (`convertToSdkInput`) |
| hook 子进程 env 组装 | `codebuddy-lite-wb.mjs` `buildChildContextEnv` / `buildHookSpawnOptions` |
| 会话 env 汇总 | `app.asar:19965776` (`contributeConversationEnv`) |
| 工程空间 env 唯一产出 | `app.asar:9205638` (`buildEnv` → 只有 `CODEBUDDY_SESSION_SKILL_DIRS`) |
| `CODEBUDDY_PROJECT_ID` 注入 | `app.asar:10348036` |
| space 建表/命名 | `app.asar:17656757`（`createTimestampPlaceholderFolder`）, `23535729`（`SPACE_NAME_CONFLICT` / `deriveAvailableNameTx`） |
| 当前标签降级逻辑 | `Sources/AgentSignalLightCore/HookAdapters.swift:579-625`（`workbuddyDisplayLabel` / `isWorkBuddyTimestampPlaygroundPath`） |
