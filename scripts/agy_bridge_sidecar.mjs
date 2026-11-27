#!/usr/bin/env node
/**
 * Official Antigravity Desktop Sidecar Bridge for TodoNotch.
 *
 * Runs inside Antigravity Desktop's bundled Node runtime (`sidecar_sdk`),
 * which injects ANTIGRAVITY_LS_ADDRESS, ANTIGRAVITY_CSRF_TOKEN,
 * ANTIGRAVITY_AGENTAPI_EXE, and ANTIGRAVITY_SIDECAR_WEB_PORT.
 *
 * Bridges TodoNotch dispatch requests into native Antigravity Desktop
 * conversations so tasks appear and resume live in the Desktop sidebar.
 */

import { execFile } from "node:child_process";
import fs from "node:fs";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const BRIDGE_DIR =
  process.env.TODONOTCH_BRIDGE_DIR?.trim() ||
  path.join(os.homedir(), "Library", "Application Support", "TodoNotch", "bridge");
const REQUESTS_DIR = path.join(BRIDGE_DIR, "requests");
const RESULTS_DIR = path.join(BRIDGE_DIR, "results");
const STOPS_DIR = path.join(BRIDGE_DIR, "stops");
const STATUS_FILE = path.join(BRIDGE_DIR, "agy-bridge-status.json");
const BRIDGE_INSTANCE = randomUUID();

const AGENTAPI_FALLBACK = path.join(os.homedir(), ".gemini", "antigravity", "bin", "agentapi");
const AGY_SIDECAR_DATA = path.join(os.homedir(), ".gemini", "antigravity", "sidecar_data");
const AGY_BRAIN_DIR = path.join(os.homedir(), ".gemini", "antigravity", "brain");

const HEARTBEAT_INTERVAL_MS = 5_000;
const POLL_INTERVAL_MS = 500;
const WATCH_POLL_INTERVAL_MS = 2_000;
const WATCH_MAX_MS = 1_800_000;
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

const recentDispatches = [];
const busyConversations = new Set();

function recordDispatchSummary(entry) {
  const idx = recentDispatches.findIndex((item) => item.dispatch_id === entry.dispatch_id);
  if (idx >= 0) {
    recentDispatches[idx] = { ...recentDispatches[idx], ...entry };
  } else {
    recentDispatches.unshift(entry);
    if (recentDispatches.length > 20) recentDispatches.length = 20;
  }
}

function nowUnixSec() {
  return Math.floor(Date.now() / 1000);
}

function atomicWriteJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmpPath = path.join(
    path.dirname(filePath),
    `.${path.basename(filePath)}.tmp.${process.pid}.${Math.random().toString(36).slice(2, 8)}`
  );
  fs.writeFileSync(tmpPath, JSON.stringify(payload), "utf8");
  fs.renameSync(tmpPath, filePath);
}

function writeHeartbeat() {
  const lsAddr = (process.env.ANTIGRAVITY_LS_ADDRESS || "").trim();
  const csrf = (process.env.ANTIGRAVITY_CSRF_TOKEN || "").trim();
  const ready = Boolean(lsAddr && csrf);
  const status = {
    pid: process.pid,
    ready,
    stop_protocol: 2,
    bridge_instance: BRIDGE_INSTANCE,
    updated_at: nowUnixSec(),
    ls_address: lsAddr,
    mode: "node-sidecar-plugin"
  };
  atomicWriteJson(STATUS_FILE, status);
  return status;
}

async function callAgentService(service, method, payload) {
  const lsAddr = (process.env.ANTIGRAVITY_LS_ADDRESS || "").trim();
  const csrf = (process.env.ANTIGRAVITY_CSRF_TOKEN || "").trim();
  if (!lsAddr || !csrf) {
    throw new Error("ANTIGRAVITY_LS_ADDRESS or ANTIGRAVITY_CSRF_TOKEN missing");
  }
  const url = `http://${lsAddr}/${service}/${method}`;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Connect-Protocol-Version": "1",
      "x-antigravity-csrf-token": csrf
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(15_000)
  });
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`${method} HTTP ${resp.status}: ${text.slice(0, 400)}`);
  }
  return text.trim() ? JSON.parse(text) : {};
}

function callConvService(method, payload) {
  return callAgentService("product.v1.ConversationService", method, payload);
}

function stopPath(dispatchId) {
  return path.join(STOPS_DIR, `${dispatchId}.json`);
}

