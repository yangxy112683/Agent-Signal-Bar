#!/usr/bin/env python3
"""Behavioral tests for the public claude-code-signal-hook script.

The hook's public contract: read a Claude Code hook payload on stdin, and
forward it to `agent-signal claude-hook` **only** when the payload really
comes from Claude Code. Compatible clients (Cursor) also execute the hooks
registered in ~/.claude/settings.json, but they only carry `conversation_id`,
which the adapter would happily turn into a "Claude" session.
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
        # Cursor 的 agent 会执行 ~/.claude/settings.json 里的钩子，payload 只带
        # conversation_id（Cursor 的会话 id）与 Cursor 风格的工具名。
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


if __name__ == "__main__":
    unittest.main()
