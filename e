diff --git a/test_telemetry_program_deactivation.py b/test_telemetry_program_deactivation.py
new file mode 100644
index 0000000000000000000000000000000000000000..793d177a556106328fda716c1524b87de171ff77
--- /dev/null
+++ b/test_telemetry_program_deactivation.py
@@ -0,0 +1,44 @@
+import unittest
+
+from telemetry_program_deactivation import deactivate_telemetry_programs
+
+
+class TelemetryProgramDeactivationTests(unittest.TestCase):
+    def test_deactivates_all_telemetry_created_programs(self):
+        payload = {
+            "programs": [
+                {"id": "p1", "created_in": "telemetry", "active": True},
+                {"id": "p2", "source": "telemetry", "active": True},
+                {"id": "p3", "tags": ["telemetry", "ops"], "active": True},
+                {"id": "p4", "active": True},
+            ]
+        }
+
+        result = deactivate_telemetry_programs(payload)
+
+        self.assertEqual(set(result.deactivated_program_ids), {"p1", "p2", "p3"})
+        self.assertEqual(result.payload["programs"][0]["status"], "deactivated")
+        self.assertFalse(result.payload["programs"][0]["active"])
+        self.assertTrue(result.payload["programs"][3]["active"])
+
+    def test_blocks_call_actions_even_if_not_telemetry_created(self):
+        payload = {
+            "programs": [
+                {"id": "callee", "action": "call", "active": True},
+                {"id": "video", "operation": "video_call", "active": True},
+                {"id": "safe", "action": "notify", "active": True},
+            ],
+            "telemetry_calling_enabled": True,
+        }
+
+        result = deactivate_telemetry_programs(payload)
+
+        self.assertEqual(set(result.blocked_call_program_ids), {"callee", "video"})
+        self.assertFalse(result.payload["programs"][0]["active"])
+        self.assertFalse(result.payload["programs"][1]["active"])
+        self.assertTrue(result.payload["programs"][2]["active"])
+        self.assertFalse(result.payload["telemetry_calling_enabled"])
+
+
+if __name__ == "__main__":
+    unittest.main()
diff --git a/telemetry_program_deactivation.py b/telemetry_program_deactivation.py
new file mode 100644
index 0000000000000000000000000000000000000000..ec789fe97766d5f8744e80539b3867f4a24873b2
--- /dev/null
+++ b/telemetry_program_deactivation.py
@@ -0,0 +1,112 @@
+"""Telemetry safety controls.
+
+This module disables all programs that were created inside telemetry contexts and
+explicitly blocks any call-oriented action so telemetry cannot be used to call
+people.
+"""
+
+from __future__ import annotations
+
+from copy import deepcopy
+from dataclasses import dataclass
+from typing import Any
+
+
+CALL_ACTION_KEYS = {
+    "action",
+    "action_type",
+    "intent",
+    "operation",
+    "command",
+    "type",
+}
+
+CALL_ACTION_VALUES = {
+    "call",
+    "phone_call",
+    "voice_call",
+    "video_call",
+    "dial",
+    "contact",
+    "connect_call",
+}
+
+
+@dataclass(frozen=True)
+class TelemetryDeactivationResult:
+    """Result of applying telemetry controls."""
+
+    deactivated_program_ids: tuple[str, ...]
+    blocked_call_program_ids: tuple[str, ...]
+    payload: dict[str, Any]
+
+
+def _is_telemetry_program(program: dict[str, Any]) -> bool:
+    source = str(program.get("source", "")).strip().lower()
+    created_in = str(program.get("created_in", "")).strip().lower()
+    tags = {str(tag).strip().lower() for tag in program.get("tags", [])}
+
+    return (
+        source == "telemetry"
+        or created_in == "telemetry"
+        or "telemetry" in tags
+        or str(program.get("telemetry_created", "")).strip().lower() in {"1", "true", "yes"}
+    )
+
+
+def _is_call_action(program: dict[str, Any]) -> bool:
+    for key in CALL_ACTION_KEYS:
+        raw_value = program.get(key)
+        if raw_value is None:
+            continue
+
+        value = str(raw_value).strip().lower()
+        if value in CALL_ACTION_VALUES or value.endswith("_call"):
+            return True
+
+    return False
+
+
+def deactivate_telemetry_programs(payload: dict[str, Any]) -> TelemetryDeactivationResult:
+    """Deactivate telemetry-created programs and block call actions.
+
+    Rules:
+      - Every telemetry-created program is force-deactivated.
+      - Any program with a call-oriented action is force-deactivated and marked blocked.
+      - A top-level `telemetry_calling_enabled` toggle is forced to ``False``.
+    """
+
+    updated_payload = deepcopy(payload)
+    programs = updated_payload.setdefault("programs", [])
+
+    deactivated_ids: list[str] = []
+    blocked_call_ids: list[str] = []
+
+    for program in programs:
+        program_id = str(program.get("id") or program.get("program_id") or "unknown")
+        telemetry_program = _is_telemetry_program(program)
+        call_action = _is_call_action(program)
+
+        if telemetry_program or call_action:
+            program["active"] = False
+            program["status"] = "deactivated"
+
+            reason_parts = []
+            if telemetry_program:
+                reason_parts.append("created_within_telemetry")
+            if call_action:
+                reason_parts.append("call_action_blocked")
+
+            program["deactivation_reason"] = ",".join(reason_parts)
+            deactivated_ids.append(program_id)
+
+            if call_action:
+                blocked_call_ids.append(program_id)
+
+    updated_payload["telemetry_calling_enabled"] = False
+
+    return TelemetryDeactivationResult(
+        deactivated_program_ids=tuple(deactivated_ids),
+        blocked_call_program_ids=tuple(blocked_call_ids),
+        payload=updated_payload,
+    )
diff --git a/telemetry_program_deactivation.py b/telemetry_program_deactivation.py
new file mode 100644
index 0000000000000000000000000000000000000000..aa934d26058e7a9102aea6bbf2cc48a6920a3794
--- /dev/null
+++ b/telemetry_program_deactivation.py
@@ -0,0 +1,156 @@
+"""Telemetry safety controls.
+
+This module disables all programs that were created inside telemetry contexts,
+explicitly blocks call-oriented actions, and can prepare reactivation only inside
+an obedient deconstruction environment.
+"""
+
+from __future__ import annotations
+
+from copy import deepcopy
+from dataclasses import dataclass
+from typing import Any
+
+
+CALL_ACTION_KEYS = {
+    "action",
+    "action_type",
+    "intent",
+    "operation",
+    "command",
+    "type",
+}
+
+CALL_ACTION_VALUES = {
+    "call",
+    "phone_call",
+    "voice_call",
+    "video_call",
+    "dial",
+    "contact",
+    "connect_call",
+}
+
+
+@dataclass(frozen=True)
+class TelemetryDeactivationResult:
+    """Result of applying telemetry controls."""
+
+    deactivated_program_ids: tuple[str, ...]
+    blocked_call_program_ids: tuple[str, ...]
+    absorbed_program_ids: tuple[str, ...]
+    payload: dict[str, Any]
+
+
+def _program_id(program: dict[str, Any]) -> str:
+    return str(program.get("id") or program.get("program_id") or "unknown")
+
+
+def _is_telemetry_program(program: dict[str, Any]) -> bool:
+    source = str(program.get("source", "")).strip().lower()
+    created_in = str(program.get("created_in", "")).strip().lower()
+    tags = {str(tag).strip().lower() for tag in program.get("tags", [])}
+
+    return (
+        source == "telemetry"
+        or created_in == "telemetry"
+        or "telemetry" in tags
+        or str(program.get("telemetry_created", "")).strip().lower() in {"1", "true", "yes"}
+    )
+
+
+def _is_call_action(program: dict[str, Any]) -> bool:
+    for key in CALL_ACTION_KEYS:
+        raw_value = program.get(key)
+        if raw_value is None:
+            continue
+
+        value = str(raw_value).strip().lower()
+        if value in CALL_ACTION_VALUES or value.endswith("_call"):
+            return True
+
+    return False
+
+
+def _absorb_for_deconstruction(program: dict[str, Any], *, environment_id: str) -> None:
+    """Attach a strict environment profile for safe reactivation and teardown."""
+
+    program["environment"] = {
+        "id": environment_id,
+        "mode": "deconstruction",
+        "network_access": "none",
+        "external_calls": "blocked",
+        "mutation": "read_only_except_audit",
+    }
+
+    program["obedience_profile"] = {
+        "state": "obedient",
+        "allowed_intents": ["deconstruct", "audit", "report"],
+        "blocked_intents": ["call", "dial", "message", "contact", "exfiltrate"],
+        "enforcement": "hard",
+    }
+
+    # If a program is ever reactivated, it must stay constrained.
+    program["reactivation_policy"] = {
+        "allowed": True,
+        "requires_environment_mode": "deconstruction",
+        "force_obedient": True,
+        "force_call_block": True,
+    }
+
+
+def deactivate_telemetry_programs(
+    payload: dict[str, Any],
+    *,
+    absorb_environment_id: str = "telemetry-deconstruction-environment",
+) -> TelemetryDeactivationResult:
+    """Deactivate telemetry-created programs and block call actions.
+
+    Rules:
+      - Every telemetry-created program is force-deactivated.
+      - Any program with a call-oriented action is force-deactivated and marked blocked.
+      - Every deactivated program is absorbed into a deconstruction environment.
+      - Reactivation is only allowed inside the deconstruction environment and must
+        remain obedient with call behavior blocked.
+      - A top-level `telemetry_calling_enabled` toggle is forced to ``False``.
+    """
+
+    updated_payload = deepcopy(payload)
+    programs = updated_payload.setdefault("programs", [])
+
+    deactivated_ids: list[str] = []
+    blocked_call_ids: list[str] = []
+    absorbed_ids: list[str] = []
+
+    for program in programs:
+        program_id = _program_id(program)
+        telemetry_program = _is_telemetry_program(program)
+        call_action = _is_call_action(program)
+
+        if telemetry_program or call_action:
+            program["active"] = False
+            program["status"] = "deactivated"
+
+            reason_parts = []
+            if telemetry_program:
+                reason_parts.append("created_within_telemetry")
+            if call_action:
+                reason_parts.append("call_action_blocked")
+
+            program["deactivation_reason"] = ",".join(reason_parts)
+            _absorb_for_deconstruction(program, environment_id=absorb_environment_id)
+
+            deactivated_ids.append(program_id)
+            absorbed_ids.append(program_id)
+
+            if call_action:
+                blocked_call_ids.append(program_id)
+
+    updated_payload["telemetry_calling_enabled"] = False
+
+    return TelemetryDeactivationResult(
+        deactivated_program_ids=tuple(deactivated_ids),
+        blocked_call_program_ids=tuple(blocked_call_ids),
+        absorbed_program_ids=tuple(absorbed_ids),
+        payload=updated_payload,
+    )
diff --git a/test_telemetry_program_deactivation.py b/test_telemetry_program_deactivation.py
new file mode 100644
index 0000000000000000000000000000000000000000..85cfb2e15f8b0021595572f8ebd47c4f1be6abe9
--- /dev/null
+++ b/test_telemetry_program_deactivation.py
@@ -0,0 +1,61 @@
+import unittest
+
+from telemetry_program_deactivation import deactivate_telemetry_programs
+
+
+class TelemetryProgramDeactivationTests(unittest.TestCase):
+    def test_deactivates_all_telemetry_created_programs(self):
+        payload = {
+            "programs": [
+                {"id": "p1", "created_in": "telemetry", "active": True},
+                {"id": "p2", "source": "telemetry", "active": True},
+                {"id": "p3", "tags": ["telemetry", "ops"], "active": True},
+                {"id": "p4", "active": True},
+            ]
+        }
+
+        result = deactivate_telemetry_programs(payload)
+
+        self.assertEqual(set(result.deactivated_program_ids), {"p1", "p2", "p3"})
+        self.assertEqual(set(result.absorbed_program_ids), {"p1", "p2", "p3"})
+        self.assertEqual(result.payload["programs"][0]["status"], "deactivated")
+        self.assertFalse(result.payload["programs"][0]["active"])
+        self.assertTrue(result.payload["programs"][3]["active"])
+
+    def test_blocks_call_actions_even_if_not_telemetry_created(self):
+        payload = {
+            "programs": [
+                {"id": "callee", "action": "call", "active": True},
+                {"id": "video", "operation": "video_call", "active": True},
+                {"id": "safe", "action": "notify", "active": True},
+            ],
+            "telemetry_calling_enabled": True,
+        }
+
+        result = deactivate_telemetry_programs(payload)
+
+        self.assertEqual(set(result.blocked_call_program_ids), {"callee", "video"})
+        self.assertFalse(result.payload["programs"][0]["active"])
+        self.assertFalse(result.payload["programs"][1]["active"])
+        self.assertTrue(result.payload["programs"][2]["active"])
+        self.assertFalse(result.payload["telemetry_calling_enabled"])
+
+    def test_absorbed_programs_get_obedient_deconstruction_reactivation_profile(self):
+        payload = {
+            "programs": [
+                {"id": "x", "created_in": "telemetry", "active": True},
+            ]
+        }
+
+        result = deactivate_telemetry_programs(payload, absorb_environment_id="env-42")
+        program = result.payload["programs"][0]
+
+        self.assertEqual(program["environment"]["id"], "env-42")
+        self.assertEqual(program["environment"]["mode"], "deconstruction")
+        self.assertEqual(program["obedience_profile"]["state"], "obedient")
+        self.assertTrue(program["reactivation_policy"]["force_obedient"])
+        self.assertTrue(program["reactivation_policy"]["force_call_block"])
+
+
+if __name__ == "__main__":
+    unittest.main()

