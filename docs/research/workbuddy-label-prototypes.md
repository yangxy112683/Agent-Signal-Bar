# WorkBuddy 展示标签 — 并排原型对比

> Ticket: [#25 Prototype WorkBuddy display label candidates side-by-side](https://github.com/yangxy112683/Agent-Signal-Bar/issues/25)  
> 前置：[#22 用户偏好](https://github.com/yangxy112683/Agent-Signal-Bar/issues/22#issuecomment-5451766383) · [#24 策略对比](./workbuddy-label-strategies.md)  
> 场景：用户在 WorkBuddy 工程空间 **bblock** 中开 Playground 会话，实际 Bash 操作 `~/work/esport_bb_lock`

## 保留方案（3 选 2+1）

| 代号 | 名称 | 结论 |
|------|------|------|
| **P0** | 现状（cwd lastPathComponent） | ❌ **不保留** — 仅作对照基线 |
| **P1** | Tiered Resolver（推荐） | ✅ **保留** — #24 选定主方案 |
| **P2** | Tiered + 无缓存 L3 变体 | ✅ **保留** — 定 L3 兜底细则 |
| ~~P3~~ | 完整路径标签 `workbuddy(~/work/…)` | ❌ 否决 — 过长、非 UI 名 |
| ~~P4~~ | timestamp 短日期 `workbuddy(08-28)` | ❌ 否决 — #22 不要日期 |

**进入 #26 锁定的候选：P1（主）+ P2（L3 细则二选一）**

---

## 共用测试场景

| 字段 | 值 |
|------|-----|
| WorkBuddy 左侧面板工程空间名 | `bblock` |
| `CODEBUDDY_PROJECT_ID` | `p_4a72e62b48154560a5ce37551dbb4a9b` |
| hook `cwd` | `/Users/dawn80s/WorkBuddy/2026-08-28-19-04-08` |
| 用户实际操作仓库 | `~/work/esport_bb_lock` |
| 并发会话 | 同工程空间下 3 个 Playground 会话 |

---

## 菜单栏信号灯 — 并排 Mock

同一时刻 aggregate 为 **working**（某会话在跑工具）。

### P0 — 现状（基线，否决）

```
┌─────────────────────────────────────┐
│  🟡  Working                        │
│  ─────────────────────────────────  │
│  Sessions                           │
│  ● workbuddy(2026-08-28-19-04-08)   │  ← thinking
│  ○ workbuddy(2026-08-28-18-38-21)   │
│  ○ workbuddy(2026-08-28-17-33-15)   │
│  ○ cursor(agent-signal-bar)         │
└─────────────────────────────────────┘
```

问题：三个 WorkBuddy 行**无法区分**工程空间；标签对用户无意义。

### P1 — Tiered Resolver（推荐）

缓存：`p_4a72… → bblock`；sessionKey 按 `project_id` 合并展示。

```
┌─────────────────────────────────────┐
│  🟡  Working                        │
│  ─────────────────────────────────  │
│  Sessions                           │
│  ● workbuddy(bblock)                │  ← thinking（3 会话聚合为 1 行）
│  ○ cursor(agent-signal-bar)         │
└─────────────────────────────────────┘
```

优点：与 WorkBuddy UI 一致；多 Playground 会话不刷屏。  
前提：v1 需用户或 v2 sync 填充缓存。

### P2a — Tiered 无缓存 L3：`workbuddy`（无括号标签）

```
┌─────────────────────────────────────┐
│  🟡  Working                        │
│  ─────────────────────────────────  │
│  Sessions                           │
│  ● workbuddy                        │  ← 无标签，仍可按 project_id 合并
│  ○ cursor(agent-signal-bar)         │
└─────────────────────────────────────┘
```

优点：无错误信息；不暴露 timestamp。  
缺点：无法一眼看出是哪个工程空间（多工程空间并行时歧义）。

### P2b — Tiered 无缓存 L3：`workbuddy(p_4a72…)` 短后缀

```
┌─────────────────────────────────────┐
│  🟡  Working                        │
│  ─────────────────────────────────  │
│  Sessions                           │
│  ● workbuddy(p_4a72e62b)            │  ← project_id 前 8 位
│  ○ cursor(agent-signal-bar)         │
└─────────────────────────────────────┘
```

优点：多工程空间可区分。  
缺点：技术性 ID，不如 `bblock` 友好；**仅作缓存未命中时的临时兜底**。

### 对照 — 若误用 cwd 仓库名（否决路径）

```
│  ● workbuddy(esport_bb_lock)        │  ← 与 UI「bblock」不一致
```

[#22](https://github.com/yangxy112683/Agent-Signal-Bar/issues/22#issuecomment-5451766383) 明确：工程空间叫 bblock 时必须显示 bblock，而非磁盘目录名。

---

## 会话列表（status.json 视角）

假设 `sessions` 映射中 agent 字段如下：

| 方案 | session A agent | session B agent | session C agent | 用户能否认出「bblock」 |
|------|-----------------|-----------------|-----------------|------------------------|
| P0 现状 | `workbuddy(2026-08-28-19-04-08)` | `workbuddy(2026-08-28-18-38-21)` | `workbuddy(2026-08-28-17-33-15)` | ❌ |
| P1 推荐 | `workbuddy(bblock)` | `workbuddy(bblock)` | `workbuddy(bblock)` | ✅ |
| P2a | `workbuddy` | `workbuddy` | `workbuddy` | ⚠️ 只知是 WorkBuddy |
| P2b | `workbuddy(p_4a72e62b)` | `workbuddy(p_4a72e62b)` | `workbuddy(p_4a72e62b)` | ⚠️ 技术 ID |
| 误用 cwd | `workbuddy(esport_bb_lock)` | … | … | ❌ |

**sessionKey 建议（P1）**：`workbuddy:p_4a72e62b48154560a5ce37551dbb4a9b`  
→ 三个 Playground 会话共享同一 aggregate 行，避免按 timestamp 碎片化。

---

## 非 Playground 场景（L2 降级）

用户直接以 `~/work/esport_bb_lock` 打开 WorkBuddy（无 Teams project_id）：

| 方案 | agentName | 评价 |
|------|-----------|------|
| P0 / L2 | `workbuddy(esport_bb_lock)` | ✅ 可接受 |
| P1（无 project_id） | `workbuddy(esport_bb_lock)` | ✅ 同 L2 |
| P1（有 project_id + 缓存） | `workbuddy(bblock)` | ✅ 仍以 UI 名为准 |

---

## 决策矩阵（供 #26）

| 维度 | P0 现状 | P1 Tiered+cache | P2a `workbuddy` | P2b `p_4a72…` |
|------|---------|-----------------|-----------------|----------------|
| 对齐 #22 `bblock` | ❌ | ✅ | ❌ | ❌ |
| 无缓存首跑可用 | ✅ | ⚠️ 需配缓存 | ✅ | ✅ |
| 多 Playground 不刷屏 | ❌ | ✅ | ✅ | ✅ |
| 多工程空间可区分 | ❌ | ✅（缓存后） | ❌ | ✅ |
| 实现复杂度 | 已有 | 中 | 低（L3 子集） | 低（L3 子集） |

### 推荐锁定（#26 草案）

1. **主方案**：P1 — `CODEBUDDY_PROJECT_ID` + `~/.agent-signal/workbuddy-project-names.json`
2. **L3 兜底**：优先 **P2a** `workbuddy`（无标签）；若用户反馈多工程空间歧义，再启用 **P2b** 短后缀
3. **废弃**：P0 timestamp 标签作为 Playground 首选输出
4. **L2 保留**：非 Playground、无 project_id 时 `workbuddy(lastPathComponent)`

---

## 对抗式审查（原型级）

| # | 场景 | P0 | P1 | 预期赢家 |
|---|------|----|----|----------|
| 1 | bblock Playground + 缓存 | timestamp | bblock | P1 |
| 2 | 缓存未配置首跑 | timestamp | workbuddy | P1 L3 > P0 |
| 3 | 两个工程空间并行、均无缓存 | 两个 timestamp | 两个 `workbuddy` 或两个短 id | P2b > P2a |
| 4 | 直接开 esport_bb_lock | esport_bb_lock | esport_bb_lock 或 bblock | 平局 / P1 若有关联 |
| 5 | 菜单栏 5 行 vs 1 行 | 3 行 WB | 1 行 WB | P1 |

---

## 下一步（#26）

- 将 P1 + L3(P2a/P2b) 写入 ADR 或 spec 片段
- 修订 ADR-0004 展示格式（当前写 `workbuddy_` 前缀，实现已改为 `workbuddy()`）
- 实现 `WorkBuddyProjectNameCache` + `GenericHookAdapter` 分支