function clearStop(dispatchId) {
  fs.rmSync(stopPath(dispatchId), { force: true });
}

function pendingStop(dispatchId) {
  try {
    const stop = JSON.parse(fs.readFileSync(stopPath(dispatchId), "utf8"));
    return stop.bridge_instance === BRIDGE_INSTANCE && typeof stop.stop_request_id === "string"
      ? stop.stop_request_id : "";
  } catch {
    return "";
  }
}

async function stopConversation(dispatchId, convId, stopRequestId) {
  try {
    await callAgentService("exa.language_server_pb.LanguageServerService", "CancelCascadeInvocation", {
      cascadeId: convId,
      killBackgroundTasks: true
    });
  } catch (err) {
    clearStop(dispatchId);
    writeResult(dispatchId, {
      status: "running", conversation_id: convId, stop_request_id: stopRequestId, error: String(err?.message || err)
    });
    return false;
  }
  clearStop(dispatchId);
  writeResult(dispatchId, { status: "stopped", conversation_id: convId, stop_request_id: stopRequestId });
  return true;
}

async function execAgentApi(args, { projectId = "" } = {}) {
  const exe = (process.env.ANTIGRAVITY_AGENTAPI_EXE || "").trim();
  const file = exe || AGENTAPI_FALLBACK;
  const execArgs = exe ? ["agentapi", ...args] : args;
  const env = { ...process.env };
  if (projectId) env.ANTIGRAVITY_PROJECT_ID = projectId;

  const { stdout } = await execFileAsync(file, execArgs, {
    encoding: "utf8",
    env,
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024
  });
  const trimmed = (stdout || "").trim();
  if (!trimmed) return {};
  try {
    return JSON.parse(trimmed);
  } catch {
    return { _rawStdout: trimmed };
  }
}

async function getConversationSafe(convId) {
  if (!convId) return null;
  try {
    const res = await callConvService("GetConversation", { conversationId: convId });
    if (res && typeof res === "object") {
      if (res.id) return res;
      if (res.conversation && typeof res.conversation === "object") return res.conversation;
      if ("state" in res) return res;
    }
  } catch {
    // Scoped sidecar tokens may not allow ConversationService; handled by fallbacks.
  }
  return null;
}

async function getMetadataViaAgentApi(convId) {
  if (!convId) return null;
  try {
    const res = await execAgentApi(["get-conversation-metadata", convId]);
    const meta =
      res?.response?.conversationMetadata?.metadata ||
      res?.conversationMetadata?.metadata ||
      res?.metadata ||
      null;
    return meta && typeof meta === "object" ? meta : null;
  } catch {
    return null;
  }
}

async function getProjectIdForConversation(convId) {
  if (!convId) return "";
  const meta = await getMetadataViaAgentApi(convId);
  if (meta?.projectId) return String(meta.projectId);
  const conv = await getConversationSafe(convId);
  const pid = conv?.metadata?.projectId;
  return pid ? String(pid) : "";
}

