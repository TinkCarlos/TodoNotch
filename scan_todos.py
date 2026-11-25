#!/usr/bin/env python3
"""
Fast cross-project conversation scanner for daily unfinished-task reminders.
Uses Lmemory session excerpts first (~400x smaller than raw logs), then does
targeted tail-only raw JSONL reads for truncated, newer, or unsynced sessions.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SHANGHAI_TZ = timezone(timedelta(hours=8))


def resolve_default_vault() -> Path:
    """Resolve the user's Lmemory/Obsidian vault without hardcoding a personal path."""
    for env_key in ("LMEMORY_VAULT", "OBSIDIAN_VAULT"):
        val = os.environ.get(env_key, "").strip()
        if val:
            p = Path(val).expanduser()
            if p.exists():
                return p
    plist_path = Path.home() / "Library/LaunchAgents/local.dsh-lmemory.daily-evolution.plist"
    if plist_path.is_file():
        try:
            with plist_path.open("rb") as fh:
                plist_data = plistlib.load(fh)
            env_vars = plist_data.get("EnvironmentVariables") or {}
            v = str(env_vars.get("OBSIDIAN_VAULT", "")).strip()
            if v:
                p = Path(v).expanduser()
                if p.exists():
                    return p
        except Exception:
            pass
    return Path.home() / "Documents/LmemoryVault"


DEFAULT_VAULT = resolve_default_vault()
DEFAULT_EXCERPTS_DIR = DEFAULT_VAULT / "05 时间日志/会话摘录"
DEFAULT_CODEX_DIR = Path.home() / ".codex/sessions"
DEFAULT_AGY_DIR = Path.home() / ".gemini/antigravity/brain"
DEFAULT_CURSOR_DIR = Path.home() / ".cursor/projects"
DEFAULT_CLAUDE_DIR = Path.home() / ".claude/projects"
DEFAULT_STATE_FILE = Path(__file__).resolve().parent / "state.json"
LMEMORY_PYTHON = Path.home() / ".local/share/uv/tools/lmemory/bin/python"

NOISE_PROJECTS = {"x-ai-blogger", "daily-todo-reminder", "TodoNotch"}
NOISE_RE = re.compile(
    r"(?:^(?:Only the tools attached to this request|Context handoff|"
    r"t3_code_orchestration_instructions|Act as the research sub-agent|"
    r"Act as the review sub-agent|Delegated task node|纠正候选|纠正[｜：:]|"
    r"<heartbeat>|请严格按以下(?:闭环|防限流)|请作为 Boloop|"
    r"请执行每日\s*9\s*点跨项目待办扫描|<t3_code_orchestration_instructions)|"
    r"Only the tools attached to this request|sent this message, not the user\.|"
    r"Act as the (?:implementation|research|review) sub-agent)",
    re.I,
)
SYSTEM_MSG_RE = re.compile(
    r"^(?:# AGENTS\.md|<environment_context|<permissions instructions|"
    r"<collaboration_mode|<turn_aborted|<send_user_message_question_reply|"
    r"<system-reminder|<user_instructions|<task-notification)",
    re.I,
)
TURN_ASK_RE = re.compile(r"^-\s*\*\*(?:问|Q)\*\*[^：:]*[：:]\s*(.*)$")
TURN_ANS_RE = re.compile(r"^\s*\*\*(?:答|A)\*\*[：:]\s*(.*)$")
PROJECT_PATH_RE = re.compile(r"/Users/[^/\s]+/projects/([^/\s)'\"`]+)")

HEAD_BYTES = 16 * 1024
TAIL_BYTES = 1024 * 1024
TAIL_FALLBACK_BYTES = 4 * 1024 * 1024
ASK_CLIP = 2000
ANSWER_CLIP = 2500  # Keep tail of reply where next steps / open items live


def fmt_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=SHANGHAI_TZ).isoformat(timespec="seconds")


def clip_head(text: str, limit: int = ASK_CLIP) -> str:
    s = re.sub(r"\s+", " ", (text or "").strip())
    return s if len(s) <= limit else s[:limit] + "…"


def clip_tail(text: str, limit: int = ANSWER_CLIP) -> str:
    """Keep the end of assistant replies so open questions/TODOs are never clipped."""
    s = re.sub(r"[ \t]+", " ", (text or "").strip())
    s = re.sub(r"\n{3,}", "\n\n", s)
    if len(s) <= limit:
        return s
    return "…" + s[-limit:]


