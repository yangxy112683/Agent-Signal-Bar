# Cursor 误报为 Claude Code：修订版修复方案

> 更新日期：2026-09-18
> 状态：源码修复与回归测试已实施（2026-09-18，16 个测试全绿），已同步更新 /Applications 内已安装 hook 副本并冒烟通过；尚未完成真实输入采样与第 4.2 节端到端验收。
> 原分析：[Cursor 会话被误报为 Claude Code](CURSOR_REPORTED_AS_CLAUDE.md)。原文保留排查历史；定位措辞、实现取舍和验收要求以本文为准。
> 下文代码路径相对项目根目录，行号为本次 review 时的位置。

## 1. 结论与修复范围

采用 **方案 A 最小过滤修复 + 方案 B 真实样本验收**，两者不是互斥选项。

- 相同会话标识同时出现在 `cursor` 和 `claude-code` 事件中，结合 Cursor 风格事件、工具名及现有 hook 配置，强烈支持同一 Cursor 会话被双重上报。
- 现有守卫的来源识别条件不足。不能把状态文件中的显示事件名当成原始输入，也不能断言新版 Cursor 已被实测同时满足两条放行条件。
- 在 Claude hook 的现有守卫之前增加五个 Cursor 特征字段的顶层键存在检查。
- 暂不排除 `conversation_id`；保留现有两个放行条件，但将其定位为兼容性启发式，而不是来源身份认证。
- 不改 Swift、状态结构、Cursor 上报通道，不新增进程树识别或通用来源识别框架。
- 必须通过本次误报的真实输入及真实 Claude 对照验收，才能宣称本次问题已修复。

## 2. 证据与推断的边界

### 2.1 本次 review 已核查的事实

| 事实 | 证据与限制 |
| --- | --- |
| 同一会话标识出现在两种来源的事件中 | 只读检查 `/tmp/agent-signal/status.json`，目标标识为 `cb1a27e7-4952-43fd-ba40-c5a6f30cb56d`。状态中的事件会持续变化，原文的事件数不是固定验收条件。 |
| Claude 路径会改写显示事件名 | `Sources/AgentSignalCLI/AgentSignalCLIMain.swift:114` 调用显示转换；`Sources/AgentSignalLightCore/HookAdapters.swift:232`、`:562`、`:569` 忽略大小写并输出规范名称。原始 `preToolUse` 可以显示成 `PreToolUse`。 |
| shell 守卫满足任意一个放行条件即转发 | `scripts/claude-code-signal-hook:40–45`：非空 `transcript_path`/`transcriptPath`，或事件首字符为大写。后者实际不是完整的 PascalCase 格式检查。 |
| session key 仍有环境变量回退 | `Sources/AgentSignalLightCore/HookAdapters.swift:285–305` 先取直接或嵌套标识，缺失时再读取 `CLAUDE_SESSION_ID`/`ANTHROPIC_SESSION_ID`。shell 守卫不用环境变量，不等于整个链路都不用。 |
| 旧版 Cursor 样本包含五个候选特征字段 | `script/test_claude_code_signal_hook.py:105–119` 保存了注明来自 Cursor 3.19.19 的 `sessionStart` 样本，包含空串、空数组和 `false`。不能据此保证 3.21.9 每种事件都有相同字段。 |
| Cursor 存在独立上报脚本 | 本机 `~/.cursor/hooks/agent-signal-bar.sh:47–60` 优先取 `conversation_id`，并以 `payload.get("agent") or "cursor"` 确定来源；不是无条件硬编码 `cursor`。修复不修改此脚本，仍需端到端确认正常事件继续上报。 |
| 实际注册指向应用内脚本 | 本次核查 `~/.claude/settings.json` 中有 28 条相关注册，均指向 `/Applications/AgentSignalLight.app/Contents/Resources/scripts/claude-code-signal-hook`；其 SHA-256 与源码一致。注册数及副本一致性需在部署时重新检查。 |

### 2.2 撤回或收窄的原结论