function readTailUtf8(filePath, maxBytes) {
  const stat = fs.statSync(filePath);
  const start = Math.max(0, stat.size - maxBytes);
  const length = stat.size - start;
  const fd = fs.openSync(filePath, "r");
  try {
    const buf = Buffer.alloc(length);
    const bytesRead = fs.readSync(fd, buf, 0, length, start);
    return buf.subarray(0, bytesRead).toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

function readRangeUtf8(filePath, startOffset, maxBytes) {
  const stat = fs.statSync(filePath);
  const start = Math.max(0, Math.min(startOffset, stat.size));
  const length = Math.min(maxBytes, stat.size - start);
  if (length <= 0) return { text: "", mtimeMs: stat.mtimeMs, size: stat.size };
  const fd = fs.openSync(filePath, "r");
  try {
    const buf = Buffer.alloc(length);
    const bytesRead = fs.readSync(fd, buf, 0, length, start);
    return { text: buf.subarray(0, bytesRead).toString("utf8"), mtimeMs: stat.mtimeMs, size: stat.size };
  } finally {
    fs.closeSync(fd);
  }
}

function transcriptPathFor(convId) {
  return path.join(AGY_BRAIN_DIR, convId, ".system_generated", "logs", "transcript.jsonl");
}

function transcriptSize(convId) {
  try {
    return fs.statSync(transcriptPathFor(convId)).size;
  } catch {
    return 0;
  }
}

function brainDirExists(convId) {
  if (!convId) return false;
  try {
    return fs.statSync(path.join(AGY_BRAIN_DIR, convId)).isDirectory();
  } catch {
    return false;
  }
}

async function resolveProjectId({ sidecarId, projectName, sessionId, cwd }) {
  if (sidecarId) {
    const logPath = path.join(AGY_SIDECAR_DATA, sidecarId, "logs", "sidecar.log");
    try {
      const tail = readTailUtf8(logPath, 262_144);
      const matches = [...tail.matchAll(/"conversationId"\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
      for (let i = matches.length - 1; i >= 0; i--) {
        const pid = await getProjectIdForConversation(matches[i]);
        if (pid) return pid;
      }
    } catch {
      // Ignore unreadable sidecar log.
    }
  }

  if (sessionId) {
    const pid = await getProjectIdForConversation(sessionId);
    if (pid) return pid;
  }

  const homeDir = os.homedir();
  const cleanCwd = cwd && cwd.trim() && cwd.trim() !== homeDir ? cwd.trim() : "";

  if (cleanCwd && fs.existsSync(AGY_BRAIN_DIR)) {
    try {
      const candidates = fs
        .readdirSync(AGY_BRAIN_DIR, { withFileTypes: true })
        .filter((d) => d.isDirectory() && UUID_RE.test(d.name))
        .map((d) => {
          const tPath = transcriptPathFor(d.name);
          try {
            return { id: d.name, tPath, mtimeMs: fs.statSync(tPath).mtimeMs };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => b.mtimeMs - a.mtimeMs)
        .slice(0, 40);

      for (const cand of candidates) {
        try {
          const { text } = readRangeUtf8(cand.tPath, 0, 16_384);
          if (!text.includes(cleanCwd)) continue;
          const meta = await getMetadataViaAgentApi(cand.id);
          if (!meta?.projectId) continue;
          const wsList = Array.isArray(meta.workspaces) ? meta.workspaces : [];
          const fileUri = `file://${cleanCwd}`;
          if (wsList.some((w) => w?.workspaceFolderAbsoluteUri === fileUri)) {
            return String(meta.projectId);
          }
          return String(meta.projectId);
        } catch {
          // Continue scanning other candidate brains.
        }
      }
    } catch {
      // Ignore brain scan failures.
    }
  }

  try {
    const listed = await callConvService("ListConversations", { pageSize: 100, includeArchived: false });
    const convs = Array.isArray(listed?.conversations) ? listed.conversations : [];

    if (cleanCwd) {
      for (const conv of convs) {
        const cid = String(conv?.id || "");
        const pid = String(conv?.metadata?.projectId || "");
        if (!cid || !pid) continue;
        try {
          const { text } = readRangeUtf8(transcriptPathFor(cid), 0, 16_384);
          if (text.includes(cleanCwd)) return pid;
        } catch {
          // Ignore missing transcript.
        }
      }
    }

    const cleanProj = (projectName || "").trim().toLowerCase();
    if (cleanProj) {
      for (const conv of convs) {
        const pid = String(conv?.metadata?.projectId || "");
        const title = String(conv?.annotations?.title || conv?.state?.summary || "").toLowerCase();
        if (pid && title.includes(cleanProj)) return pid;
      }
    }
  } catch {
    // ListConversations may be restricted for scoped sidecar tokens.
  }

  return "";
}

// Match the dispatched user input before accepting any reply from this conversation.
async function readTurnEvidence(filePath, start, prompt) {
  let offset = start;
  let pending = Buffer.alloc(0);
  let matchesPrompt = false;
  let reply;

  function consume(line, lineOffset) {
    let step;
    try {
      step = JSON.parse(line.toString("utf8"));
    } catch {
      return;
    }
    const { type, status, content, step_index: index } = step;
    if (type === "USER_INPUT") {
      const text = typeof content === "string" ? content.trim() : "";
      const end = text.indexOf("</USER_REQUEST>");
      const request = text.startsWith("<USER_REQUEST>") && end >= 0
        ? text.slice("<USER_REQUEST>".length, end).trim() : text;
      matchesPrompt = request === prompt;
      reply = undefined;
    } else if (matchesPrompt && type !== "SYSTEM_MESSAGE") {
      const finalReply = (type === "PLANNER_RESPONSE" || type === "NOTIFY_USER")
        && status === "DONE" && !(step.tool_calls?.length) && typeof content === "string" && content.trim();
      reply = finalReply && Number.isSafeInteger(index)
        ? { offset: lineOffset, length: line.length, step_index: index } : undefined;
    }
  }

  for await (const chunk of fs.createReadStream(filePath, { start })) {
    const bytes = pending.length ? Buffer.concat([pending, chunk]) : chunk;
    let from = 0;
    for (let newline = bytes.indexOf(0x0a, from); newline !== -1; newline = bytes.indexOf(0x0a, from)) {
      const line = bytes.subarray(from, newline);
      consume(line, offset);
      offset += line.length + 1;
      from = newline + 1;
    }
    pending = bytes.subarray(from);
  }
  if (pending.length) consume(pending, offset);
  return reply;
}

function writeResult(dispatchId, fields) {
  const payload = {
    dispatch_id: dispatchId,
    bridge_instance: BRIDGE_INSTANCE,
    updated_at: nowUnixSec(),
    error: "",
    ...fields
  };
  atomicWriteJson(path.join(RESULTS_DIR, `${dispatchId}.json`), payload);
  recordDispatchSummary(payload);
}

async function watchUntilDone(dispatchId, convId, prevTranscriptSize, prompt) {
  try {
    await monitorConversation(dispatchId, convId, prevTranscriptSize, prompt);
  } finally {
    busyConversations.delete(convId);
    clearStop(dispatchId);
  }
}

async function monitorConversation(dispatchId, convId, prevTranscriptSize, prompt) {
  const startedMs = Date.now();
  let convServiceDenied = false;

  while (Date.now() - startedMs < WATCH_MAX_MS) {
    const stopRequestId = pendingStop(dispatchId);
    if (stopRequestId && await stopConversation(dispatchId, convId, stopRequestId)) return;
    await new Promise((r) => setTimeout(r, WATCH_POLL_INTERVAL_MS));
    if (pendingStop(dispatchId)) continue;

    let conversation;
    if (!convServiceDenied) {
      try {
        const res = await callConvService("GetConversation", { conversationId: convId });
        conversation = res?.conversation || res;
      } catch (err) {
        const msg = String(err?.message || "");
        if (msg.includes("HTTP 401") || msg.includes("HTTP 403") || msg.includes("missing")) {
          convServiceDenied = true;
        }
      }
    }

    const runState = String(conversation?.state?.runState || "");
    if (runState && runState !== "RUN_STATE_IDLE") continue;

    let evidence;
    const transcript = transcriptPathFor(convId);
    try {
      const stat = fs.statSync(transcript);
      if (stat.size > prevTranscriptSize && Date.now() - stat.mtimeMs >= 4_000) {
        evidence = await readTurnEvidence(transcript, prevTranscriptSize, prompt);
      }
    } catch {
      // The transcript may not exist while the native conversation starts.
    }
    if (pendingStop(dispatchId)) continue;
    if (evidence) {
      writeResult(dispatchId, {
        status: "completed",
        conversation_id: convId,
        project_id: String(conversation?.metadata?.projectId || ""),
        run_state: runState || "TRANSCRIPT_IDLE",
        reply_evidence: evidence
      });
      return;
    }
  }

  writeResult(dispatchId, {
    status: "failed",
    conversation_id: convId,
    project_id: "",
    run_state: "TIMEOUT",
    error: "Timed out waiting for conversation to become idle"
  });
}

function extractCreatedConversation(res) {
  const conv = res?.conversation || res?.response?.conversation;
  if (conv && typeof conv === "object" && conv.id) {
    return {
      id: String(conv.id),
      projectId: String(conv.metadata?.projectId || "")
    };
  }
  const directId =
    res?.conversationId ||
    res?.response?.conversationId ||
    res?.id ||
    res?.response?.id;
  if (directId) {
    return {
      id: String(directId),
      projectId: String(res?.projectId || res?.metadata?.projectId || "")
    };
  }
  if (typeof res?._rawStdout === "string") {
    const match = res._rawStdout.match(UUID_RE);
    if (match) return { id: match[0], projectId: "" };
  }
  return null;
}

async function handleRequest(reqData) {
  const dispatchId = String(reqData.dispatch_id || "").trim();
  if (!UUID_RE.test(dispatchId) || dispatchId.length !== 36) return;
  const owner = String(reqData.bridge_instance || "");
  if (owner && owner !== BRIDGE_INSTANCE) {
    if (!fs.existsSync(path.join(RESULTS_DIR, `${dispatchId}.json`))) {
      writeResult(dispatchId, {
        status: "failed", bridge_instance: owner, error: "Antigravity bridge restarted before claiming this request"
      });
    }
    return;
  }

  let heldConversation = "";
  try {
    const stopBeforeStart = () => {
      const stopRequestId = pendingStop(dispatchId);
      if (!stopRequestId) return false;
      writeResult(dispatchId, { status: "stopped", conversation_id: "", stop_request_id: stopRequestId });
      clearStop(dispatchId);
      return true;
    };
    if (stopBeforeStart()) return;
    writeResult(dispatchId, { status: "starting" });
    const mode = String(reqData.mode || "new").trim().toLowerCase();
    const sessionId = String(reqData.session_id || "").trim();
    const projectName = String(reqData.project_name || "").trim();
    const cwd = String(reqData.cwd || "").trim();
    const title = String(reqData.title || "").trim();
    const prompt = String(reqData.prompt || "").trim();
    const sidecarId = String(reqData.sidecar_id || "").trim();

    if (!prompt) throw new Error("Empty prompt in bridge request");

    const existingConv = mode === "resume" && sessionId ? await getConversationSafe(sessionId) : null;
    const existingMeta =
      mode === "resume" && sessionId && !existingConv ? await getMetadataViaAgentApi(sessionId) : null;
    const canResume = Boolean(
      mode === "resume" && sessionId && (existingConv || existingMeta || brainDirExists(sessionId))
    );

    if (canResume) {
      if (stopBeforeStart()) return;
      if (busyConversations.has(sessionId) || (existingConv?.state?.runState && existingConv.state.runState !== "RUN_STATE_IDLE")) {
        throw new Error("An earlier turn is still running in this Antigravity conversation");
      }
      busyConversations.add(sessionId);
      heldConversation = sessionId;
      const projId = String(existingConv?.metadata?.projectId || existingMeta?.projectId || "");
      const prevSize = transcriptSize(sessionId);

      await execAgentApi(["send-message", sessionId, prompt], { projectId: projId });

      writeResult(dispatchId, {
        status: "running",
        conversation_id: sessionId,
        project_id: projId,
        run_state: "RUN_STATE_RUNNING"
      });
      watchUntilDone(dispatchId, sessionId, prevSize, prompt).catch((err) => {
        console.error(`[todonotch-bridge] watch error (${dispatchId}):`, err);
      });
      return;
    }

    const projId = await resolveProjectId({ sidecarId, projectName, sessionId, cwd });
    if (stopBeforeStart()) return;
    let createdInfo = null;

    try {
      const payload = { prompt: [{ text: prompt }] };
      if (title) payload.title = title;
      if (projId) payload.projectId = projId;
      const created = await callConvService("CreateConversation", payload);
      createdInfo = extractCreatedConversation(created);
    } catch {
      // Fallback to official `agentapi new-conversation` (supported under sidecar scoped token).
      const args = ["new-conversation", "--model=flash"];
      if (title) args.push(`--title=${title}`);
      args.push(prompt);
      const created = await execAgentApi(args, { projectId: projId });
      createdInfo = extractCreatedConversation(created);
    }

    if (!createdInfo?.id) {
      throw new Error("Could not extract conversation_id after creating Antigravity conversation");
    }

    busyConversations.add(createdInfo.id);
    const finalProj = createdInfo.projectId || projId;
    writeResult(dispatchId, {
      status: "running",
      conversation_id: createdInfo.id,
      project_id: finalProj,
      run_state: "RUN_STATE_RUNNING"
    });
    watchUntilDone(dispatchId, createdInfo.id, 0, prompt).catch((err) => {
      console.error(`[todonotch-bridge] watch error (${dispatchId}):`, err);
    });
  } catch (err) {
    if (heldConversation) busyConversations.delete(heldConversation);
    clearStop(dispatchId);
    writeResult(dispatchId, {
      status: "failed",
      conversation_id: String(reqData.session_id || ""),
      project_id: "",
      run_state: "ERROR",
      error: String(err?.message || err)
    });
  }
}

async function pollRequestsOnce() {
  let entries;
  try {
    entries = fs.readdirSync(REQUESTS_DIR).filter((name) => name.endsWith(".json") && !name.startsWith(".")).sort();
  } catch {
    return;
  }

  for (const name of entries) {
    const reqFile = path.join(REQUESTS_DIR, name);
    const procFile = `${reqFile}.processing`;
    try {
      fs.renameSync(reqFile, procFile);
    } catch {
      continue;
    }

    let raw;
    try {
      raw = fs.readFileSync(procFile, "utf8");
    } catch (err) {
      console.error(`[todonotch-bridge] read error (${name}):`, err);
    } finally {
      try {
        fs.unlinkSync(procFile);
      } catch {
        // Ignore cleanup failure.
      }
    }

    if (!raw) continue;
    try {
      const data = JSON.parse(raw);
      if (data && typeof data === "object" && !Array.isArray(data)) {
        handleRequest(data).catch((err) => {
          console.error(`[todonotch-bridge] handleRequest error (${name}):`, err);
        });
      }
    } catch (err) {
      console.error(`[todonotch-bridge] invalid JSON (${name}):`, err);
    }
  }
}

async function loadSidecarSdk() {
  const candidates = [
    path.join(os.homedir(), ".gemini", "antigravity", "lib", "node_modules", "sidecar_sdk", "index.mjs"),
    path.join(os.homedir(), ".gemini", "config", "node_modules", "sidecar_sdk", "index.mjs")
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      try {
        return await import(pathToFileURL(candidate).href);
      } catch {
        // Try next candidate.
      }
    }
  }
  try {
    return await import("sidecar_sdk");
  } catch {
    return null;
  }
}

function renderStatusHtml() {
  const lsAddr = (process.env.ANTIGRAVITY_LS_ADDRESS || "").trim();
  const ready = Boolean(lsAddr && (process.env.ANTIGRAVITY_CSRF_TOKEN || "").trim());
  const rows = recentDispatches
    .map(
      (d) =>
        `<tr><td><code>${escapeHtml(d.dispatch_id.slice(0, 8))}</code></td><td>${escapeHtml(d.status)}</td><td><code>${escapeHtml(d.conversation_id || "-")}</code></td><td>${escapeHtml(d.error || "-")}</td></tr>`
    )
    .join("");
  return `<!doctype html><html><head><meta charset="utf-8"><title>TodoNotch Bridge</title>
<style>body{font-family:-apple-system,sans-serif;margin:16px;background:#111318;color:#e6eaf2;font-size:13px}
code{background:#1c212b;padding:2px 5px;border-radius:4px}table{width:100%;border-collapse:collapse;margin-top:12px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #262c38}th{color:#9aa4b2}</style></head>
<body><h3>TodoNotch Desktop Bridge</h3>
<p>Status: <strong>${ready ? "READY" : "WAITING"}</strong> | PID: <code>${process.pid}</code> | LS: <code>${escapeHtml(lsAddr || "unset")}</code></p>
<table><thead><tr><th>Dispatch</th><th>Status</th><th>Conversation</th><th>Error</th></tr></thead>
<tbody>${rows || '<tr><td colspan="4">No dispatches yet in this session.</td></tr>'}</tbody></table></body></html>`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function startWebUiIfSidecar() {
  if (process.env.TODONOTCH_BRIDGE_NO_HTTP === "1") return;
  const hasEnv =
    (process.env.ANTIGRAVITY_LS_ADDRESS || "").trim() &&
    (process.env.ANTIGRAVITY_CSRF_TOKEN || "").trim() &&
    (process.env.ANTIGRAVITY_SIDECAR_WEB_PORT || "").trim();
  if (!hasEnv) return;

  const sdk = await loadSidecarSdk();
  if (!sdk?.SidecarApp) return;

  const app = new sdk.SidecarApp();
  const SidecarResponse = sdk.Response;
  app.page("/", () =>
    SidecarResponse
      ? new SidecarResponse(renderStatusHtml(), { contentType: "text/html; charset=utf-8", status: 200 })
      : renderStatusHtml()
  );
  app.api(
    "/api/status",
    () => ({
      pid: process.pid,
      ready: true,
      updated_at: nowUnixSec(),
      ls_address: process.env.ANTIGRAVITY_LS_ADDRESS || "",
      recent_dispatches: recentDispatches
    }),
    "POST"
  );
  await app.run();
}

async function main() {
  fs.mkdirSync(REQUESTS_DIR, { recursive: true });
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  fs.mkdirSync(STOPS_DIR, { recursive: true, mode: 0o700 });

  await startWebUiIfSidecar();
  writeHeartbeat();

  setInterval(() => {
    try {
      writeHeartbeat();
    } catch (err) {
      console.error("[todonotch-bridge] heartbeat error:", err);
    }
  }, HEARTBEAT_INTERVAL_MS);

  while (true) {
    await pollRequestsOnce();
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch((err) => {
  console.error("[todonotch-bridge] fatal:", err);
  process.exit(1);
});
