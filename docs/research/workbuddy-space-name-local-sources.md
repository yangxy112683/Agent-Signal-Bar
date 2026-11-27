# WorkBuddy 分组名（space）的本地来源调研

> Ticket: [#32 调研分组名除 sqlite 外还有哪些本地来源](https://github.com/yangxy112683/Agent-Signal-Bar/issues/32)
> Map: [【wayfinder】WorkBuddy 分组名作为括号标签](https://github.com/yangxy112683/Agent-Signal-Bar/issues/29)
> 前置：[#23 workspace metadata](./workbuddy-workspace-metadata.md) · [#24 标签策略](./workbuddy-label-strategies.md) · [ADR-0005](../adr/0005-workbuddy-session-label-naming.md)
> 环境：WorkBuddy 5.12.0（build `ed412667`）/ macOS 24.5.0 / 2026-11-27

## 结论（四句话）

1. **「电竞联盟系统」不是工程空间展示名，是「分组」（space）名**。它只存在于 `~/.workbuddy/workbuddy.db` 的 `spaces.name`，全机 `~/.workbuddy/` 全文扫描只有这一个文件命中。
2. **`workspace-display-names.json` 与分组名是两套东西**，写它的 `WorkspaceDisplayNameStore` 服务的是「目录 → 展示名」（工程空间 / automation 目录），不是 space。所以它天然不会有分组名，不是同步 bug。
3. **`wb:workspaces:getDisplayNames` 也拿不到分组名**；分组名走另一组 RPC：`wb:spaces:list` / `get` / `rename`，且 `daemon.log` 只记调用不记响应。
4. **能养活括号标签的只有一条路**：后台读 `workbuddy.db`（只读、`mode=ro`）→ 写 JSON 缓存 → hook 只读 JSON。hook 热路径不碰 sqlite、不碰网络、不改 WorkBuddy.app。

---

## 一、概念先对齐：workspace ≠ space

WorkBuddy 本地有**两套并存的命名体系**，`app.asar` 里是两个独立 Service：

| | workspace（工作区/目录） | space（分组） |
|---|---|---|
| RPC 前缀 | `wb.workspaces.*` | `wb.spaces.*` |
| 名字来源 | `~/.workbuddy/workspace-display-names.json` | `~/.workbuddy/workbuddy.db` → `spaces.name` |
| 名字语义 | 某个**目录**在 UI 里叫什么（`bblock_for_light`） | 左侧栏某个**分组**叫什么（`电竞联盟系统`） |
| 当前条数 | 4 条 | 13 个（12 active + 1 空名 seed） |

`app.asar` 内两处并置的代码可以证明它们是不同的东西：

```js
// 记录工作区时，先写 workspace display name，再 ensure space
recordWorkspace: async (n, r, i) => {
  if (r && e.workspaces) {
    let t = workspaceDisplayNameKey(n);
    (await e.workspaces.getDisplayNames()).displayNames[t]?.trim()
      || await e.workspaces.setDisplayName({ workspaceId: t, path: n, displayName: r })
  }
  i?.space && e.spaces && await e.spaces.ensureForDir(n, r || J.basename(n), ...)
}
```

```js
// 两套 RPC 分别注册
getDisplayNames: t => m.o(`wb.workspaces.getDisplayNames`, () => e.getDisplayNames(t)),
setDisplayName:   t => m.o(`wb.workspaces.setDisplayName`,   () => e.setDisplayName(t)),
// ...
list:   t => m.o(`wb.spaces.list`,   () => e.list(t)),
rename: (t, n) => m.o(`wb.spaces.rename`, () => notifyAfter(() => e.rename(t, n), ...)),
```

`ensureForDir(dir, name)` 说明分组名是**建 space 时从目录名派生一次**，之后用户可独立改名（`wb.spaces.rename`），从此与目录名解耦。「电竞联盟系统」就是创建后改的名——`create_folder_path` 仍是 `2026_11_27_11-41-35`，`name` 已是中文。

### 这直接推翻了 ADR-0005 的一条假设

ADR-0005 写着：

> v2（未实现）：菜单栏 App 调 `wb:workspaces:getDisplayNames` 自动刷新。

按源码，`getDisplayNames` 的返回结构是 `{ displayNames: {workspaceId: name}, workspaces: {...}, siblingDisplayNames: [] }`，**没有一个字段是 space**。用它刷新分组名永远刷不出来。这条 v2 需要在后续 ADR 修订时改成 `wb:spaces:list`（或直接读 sqlite，见第四节）。

---

## 二、`workspace-display-names.json` 为什么没有「电竞联盟系统」

### 2.1 现有内容（实测）

```json
{
  "version": 1,
  "workspaces": {
    "p_4a72e62b48154560a5ce37551dbb4a9b":            { "displayName": "bblock_for_light", ... },
    "/Users/dawn80s/WorkBuddy/2026-09-04-14-40-15":  { "displayName": "招聘", ... },
    "/Users/dawn80s/WorkBuddy/2026-09-28-17-26-32":  { "displayName": "NGA", ... },
    "/Users/dawn80s/WorkBuddy/automation-2026-11-13-19-05-40": { "displayName": "出差结束-恢复显示器自动休眠", ... }
  }
}
```

4 条，`mtime = 2026-11-13 19:05:40`。key 有两种形态：`p_<32hex>`（Teams project）和绝对路径。

### 2.2 三层原因，任一层单独成立都不会有分组名

| 层 | 事实 | 证据 |
|---|---|---|
| **语义层** | 这个文件是 `WorkspaceDisplayNameStore` 的落盘，只由 `workspaces.setDisplayName` / `initializeDisplayName` 写。分组改名走 `spaces.rename`，不写这个文件 | `app.asar`：`WorkspaceDisplayNameStore` 类 + `setDisplayName` / `initializeDisplayName` 调用点 |
| **时间层** | 文件最后写入 11-13 19:05；「电竞联盟系统」创建于 **11-27 11:41:35**（`spaces.created_at = 1795750895518`）。差了 14 天 | `stat workspace-display-names.json`；`spaces.created_at` |
| **路径层** | 唯一与 spaces 有路径交集的条目只有 `招聘`（`~/WorkBuddy/2026-09-04-14-40-15`，`source_kind = seed`）。分组目录 `~/WorkBuddy/spaces/...` 在这 4 条里一条都没有 | 交叉比对 4 条 path 与 13 个 space 的 `create_folder_path` / `primary_folder_path` |

### 2.3 为什么现有同步链路即使有数据也救不回来

`WorkBuddyProjectNameSyncService` 每 90 秒调 `WorkBuddyLocalFileDisplayNameSource` → 合并进 `/tmp/agent-signal/workbuddy-project-names.json`。两个硬约束：

**约束 A：只有 `CODEBUDDY_PROJECT_ID` 存在时才查缓存。**

```586:591:Sources/AgentSignalLightCore/HookAdapters.swift
        if let projectID = codebuddyProjectID(environment: environment),
           let cached = WorkBuddyProjectNameCache.displayName(forProjectID: projectID, environment: environment) {
            return cached
        }
```

而分组会话的 hook env **没有** `CODEBUDDY_PROJECT_ID`。实测该分组会话在库里的 `project_id` 是 `NULL`（`is_playground = 0`）；全库 195 条会话里 171 条 `project_id` 为空。所以缓存里就算写了分组名，这段代码也不会去查。

> 实测反证：手工把 `/tmp/.../workbuddy-project-names.json` 写成
> `{"/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35": {"displayName":"电竞联盟系统"}}`，
> 再喂 hook payload（`cwd` = 该分组目录），标签仍是 `workbuddy(2026_11_27_11-41-35)`，未被读取。

**约束 B：路径 key 与 cwd 匹配不上层级。**

`workbuddy-project-names.json` 的 key 是「目录路径」，而 hook 只有 `cwd`。分组场景下 cwd = `~/WorkBuddy/spaces/<ts>`，这条路径确实能作为 key——问题是约束 A 让它根本进不了查表分支。

---

## 三、除 sqlite 外，本地还有哪些地方出现分组名

对 `~/.workbuddy/` 做全量二进制+文本扫描（`rg -a`），搜 `电竞联盟系统`：

```
命中文件数 = 1
→ ./workbuddy.db
```

逐一核对候选来源：

| # | 来源 | 有分组名？ | 实测证据 | 能当标签源？ |
|---|---|---|---|---|
| 1 | `workbuddy.db` → `spaces.name` | ✅ **唯一权威** | `select name from spaces` → 13 行，含「电竞联盟系统」 | ✅ 但不在 hook 热路径直读 |
| 2 | `workspace-display-names.json` | ❌ | 4 条，无分组名；语义是 workspace 不是 space | ❌ |
| 3 | `space-history/spaces/<spaceId>.json` | ⚠️ 极弱 | 13 个文件里只有 **1 个**（`腾讯云服务分组`）带 `name`，因为只有它发生过 `rename`。`电竞联盟系统` 的 snapshot 只有 `reason: "create"`，无 `name` 字段 | ❌ 覆盖率 ≈ 8% |
| 4 | `storage/<user>/scoped/*/conversation-list.json` | ❌ | 有 `space-order:v1` 列表，但元素是 `space:<uuid>`，**只有 ID 没有名字** | ❌ |
| 5 | `storage/<user>/scoped/*/sidebar-list-snapshot.json` | ❌ | `item.space = {type:"local", name:"/Users/.../spaces/2026_11_27_11-41-35"}` —— 这里的 `name` 是 **cwd 路径**，不是分组名 | ❌ 反而会被误读 |
| 6 | `app/session/Local Storage/leveldb/*.ldb` | ❌ | `strings` 扫 `电竞联盟系统` / `腾讯云服务分组` 均 0 命中 | ❌ |
| 7 | `app/session/Session Storage`、`IndexedDB/http_127.0.0.1_39099.*` | ❌ | 同上，0 命中 | ❌ |
| 8 | `local_storage/entry_*.info` | ❌ | 0 命中 | ❌ |
| 9 | `logs/daemon.log` | ❌ | 有 `wb:spaces:list` / `create` / `get` 调用记录（40 / 2 / 4 次），但**只记 `elapsedMs`，不记响应体**；`电竞联盟系统` 在日志里 0 命中 | ❌ |
| 10 | `logs/2026-11-27/edge-sync.log` | ❌ | `CREATE` body 里只有 `workDir` 与 `isPlayground`，无 `spaceId` 字段 | ❌ |
| 11 | `audit-log/*.jsonl` | ❌ | 只有工具调用记录，分组名 0 命中 | ❌ |

### 关于「WorkBuddy 本地 API」的实测结论：**当前没有可用的 HTTP 通道**

| 端点 | 是什么 | 能否取分组名 |
|---|---|---|
| `127.0.0.1:39099`（`editor_sdk` 进程） | 腾讯文档编辑器 SDK 引擎，与 WorkBuddy 数据无关 | ❌ 只有 `/health` → `ok`，其他全 `Unknown endpoint` |
| `127.0.0.1:64852`（codebuddy CLI gateway） | CLI 侧 HTTP gateway，带 `CODEBUDDY_GATEWAY_PASSWORD` | ⚠️ 有 bearer 可过 `/health`，但 `/wb/spaces/list`、`/spaces`、`/v1/spaces` 全 `No mapping found`，无 spaces 路由 |
| `~/.workbuddy/.runtime/pac-rpc/workbuddy-pac-<pid>-<hash>.sock` | daemon 的 PacRpc Unix socket（`prepareSocketDir` 强制 0700） | ❌ 连接可建立，但 `wb:spaces:list` 走 GET/POST 均 404 / 405，路由表未公开 |
| `.../wbipc/b-<hash>.sock` | sidecar IPC | ❌ 返回 `{"type":"session_hello_error","code":"bad_request"}`，需握手协议 |

也就是说 `wb:spaces:list` 目前**只有 Electron renderer 内部能调**。要复用它得逆向握手协议，脆弱且不属于「不改 WorkBuddy.app、不改 hook」的可行范围。

---

## 四、哪些来源能养活括号标签（不改 app、不走 hook 热路径）

### 4.1 唯一可行数据源：`workbuddy.db` 只读查询

已验证三件事：

**① 只读打开安全**（WorkBuddy 是 WAL 模式，不能被独占锁）

```python
sqlite3.connect("file:~/.workbuddy/workbuddy.db?mode=ro", uri=True, timeout=2)
# 13 rows for `select count(*) from spaces` —— OK
# 加 &immutable=1 也 OK
```

**② 快**：一次 `open + 单行 join 查询` 平均 **0.36 ms**（20 次取样）。即便每次 hook 都开库也在预算内，但仍不建议放进热路径。

**③ 有两条定位路径，精度不同**

| 定位方式 | SQL | 精确度 | 覆盖率 |
|---|---|---|---|
| 按 `session_id`（推荐） | `select p.name from sessions s join spaces p on p.id = s.space_id and p.deleted_at < 0 where s.id = ?` | **100% 精确**——直接命中会话真实归属 | 40 / 195 条会话有 `space_id`；无 `space_id` 的会话无分组，属正常 |
| 按 `cwd` 反查 | 用 `create_folder_path ∪ primary_folder_path ∪ space_folders.path` 匹配 | ⚠️ **有歧义**：`~/WorkBuddy/spaces/2026_11_05_10-36-32` 同时属于 `腾讯云服务分组`（user）和 `2026_11_05_10-36-32`（seed），5 条会话踩中；按 `source_kind='user'` 优先只能定对其中 2 条，另外 3 条真实归属是 seed 分区 | 全部可匹配，但 5 条会错 |

**关键点**：hook payload 里有 `session_id`，而 `sessions.id` 就是同一个 uuid（实测 `45c33909-6537-4c1e-b860-272d8db72dd9` 双向一致）。所以**走 `session_id` 而不是 `cwd`**，可以绕开全部歧义。

### 4.2 推荐形态：后台同步 + JSON 缓存（与现有架构同构）

```
┌─────────────────────────────┐
│ WorkBuddyProjectNameSyncService（已有，90s 定时）│
└──────────┬──────────────────┘
           │ 新增一个 source
           ▼
┌─────────────────────────────┐        ┌──────────────────────────┐
│ WorkBuddySpaceNameSource    │──写──▶│ space-names.json          │
│ 只读 sqlite: spaces + sessions│        │ { sessions:{sid:name},    │
│  (后台，不在 hook 热路径)      │        │   paths:{cwd:name} }      │
└─────────────────────────────┘        └──────────┬───────────────┘
                                                   │ 只读 JSON
                                                   ▼
                                     ┌──────────────────────────┐
                                     │ GenericHookAdapter 标签解析 │
                                     │  (mtime 缓存，无 sqlite)    │
                                     └──────────────────────────┘
```

为什么必须分两层：hook 是 **5 秒超时**的子进程（`HookExecutor ... timeout=5000ms`，每次 PreToolUse 都跑）。目前 `AgentSignalLightCore` 目标里**没有** `import SQLite3`（只有 App 层的 2 个文件有），加进去等于给 CLI 二进制引入 sqlite 链接 + 每次 hook 的文件 IO。后台同步写 JSON、hook 读 JSON 是零新增风险的做法，也和已落地的 #27 同步服务同构。

### 4.3 只改缓存还不够：还要修 timestamp 判定

当前分组会话的标签是 `workbuddy(2026_11_27_11-41-35)`，因为：

```616:626:Sources/AgentSignalLightCore/HookAdapters.swift
        let parent = ((trimmed as NSString).deletingLastPathComponent as NSString).lastPathComponent
            .lowercased()
        guard parent == "workbuddy" else { return false }
        let lastComponent = (trimmed as NSString).lastPathComponent
        let patterns = [
            #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$"#,
            #"^\d{4}-\d{2}-\d{2}$"#,
            #"^\d{8,14}$"#
        ]
```

`~/WorkBuddy/spaces/2026_11_27_11-41-35` 的父目录是 `spaces` 不是 `workbuddy`，末段又是 `2026_11_27_11-41-35`（下划线分隔），**两条都不满足** → 不算 playground → L2 兜底把目录名当标签。

实测：

| cwd | 当前标签 |
|---|---|
| `~/WorkBuddy/spaces/2026_11_27_11-41-35` | `workbuddy(2026_11_27_11-41-35)` |
| `~/WorkBuddy/2026-11-26-14-22-15` | `workbuddy`（正确落 L3） |

所以括号标签要生效，需要同时做两件事：**(a) 补分组名数据源；(b) 把 `spaces/<ts>` 形态纳入 playground 判定**，否则即使缓存有名字也会被 L2 抢先。

---

## 五、方案排序（供 map #29 决策）

| 方案 | 数据精度 | 热路径开销 | 实现风险 | 结论 |
|---|---|---|---|---|
| **A. 后台读 sqlite → JSON 缓存 → hook 读 JSON（按 session_id）** | 高（100%） | 0（只读 JSON） | 低（复用 #27 骨架） | ✅ **推荐** |
| B. hook 内直读 sqlite（按 session_id） | 高 | 0.36 ms + 进程内 sqlite 链接 | 中（Core 目标新增 SQLite3，5s 超时预算仍够） | ⚠️ 备选 |
| C. hook 内按 cwd 反查 sqlite | 中（5 条歧义） | 同上 | 中 | ❌ 不如 A/B |
| D. 解析 `space-history/*.json` | 极低（1/13） | 0 | 低 | ❌ 只有 rename 过的分组有名字 |
| E. 调 `wb:spaces:list`（PAC RPC / socket） | 高 | 需后台 | 高（协议未公开，404/405） | ❌ 现在不可行 |
| F. 依赖 `wb:workspaces:getDisplayNames` | — | — | — | ❌ 语义不对，永远拿不到 space |

### 落地要点（给实现 ticket）

1. 新增 `WorkBuddySpaceNameSource: WorkBuddyDisplayNameSource`（或独立协议，避免污染 project 语义）。
2. 查询必须 **`mode=ro`**，且只读 `spaces` / `sessions` / `space_folders` 三张表；不要 `select *`。
3. 缓存 key 用 **`session_id`**（精确），`cwd` 只作次级兜底并标注歧义风险。
4. `spaces.deleted_at < 0 and status = 'active'` 过滤（`app.asar` 的 `_a` 片段就是这么判活的）。
5. 同步周期沿用 90s；文件写入用 `.atomic`，mtime 触发 hook 侧 reload（`WorkBuddyProjectNameCache` 已有该机制）。
6. 同步修 `isWorkBuddyTimestampPlaygroundPath`：父目录 `workbuddy` **或** `spaces`，末段匹配 `^\d{4}_\d{2}_\d{2}_\d{2}-\d{2}-\d{2}$`。

---

## 六、证据清单（可复现）

```bash
# 1. 分组名只在 sqlite
rg -a -l "电竞联盟系统" ~/.workbuddy/            # → 仅 ./workbuddy.db
sqlite3 ~/.workbuddy/workbuddy.db "select name, create_folder_path, source_kind from spaces where deleted_at=-1;"

# 2. display-names 是另一套
cat ~/.workbuddy/workspace-display-names.json
stat -f "%Sm" ~/.workbuddy/workspace-display-names.json   # Nov 13 19:05:40

# 3. 分组会话的 project_id 为空 → 缓存查不到
sqlite3 ~/.workbuddy/workbuddy.db "select id, cwd, project_id, is_playground, space_id from sessions where id='45c33909-6537-4c1e-b860-272d8db72dd9';"

# 4. session_id → 分组名（推荐路径，0.36ms）
sqlite3 ~/.workbuddy/workbuddy.db "select p.name from sessions s join spaces p on p.id=s.space_id and p.deleted_at<0 where s.id='45c33909-6537-4c1e-b860-272d8db72dd9';"

# 5. LevelDB / IndexedDB 无命中
strings -a ~/.workbuddy/app/session/"Local Storage"/leveldb/*.ldb | grep -c 电竞联盟系统
strings -a ~/.workbuddy/app/session/Session\ Storage/*.ldb | grep -c 电竞联盟系统

# 6. daemon.log 只记调用不记响应
rg -c "wb:spaces:list" ~/.workbuddy/logs/daemon.log            # 40
rg -c "电竞联盟系统" ~/.workbuddy/logs/daemon.log               # 0

# 7. 标签现状复现（不写真实状态文件）
echo '{"session_id":"probe","cwd":"/Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35",
       "hook_event_name":"PreToolUse","tool_name":"Bash","client":"WorkBuddy"}' \
 | AGENT_SIGNAL_LIGHT_STATE_DIR=/tmp/wbprobe WORKBUDDY_APP_NAME=WorkBuddy \
   ~/Applications/AgentSignalLight.app/Contents/Resources/scripts/generic-agent-signal-hook
# → workbuddy(2026_11_27_11-41-35)
```

### 数据快照（2026-11-27 12:16）

- `spaces` 共 13 行：`source_kind` = user 10 / seed 3，全部 `status = active`，`deleted_at = -1`
- 有 `space_id` 的会话：40 / 195
- `project_id` 非空会话：24 / 195（`p_449fa5…` 14、`p_4a72e6…` 6、`p_f15aa2…` 4）
- `workbuddy.db` 708 KB，WAL 模式，`-wal` 活跃
- `workspace-display-names.json` 1 KB / 4 条 / mtime 11-13 19:05:40

---

## 七、对 ADR-0005 的影响（不在本 ticket 修改）

- 「v2：菜单栏 App 调 `wb:workspaces:getDisplayNames` 自动刷新」**需改写**：该 RPC 不含 space 数据。
- 降级梯度 L1→L2→L3 需要新增一层「space 名」，且 `spaces/<ts>` 目录形态要并入 playground 判定，否则 L2 会持续产出 `workbuddy(2026_11_27_11-41-35)`。
- `CODEBUDDY_PROJECT_ID` 不能作为分组标签的查找键——分组会话该变量为空。
