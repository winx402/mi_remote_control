#!/usr/bin/env python3
"""Offline profile-update contract checks; never read or write user configuration."""

import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("codex_profile", ROOT / "scripts/apply-codex-profile.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PATCH = json.loads((ROOT / "Resources/codex-profile.patch.json").read_text())


class CodexProfileTests(unittest.TestCase):
    def test_only_codex_changes(self):
        config = {
            "version": 8,
            "settings": {"holdMs": 812, "doubleMs": 315, "remoteVendorID": 1234,
                         "remoteProductID": 5678, "voiceOutputDevice": "Custom Microphone"},
            "profiles": {"global": {"menu": {"tap": {"type": "none"}}},
                         "com.example.custom": {"up": {"tap": {"type": "none"}}},
                         "com.openai.codex": {"home": {"tap": {"type": "overlay", "value": "codex_sessions"}},
                                              "left": {"tap": {"type": "system", "value": "codex_previous_chat"}}}},
            "globalShortcuts": {"left": {"holdMs": 912, "hold": {"type": "system", "value": "space_left"}}},
            "voiceProfiles": {"global": {"keyName": "custom", "mode": "hold"}},
            "appNavigationProfiles": {"com.openai.codex": {"mode": "buttons", "layout": "chat"},
                                      "com.example.custom": {"mode": "buttons", "layout": "video"}},
            "television": {"customLocalSetting": "must survive"},
            "futureSetting": {"unknown": [1, 2, 3]},
        }
        original = copy.deepcopy(config)
        result = MODULE.apply_preset(config, PATCH)
        expected = copy.deepcopy(original)
        expected["profiles"]["com.openai.codex"] = PATCH["profiles"]["com.openai.codex"]
        del expected["appNavigationProfiles"]["com.openai.codex"]
        self.assertEqual(result, expected)
        self.assertEqual(MODULE.apply_preset(result, PATCH), expected)  # idempotent
        self.assertNotIn("home", result["profiles"]["com.openai.codex"])
        result["profiles"]["com.openai.codex"]["ok"]["tap"]["value"] = "changed"
        self.assertEqual(PATCH["profiles"]["com.openai.codex"]["ok"]["tap"]["value"], "codex_context_ok")

    def test_legacy_without_global_shortcuts_stays_legacy(self):
        config = {"profiles": {"global": {}}, "settings": {"holdMs": 350}}
        result = MODULE.apply_preset(config, PATCH)
        self.assertNotIn("globalShortcuts", result)
        self.assertEqual(result["settings"], {"holdMs": 350})
        self.assertNotIn("appNavigationProfiles", result)

    def test_patch_has_only_codex_semantics(self):
        self.assertEqual(set(PATCH), {"profiles"})
        self.assertEqual(set(PATCH["profiles"]), {"com.openai.codex"})
        profile = PATCH["profiles"]["com.openai.codex"]
        for key in ("up", "down", "left", "right", "ok"):
            self.assertEqual(profile[key]["tap"], {"type": "system", "value": f"codex_context_{key}"})
        self.assertEqual(profile["ok"]["hold"], {"type": "system", "value": "codex_context_submit"})
        self.assertEqual(profile["voice"]["tap"], {"type": "system", "value": "codex_context_focus"})
        self.assertEqual(profile["voice"]["hold"], {"type": "system", "value": "codex_context_voice_start"})
        self.assertEqual(profile["menu"]["tap"], {"type": "overlay", "value": "codex_sessions"})
        self.assertNotIn("tv", profile)
        for key in ("up", "down", "left", "right", "back"):
            self.assertIs(profile[key]["overrideBase"], True)


if __name__ == "__main__":
    unittest.main()
