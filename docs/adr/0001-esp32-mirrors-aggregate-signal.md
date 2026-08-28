---
status: accepted
---

# ESP32 硬件红绿灯镜像 aggregate 信号，不做 per-agent 多路显示

用户同时运行 3-4 个 agent 时，ESP32 硬件红绿灯只镜像 `MenuBarStatusModel.lightSnapshot.aggregate`（单一 `AgentSignal` 值），与桌面悬浮窗 `FloatingSignalWindowController` 展示的完全一致，不为每个 agent/session 单独分配一路 LED 或状态位。

考虑过的替代方案：让硬件按 session 展示多路独立状态（每个 agent 一组灯），以便直接看出具体哪个 agent 卡住。放弃的原因是——`aggregate` 的聚合优先级（红色永不被绿色覆盖等）本身就是"信号灯"这个产品形态的核心设计意图：用户要看的是"现在该不该管"，不是"每个 agent 具体在干什么"。做 per-agent 多路显示需要 Mac 端额外传输 per-session 数据、硬件端做多路输出电路，且会让硬件和悬浮窗出现"看起来不一样"的体验分裂。

后续如果需求变成"要分清是哪个 agent 卡住"，需要重新评估，这不是本决策能覆盖的场景。