def clean_user_text(raw: str) -> str:
    s = (raw or "").strip()
    for tag in ("USER_REQUEST", "user_request"):
        m = re.search(rf"<{tag}>\s*([\s\S]*?)\s*</{tag}>", s)
        if m:
            s = m.group(1).strip()
            break
    if "## My request:" in s:
        s = s.split("## My request:", 1)[1].strip()
    return s


def is_noise(title: str = "", project: str = "", ask: str = "") -> bool:
    if (project or "").strip().lower() in NOISE_PROJECTS:
        return True
    probe = f"{title}\n{ask}".strip()
    if not probe:
        return True
    if NOISE_RE.search(title.strip()) or NOISE_RE.search(ask.strip()):
        return True
    if SYSTEM_MSG_RE.search(probe):
        return True
    return False


def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    normalized = text.replace("\r\n", "\n")
    if not normalized.startswith("---\n"):
        return {}, normalized
    end = normalized.find("\n---\n", 4)
    if end == -1:
        return {}, normalized
    meta: dict[str, str] = {}
    for line in normalized[4:end].splitlines():
        m = re.match(r"^([A-Za-z0-9_]+)\s*:\s*(.*)$", line)
        if m:
            val = m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                val = val[1:-1]
            meta[m.group(1)] = val
    return meta, normalized[end + 5 :].strip()


def read_head_and_tail_lines(path: Path, tail_bytes: int = TAIL_BYTES) -> tuple[list[str], list[str], bool]:
    """Read only first HEAD_BYTES and last tail_bytes to avoid loading huge JSONL files."""
    size = path.stat().st_size
    if size <= HEAD_BYTES + tail_bytes:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return lines, lines, False
    with path.open("rb") as fh:
        head_raw = fh.read(HEAD_BYTES)
        fh.seek(max(0, size - tail_bytes))
        tail_raw = fh.read()
    head_lines = head_raw.decode("utf-8", errors="replace").splitlines()
    tail_lines = tail_raw.decode("utf-8", errors="replace").splitlines()
    if len(tail_lines) > 1:
        tail_lines = tail_lines[1:]  # drop partial first line after seek
    return head_lines, tail_lines, True


def parse_excerpt_md(path: Path, mtime: float) -> dict[str, Any] | None:
    raw = path.read_text(encoding="utf-8", errors="replace")
    meta, body = parse_frontmatter(raw)
    if meta.get("type", "").lower() == "correction":
        return None
    agent = (meta.get("agent") or "other").strip().lower()
    session_id = (meta.get("session") or path.stem).strip()
    project = (meta.get("project") or "").strip()
    if not project or project == "-":
        pr = meta.get("project_root", "").strip()
        project = Path(pr).name if pr else "unknown"
    title = (meta.get("title") or path.stem).strip()

    turns: list[dict[str, str]] = []
    cur: dict[str, str] | None = None
    in_ans = False
    for line in body.splitlines():
        m_ask = TURN_ASK_RE.match(line)
        if m_ask:
            if cur:
                turns.append(cur)
            cur = {"ask": m_ask.group(1).strip(), "answer": ""}
            in_ans = False
            continue
        m_ans = TURN_ANS_RE.match(line)
        if m_ans and cur is not None:
            cur["answer"] = m_ans.group(1).strip()
            in_ans = True
            continue
        if cur is not None and (line.startswith("  ") or line == ""):
            key = "answer" if in_ans else "ask"
            cur[key] = (cur[key] + "\n" + line.strip()).strip()
    if cur:
        turns.append(cur)

    tail_turns = turns[-3:]
    truncated = ("超出一页的摘录上限" in body) or any(
        t["answer"].rstrip().endswith("…") for t in tail_turns
    )
    return {
        "agent": agent,
        "session_id": session_id,
        "project": project,
        "source": "lmemory-excerpt",
        "updated_at": fmt_iso(mtime),
        "mtime": mtime,
        "title": clip_head(title, 120),
        "excerpt_path": str(path),
        "raw_path": None,
        "truncated": truncated,
        "tail_turns": [
            {"ask": clip_head(t["ask"]), "answer": clip_tail(t["answer"])}
            for t in tail_turns
        ],
    }


def _extract_content_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts).strip()
    return ""


def _build_turns(events: list[tuple[str, str]]) -> list[dict[str, str]]:
    turns: list[dict[str, str]] = []
    for role, text in events:
        if role == "user":
            turns.append({"ask": text, "answer": ""})
        elif role == "assistant":
            if not turns:
                turns.append({"ask": "", "answer": text})
            else:
                turns[-1]["answer"] = text
    return turns[-3:]


