# workbuddy.db 能否按 hook 事件查出分组名

> Ticket: [#31 调研 workbuddy.db 能否按 hook 事件查出分组名](https://github.com/yangxy112683/Agent-Signal-Bar/issues/31)
> 上级地图：[#29【wayfinder】WorkBuddy 分组名作为括号标签](https://github.com/yangxy112683/Agent-Signal-Bar/issues/29)
> 环境：WorkBuddy **5.12.1** / macOS (darwin 24.5.0) / SQLite 3.43.2 / 采样时间 2026-11-27 12:06–12:12
> 主数据源：`~/.workbuddy/workbuddy.db`（本机实库，非推断）

## 结论（一句话）

**能，但要两级拼接：`session_id` 直连优先，`cwd` 精确匹配兜底。** `sessions.space_id → spaces.name` 一次 join 就拿到「电竞联盟系统」这类分组名（进程内 p50 **0.21ms**），只读安全（WAL + `mode=ro` + busy_timeout，500 次连读 0 失败）；`cwd` 兜底用「候选唯一才采信」，在 25 条可验证会话上 **零误判**（另有 3 条补出历史缺口，4 条因路径冲突主动放弃），`Documents` 真实路径场景 **15/15** 全中。

**但旧结论「db 里没有分组名」已经过期**：`spaces` 表是 **2026-11-02** 才建的（migration `0020_create_spaces`），而 [#23 工作区 metadata 调研](./workbuddy-workspace-metadata.md)（2026-08-28）查库时这张表还不存在。ADR-0005 里「工程空间展示名本地无明文」的推断来自那个时间点，**不再是当前事实**。

---

## 1. 连接键：主键是 `sessions.space_id`，不是 hook env

### 1.1 schema 实测

```sql
-- sqlite3 ~/.workbuddy/workbuddy.db ".schema spaces"
CREATE TABLE spaces (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    name TEXT NOT NULL,                -- ← 分组名，如「电竞联盟系统」
    primary_folder_path TEXT,          -- 真实工作目录（可为 Documents 下）
    create_folder_path TEXT,           -- space 容器目录（~/WorkBuddy/spaces/<ts>）
    pinned INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER,
    status TEXT NOT NULL DEFAULT 'active',
    transport TEXT NOT NULL DEFAULT 'local',
    conversation_origin TEXT,
    deleted_at INTEGER NOT NULL DEFAULT -1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
, source_kind TEXT, last_activity_at INTEGER);

CREATE TABLE sessions (        -- 节选与分组相关的列
    id TEXT PRIMARY KEY,       -- = hook payload.session_id
    cwd TEXT NOT NULL,         -- = hook payload.cwd
    ...
    group_id TEXT, group_title TEXT,     -- 云端分组，本机全空（见 §5.3）
    space_id TEXT                        -- ← 外键 → spaces.id
);
CREATE INDEX idx_sessions_space_group ON sessions(user_id, space_id, deleted_at);

CREATE TABLE space_folders (   -- space 绑定的额外目录（多目录分组）
    space_id TEXT NOT NULL,
    path TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (space_id, path)
);
CREATE INDEX idx_space_folders_path ON space_folders(path);
```

`idx_sessions_space_group` 与 `idx_space_folders_path` 说明 `space_id` 直查和 `path` 反查都是厂商设计内的路径，不是我们硬凑的。

### 1.2 主查询（推荐）

```sql
-- $1 = hook payload.session_id
SELECT s.id AS session_id, sp.id AS space_id, sp.name AS space_name
FROM sessions s
LEFT JOIN spaces sp
       ON sp.id = s.space_id
      AND sp.deleted_at < 0
      AND sp.status = 'active'
WHERE s.id = $1;
```

命中样例（本机实跑）：

| session_id | space_id | space_name |
|---|---|---|
| `45c33909-6537-4c1e-b860-272d8db72dd9` | `eabc3ec9-ae39-4941-a9bb-aa5c09840ecf` | 电竞联盟系统 |

与工单给出的起始线索完全一致。对应的 `spaces` 行：

```sql
SELECT id, name, primary_folder_path, create_folder_path, source_kind FROM spaces
WHERE id='eabc3ec9-ae39-4941-a9bb-aa5c09840ecf';
-- eabc3ec9…| 电竞联盟系统 | NULL | /Users/dawn80s/WorkBuddy/spaces/2026_11_27_11-41-35 | user
```

注意这条 space 的 `primary_folder_path` 是 **NULL**，只有 `create_folder_path`。所以拿 `primary_folder_path` 兜底不能当唯一通道。

### 1.3 `session_id` 是否可靠

- 转录文件名 = `sessions.id`：`~/.workbuddy/projects/<slug>/<session_id>.jsonl`。
- 158 个转录 id **全部**能在 `sessions` 里找到。
- 最近 30 条 db 会话中 28 条有转录；缺的 2 条均为 `source_mode='craft'`、`title IS NULL` 的空会话（可能是预创建但没产生对话）。
- hook payload 的 `session_id` 与 `sessions.id` 同一命名空间（[#21 payload 调研](./workbuddy-hook-payload-catalog.md) 已记录该字段必带）。

结论：`session_id` 是一等连接键，**不需要 `cwd`**。反向不成立（转录比 db 会话少），所以不能用转录目录反查会话。

### 1.4 为什么不能用 `CODEBUDDY_PROJECT_ID`

app bundle 里只有 `CODEBUDDY_PROJECT_ID`（无 `CODEBUDDY_SPACE_ID`）：

```bash
rg -o "CODEBUDDY_PROJECT_ID|CODEBUDDY_SPACE_ID" /tmp/wb-asar/main/*.js | sort -u
# CODEBUDDY_PROJECT_ID   （CODEBUDDY_SPACE_ID 不存在）
```

而 `sessions.project_id` 取值形如 `p_4a72e62b…`，与 `spaces.id`（UUID）**完全不同域**：

```sql
SELECT count(*) n, sum(project_id IN (SELECT id FROM spaces)) pid_is_space_id FROM sessions;
-- 195 | 0        ← 零交集
```

即 `project_id` 走的是另一套（Teams 云端工程空间）体系，和本机 `spaces` 不互通。

---

## 2. `cwd` 兜底：能覆盖，但必须精确匹配 + 唯一性裁决

### 2.1 候选收集 + 唯一性裁决

```sql
-- $1 = hook payload.cwd（原样，不做大小写/软链接归一化）
-- 第一步：收集所有声明该路径的 space（三个来源的并集）
SELECT sp.id, sp.name,
       CASE WHEN sp.primary_folder_path = $1 THEN 'primary'
            WHEN sp.create_folder_path  = $1 THEN 'create'
            ELSE 'bound' END AS tier
FROM spaces sp
WHERE sp.deleted_at < 0 AND sp.status = 'active'
  AND (
        sp.primary_folder_path = $1
     OR sp.create_folder_path  = $1
     OR EXISTS (SELECT 1 FROM space_folders sf
                 WHERE sf.space_id = sp.id AND sf.path = $1)
  );
```

**第二步：应用侧裁决——候选恰好 1 个才采信，否则返回 nil。**

为什么不写 `ORDER BY … LIMIT 1`：本机存在一个 cwd 被两个 space 共用，且真值本身是 1:3 分裂的（§2.3）。任何排序都是猜，唯一正确的动作是放弃。实测「唯一才采信」在 25 条可验证样本上 **零误判**。

`tier` 列只用于日志/调试，不参与裁决。

### 2.2 实测精度（真值 = `sessions.space_id`）

活跃会话 148 条（`deleted_at IS NULL OR deleted_at < 0`），其中 29 条有 `space_id` 真值。

**策略 A（推荐）：候选唯一才采信，多候选直接放弃。**

| 指标 | 数值 |
|---|---|
| 活跃会话总数 | 148 |
| 有真值的会话 | 29 |
| `cwd` 解析出唯一 space | 28 |
| —— 其中与真值一致 | **25** |
| —— 其中与真值冲突 | **0** |
| —— 其中真值为 NULL（`cwd` 补出来的历史缺口） | 3 |
| 因多候选放弃 | 4 |

可验证样本上 **25/25 全对，零误判**；代价是 4 条（2.7%）放弃 → 降级为裸 `workbuddy`。

**策略 B（不推荐）：多候选时按 `created_at DESC` 取第一条。**

| 指标 | 数值 |
|---|---|
| 有真值的会话 | 29 |
| 正确 | 28 |
| **错误** | **1** |

多命中 1 条却换来 1 条错判。放弃比猜更划算。

`Documents` 真实路径子集（`cwd LIKE '/Users/dawn80s/Documents/%'`）：

| 指标 | 数值 |
|---|---|
| 有真值样本 | 15 |
| 正确 | **15** |
| 错误 / 放弃 | 0 / 0 |

即「cwd 是 Documents 真实路径」场景**同样能命中分组**，而且是全库最干净的一类：`primary_folder_path` 与它一一对应，无路径复用冲突。`WorkBuddy/spaces/<ts>` 容器目录才是冲突来源。

### 2.3 唯一的冲突源：`create_folder_path` 被两个 space 共用

```sql
SELECT id, name, create_folder_path, primary_folder_path, source_kind FROM spaces
WHERE create_folder_path = '/Users/dawn80s/WorkBuddy/spaces/2026_11_05_10-36-32';
```

| id | name | primary_folder_path | source_kind |
|---|---|---|---|
| `da0ae694-…` | 腾讯云服务分组 | `/Users/dawn80s/Documents/云服务器` | user |
| `9324b537-…` | 2026_11_05_10-36-32 | NULL | seed |

`seed` 行是旧版本自动播种的占位 space，和用户真实建的 space 撞了同一个容器目录。该 cwd 下 4 条活跃会话的真值是 **1 条 `腾讯云服务分组` + 3 条 `2026_11_05_10-36-32`** —— 这是一个人为分裂的数据集，**任何单一 tiebreak 都不可能全对**：

| tiebreak | 正确 | 错误 |
|---|---|---|
| 唯一候选才采信（策略 A） | 0（4 条全放弃） | 0 |
| `created_at DESC` | 1 | 3 |
| `created_at ASC` | 3 | 1 |
| 偏好 `source_kind <> 'seed'` | 3 | 1 |

所以正确做法是**放弃**，不是选一个启发式。这也是策略 A 优于策略 B 的全部原因。

### 2.4 只靠 `cwd` 会漏掉什么

- 有 3 条活跃会话 `space_id IS NULL` 但 `cwd` 能解析出唯一 space —— 说明 `cwd` 兜底反而比 `space_id` **多**覆盖（历史数据未回填）。
- 反向：`space_id` 有值而 `cwd` 解析到唯一候选的场景，本机 **28/29**；剩下的 1 条落在 §2.3 的冲突 cwd 上，按策略 A 会放弃。

所以组合策略应为「`session_id` 先查，`space_id` 为空或查不到再用 `cwd`」，不是二选一。

### 2.5 路径字符串必须原样比较

```bash
sqlite3 "file:$HOME/.workbuddy/workbuddy.db?mode=ro" \
  "SELECT count(*) FROM spaces WHERE primary_folder_path='/users/dawn80s/documents/云服务器';"
# 0        ← 大小写不匹配即 0 行
```

- 不做小写归一化（会 miss）。
- 本机实测两条关键路径 `realpath` 与 DB 值逐字节相同，NFC 已归一，无需 Unicode 重编码。
- 但**不要**对任意路径假设这一点：若需防软链，先 `realpath` 再比较，且 `realpath` 失败时回退原值。

---

## 3. SQLite 锁与只读安全（WorkBuddy 正在运行时）

本机实库当前是 WAL：

```bash
sqlite3 ~/.workbuddy/workbuddy.db "PRAGMA journal_mode;"   # wal
ls -la ~/.workbuddy/workbuddy.db*
# workbuddy.db        708608
# workbuddy.db-shm     32768
# workbuddy.db-wal     61832
```

### 3.1 `mode=ro` 是正确姿势

| 测试 | 结果 |
|---|---|
| `file:…?mode=ro` 连读 **200** 次 | 200/200 成功，0 报错 |
| `mode=ro` + `busy_timeout=1500`，**500** 次 join 查询（每次新建进程） | 全部成功，总耗时 2.90s |
| 单次「开库 + join 查询」（进程内 200 次） | **p50 = 0.21ms**，p95 = 0.47ms，max = 3.39ms |
| 写事务进行中并发只读 | 读到已提交快照，未阻塞（`BEGIN IMMEDIATE` 持锁 5s 期间读取返回旧值） |
| 在 `mode=ro` 连接上尝试写 | `attempt to write a readonly database (8)` —— 只读约束真实生效 |

进程内 0.2ms 意味着**每条 hook 都开库查询也完全可接受**，缓存不是性能必需，只用于减少文件句柄与应对 WorkBuddy 退出后的 WAL 缺失。

WAL 的读不阻塞写、写不阻塞读在这里直接体现：应用侧插入时我们的读仍然成功且读到旧快照。

### 3.2 三个必须避开的坑

**(a) 不要用 `immutable=1`。**

`immutable=1` 会**忽略 `-wal` 里的已提交帧**，读到旧数据。合成库实测：

```
writer 持有未 checkpoint 的已提交帧，-wal 4152 字节
  mode=ro       → base,wal-in-frames   ✅
  immutable=1   → base                 ❌ 静默丢数据
```

在本机活库上当前两种读法**结果一致**（`sessions`/`spaces`/`space_folders` 全部行的 `md5` 相同），但这不是 `immutable=1` 安全的证据 —— 原因是主库刚被 checkpoint 过（`workbuddy.db` mtime 12:16:16 晚于 `-wal` 的 12:16:05），WAL 里 15 帧对查询已是冗余。

**只要主库落后于 WAL**，`immutable=1` 就静默返回旧值。合成库实验证明了这一点，而这正是应用刚写完、还没 checkpoint 的窗口。用它换"更安全"是净损失。

**(b) 直接开库（无 URI 参数）会尝试写。**

`sqlite3 ~/.workbuddy/workbuddy.db "SELECT …"` 走读写路径，理论上可触发 `-wal`/`-shm` 创建或 checkpoint。虽然实测本机未观察到副作用，但不符合"绝不写别人状态文件"的约束。

**(c) `mode=ro` 依赖 aux 文件，缺 `-wal` 必失败。**

完整矩阵（合成库实测，`PRAGMA journal_mode=wal` 的库）：

| `-wal` | `-shm` | 目录可写 | `mode=ro` |
|---|---|---|---|
| 有 | 有 | 是 | ✅ OK |
| 有 | 有 | 否 | ✅ OK |
| 有 | 无 | 是 | ✅ OK（自建 `-shm`） |
| 有 | 无 | 否 | ❌ `unable to open database file (14)` |
| 无 | 无 | 是 | ❌ (14) |
| 无 | 无 | 否 | ❌ (14) |

关键点：**WAL 模式的库没有 `-wal` 时，只读连接无法自建 `-wal`，直接失败**。

对 WorkBuddy 的含义：应用在跑 → `.db-wal` / `.db-shm` 都在（本机实测 `.db-wal` 61832 字节 / 15 帧）→ `mode=ro` 稳定可用；应用完全退出且 WAL 被清理 → `mode=ro` 会失败，此时降级见 §3.3。

### 3.3 兜底：复制到临时目录

`mode=ro` 打开失败时（典型：应用退出后 `-wal` 被清理），拷副本重开。合成库 + 活库双实测：

```bash
TMP=$(mktemp -d)
cp ~/.workbuddy/workbuddy.db ~/.workbuddy/workbuddy.db-wal "$TMP/"
sqlite3 "file:$TMP/workbuddy.db?mode=ro" "SELECT count(*) FROM sessions;"   # 195 ✅
```

| 拷贝内容 | `mode=ro` 结果 |
|---|---|
| `.db` + `.db-wal`（无 `-shm`，目录可写） | ✅ 读到全部帧（`1,2`，未 checkpoint 的也在） |
| 仅 `.db` | ❌ (14) —— 缺 `-wal`，与 §3.2(c) 同因 |
| 仅 `.db` + `immutable=1` | ✅ 但属于 §3.2(a) 的危险读法 |

- 必须 **`.db` + `.db-wal` 一起拷**，漏 `-wal` 直接打不开。
- `-shm` 不必拷：目录可写时 SQLite 自建。
- 只在 `mode=ro` 失败时走这条，不要默认走（多一次 IO + 临时文件生命周期管理）。

### 3.4 与 repo 现有实现的一致性

`Sources/AgentSignalLight/Services/AgentSignalCostUsage/CostUsageScanner+CodexPriority.swift:249` 已经是同一模式：

```swift
sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
sqlite3_busy_timeout(db, 250)
```

复用它即可，不需要引入新依赖。`busy_timeout` 建议放到 **500–2000ms**（250ms 在应用做 checkpoint 时偏紧；本机 500 次测试用 1500ms 零失败）。

---

## 4. schema 是否稳定

### 4.1 用厂商自己的 migration 作为稳定性证据

`__workbuddy_drizzle_migrations` 共 27 条，最早 `20260626034403_0000_workbuddy_sqlite_baseline`。`spaces` 相关的三条：

| 迁移 | `applied_at` | 内容 |
|---|---|---|
| `20290729061320_0020_create_spaces` | 2026-11-02 04:01:33Z | 建 `spaces` + `space_folders` |
| `20300118205320_0023_space_source_and_orphan_release` | 2026-11-02 04:01:33Z | 加 `sessions.space_id`、`spaces.create_folder_path`、`source_kind` |
| `20300317174640_0026_add_space_last_activity_at` | 2026-11-24 07:52:58Z | 加 `spaces.last_activity_at` |

（迁移文件名前缀是未来时间戳，`applied_at` 才是真实落库时间。）

**这是本工单最重要的时间线索**：#23 的调研日期是 2026-08-28，`spaces` 表 **2026-11-02** 才出现。旧结论「db 里没有分组名」在当时是对的，现在已失效。

### 4.2 稳定性评估

| 维度 | 判断 | 依据 |
|---|---|---|
| `spaces.id` / `name` | **稳定** | 建表即有，27 条迁移与启动期 schema 逻辑中从未改名 |
| `sessions.space_id` | **稳定** | 0023 加入后未变；有专用索引 |
| `space_folders(space_id, path)` | **稳定** | 建表即有，主键即 `(space_id, path)` |
| 启动期 DDL | **会重建表** | 见下 |
| 整体版本 | 会漂移 | 有 `applied_at` 的 9 条落在 2026-10-28 ~ 11-24，约一个月 9 次迁移 |

**结论**：我们要的三列（`spaces.id` / `spaces.name` / `sessions.space_id` / `space_folders.path`）稳定，可按「读列名、缺列即降级」实现；**不要** `SELECT *` 后按索引取列。

### 4.3 启动期会重建 `spaces` 表（读侧无需特殊处理，但要知道）

bundle 里 `ensureSpacesSchema` 每次启动执行：

```js
// /Applications/WorkBuddy.app/Contents/Resources/app.asar → main/storage.js
function ensureSpacesSchema(e){
  runGuardedColumnMigrations(e, `sessions`, ue);         // ADD COLUMN space_id 等
  ensureSpacesTables(e);                                  // 0020 + 0023 的 CREATE IF NOT EXISTS
  hasTable$1(e, `spaces`) && (
    runGuardedColumnMigrations(e, `spaces`, de),           // create_folder_path / source_kind / last_activity_at
    reshapeSpacesPrimaryFolderPathNullable(e)              // 条件性重建整表
  );
  assertTableColumns(e, `spaces`, S.spaces);
  assertTableColumns(e, `space_folders`, S.space_folders);
}
```

`reshapeSpacesPrimaryFolderPathNullable` 触发条件：`PRAGMA table_info(spaces)` 显示 `primary_folder_path` 是 `NOT NULL`。一旦命中，它在 `BEGIN IMMEDIATE` 事务里 `DROP TABLE spaces` → 重建 `spaces__reshape` → 改回 `spaces`。本机已经是 `notnull=0`（已 nullable），所以这条只在老版本升级路径上跑，**但说明厂商把「重建 `spaces`」当作合法迁移手段**。

对只读读取的影响（合成库实测，模拟同样的 `BEGIN IMMEDIATE` + `DROP`/`RENAME`）：

| 时刻 | `mode=ro` 读结果 |
|---|---|
| 重建事务进行中 | ✅ 读到旧快照（`a|电竞联盟系统`） |
| 事务提交后（新连接） | ✅ 读到新表 |

WAL 的 MVCC 让重建期间读取不报错、不阻塞、不读到半成品。但**长事务期间读到的 `spaces.name` 可能是重建前的旧值**，这正是需要缓存 TTL 而不是永久缓存的原因之一。

### 4.4 建议的容错写法

```sql
-- 先探列，缺列则整段功能关闭（而不是报错）
SELECT name FROM pragma_table_info('spaces');   -- 需 SQLite ≥ 3.16
```

本机 3.43.2 支持。若目标机器版本不可控，退化用 `PRAGMA table_info(spaces)`。这与厂商自己的 `assertTableColumns` 用同一手法。

---

## 5. 边界与坑（实测）

### 5.1 一个 space 可能有多个 cwd

```sql
SELECT sp.name, count(DISTINCT s.cwd), group_concat(DISTINCT s.cwd)
FROM sessions s JOIN spaces sp ON sp.id = s.space_id GROUP BY sp.id;
-- 腾讯云服务分组 | 2 | .../spaces/2026_11_05_10-36-32 , .../Documents/云服务器
```

同一分组内既有容器目录会话，也有真实目录会话。反过来也成立：**同一 cwd 可能被多个 space 声明**（§2.3）。所以 `cwd` 永远不能当唯一键。

### 5.2 `is_playground` 与 `space_id` 互相独立

有 1 条 `is_playground=1` 且 `space_id IS NULL` 的会话，落在 `电竞业务` 的容器目录里：

```
3647e1d4… | /Users/dawn80s/WorkBuddy/spaces/2026_11_09_15-24-04 | is_playground=1 | space_id=NULL
```

不要用 `is_playground` 反推是否属于分组。

### 5.3 `group_id` / `group_title` 全库为空，不可用

```sql
SELECT count(*) n,
       sum(group_title IS NOT NULL AND group_title <> '') gt,
       sum(group_id    IS NOT NULL AND group_id    <> '') gid
FROM sessions;
-- 195 | 0 | 0
```

工单里「`sessions.group_title` 采样为空」不是偶发，是**结构性为空**（这两个字段服务云端 transport，本机 192/195 是 `local`）。**分组名只能走 `spaces.name`。**

### 5.4 软删除语义不一致

| 表 | 未删除标记 |
|---|---|
| `spaces` | `deleted_at < 0`（默认 `-1`，本机 13 行全为 `-1`） |
| `sessions` | `deleted_at IS NULL` **或** `deleted_at < 0`（本机 145 行 NULL、3 行 `-1`、47 行正数时间戳） |

写查询时两边条件不同，写错会漏行或纳入已删会话。

### 5.5 `name` 本机无重名，但 schema 不保证

```sql
SELECT name, count(*) FROM spaces GROUP BY name HAVING count(*) > 1;  -- 空
SELECT count(*) FROM spaces WHERE trim(name) = '';                    -- 0
```

本机 13 个 space 名唯一、无空串。**但这是数据现状不是 schema 约束**（`name TEXT NOT NULL` 允许重名），不要拿它当键。显示层可以放心用，索引层不行。

### 5.6 有 `space_id` 但会话已删

11 条会话 `space_id IS NOT NULL AND deleted_at > 0`。查历史会话时要自己决定是否 `deleted_at` 过滤。

---

## 6. 对 #29 的落点建议（只给结论，不改代码）

1. **主路径**：hook payload `session_id` → `sessions.space_id` → `spaces.name`。一次查询、5ms 级、无歧义。
2. **兜底**：`cwd` 精确匹配三个路径字段（`primary_folder_path` / `space_folders.path` / `create_folder_path`）的并集，**候选唯一才采信，多命中即放弃**（本机唯一冲突 cwd 的真值本身是 1:3 分裂，任何排序都是猜）。
3. **只读**：`SQLITE_OPEN_READONLY` + `busy_timeout` 500–2000ms；**禁用 `immutable=1`**；打开失败再退「拷 `.db`+`-wal` 到临时目录」。
4. **缓存**：结果按 `session_id → space_name` 落 `workbuddy-project-names.json`（已有 `WorkBuddyProjectNameCache` 同构）。性能上非必需（进程内查询 p50 0.21ms），主要用于 WorkBuddy 退出后 `mode=ro` 打不开时仍有名可用。分组名改名后由 TTL 或 `spaces.updated_at` 变化触发刷新。
5. **降级**：查不到 → 保持现有 `workbuddy(<cwd lastPathComponent>)` / 裸 `workbuddy`，**不要**把 `WorkBuddy/spaces/2026_11_27_11-41-35` 这种容器目录名当标签。

ADR-0005 需要被这次结论**修订**的点（本工单不改 ADR，仅记录）：

- ADR-0005 的三级分层（L1 `CODEBUDDY_PROJECT_ID` 缓存 → L2 `cwd.lastPathComponent` → L3 裸 `workbuddy`）里**没有「查 `workbuddy.db`」这一级**，`spaces.name` 应插在 L1 与 L2 之间。
- L1 的 `CODEBUDDY_PROJECT_ID`（`p_…` 前缀）与本机 `spaces.id`（UUID）**零交集**，两者不是同一体系，不能互相替代。
- ADR 里「工程空间展示名本地无明文」的依据是 2026-08-28 的调查，而 `spaces` 表 2026-11-02 才建；该结论已失效。

---

## 7. 复现命令

```bash
DB=~/.workbuddy/workbuddy.db

# 1) 环境与 schema
sqlite3 "$DB" "PRAGMA journal_mode; PRAGMA page_size;"
sqlite3 "$DB" ".schema spaces"
sqlite3 "$DB" ".schema space_folders"

# 2) 主查询
sqlite3 "file:$DB?mode=ro" "PRAGMA busy_timeout=1500;
SELECT s.id, sp.id, sp.name FROM sessions s
LEFT JOIN spaces sp ON sp.id=s.space_id AND sp.deleted_at<0 AND sp.status='active'
WHERE s.id='45c33909-6537-4c1e-b860-272d8db72dd9';"

# 3) cwd 兜底（Documents 真实路径）
sqlite3 "file:$DB?mode=ro" "
SELECT sp.id, sp.name FROM spaces sp
WHERE sp.deleted_at<0 AND sp.status='active'
  AND ( sp.primary_folder_path='/Users/dawn80s/Documents/云服务器'
     OR EXISTS(SELECT 1 FROM space_folders sf WHERE sf.space_id=sp.id
               AND sf.path='/Users/dawn80s/Documents/云服务器')
     OR sp.create_folder_path='/Users/dawn80s/Documents/云服务器' );"

# 4) cwd 兜底：候选唯一才采信，再看准确率
sqlite3 -header -column "$DB" "
WITH live AS (SELECT id,cwd,space_id FROM sessions
              WHERE deleted_at IS NULL OR deleted_at<0),
cand AS (
 SELECT l.id, l.space_id,
  (SELECT group_concat(x.id) FROM (
     SELECT sp.id FROM spaces sp WHERE sp.deleted_at<0 AND sp.status='active'
       AND sp.primary_folder_path=l.cwd
     UNION SELECT sf.space_id FROM space_folders sf JOIN spaces sp2 ON sp2.id=sf.space_id
       WHERE sp2.deleted_at<0 AND sp2.status='active' AND sf.path=l.cwd
     UNION SELECT sp3.id FROM spaces sp3 WHERE sp3.deleted_at<0 AND sp3.status='active'
       AND sp3.create_folder_path=l.cwd
  ) x) ids FROM live l),
u AS (SELECT id, space_id, CASE WHEN instr(ids,',')=0 THEN ids END got FROM cand)
SELECT count(*) sessions,
       sum(space_id IS NOT NULL) with_truth,
       sum(got IS NOT NULL) resolved,
       sum(space_id IS NOT NULL AND got = space_id) ok,
       sum(space_id IS NOT NULL AND got IS NOT NULL AND got <> space_id) wrong,
       sum(space_id IS NULL AND got IS NOT NULL) recovered_null,
       sum(space_id IS NOT NULL AND got IS NULL) abandoned
FROM u;"
# 期望：148 | 29 | 28 | 25 | 0 | 3 | 4

# 5) 只读压力
for i in $(seq 1 500); do
  sqlite3 "file:$DB?mode=ro" "PRAGMA busy_timeout=1500;
    SELECT sp.name FROM sessions s JOIN spaces sp ON sp.id=s.space_id LIMIT 1;"
done | sort | uniq -c

# 6) 迁移历史（判断 schema 漂移）
sqlite3 -header -column "$DB" \
  "SELECT name, applied_at FROM __workbuddy_drizzle_migrations
   WHERE name LIKE '%space%' ORDER BY applied_at;"
```

---

## 8. 证据清单

| 证据 | 路径 / 命令 |
|---|---|
| `spaces` / `space_folders` / `sessions` DDL | `sqlite3 ~/.workbuddy/workbuddy.db ".schema …"`；同源 DDL 亦见 `/Applications/WorkBuddy.app/Contents/Resources/app.asar` → `main/storage.js` |
| 迁移历史与时间点 | `SELECT name, applied_at FROM __workbuddy_drizzle_migrations` |
| 启动期表重建逻辑 | `app.asar → main/storage.js`：`ensureSpacesSchema` / `reshapeSpacesPrimaryFolderPathNullable` |
| 分组名实值 | `spaces.name`（13 行，含「电竞联盟系统」「腾讯云服务分组」） |
| 覆盖/精度数字 | 本文 §2.2、§7 查询 4 |
| WAL / 锁行为 | 本文 §3 合成库 + 活库实测 |
| `immutable=1` 丢帧 | 合成库（writer 持未 checkpoint 已提交帧）对比实验 |
| `session_id` 对齐转录 | `~/.workbuddy/projects/<slug>/<session_id>.jsonl` 共 158 个，全部在 `sessions` |
| 无 `CODEBUDDY_SPACE_ID` | `rg` 扫 `app.asar` 解包后的 `main/*.js` |
| 既有只读实现 | `Sources/AgentSignalLight/Services/AgentSignalCostUsage/CostUsageScanner+CodexPriority.swift:249` |
| 旧结论（已过期） | [`workbuddy-workspace-metadata.md`](./workbuddy-workspace-metadata.md)（2026-08-28，早于 `spaces` 建表） |
