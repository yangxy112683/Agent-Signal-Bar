#!/usr/bin/env python3
"""Behavioral tests for the public claude-code-signal-hook script.

The hook's public contract: read a Claude Code hook payload on stdin, and
forward it to `agent-signal claude-hook` only when the payload does not look
like a known compatible client. Compatible clients (Cursor) also execute the
hooks registered in ~/.claude/settings.json, so any payload carrying a known
Cursor marker key at the top level must be dropped — matched by key presence
(empty values count too), never by truthiness. Payloads without markers fall
back to the legacy heuristics (non-empty transcript_path / transcriptPath, or
a capitalized event name), which are compatibility heuristics rather than
proof of a Claude Code origin.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts" / "claude-code-signal-hook"


class ClaudeCodeSignalHookTests(unittest.TestCase):
    def test_forwards_claude_code_pre_tool_use_payload(self) -> None:
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "d0ecc8f5-d975-416e-9a2f-d59842029bff",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
            "tool_name": "Bash",
        }

        invocation = self._run_hook(payload)

        self.assertIsNotNone(invocation, "Claude Code payload must be forwarded")
        assert invocation is not None
        self.assertEqual(invocation["argv"], ["claude-hook"])
        self.assertEqual(json.loads(invocation["stdin"]), payload)

    def test_forwards_pascal_case_event_without_transcript_path(self) -> None:
        payload = {
            "hook_event_name": "Stop",
            "session_id": "d0ecc8f5-d975-416e-9a2f-d59842029bff",
        }

        invocation = self._run_hook(payload)

        self.assertIsNotNone(
            invocation, "Claude Code always spells hook events in PascalCase"
        )

    def test_forwards_payload_that_carries_transcript_path(self) -> None:
        payload = {
            "hook_event_name": "Stop",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
        }

        invocation = self._run_hook(payload)

        self.assertIsNotNone(invocation, "transcript_path identifies Claude Code")
        assert invocation is not None
        self.assertEqual(invocation["argv"], ["claude-hook"])

    def test_forwards_claude_payload_with_marker_key_only_inside_tool_input(self) -> None:
        # 只判断顶层键：工具入参属于用户数据，里面的同名键不是客户端特征，
        # 不能因此误拦真实 Claude Code 事件。
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "d0ecc8f5-d975-416e-9a2f-d59842029bff",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
            "tool_name": "Bash",
            "tool_input": {
                "command": "echo cursor_version",
                "cursor_version": "in-user-data",
            },
        }

        invocation = self._run_hook(payload)

        self.assertIsNotNone(
            invocation, "嵌套在 tool_input 里的同名键不能触发拦截"
        )
        assert invocation is not None
        self.assertEqual(invocation["argv"], ["claude-hook"])

    def test_ignores_compatible_client_payload_despite_foreign_claude_env(self) -> None:
        # 环境变量不可信：Claude Code 同源工具（CodeBuddy 等）会把 CLAUDE_SESSION_ID
        # 注入到自己拉起的所有进程里，Cursor 的钩子进程可能直接继承到。
        payload = {
            "hook_event_name": "preToolUse",
            "conversation_id": "d87d8490-17db-457f-97b3-ed49b31c8f69",
        }

        invocation = self._run_hook(
            payload, environment={"CLAUDE_SESSION_ID": "inherited-session"}
        )

        self.assertIsNone(
            invocation,
            "an inherited CLAUDE_SESSION_ID must not turn a foreign payload into Claude",
        )

    def test_ignores_compatible_client_payload_with_only_conversation_id(self) -> None:
        # 兼容客户端不带特征字段的情形：只有 conversation_id（Cursor 的会话 id）
        # 与 Cursor 风格的工具名，靠旧判据丢弃。
        payload = {
            "hook_event_name": "preToolUse",
            "conversation_id": "d87d8490-17db-457f-97b3-ed49b31c8f69",
            "tool_name": "MCP:search",
        }

        invocation = self._run_hook(payload)

        self.assertIsNone(
            invocation,
            "payload without session_id/transcript_path must not be reported as Claude",
        )

    def test_ignores_payload_identified_only_by_cwd(self) -> None:
        payload = {"cwd": "/Users/me/work/agent-signal-bar"}

        invocation = self._run_hook(payload)

        self.assertIsNone(invocation, "a bare cwd is not proof of a Claude session")

    def test_ignores_cursor_session_start_payload(self) -> None:
        # 2026-09-10 从 Cursor 3.19.19 的钩子进程抓到的真实 payload：
        # session_id 与 conversation_id 同值，事件名驼峰，transcript_path 为 null。
        payload = {
            "conversation_id": "a51d5131-21f8-4d23-9dcb-e435c5b47e13",
            "generation_id": "",
            "model": "cursor-grok-4.6-high-fast",
            "model_id": "grok-4.6",
            "is_background_agent": False,
            "composer_mode": "agent",
            "session_id": "a51d5131-21f8-4d23-9dcb-e435c5b47e13",
            "hook_event_name": "sessionStart",
            "cursor_version": "3.19.19",
            "workspace_roots": [],
            "transcript_path": None,
        }

        invocation = self._run_hook(payload)

        self.assertIsNone(invocation, "Cursor's sessionStart must not be reported as Claude")

    def test_ignores_cursor_payload_with_marker_despite_legacy_guards(self) -> None:
        # 旧判据全过（PascalCase 事件 + 非空 transcript_path）的输入，
        # 只要带 Cursor 特征字段就必须丢弃，不能再当成 Claude Code 转发。
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "cb1a27e7-4952-43fd-ba40-c5a6f30cb56d",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
            "tool_name": "Shell",
            "cursor_version": "3.21.9",
        }

        invocation = self._run_hook(payload)

        self.assertIsNone(
            invocation,
            "cursor_version 出现时必须丢弃，无论旧判据是否放行",
        )

    def test_ignores_cursor_payload_with_any_marker_key(self) -> None:
        # 五个已知特征字段任一出现即丢弃；按「键是否存在」判断，与值无关。
        marker_keys = (
            "cursor_version",
            "composer_mode",
            "workspace_roots",
            "is_background_agent",
            "generation_id",
        )

        for key in marker_keys:
            with self.subTest(key=key):
                payload = {
                    "hook_event_name": "PreToolUse",
                    "session_id": "cb1a27e7-4952-43fd-ba40-c5a6f30cb56d",
                    "transcript_path": "/tmp/claude/transcript-1.jsonl",
                    key: "marker",
                }

                self.assertIsNone(
                    self._run_hook(payload),
                    f"{key} 出现时必须丢弃，无论旧判据是否放行",
                )

    def test_ignores_cursor_payload_with_empty_marker_values(self) -> None:
        # 空值同样拦截：真实样本里 generation_id 是空串、workspace_roots 是
        # 空数组、is_background_agent 是 false。必须按「键是否存在」判断，
        # 不能按真值判断。
        marker_keys = (
            "cursor_version",
            "composer_mode",
            "workspace_roots",
            "is_background_agent",
            "generation_id",
        )

        for key in marker_keys:
            for value in (None, "", [], False):
                with self.subTest(key=key, value=value):
                    payload = {
                        "hook_event_name": "Stop",
                        "session_id": "cb1a27e7-4952-43fd-ba40-c5a6f30cb56d",
                        key: value,
                    }

                    self.assertIsNone(
                        self._run_hook(payload),
                        "特征字段的值为空时同样必须丢弃",
                    )

    def test_ignores_cursor_camel_case_event_with_transcript_and_marker(self) -> None:
        # 2026-09-18 误报涉及的场景：camelCase 事件 + 非空 transcript_path
        # （旧判据①的放行路径）。只要带特征字段就必须丢弃。
        payload = {
            "hook_event_name": "beforeSubmitPrompt",
            "session_id": "cb1a27e7-4952-43fd-ba40-c5a6f30cb56d",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
            "cursor_version": "3.21.9",
        }

        self.assertIsNone(
            self._run_hook(payload),
            "camelCase 事件 + 非空 transcript 的兼容客户端 payload 必须丢弃",
        )

    def test_ignores_cursor_payload_with_transcript_path_alias(self) -> None:
        # transcriptPath（camelCase 别名）同样走旧判据①，特征字段仍要前置拦截。
        payload = {
            "hook_event_name": "beforeSubmitPrompt",
            "transcriptPath": "/tmp/claude/transcript-1.jsonl",
            "cursor_version": "3.21.9",
        }

        self.assertIsNone(
            self._run_hook(payload),
            "transcriptPath 别名不能绕过特征字段拦截",
        )

    def test_ignores_camel_case_event_even_with_session_id(self) -> None:
        payload = {
            "hook_event_name": "preToolUse",
            "session_id": "a51d5131-21f8-4d23-9dcb-e435c5b47e13",
            "tool_name": "MCP:search",
        }

        invocation = self._run_hook(payload)

        self.assertIsNone(
            invocation,
            "camelCase hook events are not how Claude Code names its events",
        )

    def test_ignores_empty_and_invalid_payloads(self) -> None:
        self.assertIsNone(self._run_hook({}, environment={}))
        self.assertIsNone(self._run_raw("not json"))

    def test_rejected_payload_exits_cleanly_without_output(self) -> None:
        # 拒绝对调用方是正常结果：退出码 0、无标准输出、不调用下游上报器。
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "cb1a27e7-4952-43fd-ba40-c5a6f30cb56d",
            "transcript_path": "/tmp/claude/transcript-1.jsonl",
            "cursor_version": "3.21.9",
        }

        contract = self._run_hook_contract(payload)

        self.assertFalse(contract["invoked"], "被拒绝的 payload 不能调用上报器")
        self.assertEqual(contract["returncode"], 0, "拒绝必须以退出码 0 结束")
        self.assertEqual(contract["stdout"], "", "拒绝时不应有标准输出")

    # MARK: - 辅助

    def _run_hook(
        self, payload: dict, environment: dict[str, str] | None = None
    ) -> dict | None:
        return self._run_raw(json.dumps(payload), environment or {})

    def _run_raw(self, stdin: str, environment: dict[str, str] | None = None) -> dict | None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            argv_file = root / "argv.json"
            stdin_file = root / "stdin.txt"
            recorder = root / "recorder"

            recorder.write_text(
                "#!/bin/sh\n"
                f'for arg in "$@"; do printf "%s\\n" "$arg"; done > "{argv_file}"\n'
                f'cat > "{stdin_file}"\n',
                encoding="utf-8",
            )
            recorder.chmod(recorder.stat().st_mode | stat.S_IEXEC)

            env = dict(os.environ)
            env["AGENT_SIGNAL_BIN"] = str(recorder)
            env.update(environment or {})

            subprocess.run(
                [str(HOOK)],
                input=stdin,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            if not argv_file.exists():
                return None

            argv = argv_file.read_text(encoding="utf-8").splitlines()
            return {"argv": argv, "stdin": stdin_file.read_text(encoding="utf-8")}

    def _run_hook_contract(self, payload: dict) -> dict:
        """跑完整脚本并返回契约：是否调用上报器、退出码与标准输出。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            argv_file = root / "argv.json"
            recorder = root / "recorder"

            recorder.write_text(
                "#!/bin/sh\n"
                f'for arg in "$@"; do printf "%s\\n" "$arg"; done > "{argv_file}"\n'
                "cat > /dev/null\n",
                encoding="utf-8",
            )
            recorder.chmod(recorder.stat().st_mode | stat.S_IEXEC)

            env = dict(os.environ)
            env["AGENT_SIGNAL_BIN"] = str(recorder)

            proc = subprocess.run(
                [str(HOOK)],
                input=json.dumps(payload),
                env=env,
                capture_output=True,
                text=True,
            )

            return {
                "invoked": argv_file.exists(),
                "returncode": proc.returncode,
                "stdout": proc.stdout,
            }


if __name__ == "__main__":
    unittest.main()