def parse_codex_raw(path: Path, mtime: float) -> dict[str, Any] | None:
    head_lines, tail_lines, was_sliced = read_head_and_tail_lines(path)
    session_id = ""
    cwd = ""
    first_ask = ""
    for line in head_lines:
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "session_meta" and isinstance(obj.get("payload"), dict):
            pl = obj["payload"]
            session_id = session_id or str(pl.get("id") or pl.get("session_id") or "")
            cwd = cwd or str(pl.get("cwd") or "")
            src = str(pl.get("source") or "")
            origin = str(pl.get("originator") or "")
            # Skip automated headless / subagent runs
            if "exec" in origin.lower() or "subagent" in src.lower() or "thread_spawn" in src.lower():
                return None
        elif not first_ask and obj.get("type") == "response_item":
            pl = obj.get("payload") or {}
            if pl.get("type") == "message" and pl.get("role") == "user":
                txt = _extract_content_text(pl.get("content"))
                if txt and not SYSTEM_MSG_RE.search(txt):
                    first_ask = clean_user_text(txt)

    def _extract_codex_events(lines: list[str]) -> list[tuple[str, str]]:
        ev: list[tuple[str, str]] = []
        for line in lines:
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            typ = obj.get("type")
            pl = obj.get("payload") or {}
            if typ == "response_item" and pl.get("type") == "message":
                role = pl.get("role")
                txt = _extract_content_text(pl.get("content"))
                if not txt:
                    continue
                if role == "user":
                    if SYSTEM_MSG_RE.search(txt):
                        continue
                    cleaned = clean_user_text(txt)
                    if cleaned:
                        ev.append(("user", cleaned))
                elif role == "assistant":
                    ev.append(("assistant", txt))
            elif typ == "event_msg":
                et = pl.get("type")
                if et == "user_message" and pl.get("message"):
                    cleaned = clean_user_text(str(pl["message"]))
                    if cleaned and not SYSTEM_MSG_RE.search(cleaned):
                        ev.append(("user", cleaned))
                elif et == "agent_message" and pl.get("message"):
                    ev.append(("assistant", str(pl["message"]).strip()))
        return ev

    events = _extract_codex_events(tail_lines)
    if was_sliced and not any(r == "assistant" for r, _ in events):
        _, wider_tail, _ = read_head_and_tail_lines(path, TAIL_FALLBACK_BYTES)
        events = _extract_codex_events(wider_tail)

    tail_turns = _build_turns(events)
    if not tail_turns:
        return None
    title = first_ask or tail_turns[0]["ask"] or path.stem
    project = Path(cwd).name if cwd else "unknown"
    return {
        "agent": "codex",
        "session_id": session_id or path.stem,
        "project": project,
        "source": "raw-tail",
        "updated_at": fmt_iso(mtime),
        "mtime": mtime,
        "title": clip_head(title, 120),
        "excerpt_path": None,
        "raw_path": str(path),
        "truncated": False,
        "tail_turns": [
            {"ask": clip_head(t["ask"]), "answer": clip_tail(t["answer"])}
            for t in tail_turns
        ],
    }


def parse_antigravity_raw(path: Path, mtime: float) -> dict[str, Any] | None:
    session_id = path.parents[2].name
    head_lines, tail_lines, was_sliced = read_head_and_tail_lines(path)
    first_ask = ""
    for line in head_lines:
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "USER_INPUT" and obj.get("content"):
            first_ask = clean_user_text(str(obj["content"]))
            if first_ask:
                break

    def _extract_agy_events(lines: list[str]) -> list[tuple[str, str]]:
        ev: list[tuple[str, str]] = []
        for line in lines:
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            typ = obj.get("type")
            content = obj.get("content")
            if not content:
                continue
            if typ == "USER_INPUT":
                cleaned = clean_user_text(str(content))
                if cleaned and not SYSTEM_MSG_RE.search(cleaned):
                    ev.append(("user", cleaned))
            elif typ == "PLANNER_RESPONSE":
                ev.append(("assistant", str(content).strip()))
        return ev

    events = _extract_agy_events(tail_lines)
    if was_sliced and not any(r == "assistant" for r, _ in events):
        _, wider_tail, _ = read_head_and_tail_lines(path, TAIL_FALLBACK_BYTES)
        events = _extract_agy_events(wider_tail)

    tail_turns = _build_turns(events)
    if not tail_turns:
        return None
    probe = f"{first_ask} " + " ".join(t["ask"] + " " + t["answer"] for t in tail_turns)
    m_proj = PROJECT_PATH_RE.search(probe)
    project = m_proj.group(1) if m_proj else "unknown"
    title = first_ask or tail_turns[0]["ask"] or session_id
    return {
        "agent": "antigravity",
        "session_id": session_id,
        "project": project,
        "source": "raw-tail",
        "updated_at": fmt_iso(mtime),
        "mtime": mtime,
        "title": clip_head(title, 120),
        "excerpt_path": None,
        "raw_path": str(path),
        "truncated": False,
        "tail_turns": [
            {"ask": clip_head(t["ask"]), "answer": clip_tail(t["answer"])}
            for t in tail_turns
        ],
    }