1. **撤回“新版 Cursor 原始事件已确定混用 PascalCase”。** 当前证据是转换后的显示名称，不足以反推原始大小写。
2. **收窄非空 transcript 推断。** 若 `beforeSubmitPrompt` 确实经过当前 shell 守卫，且没有事件字段或命令行覆盖等差异，它被放行支持该次输入存在非空 `transcript_path` 或 `transcriptPath`。这是有前提的间接证据，不是实时采样结果，也不代表其他事件。
3. **相同 UUID 是强关联证据，不是调用来源证明。** 不应把标识复用、继承或转发等可能性等同于随机 UUID 碰撞；不能仅凭状态记录彻底排除这些路径。
4. **环境变量污染尚不能仅凭 shell 代码排除。** 若原始输入有优先级更高的有效标识，才可针对该条事件排除环境变量回退。
5. **五字段是当前候选特征，不承诺永久专属。** 没有证据保证所有 Cursor 事件都携带它们，也不保证所有未来 Claude 或兼容包装层永不发送同名字段。

### 2.3 待验证的原因分支

| 假设 | 当前判断 | 验证方法 |
| --- | --- | --- |
| H1：Cursor 输入带非空 transcript，绕过大小写限制 | 有 `beforeSubmitPrompt` 的间接支持，是优先验证分支 | 记录该次输入的原始事件字段及两个 transcript 字段是否为非空字符串。 |
| H2：Cursor 输入本身使用大写开头的事件名，被另一放行条件接受 | 构造输入可证明机制存在，但尚未证实本次真实输入如此 | 在进入显示转换前记录原始事件字段，不使用状态文件中的事件名反推。 |
| H3：标识回退、复用或其他写入路径影响归因 | 不是当前首选解释，但不能仅凭相同 UUID 排除 | 对照实际 hook 命令、原始输入中标识的存在情况及必要的脱敏关联值；需要时再做局部调用链诊断。 |

可接受的根因表述为：**现有 Claude hook 使用非空 transcript 或大写开头事件作为放行条件，这些启发式不足以区分兼容客户端。具体是哪条条件放行了本次 Cursor 事件，需要真实输入确认。**

## 3. 最小实现方案

### 3.1 插入位置和逻辑

修改 `scripts/claude-code-signal-hook` 内嵌 Python：在 JSON 解析、`dict` 类型校验之后，现有 `text()` 函数及两条放行条件之前，插入：

```python
# 已知 Cursor 特征字段：按顶层键存在判断，空值也需要拦截。
# 这是兼容客户端过滤规则，不是来源身份认证。
CURSOR_MARKER_KEYS = (
    "cursor_version",
    "composer_mode",
    "workspace_roots",
    "is_background_agent",
    "generation_id",
)
if any(key in payload for key in CURSOR_MARKER_KEYS):
    sys.exit(1)
```

处理顺序为：

1. 无效 JSON 或非对象输入：不转发，保持原行为。
2. 任一顶层特征键存在：不转发，不再检查 transcript 或事件大小写。
3. 没有特征键：保留原有两个放行条件，任一满足则转发。
4. 均不满足：不转发。

仅检查顶层字段，不递归扫描工具输入、工具输出等任意内容，避免把用户数据中的同名键误当成客户端标记。

拒绝时的 Python `sys.exit(1)` 由外层 `if ! …; then exit 0` 吞掉，见 `scripts/claude-code-signal-hook:48–49`。**对调用方应正常退出、不输出内容、不调用下游上报器**，不能把拒绝误写成整个 shell 返回错误。

### 3.2 两个取舍的决定

**不将 `conversation_id` 纳入排除列表。**

- 它是通用会话标识，现有 `ClaudeHookAdapter.sessionKey` 将其作为兼容输入，见 `Sources/AgentSignalLightCore/HookAdapters.swift:285–299`。
- 这支持保留现有行为，但不能证明真实 Claude 一定发送该字段。
- 新版样本若缺少五个候选字段，先补齐证据、重新评估识别条件，不自动扩大到仅凭 `conversation_id` 拦截。

