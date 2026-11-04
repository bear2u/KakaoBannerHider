#!/usr/bin/env python3
"""Codex / Claude Code 남은 한도를 읽어 JSON 한 줄로 출력한다.

- 토큰은 읽기만 한다. 갱신(refresh)은 하지 않는다. (CLI가 스스로 갱신)
- Claude: 키체인 "Claude Code-credentials" → api.anthropic.com/api/oauth/usage
- Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage
"""
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
import urllib.request
import urllib.error

TIMEOUT = 15


def iso_to_epoch(value):
    if not value:
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except Exception:
        return None


def window_seconds_to_label(seconds):
    if not seconds:
        return "한도"
    seconds = int(seconds)
    if seconds <= 6 * 3600:
        return "5시간"
    if seconds <= 2 * 86400:
        return "일간"
    return "주간"


def remaining(used_percent):
    try:
        return round(max(0.0, min(100.0, 100.0 - float(used_percent))), 1)
    except Exception:
        return None


# ---------------------------------------------------------------- Claude

def claude_credentials():
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=10,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError("자격 증명 없음")
    return json.loads(out.stdout)["claudeAiOauth"]


def fetch_claude():
    cred = claude_credentials()
    if cred.get("expiresAt", 0) / 1000 < time.time():
        raise RuntimeError("갱신 필요 (claude)")
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": "Bearer " + cred["accessToken"],
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": "claude-code/2.0",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        data = json.loads(resp.read())

    session = data.get("five_hour") or {}
    weekly = data.get("seven_day") or {}
    primary = None
    secondary = None
    if session.get("utilization") is not None:
        primary = {
            "label": "5시간",
            "remaining": remaining(session.get("utilization")),
            "reset_at": iso_to_epoch(session.get("resets_at")),
        }
    if weekly.get("utilization") is not None:
        w = {
            "label": "주간",
            "remaining": remaining(weekly.get("utilization")),
            "reset_at": iso_to_epoch(weekly.get("resets_at")),
        }
        if primary is None:
            primary = w
        else:
            secondary = w
    return {
        "id": "claude",
        "label": "Claude",
        "ok": primary is not None,
        "plan": cred.get("subscriptionType"),
        "primary": primary,
        "secondary": secondary,
        "error": None if primary else "사용량 없음",
    }


# ---------------------------------------------------------------- Codex

def fetch_codex():
    auth = json.loads((Path.home() / ".codex" / "auth.json").read_text())
    tokens = auth.get("tokens") or {}
    token = tokens.get("access_token")
    account = tokens.get("account_id") or ""
    if not token:
        raise RuntimeError("자격 증명 없음")

    req = urllib.request.Request(
        "https://chatgpt.com/backend-api/wham/usage",
        headers={
            "Authorization": "Bearer " + token,
            "chatgpt-account-id": account,
            "User-Agent": "codex-cli/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        data = json.loads(resp.read())

    rate = data.get("rate_limit") or {}
    windows = []
    for key in ("primary_window", "secondary_window"):
        w = rate.get(key)
        if not w:
            continue
        windows.append({
            "label": window_seconds_to_label(w.get("limit_window_seconds")),
            "remaining": remaining(w.get("used_percent")),
            "reset_at": w.get("reset_at"),
            "_window": int(w.get("limit_window_seconds") or 0),
        })
    windows.sort(key=lambda w: w["_window"] or 10**9)
    for w in windows:
        w.pop("_window", None)
    return {
        "id": "codex",
        "label": "Codex",
        "ok": bool(windows),
        "plan": data.get("plan_type"),
        "primary": windows[0] if windows else None,
        "secondary": windows[1] if len(windows) > 1 else None,
        "error": None if windows else "한도 정보 없음",
    }


def main():
    providers = []
    for fn in (fetch_codex, fetch_claude):
        try:
            providers.append(fn())
        except urllib.error.HTTPError as e:
            providers.append({
                "id": fn.__name__.replace("fetch_", ""), "label": "",
                "ok": False, "plan": None, "primary": None, "secondary": None,
                "error": "갱신 필요" if e.code in (401, 403) else "HTTP %d" % e.code,
            })
        except Exception as e:  # noqa: BLE001
            providers.append({
                "id": fn.__name__.replace("fetch_", ""), "label": "",
                "ok": False, "plan": None, "primary": None, "secondary": None,
                "error": str(e)[:60],
            })
    labels = {"codex": "Codex", "claude": "Claude"}
    for p in providers:
        p["label"] = labels.get(p["id"], p["id"])
    print(json.dumps({"updated_at": int(time.time()), "providers": providers},
                     ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": str(e)[:120]}, ensure_ascii=False))
        sys.exit(1)