def parse_claude_or_cursor_raw(path: Path, mtime: float, agent: str) -> dict[str, Any] | None:
    head_lines, tail_lines, _ = read_head_and_tail_lines(path)
    cwd = ""
    session_id = path.stem
    events: list[tuple[str, str]] = []

    for line in head_lines[:15]:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("isSidechain") or obj.get("entrypoint") == "sdk":
            return None
        cwd = cwd or str(obj.get("cwd") or "")
        session_id = str(obj.get("sessionId") or session_id)

    for line in tail_lines:
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = obj.get("role") or obj.get("type")
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else obj
        if role not in ("user", "assistant"):
            role = msg.get("role")
        if role not in ("user", "assistant"):
            continue
        txt = _extract_content_text(msg.get("content"))
        if not txt:
            continue
        if role == "user":
            if SYSTEM_MSG_RE.search(txt):
                continue
            cleaned = clean_user_text(txt)
            if cleaned:
                events.append(("user", cleaned))
        else:
            events.append(("assistant", txt))

    tail_turns = _build_turns(events)
    if not tail_turns:
        return None
    if cwd:
        project = Path(cwd).name
    elif agent == "cursor" and len(path.parents) >= 3:
        project = path.parents[2].name.split("-")[-1] or "unknown"
    else:
        project = "unknown"
    return {
        "agent": agent,
        "session_id": session_id,
        "project": project,
        "source": "raw-tail",
        "updated_at": fmt_iso(mtime),
        "mtime": mtime,
        "title": clip_head(tail_turns[0]["ask"] or session_id, 120),
        "excerpt_path": None,
        "raw_path": str(path),
        "truncated": False,
        "tail_turns": [
            {"ask": clip_head(t["ask"]), "answer": clip_tail(t["answer"])}
            for t in tail_turns
        ],
    }