**保留现有两条放行条件。**

- 目的是减少对既有输入的兼容性影响。
- 更新脚本注释与测试说明，删除“Cursor 一定传 null”“Cursor 一定只用 camelCase”“非空 transcript 能证明来自 Claude”等断言。
- 不称为“负向排除 + 正向身份确认”双保险。没有特征字段的兼容客户端仍可能被放行。

### 3.3 明确的能力边界

以下输入在本方案下仍会放行：

```json
{
  "hook_event_name": "beforeSubmitPrompt",
  "conversation_id": "cursor-without-marker",
  "transcript_path": "/tmp/example.jsonl"
}
```

这是保留启发式的已知边界，而不是已解决场景。若本次真实误报输入属于此类，**不得以五字段构造测试通过作为修复完成依据**，需暂停定稿并调整方案。

同理，若真实 Claude 对照输入包含任一候选键，应先收窄规则再上线，不能静默漏报真实 Claude。

## 4. 真实输入采样与验收

### 4.1 采样要求

涉及修改用户 `~/.claude/settings.json` 或应用内脚本，实施前另行取得确认。当前文档更新不代表已授权这些操作。

1. 在实际触发误报的 hook 路径增加临时、只写本地日志的诊断步骤；不替换、不删除现有 hook，不改变其输入、输出或退出行为。
2. 优先覆盖提示提交、工具调用前后及 Stop。至少取得一份与本次误报可关联的原始输入元数据，再覆盖需要宣称修复的各类事件。
3. 日志保持最小化：时间、原始事件字段、顶层键集合、候选字段的类型及是否为空、两个 transcript 字段是否为非空字符串。
4. 会话关联优先使用会话标识的本地一致脱敏值，并记录标识字段是否存在及是否非空；必要时覆盖嵌套标识或环境变量回退的存在情况。不记录完整提示词、工具参数、工具输出、transcript 内容或完整路径。
5. 使用仅当前用户可访问的临时日志，不上传；诊断自身失败不得阻断正常 hook。采样结束后撤销临时配置，并按确认范围清理日志。
6. 取得真实 Claude 对照数据，确认已观察到的事件不会命中排除规则。

根据采样结果生成脱敏测试样本，保留对识别有意义的字段名、值类型及空值状态。注明来源版本、事件和采样日期；必须区分真实采样与人工构造。

### 4.2 端到端验收标准

- [ ] 新版 Cursor 的真实误报样本在旧守卫下能够解释或复现错误放行。
- [ ] 同一样本经修复后的完整 shell hook 不再调用 Claude 上报器，且退出码为 0。
- [ ] 真实 Claude 对照输入继续转发，参数及 stdin 不被修改。
- [ ] 安装后触发新的 Cursor 提示提交、工具调用与结束事件，不再新增对应的 `claude-code` 误报。
- [ ] Cursor 自己的正常上报仍存在；不是把两条通道都关闭后取得表面上的“不误报”。
- [ ] Claude 的正常工具调用及结束事件仍可显示。
- [ ] 临时诊断配置已撤销。

历史事件可能仍保留在状态文件中。验收按部署后的时间和会话关联检查新增事件，不能要求历史误报自动消失，也不要为验收直接清空用户状态。

## 5. 自动化测试与已执行验证

### 5.1 持久化回归测试（已实施）

在现有 `script/test_claude_code_signal_hook.py` 中补充，不新建测试框架：