def sync_lmemory_local(vault: Path) -> dict[str, Any]:
    """Run Lmemory's pure-local intraday session importer (0 LLM calls, ~2-4s)."""
    if not LMEMORY_PYTHON.is_file():
        return {"ran": False, "reason": "lmemory python not found"}
    env = {
        **os.environ,
        "LMEMORY_STATE_DIR": str(Path.home() / ".local/state/krouter"),
    }
    try:
        res = subprocess.run(
            [
                str(LMEMORY_PYTHON),
                "-m",
                "lmemory_router.import_sessions",
                "--vault",
                str(vault),
                "--intraday",
                "--local",
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return {"ran": True, "ok": res.returncode == 0, "rc": res.returncode}
    except Exception as exc:
        return {"ran": False, "reason": str(exc)}


def load_state(state_file: Path) -> dict[str, Any]:
    if not state_file.is_file():
        return {}
    try:
        return json.loads(state_file.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state_file: Path, now_ts: float, summary: dict[str, Any] | None = None) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "initialized": True,
        "last_scan_ts": now_ts,
        "last_scan_iso": fmt_iso(now_ts),
    }
    if summary:
        payload["last_summary"] = summary
    state_file.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def compute_window(state: dict[str, Any], hours_override: float | None, now_ts: float) -> tuple[float, str]:
    if hours_override is not None:
        return hours_override, f"manual_{hours_override:g}h"
    last_ts = state.get("last_scan_ts")
    if isinstance(last_ts, (int, float)) and last_ts > 0 and last_ts < now_ts:
        elapsed_h = (now_ts - last_ts) / 3600.0
        # At least 24h overlap + 1h safety buffer, capped at 7d
        return min(max(elapsed_h + 1.0, 24.0), 168.0), "incremental"
    return 168.0, "initial_7d"


def iter_codex_files(codex_dir: Path, cutoff_ts: float, now_ts: float) -> list[tuple[Path, float]]:
    if not codex_dir.is_dir():
        return []
    out: list[tuple[Path, float]] = []
    start_day = datetime.fromtimestamp(cutoff_ts, tz=SHANGHAI_TZ).date() - timedelta(days=1)
    end_day = datetime.fromtimestamp(now_ts, tz=SHANGHAI_TZ).date() + timedelta(days=1)
    d = start_day
    while d <= end_day:
        day_dir = codex_dir / f"{d.year:04d}" / f"{d.month:02d}" / f"{d.day:02d}"
        if day_dir.is_dir():
            for p in day_dir.glob("rollout-*.jsonl"):
                mt = p.stat().st_mtime
                if mt >= cutoff_ts:
                    out.append((p, mt))
        d += timedelta(days=1)
    return out


def scan_conversations(
    *,
    excerpts_dir: Path = DEFAULT_EXCERPTS_DIR,
    codex_dir: Path = DEFAULT_CODEX_DIR,
    agy_dir: Path = DEFAULT_AGY_DIR,
    cursor_dir: Path = DEFAULT_CURSOR_DIR,
    claude_dir: Path = DEFAULT_CLAUDE_DIR,
    state_file: Path = DEFAULT_STATE_FILE,
    hours_override: float | None = None,
    now_ts: float | None = None,
    do_sync: bool = False,
    vault: Path = DEFAULT_VAULT,
) -> dict[str, Any]:
    now_ts = now_ts if now_ts is not None else time.time()
    sync_info = sync_lmemory_local(vault) if do_sync else {"ran": False}
    state = load_state(state_file)
    hours, mode = compute_window(state, hours_override, now_ts)
    cutoff_ts = now_ts - hours * 3600.0

    by_session: dict[str, dict[str, Any]] = {}
    lmemory_hits = 0
    raw_tail_backfills = 0

    # Tier 1: Lmemory session excerpts (fast, unified, already has project metadata)
    if excerpts_dir.is_dir():
        for p in excerpts_dir.glob("*.md"):
            if not re.match(r"^\d{4}-\d{2}-\d{2}｜", p.name):
                continue
            mt = p.stat().st_mtime
            if mt < cutoff_ts:
                continue
            item = parse_excerpt_md(p, mt)
            if item:
                prev = by_session.get(item["session_id"])
                if prev is None or item["mtime"] > prev["mtime"]:
                    by_session[item["session_id"]] = item
                lmemory_hits += 1

    def maybe_backfill(raw_path: Path, raw_mtime: float, session_hint: str | None, parser) -> None:
        nonlocal raw_tail_backfills
        existing = by_session.get(session_hint) if session_hint else None
        # Skip raw read if Lmemory excerpt is fresh AND untruncated
        if existing and not existing["truncated"] and raw_mtime <= existing["mtime"] + 60:
            existing["raw_path"] = str(raw_path)
            return
        parsed = parser(raw_path, raw_mtime)
        if not parsed:
            return
        sid = parsed["session_id"]
        existing = by_session.get(sid)
        if not existing:
            by_session[sid] = parsed
            raw_tail_backfills += 1
            return
        existing["raw_path"] = str(raw_path)
        if existing["truncated"] or raw_mtime > existing["mtime"] + 60:
            existing["tail_turns"] = parsed["tail_turns"]
            existing["truncated"] = False
            existing["source"] = "lmemory+raw-tail"
            if raw_mtime > existing["mtime"]:
                existing["mtime"] = raw_mtime
                existing["updated_at"] = parsed["updated_at"]
            if existing["project"] == "unknown" and parsed["project"] != "unknown":
                existing["project"] = parsed["project"]
            raw_tail_backfills += 1

    # Tier 2: Targeted tail-only backfill from raw transcripts
    if agy_dir.is_dir():
        for conv_dir in agy_dir.iterdir():
            if not conv_dir.is_dir():
                continue
            logs_dir = conv_dir / ".system_generated/logs"
            full_p = logs_dir / "transcript_full.jsonl"
            p = full_p if full_p.is_file() else (logs_dir / "transcript.jsonl")
            if not p.is_file():
                continue
            mt = p.stat().st_mtime
            if mt < cutoff_ts:
                continue
            maybe_backfill(p, mt, conv_dir.name, parse_antigravity_raw)

    for p, mt in iter_codex_files(codex_dir, cutoff_ts, now_ts):
        # Codex filename ends with -<uuid>.jsonl
        m_uuid = re.search(r"([0-9a-f]{8}-[0-9a-f-]{27})\.jsonl$", p.name, re.I)
        hint = m_uuid.group(1) if m_uuid else None
        maybe_backfill(p, mt, hint, parse_codex_raw)

    if cursor_dir.is_dir():
        for p in cursor_dir.glob("*/agent-transcripts/*/*.jsonl"):
            mt = p.stat().st_mtime
            if mt < cutoff_ts:
                continue
            maybe_backfill(p, mt, p.stem, lambda fp, m: parse_claude_or_cursor_raw(fp, m, "cursor"))

    if claude_dir.is_dir():
        for p in claude_dir.glob("*/*.jsonl"):
            mt = p.stat().st_mtime
            if mt < cutoff_ts:
                continue
            maybe_backfill(p, mt, p.stem, lambda fp, m: parse_claude_or_cursor_raw(fp, m, "claude-code"))

    # Filter noise & sort newest first
    sessions = []
    for s in by_session.values():
        last_ask = s["tail_turns"][-1]["ask"] if s["tail_turns"] else ""
        if not any(t["ask"] for t in s["tail_turns"]):
            continue  # Pure subagent / image-generator transcripts without user input
        if is_noise(s["title"], s["project"], last_ask):
            continue
        sessions.append(s)
    sessions.sort(key=lambda x: x["mtime"], reverse=True)

    max_shown = 120 if mode == "initial_7d" else 60
    counts: dict[str, int] = defaultdict(int)
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for s in sessions[:max_shown]:  # Cap output size for prompt hygiene
        counts[s["agent"]] += 1
        out_item = {k: v for k, v in s.items() if k != "mtime"}
        grouped[s["project"]].append(out_item)

    return {
        "scanned_at": fmt_iso(now_ts),
        "window_mode": mode,
        "window_hours": round(hours, 1),
        "cutoff": fmt_iso(cutoff_ts),
        "lmemory_sync": sync_info,
        "total_sessions": len(sessions),
        "shown_sessions": sum(len(v) for v in grouped.values()),
        "lmemory_hits": lmemory_hits,
        "raw_tail_backfills": raw_tail_backfills,
        "counts_by_agent": dict(counts),
        "projects": dict(grouped),
    }


def trigger_notch_app(title: str = "每日待办提醒", message: str = "") -> dict[str, Any]:
    """Ensure TodoNotch.app is running, drop a structured inbox event, and touch .trigger."""
    app_path = Path(__file__).resolve().parent / "TodoNotch.app"
    trigger_file = Path(__file__).resolve().parent / ".trigger"
    inbox_dir = Path.home() / "Library/Application Support/TodoNotch/inbox"
    if not app_path.is_dir():
        return {"ok": False, "reason": "TodoNotch.app not found"}
    running = subprocess.run(["pgrep", "-x", "TodoNotch"], capture_output=True, check=False).returncode == 0
    if not running:
        subprocess.run(["open", "-g", str(app_path)], capture_output=True, check=False)
        time.sleep(0.5)
    now_iso = fmt_iso(time.time())
    trigger_file.write_text(now_iso + "\n", encoding="utf-8")
    # Atomic drop-in event per API-LOCAL-01
    try:
        inbox_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        ev = {
            "schema_version": "1",
            "event_id": f"antigravity:daily-todo-reminder:{now_iso}",
            "source": "antigravity",
            "task_id": "daily-todo-reminder",
            "task_name": title or "每日 9 点跨项目待办提醒",
            "status": "attention",
            "summary": message or "今日跨项目待办清单已更新",
            "artifact_path": str(DEFAULT_VAULT / "05 时间日志/每日待办.md"),
            "log_path": "",
            "occurred_at": now_iso,
        }
        tmp_f = inbox_dir / f".tmp-{int(time.time() * 1000)}.json"
        dst_f = inbox_dir / f"todo-{int(time.time() * 1000)}.json"
        tmp_f.write_text(json.dumps(ev, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp_f.replace(dst_f)
    except Exception:
        pass
    return {"ok": True, "launched": not running, "trigger": str(trigger_file)}


def send_macos_notification(title: str, message: str) -> dict[str, Any]:
    notch = trigger_notch_app(title=title, message=message)
    res = subprocess.run(
        [
            "osascript",
            "-e",
            "on run argv",
            "-e",
            "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e",
            "end run",
            "--",
            title,
            message,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return {"ok": res.returncode == 0 or notch["ok"], "notch_app": notch, "osascript_ok": res.returncode == 0, "stderr": res.stderr.strip()}


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="daily-todo-scan-test-") as td:
        tmp = Path(td)
        now_ts = datetime(2026, 11, 24, 9, 0, 0, tzinfo=SHANGHAI_TZ).timestamp()
        excerpts = tmp / "excerpts"
        codex = tmp / "codex" / "2026" / "11" / "24"
        agy = tmp / "agy" / "sess-agy-1" / ".system_generated" / "logs"
        state_file = tmp / "state.json"
        excerpts.mkdir(parents=True)
        codex.mkdir(parents=True)
        agy.mkdir(parents=True)

        # 1. Truncated Lmemory excerpt for sess-agy-1
        exc_file = excerpts / "2026-11-24｜geo报告改版（sess-agy-1）.md"
        exc_file.write_text(
            "---\n"
            "agent: antigravity\n"
            "session: sess-agy-1\n"
            "project: html-report-generator-master\n"
            "title: geo报告改版\n"
            "---\n\n"
            "- **问**（08:00）：分析每个页面要怎么改，先告诉我\n"
            "  **答**：开头部分被截断了…\n",
            encoding="utf-8",
        )
        os.utime(exc_file, (now_ts - 600, now_ts - 600))

        # 2. Raw Antigravity transcript with full tail containing the open TODO
        long_reply = ("说明文字 " * 400) + "\n最终待你拍板：1) 确认封面蓝色色号；2) 确认是否推送到生产。"
        agy_file = agy / "transcript.jsonl"
        agy_file.write_text(
            json.dumps({"type": "USER_INPUT", "content": "<USER_REQUEST>分析每个页面要怎么改</USER_REQUEST>"})
            + "\n"
            + json.dumps({"type": "PLANNER_RESPONSE", "content": long_reply})
            + "\n",
            encoding="utf-8",
        )
        os.utime(agy_file, (now_ts - 600, now_ts - 600))

        # 3. Unsynced Codex session + noise automation excerpt
        codex_file = codex / "rollout-2026-11-24T08-30-00-01a20b99-1111-2222-3333-444455556666.jsonl"
        codex_file.write_text(
            json.dumps({"type": "session_meta", "payload": {"id": "01a20b99-1111-2222-3333-444455556666", "cwd": "/Users/demo/projects/sample-project", "originator": "Codex Desktop"}})
            + "\n"
            + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "重新提交审核"}]}})
            + "\n"
            + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "已重提审核，明天记得复查微信后台审核结果。"}]}})
            + "\n",
            encoding="utf-8",
        )
        os.utime(codex_file, (now_ts - 300, now_ts - 300))

        noise_file = excerpts / "2026-11-24｜请严格按以下防限流（noise-1）.md"
        noise_file.write_text(
            "---\nagent: antigravity\nsession: noise-1\nproject: x-ai-blogger\ntitle: 请严格按以下防限流\n---\n- **问**（08:00）：发帖\n  **答**：已排期\n",
            encoding="utf-8",
        )
        os.utime(noise_file, (now_ts - 200, now_ts - 200))

        # Initial run => 7d window
        res1 = scan_conversations(
            excerpts_dir=excerpts,
            codex_dir=tmp / "codex",
            agy_dir=tmp / "agy",
            cursor_dir=tmp / "cursor",
            claude_dir=tmp / "claude",
            state_file=state_file,
            now_ts=now_ts,
        )
        assert res1["window_mode"] == "initial_7d", res1["window_mode"]
        assert res1["total_sessions"] == 2, res1["total_sessions"]
        assert res1["raw_tail_backfills"] == 2, res1["raw_tail_backfills"]
        agy_item = res1["projects"]["html-report-generator-master"][0]
        assert agy_item["source"] == "lmemory+raw-tail", agy_item["source"]
        assert "最终待你拍板" in agy_item["tail_turns"][-1]["answer"], agy_item["tail_turns"]
        assert "sample-project" in res1["projects"]
        assert "x-ai-blogger" not in res1["projects"]

        # Commit watermark => next run is incremental
        save_state(state_file, now_ts)
        res2 = scan_conversations(
            excerpts_dir=excerpts,
            codex_dir=tmp / "codex",
            agy_dir=tmp / "agy",
            cursor_dir=tmp / "cursor",
            claude_dir=tmp / "claude",
            state_file=state_file,
            now_ts=now_ts + 86400,
        )
        assert res2["window_mode"] == "incremental", res2["window_mode"]
        assert res2["window_hours"] == 25.0, res2["window_hours"]

    print("SELF_TEST_OK")


def write_initial_todo_md_if_missing(result: dict[str, Any], target_path: Path) -> bool:
    """Create an initial 每日待办.md from scanned multi-agent conversations when missing."""
    if target_path.is_file() and target_path.stat().st_size > 20:
        return False
    target_path.parent.mkdir(parents=True, exist_ok=True)
    personal_kw = re.compile(r"拍板|确认|登录|扫码|审核|三方|接口|密钥|Key|草稿|发邮件|授权")
    project_kw = re.compile(r"未提交|未推送|未部署|待验收|待复查|待联调|报错|失败|暂时没数据|先空着|进行中|待完成")
    personal_lines: list[str] = []
    project_lines: list[str] = []
    for proj, items in result.get("projects", {}).items():
        if proj == "unknown":
            continue
        for it in items:
            turns = it.get("tail_turns") or []
            if not turns:
                continue
            blob = "\n".join((t.get("ask", "") + "\n" + t.get("answer", "")) for t in turns)
            sid = str(it.get("session_id", ""))[:8]
            day = str(it.get("updated_at", ""))[:10]
            agent = it.get("agent", "agent")
            title = str(it.get("title", "")).strip()
            in_progress = (turns[-1].get("answer", "").strip() == "")
            entry = f"- [ ] **[{proj}]** {title} — 来源：`{day} {agent} ({sid})`"
            if personal_kw.search(blob) and len(personal_lines) < 12:
                personal_lines.append(entry)
            elif (in_progress or project_kw.search(blob)) and len(project_lines) < 12:
                project_lines.append(entry)

    now_iso = result.get("scanned_at") or fmt_iso(time.time())
    lines = [
        "---",
        "title: 每日待办",
        "type: daily-todo",
        f"updated_at: {now_iso}",
        f"window_mode: {result.get('window_mode', 'initial_7d')}",
        "---",
        "",
        "# 每日待办（跨项目对话自动初始化）",
        "",
        f"> 初始化时间：`{now_iso[:16].replace('T', ' ')}`（自动扫描近 7 天多 Agent 会话，共命中 {result.get('total_sessions', 0)} 条有效会话）。",
        "",
        "## 待你亲自处理（需拍板 / 登录 / 验收 / 外部跟进）",
        "",
        *(personal_lines or ["- （暂未识别到待亲自处理事项）"]),
        "",
        "## 进行中 / 未收尾项目任务",
        "",
        *(project_lines or ["- （暂未识别到未收尾项目任务）"]),
        "",
        "## 今日已自动消项（最近完成）",
        "",
        "- （首次初始化建池）",
        "",
    ]
    target_path.write_text("\n".join(lines), encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Scan cross-project conversations for daily unfinished tasks.")
    ap.add_argument("--self-test", action="store_true", help="Run built-in assertions")
    ap.add_argument("--hours", type=float, default=None, help="Override lookback window in hours")
    ap.add_argument("--sync-lmemory", action="store_true", help="Run local Lmemory intraday import first")
    ap.add_argument("--commit", action="store_true", help="Advance state.json watermark to now")
    ap.add_argument("--out", default="", help="Write full JSON output to this file and print compact summary")
    ap.add_argument("--bootstrap-todo-md", default="", help="If target 每日待办.md does not exist, generate initial checklist from scan")
    ap.add_argument("--notify", action="store_true", help="Send a macOS notification")
    ap.add_argument("--title", default="每日待办提醒", help="Notification title")
    ap.add_argument("--message", default="", help="Notification message")
    args = ap.parse_args()

    if args.self_test:
        run_self_test()
        return 0
    if args.notify:
        res = send_macos_notification(args.title, args.message or "今日跨项目待办清单已更新")
        print(json.dumps(res, ensure_ascii=False))
        return 0 if res["ok"] else 1
    if args.commit and args.hours is None and not args.sync_lmemory and not args.out:
        save_state(DEFAULT_STATE_FILE, time.time())
        print(json.dumps({"committed": True, "state_file": str(DEFAULT_STATE_FILE)}, ensure_ascii=False))
        return 0

    result = scan_conversations(hours_override=args.hours, do_sync=args.sync_lmemory)
    bootstrapped_md = False
    if args.bootstrap_todo_md:
        bootstrapped_md = write_initial_todo_md_if_missing(result, Path(args.bootstrap_todo_md))
    if args.commit:
        save_state(
            DEFAULT_STATE_FILE,
            time.time(),
            {"total_sessions": result["total_sessions"], "counts_by_agent": result["counts_by_agent"]},
        )
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        summary = {k: v for k, v in result.items() if k != "projects"}
        summary["project_counts"] = {p: len(v) for p, v in result["projects"].items()}
        summary["out_file"] = str(out_path)
        summary["bootstrapped_todo_md"] = bootstrapped_md
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