| 测试组 | 输入重点 | 期望 |
| --- | --- | --- |
| 每个特征键单独命中 | 五个键分别单独出现；值覆盖 `null`、`""`、`[]`、`false` | 均不转发，不能只测包含全部字段的大样本。 |
| 原放行路径被前置拦截 | 大写开头事件 + 空 transcript；大写开头事件 + 非空 transcript；camelCase 事件 + 非空 transcript | 带任一特征键均不转发。 |
| transcript 别名 | 带特征键，使用非空 `transcriptPath` | 不转发。 |
| 真实旧版与新版样本 | 保留旧样本，补充第 4 节的新版脱敏输入 | Cursor 样本不转发。 |
| Claude 兼容性对照 | 无特征键的标准工具事件；无 transcript 的 `Stop`；仅非空 transcript；`conversation_id` + `Stop` | 保持放行；其中人工构造项标注为兼容性测试，而非真实协议证据。 |
| 顶层范围 | 仅工具输入等嵌套对象含同名键，顶层满足原放行条件 | 保持放行，不递归误拦用户内容。 |
| 原拒绝行为 | 空对象、非法 JSON、非对象 JSON、无 transcript 的 camelCase 事件 | 保持不转发。 |
| 完整脚本契约 | 检查是否调用 recorder、argv、stdin、退出码和标准输出 | 拒绝为正常空响应；放行时保持原参数和原始输入。 |

使用现有 `AGENT_SIGNAL_BIN` recorder 隔离下游调用，不写生产状态。若另需调用真实 CLI，使用 `AGENT_SIGNAL_LIGHT_STATE_FILE` 指向临时目录内的独立状态文件。

测试命令（在项目根目录运行）：

```bash
python3 -B script/test_claude_code_signal_hook.py
```

这些测试为 Python + shell，不依赖 Swift 构建。临时 `/tmp/repro_cursor_hook.py` 只能作为补充，不应成为唯一回归保障。

### 5.2 本次 review 已执行的检查

| 检查 | 结果 | 不代表什么 |
| --- | --- | --- |
| 当前完整 shell 测试 | 原有 9 个测试全部通过 | 不代表现有实现能过滤新版误报。 |
| `/tmp/repro_cursor_hook.py` | 三组构造 Cursor 输入均放行，两个 Claude 风格对照也放行 | 不是新版实时抓包；脚本中的“真实 Claude”命名不能替代采样来源证明。 |
| 内存中插入拟议 Python 守卫 | 五键 × 四种空值 × 三组事件/transcript 组合，共 60 组全部拒绝；4 组兼容性对照全部放行 | 没有改动仓库脚本，也未验证部署后端到端行为。 |
| 无五字段的 camelCase + 非空 transcript | 拟议守卫仍放行 | 说明真实样本验收不能省略。 |
| 源码与应用内 hook 校验值 | 本次 review 时一致 | 实施后需重新安装并复核实际生效副本。 |

## 6. 实施顺序、交付物与部署

1. **确认实施范围。** 本文仅记录方案；代码修改、诊断配置变更和应用安装分别按用户授权执行。
2. **补测试并确认旧实现失败。** 用明确标注的构造输入覆盖前置过滤及兼容性边界。
3. **最小修改 hook。** 加入顶层键存在检查，同步更新相关过时注释；不改 Swift 或 Cursor hook。
4. **运行回归。** 验证完整 shell 契约，而不只是抽出的 Python 条件。
5. **采样与回放。** 采样可提前进行，但真实误报样本和 Claude 对照必须在宣称修复完成前验证通过；字段假设不成立则回到方案评估。
6. **部署实际副本。** 经确认按项目正常打包、安装流程更新应用，不把源码变化等同于线上生效，也不未经确认直接覆盖应用资源。
7. **重新核查注册路径和副本。** 确认 `~/.claude/settings.json` 指向的脚本就是本次安装版本。
8. **完成第 4.2 节端到端验收。** 观察新事件，撤销诊断步骤，记录真实样本覆盖范围和已知边界。

计划修改文件：

- `scripts/claude-code-signal-hook`：前置过滤与注释。
- `script/test_claude_code_signal_hook.py`：持久化回归、脱敏样本与过时说明修订。
- 本文：后续记录采样和验收结果；当前没有任何实现或部署完成声明。

不修改原分析文档、Swift 源码、状态数据结构或 Cursor 上报脚本，不引入新的依赖、后台服务或客户端识别框架。若上线后发生真实 Claude 漏报，应先保留脱敏证据，经确认回退本次过滤改动或恢复上一安装版本，不删除会话数据，也不覆盖无关的在途修改。
