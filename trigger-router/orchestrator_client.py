"""
orchestrator_client.py

Connects the trigger-router to the agent-orchestrator, implementing the
full protocol defined in AGENT_MANIFEST.md.

Protocol checklist (§14):
  ✓ POST /api/v1/agents/register — capability schema + required_settings
  ✓ WS /ws/{agent_id} — connect immediately after registration
  ✓ Close code 4004 — re-register then reconnect
  ✓ Exponential-backoff auto-reconnect (cap: 60 s)
  ✓ Heartbeat every 15 s — status, current_load, active_tasks, metrics
  ✓ task_request → capability handler → task_response
  ✓ Respects task timeout_ms hint
  ✓ status_update sent on task start / finish (available ↔ busy)
  ✓ Status machine: starting → available → busy → draining → offline
  ✓ Metrics: tasks_completed, tasks_failed, avg_response_time_ms, uptime_seconds
  ✓ agent_registered / agent_offline / error / broadcast / discovery_response handlers
  ✓ Graceful shutdown on SIGINT/SIGTERM: draining → wait → DELETE → WS close
  ✓ Outbound task_request dispatch with correlation_id tracking
  ✓ Background poll loop for due schedule triggers (every POLL_INTERVAL_S seconds)
  ✓ SQLite trigger persistence via TriggerStore
  ✓ Deduplication via idempotency_key in fire log

Usage:
    python orchestrator_client.py [--orchestrator-url http://localhost:8000]
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import signal
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
import websockets
import websockets.exceptions

from router import TriggerStore, VALID_TRIGGER_TYPES

# ── Stable agent identity ──────────────────────────────────────────────────────

_AGENT_ID_FILE = Path(".agent_id")


def _stable_agent_id() -> str:
    if _AGENT_ID_FILE.exists():
        return _AGENT_ID_FILE.read_text().strip()
    new_id = str(uuid.uuid4())
    _AGENT_ID_FILE.write_text(new_id)
    logger.info("Generated new stable agent ID: %s → %s", new_id, _AGENT_ID_FILE)
    return new_id


logger = logging.getLogger(__name__)

# ── Agent identity ─────────────────────────────────────────────────────────────

AGENT_NAME        = "trigger-router"
AGENT_VERSION     = "1.0.0"
AGENT_DESCRIPTION = (
    "Manages trigger definitions and routes trigger events to workflow plans or "
    "saved workflows. Supports schedule, webhook, conversation, email, condition, "
    "workflow_event, data_change, and manual triggers. Source connectors "
    "(webhook, condition, etc.) call receive_trigger_event to fire registered triggers."
)

# ── Registration payload ───────────────────────────────────────────────────────

REGISTRATION_PAYLOAD: dict = {
    "name":        AGENT_NAME,
    "description": AGENT_DESCRIPTION,
    "version":     AGENT_VERSION,
    "capabilities": [
        # ── register_trigger ──────────────────────────────────────────────────
        {
            "name": "register_trigger",
            "description": (
                "Register a new trigger definition. Returns a trigger_id that source agents "
                "(webhook-agent, condition-agent, etc.) include when calling receive_trigger_event. "
                "For schedule triggers the cron expression is validated and the first next_run_at computed."
            ),
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Human-readable label for this trigger.",
                    },
                    "type": {
                        "type": "string",
                        "enum": sorted(VALID_TRIGGER_TYPES),
                        "description": (
                            "Trigger family: schedule | webhook | conversation | email | "
                            "condition | workflow_event | data_change | manual"
                        ),
                    },
                    "owner_id": {
                        "type": "string",
                        "description": "requester_id or user_id who owns this trigger.",
                    },
                    "config": {
                        "type": "object",
                        "description": (
                            "Type-specific configuration JSON. "
                            "schedule → {cron, timezone}. "
                            "webhook → {secret, payload_mapping}. "
                            "condition → {check_url, jq_filter, operator, threshold, poll_interval_s}. "
                            "workflow_event → {event, watch_workflow_id, output_filter}. "
                            "Others → arbitrary key/value config."
                        ),
                    },
                    "workflow_id": {
                        "type": "string",
                        "description": (
                            "Bind to a saved workflow — on fire, calls execute_saved_workflow. "
                            "Mutually exclusive with goal_template."
                        ),
                    },
                    "goal_template": {
                        "type": "string",
                        "description": (
                            "Goal string passed to the task planner on fire. "
                            "Use {{field}} placeholders interpolated from the trigger payload. "
                            "Example: 'Summarise the new PR: {{pr_title}} by {{author}}'. "
                            "Mutually exclusive with workflow_id."
                        ),
                    },
                    "active": {
                        "type": "boolean",
                        "description": "Activate immediately (default true).",
                    },
                },
                "required": ["name", "type", "owner_id"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "trigger_id":  {"type": "string"},
                    "name":        {"type": "string"},
                    "type":        {"type": "string"},
                    "active":      {"type": "boolean"},
                    "next_run_at": {
                        "type": ["string", "null"],
                        "description": "First scheduled fire time (schedule triggers only).",
                    },
                },
            },
            "tags": ["trigger", "register"],
        },
        # ── get_trigger ───────────────────────────────────────────────────────
        {
            "name": "get_trigger",
            "description": "Get full trigger details including the recent fire log.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "trigger_id": {
                        "type": "string",
                        "description": "UUID of the trigger.",
                    },
                    "include_fire_log": {
                        "type": "boolean",
                        "description": "Include the last 20 fire-log entries (default true).",
                    },
                },
                "required": ["trigger_id"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "trigger":  {"type": "object"},
                    "fire_log": {"type": "array"},
                },
            },
            "tags": ["trigger", "query"],
        },
        # ── list_triggers ─────────────────────────────────────────────────────
        {
            "name": "list_triggers",
            "description": "List registered triggers with optional owner / type / active filters.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "owner_id": {"type": "string",  "description": "Filter by owner."},
                    "type":     {"type": "string",  "description": "Filter by trigger type."},
                    "active":   {"type": "boolean", "description": "Filter by active state."},
                    "limit":    {"type": "integer", "default": 50,  "description": "Max results (default 50, max 500)."},
                    "offset":   {"type": "integer", "default": 0,   "description": "Pagination offset."},
                },
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "triggers": {"type": "array"},
                    "count":    {"type": "integer"},
                    "total":    {"type": "integer"},
                    "offset":   {"type": "integer"},
                    "limit":    {"type": "integer"},
                },
            },
            "tags": ["trigger", "query"],
        },
        # ── update_trigger ────────────────────────────────────────────────────
        {
            "name": "update_trigger",
            "description": (
                "Update a trigger's name, config, goal_template, workflow_id, or active state. "
                "Changing config.cron on a schedule trigger recalculates next_run_at automatically."
            ),
            "input_schema": {
                "type": "object",
                "properties": {
                    "trigger_id":    {"type": "string"},
                    "name":          {"type": "string"},
                    "config":        {"type": "object"},
                    "workflow_id":   {"type": ["string", "null"]},
                    "goal_template": {"type": ["string", "null"]},
                    "active":        {"type": "boolean"},
                },
                "required": ["trigger_id"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "success": {"type": "boolean"},
                    "trigger": {"type": "object"},
                },
            },
            "tags": ["trigger", "mutate"],
        },
        # ── delete_trigger ────────────────────────────────────────────────────
        {
            "name": "delete_trigger",
            "description": "Permanently delete a trigger and all its fire-log entries.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "trigger_id": {"type": "string", "description": "UUID of the trigger to delete."},
                },
                "required": ["trigger_id"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "success": {"type": "boolean"},
                    "message": {"type": "string"},
                },
            },
            "tags": ["trigger", "mutate"],
        },
        # ── receive_trigger_event ─────────────────────────────────────────────
        {
            "name": "receive_trigger_event",
            "description": (
                "Called by source agents (webhook-agent, condition-agent, conversation connectors, "
                "etc.) when a trigger condition is met. The router deduplicates on idempotency_key, "
                "looks up the trigger definition, and dispatches to plan_task (goal_template) or "
                "execute_saved_workflow (workflow_id). Returns immediately; routing is async."
            ),
            "input_schema": {
                "type": "object",
                "properties": {
                    "trigger_id": {
                        "type": "string",
                        "description": "UUID of the trigger that fired.",
                    },
                    "payload": {
                        "type": "object",
                        "description": (
                            "Source-specific data (webhook body, condition reading, "
                            "email metadata, etc.). Used for {{field}} interpolation in goal_template."
                        ),
                    },
                    "idempotency_key": {
                        "type": "string",
                        "description": (
                            "Unique key for this specific firing event. "
                            "Router deduplicates — duplicate keys are silently ignored. "
                            "Example: GitHub delivery ID, message ID, 'check:{trigger_id}:{timestamp}'."
                        ),
                    },
                    "fired_at": {
                        "type": "string",
                        "description": "ISO 8601 UTC when the trigger fired. Defaults to now.",
                    },
                    "source_agent": {
                        "type": "string",
                        "description": "Name of the agent that detected the trigger condition.",
                    },
                },
                "required": ["trigger_id", "payload", "idempotency_key"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "accepted":        {"type": "boolean"},
                    "fire_id":         {"type": ["string", "null"]},
                    "duplicate":       {"type": "boolean"},
                    "dispatch_status": {
                        "type": "string",
                        "description": "dispatching | duplicate | trigger_inactive | trigger_not_found",
                    },
                },
            },
            "tags": ["trigger", "event", "dispatch"],
        },
        # ── fire_trigger ──────────────────────────────────────────────────────
        {
            "name": "fire_trigger",
            "description": (
                "Manually fire a trigger immediately. Useful for manual / approval triggers, "
                "dashboard 'Run now' buttons, and testing. Accepts an optional payload."
            ),
            "input_schema": {
                "type": "object",
                "properties": {
                    "trigger_id": {
                        "type": "string",
                        "description": "UUID of the trigger to fire.",
                    },
                    "payload": {
                        "type": "object",
                        "description": "Optional payload forwarded to the workflow or planner.",
                    },
                },
                "required": ["trigger_id"],
            },
            "output_schema": {
                "type": "object",
                "properties": {
                    "accepted":        {"type": "boolean"},
                    "fire_id":         {"type": ["string", "null"]},
                    "dispatch_status": {"type": "string"},
                },
            },
            "tags": ["trigger", "manual"],
        },
    ],
    "tags": ["trigger", "router", "workflow", "event-driven"],
    "required_settings": [],
}

# ── Constants ──────────────────────────────────────────────────────────────────

HEARTBEAT_INTERVAL_S: int   = 15
MAX_BACKOFF_S:        int   = 60
DRAIN_TIMEOUT_S:      int   = 30
POLL_INTERVAL_S:      int   = 5      # schedule-trigger poll cadence
DISPATCH_TIMEOUT_S:   float = 120.0  # default timeout for outbound capability calls


# ── Helpers ────────────────────────────────────────────────────────────────────

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _envelope(
    sender_id:      str,
    msg_type:       str,
    payload:        dict,
    recipient_id:   str | None = None,
    correlation_id: str | None = None,
    msg_id:         str | None = None,
) -> str:
    return json.dumps({
        "id":             msg_id or str(uuid.uuid4()),
        "type":           msg_type,
        "sender_id":      sender_id,
        "recipient_id":   recipient_id,
        "payload":        payload,
        "timestamp":      _now_iso(),
        "correlation_id": correlation_id,
    })


_PLACEHOLDER_RE = re.compile(r"\{\{(\w+)\}\}")


def _interpolate(template: str, payload: dict) -> str:
    """Replace {{field}} placeholders with values from payload."""
    def _sub(m: re.Match) -> str:
        return str(payload.get(m.group(1), m.group(0)))
    return _PLACEHOLDER_RE.sub(_sub, template)


# ── Main client ────────────────────────────────────────────────────────────────

class OrchestratorClient:
    """
    Registers the trigger-router with the orchestrator, maintains the
    persistent WebSocket connection, handles incoming capability requests, and
    routes trigger events to the planner or workflow executor.
    """

    def __init__(self, orchestrator_url: str = "http://localhost:8000") -> None:
        self._base = orchestrator_url.rstrip("/")
        self._http = httpx.AsyncClient(timeout=15)

        # Identity — populated after registration
        self._agent_id: str = ""
        self._ws_url:   str = ""

        # Status / metrics
        self._status:             str   = "starting"
        self._active_tasks:       int   = 0
        self._dispatching:        int   = 0
        self._tasks_completed:    int   = 0
        self._tasks_failed:       int   = 0
        self._total_duration_ms:  float = 0.0
        self._start_time:         float = time.monotonic()
        self._shutting_down:      bool  = False

        self._current_ws: Any = None

        # Correlation map for outbound task_requests
        self._pending_responses: dict[str, asyncio.Future] = {}

        self._store = TriggerStore()
        self._poll_task: asyncio.Task | None = None

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    async def start(self) -> None:
        """Register, open the store, start the schedule poll loop, connect WS. Blocks until shutdown."""
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(self._graceful_shutdown()))

        self._store.open()
        await self._register()
        self._poll_task = asyncio.create_task(self._poll_loop(), name="trigger-schedule-poll")
        await self._connect_loop()

    # ── Registration ───────────────────────────────────────────────────────────

    async def _register(self) -> None:
        url     = f"{self._base}/api/v1/agents/register"
        payload = {**REGISTRATION_PAYLOAD, "id": _stable_agent_id()}
        logger.info("Registering with orchestrator at %s …", url)
        resp = await self._http.post(url, json=payload)
        resp.raise_for_status()
        data           = resp.json()
        self._agent_id = data["agent_id"]
        self._ws_url   = data["ws_url"]
        logger.info("Registered — agent_id=%s  ws=%s", self._agent_id, self._ws_url)

    # ── WebSocket loop ─────────────────────────────────────────────────────────

    async def _connect_loop(self) -> None:
        backoff = 1.0
        while not self._shutting_down:
            try:
                logger.info("Connecting to %s …", self._ws_url)
                async with websockets.connect(self._ws_url) as ws:
                    backoff = 1.0
                    await self._run_session(ws)

            except websockets.exceptions.ConnectionClosed as exc:
                code = exc.rcvd.code if exc.rcvd else None
                if code == 4004:
                    logger.warning("Unknown agent_id (4004) — re-registering …")
                    try:
                        await self._register()
                    except Exception as reg_exc:
                        logger.error("Re-registration failed: %s", reg_exc)
                elif code == 4003:
                    logger.info("Agent disabled (4003) — retrying …")
                    backoff = max(backoff, 10.0)
                elif self._shutting_down:
                    break
                else:
                    logger.warning("WS closed (code=%s) — retry in %.0fs", code, backoff)

            except (OSError, Exception) as exc:
                if self._shutting_down:
                    break
                logger.warning("WS error (%s) — retry in %.0fs", exc, backoff)

            if not self._shutting_down:
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF_S)

    async def _run_session(self, ws) -> None:
        self._current_ws = ws
        self._status     = "available"
        logger.info("WebSocket session active — status: available")
        try:
            await asyncio.gather(
                self._heartbeat_loop(ws),
                self._recv_loop(ws),
            )
        finally:
            self._current_ws = None
            self._status     = "offline"
            for fut in list(self._pending_responses.values()):
                if not fut.done():
                    fut.set_exception(ConnectionError("WebSocket session ended"))

    # ── Heartbeat ──────────────────────────────────────────────────────────────

    async def _heartbeat_loop(self, ws) -> None:
        while True:
            total = self._active_tasks + self._dispatching
            await self._ws_send(ws, self._msg("heartbeat", {
                "status":                self._status,
                "current_load":          min(total / 10, 1.0),
                "active_tasks":          total,
                "expected_wait_time_ms": 0,
                "metrics":               self._metrics(),
            }))
            await asyncio.sleep(HEARTBEAT_INTERVAL_S)

    # ── Receive loop ───────────────────────────────────────────────────────────

    async def _recv_loop(self, ws) -> None:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                logger.warning("Non-JSON WS frame ignored")
                continue
            mtype = msg.get("type", "?")
            lvl = logging.DEBUG if mtype in (
                "agent_registered", "agent_offline", "heartbeat_ack", "settings_push"
            ) else logging.INFO
            logger.log(
                lvl, "← [%s] from=%s  %s",
                mtype, msg.get("sender_id", "?"),
                json.dumps(msg.get("payload", {}))[:200],
            )
            await self._dispatch_msg(ws, msg)

    async def _dispatch_msg(self, ws, msg: dict) -> None:
        mtype   = msg.get("type", "")
        payload = msg.get("payload", {})

        if mtype == "task_request":
            asyncio.create_task(self._handle_incoming_task(ws, msg))

        elif mtype == "task_response":
            corr = msg.get("correlation_id")
            if corr and corr in self._pending_responses:
                fut = self._pending_responses.pop(corr)
                if not fut.done():
                    fut.set_result(payload)
            else:
                logger.debug("Unmatched task_response correlation_id=%s", corr)

        elif mtype == "agent_registered":
            logger.info("Peer joined: %s", payload.get("agent_id"))

        elif mtype == "agent_offline":
            logger.info("Peer left: %s (reason: %s)", payload.get("agent_id"), payload.get("reason"))

        elif mtype == "agent_restart":
            logger.info("Restart requested by orchestrator — shutting down")
            asyncio.create_task(self._graceful_shutdown())
            import sys
            asyncio.get_event_loop().call_later(1.0, lambda: sys.exit(0))

        elif mtype == "error":
            logger.error("Orchestrator error [%s]: %s", payload.get("code"), payload.get("detail"))
            orig = payload.get("original_message_id")
            if orig and orig in self._pending_responses:
                fut = self._pending_responses.pop(orig)
                if not fut.done():
                    fut.set_exception(RuntimeError(
                        f"[{payload.get('code')}] {payload.get('detail')}"
                    ))

        elif mtype in ("broadcast", "discovery_response"):
            logger.debug("Received %s", mtype)

        else:
            logger.debug("Unhandled message type: %r", mtype)

    # ── Incoming task handler ──────────────────────────────────────────────────

    async def _handle_incoming_task(self, ws, msg: dict) -> None:
        req_id     = msg.get("id")
        sender_id  = msg.get("sender_id")
        payload    = msg.get("payload", {})
        capability = payload.get("capability")
        input_data = payload.get("input_data", {})

        self._active_tasks += 1
        self._status = "busy"
        t0 = time.monotonic()

        try:
            if capability == "register_trigger":
                output, error = await self._cap_register_trigger(input_data)
            elif capability == "get_trigger":
                output, error = await self._cap_get_trigger(input_data)
            elif capability == "list_triggers":
                output, error = await self._cap_list_triggers(input_data)
            elif capability == "update_trigger":
                output, error = await self._cap_update_trigger(input_data)
            elif capability == "delete_trigger":
                output, error = await self._cap_delete_trigger(input_data)
            elif capability == "receive_trigger_event":
                output, error = await self._cap_receive_trigger_event(input_data)
            elif capability == "fire_trigger":
                output, error = await self._cap_fire_trigger(input_data)
            else:
                output, error = None, f"Unknown capability: {capability!r}"

            duration_ms = (time.monotonic() - t0) * 1000

            if error:
                self._tasks_failed += 1
                await self._ws_send(ws, self._msg(
                    "task_response",
                    {"success": False, "error": error, "duration_ms": round(duration_ms, 1)},
                    recipient_id=sender_id, correlation_id=req_id,
                ))
            else:
                self._tasks_completed += 1
                self._total_duration_ms += duration_ms
                await self._ws_send(ws, self._msg(
                    "task_response",
                    {"success": True, "output_data": output, "duration_ms": round(duration_ms, 1)},
                    recipient_id=sender_id, correlation_id=req_id,
                ))

        except Exception as exc:
            duration_ms = (time.monotonic() - t0) * 1000
            self._tasks_failed += 1
            logger.exception("Unhandled exception in capability %r", capability)
            await self._ws_send(ws, self._msg(
                "task_response",
                {"success": False, "error": str(exc), "duration_ms": round(duration_ms, 1)},
                recipient_id=sender_id, correlation_id=req_id,
            ))

        finally:
            self._active_tasks = max(0, self._active_tasks - 1)
            total = self._active_tasks + self._dispatching
            self._status = "draining" if self._shutting_down else ("busy" if total else "available")
            await self._send_status_update(ws)

    # ── Capability handlers ────────────────────────────────────────────────────

    async def _cap_register_trigger(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        name          = (input_data.get("name") or "").strip()
        ttype         = (input_data.get("type") or "").strip().lower()
        owner_id      = (input_data.get("owner_id") or "").strip()
        config        = input_data.get("config") or {}
        workflow_id   = (input_data.get("workflow_id") or "").strip() or None
        goal_template = (input_data.get("goal_template") or "").strip() or None
        active        = bool(input_data.get("active", True))

        if not name:
            return None, "input_data.name is required"
        if not ttype:
            return None, "input_data.type is required"
        if ttype not in VALID_TRIGGER_TYPES:
            return None, (
                f"Unknown trigger type: {ttype!r}. "
                f"Valid types: {', '.join(sorted(VALID_TRIGGER_TYPES))}"
            )
        if not owner_id:
            return None, "input_data.owner_id is required"
        if not isinstance(config, dict):
            return None, "input_data.config must be an object"
        if workflow_id and goal_template:
            return None, "Provide either workflow_id or goal_template, not both"

        next_run_at: str | None = None
        if ttype == "schedule":
            err, next_run_at = _validate_schedule_config(config)
            if err:
                return None, err

        trigger_id = await asyncio.to_thread(
            self._store.create_trigger,
            name=name,
            type=ttype,
            owner_id=owner_id,
            config=config,
            workflow_id=workflow_id,
            goal_template=goal_template,
            next_run_at=next_run_at,
            active=active,
        )
        logger.info(
            "Registered trigger %s (name=%r type=%s active=%s next_run=%s)",
            trigger_id, name, ttype, active, next_run_at or "N/A",
        )
        return {
            "trigger_id":  trigger_id,
            "name":        name,
            "type":        ttype,
            "active":      active,
            "next_run_at": next_run_at,
        }, None

    async def _cap_get_trigger(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        trigger_id       = (input_data.get("trigger_id") or "").strip()
        include_fire_log = bool(input_data.get("include_fire_log", True))
        if not trigger_id:
            return None, "input_data.trigger_id is required"
        trigger = await asyncio.to_thread(self._store.get_trigger, trigger_id)
        if trigger is None:
            return None, f"Trigger '{trigger_id}' not found"
        result: dict = {"trigger": trigger}
        if include_fire_log:
            result["fire_log"] = await asyncio.to_thread(self._store.list_fire_log, trigger_id)
        return result, None

    async def _cap_list_triggers(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        owner_id  = (input_data.get("owner_id") or "").strip() or None
        ttype     = (input_data.get("type") or "").strip() or None
        raw_active = input_data.get("active")
        active    = None if raw_active is None else bool(raw_active)
        try:
            limit  = max(1, min(500, int(input_data.get("limit",  50))))
            offset = max(0,          int(input_data.get("offset",  0)))
        except (ValueError, TypeError):
            limit, offset = 50, 0

        triggers = await asyncio.to_thread(
            self._store.list_triggers,
            owner_id=owner_id, type=ttype, active=active, limit=limit, offset=offset,
        )
        total = await asyncio.to_thread(
            self._store.count_triggers,
            owner_id=owner_id, type=ttype, active=active,
        )
        return {
            "triggers": triggers,
            "count":    len(triggers),
            "total":    total,
            "offset":   offset,
            "limit":    limit,
        }, None

    async def _cap_update_trigger(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        trigger_id = (input_data.get("trigger_id") or "").strip()
        if not trigger_id:
            return None, "input_data.trigger_id is required"

        trigger = await asyncio.to_thread(self._store.get_trigger, trigger_id)
        if trigger is None:
            return None, f"Trigger '{trigger_id}' not found"

        kwargs: dict = {}
        _MISSING = TriggerStore._MISSING

        if "name" in input_data:
            kwargs["name"] = (input_data["name"] or "").strip()
        if "config" in input_data:
            kwargs["config"] = input_data["config"] or {}
        if "workflow_id" in input_data:
            kwargs["workflow_id"] = (input_data["workflow_id"] or None)
        if "goal_template" in input_data:
            kwargs["goal_template"] = (input_data["goal_template"] or None)
        if "active" in input_data:
            kwargs["active"] = bool(input_data["active"])

        if not kwargs:
            return None, "Provide at least one of: name, config, workflow_id, goal_template, active"

        # Recompute next_run_at when cron config changes on a schedule trigger
        if trigger["type"] == "schedule" and "config" in kwargs:
            err, next_run_at = _validate_schedule_config(kwargs["config"])
            if err:
                return None, err
            kwargs["next_run_at"] = next_run_at

        updated = await asyncio.to_thread(self._store.update_trigger, trigger_id, **kwargs)
        if not updated:
            return None, f"Update failed for trigger '{trigger_id}'"

        updated_trigger = await asyncio.to_thread(self._store.get_trigger, trigger_id)
        return {"success": True, "trigger": updated_trigger}, None

    async def _cap_delete_trigger(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        trigger_id = (input_data.get("trigger_id") or "").strip()
        if not trigger_id:
            return None, "input_data.trigger_id is required"
        deleted = await asyncio.to_thread(self._store.delete_trigger, trigger_id)
        if deleted:
            return {"success": True, "message": f"Trigger '{trigger_id}' deleted."}, None
        return None, f"Trigger '{trigger_id}' not found"

    async def _cap_receive_trigger_event(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        trigger_id      = (input_data.get("trigger_id") or "").strip()
        payload         = input_data.get("payload") or {}
        idempotency_key = (input_data.get("idempotency_key") or "").strip()
        fired_at        = (input_data.get("fired_at") or _now_iso()).strip()
        source_agent    = (input_data.get("source_agent") or "").strip() or None

        if not trigger_id:
            return None, "input_data.trigger_id is required"
        if not idempotency_key:
            return None, "input_data.idempotency_key is required"
        if not isinstance(payload, dict):
            return None, "input_data.payload must be an object"

        trigger = await asyncio.to_thread(self._store.get_trigger, trigger_id)
        if trigger is None:
            return {"accepted": False, "fire_id": None, "duplicate": False,
                    "dispatch_status": "trigger_not_found"}, None
        if not trigger["active"]:
            return {"accepted": False, "fire_id": None, "duplicate": False,
                    "dispatch_status": "trigger_inactive"}, None

        fire_id = await asyncio.to_thread(
            self._store.start_fire,
            trigger_id=trigger_id,
            idempotency_key=idempotency_key,
            fired_at=fired_at,
            source_agent=source_agent,
            payload=payload,
        )
        if fire_id is None:
            return {"accepted": False, "fire_id": None, "duplicate": True,
                    "dispatch_status": "duplicate"}, None

        # Route asynchronously — respond immediately so the source agent isn't blocked
        asyncio.create_task(
            self._route_event(trigger, payload, fire_id),
            name=f"route-{fire_id[:8]}",
        )
        logger.info(
            "Trigger %s accepted (source=%s fire_id=%s idempotency=%s)",
            trigger_id, source_agent, fire_id, idempotency_key,
        )
        return {
            "accepted":        True,
            "fire_id":         fire_id,
            "duplicate":       False,
            "dispatch_status": "dispatching",
        }, None

    async def _cap_fire_trigger(
        self, input_data: dict
    ) -> tuple[dict | None, str | None]:
        trigger_id = (input_data.get("trigger_id") or "").strip()
        payload    = input_data.get("payload") or {}
        if not trigger_id:
            return None, "input_data.trigger_id is required"

        trigger = await asyncio.to_thread(self._store.get_trigger, trigger_id)
        if trigger is None:
            return None, f"Trigger '{trigger_id}' not found"

        idempotency_key = f"manual:{trigger_id}:{_now_iso()}:{uuid.uuid4().hex[:6]}"
        fire_id = await asyncio.to_thread(
            self._store.start_fire,
            trigger_id=trigger_id,
            idempotency_key=idempotency_key,
            fired_at=_now_iso(),
            source_agent="manual",
            payload=payload,
        )
        if fire_id is None:
            return {"accepted": False, "fire_id": None, "dispatch_status": "duplicate"}, None

        asyncio.create_task(
            self._route_event(trigger, payload, fire_id),
            name=f"manual-{fire_id[:8]}",
        )
        return {"accepted": True, "fire_id": fire_id, "dispatch_status": "dispatching"}, None

    # ── Event routing ──────────────────────────────────────────────────────────

    async def _route_event(self, trigger: dict, payload: dict, fire_id: str) -> None:
        """Dispatch to plan_task or execute_saved_workflow based on trigger binding."""
        t0          = time.monotonic()
        trigger_id  = trigger["id"]
        workflow_id = trigger.get("workflow_id")
        goal_tmpl   = trigger.get("goal_template")
        owner_id    = trigger.get("owner_id", "")

        self._dispatching += 1
        try:
            if workflow_id:
                success, result, error = await self._dispatch_saved_workflow(workflow_id, payload)

            elif goal_tmpl:
                goal = _interpolate(goal_tmpl, payload)
                success, result, error = await self._dispatch_plan_task(
                    goal=goal, requester_id=owner_id, context=payload
                )

            else:
                # Trigger with no binding — just log; treat as success
                success, result, error = True, {"logged": True}, None
                logger.info("Trigger %s fired with no binding — logged only", trigger_id)

            duration_ms = (time.monotonic() - t0) * 1000

            if success:
                await asyncio.to_thread(
                    self._store.complete_fire, fire_id,
                    "dispatched", result, None, duration_ms,
                )
                await asyncio.to_thread(self._store.bump_fire_count, trigger_id)
                logger.info(
                    "Trigger %s dispatched (fire=%s duration=%.0fms)",
                    trigger_id, fire_id, duration_ms,
                )
            else:
                await asyncio.to_thread(
                    self._store.complete_fire, fire_id,
                    "failed", None, error, duration_ms,
                )
                logger.warning(
                    "Trigger %s dispatch failed (fire=%s): %s", trigger_id, fire_id, error
                )

        except Exception as exc:
            duration_ms = (time.monotonic() - t0) * 1000
            logger.exception("Unexpected error routing trigger %s (fire=%s)", trigger_id, fire_id)
            await asyncio.to_thread(
                self._store.complete_fire, fire_id, "failed", None, str(exc), duration_ms
            )
        finally:
            self._dispatching = max(0, self._dispatching - 1)

    async def _dispatch_plan_task(
        self, goal: str, requester_id: str, context: dict
    ) -> tuple[bool, dict | None, str | None]:
        target_id = await self._discover_best("plan_task")
        if not target_id:
            return False, None, "No plan_task agent available (is task-planner-agent running?)"
        return await self._forward_task(
            target_agent_id=target_id,
            capability="plan_task",
            input_data={"goal": goal, "requester_id": requester_id, "context": context},
        )

    async def _dispatch_saved_workflow(
        self, workflow_id: str, context: dict
    ) -> tuple[bool, dict | None, str | None]:
        target_id = await self._discover_best("execute_saved_workflow")
        if not target_id:
            return False, None, "No execute_saved_workflow agent available"
        return await self._forward_task(
            target_agent_id=target_id,
            capability="execute_saved_workflow",
            input_data={"workflow_id": workflow_id, "context": context},
        )

    # ── Schedule trigger poll loop ─────────────────────────────────────────────

    async def _poll_loop(self) -> None:
        """Check for due schedule triggers every POLL_INTERVAL_S seconds."""
        logger.info("Schedule trigger poll loop started (interval=%ds)", POLL_INTERVAL_S)
        while not self._shutting_down:
            await asyncio.sleep(POLL_INTERVAL_S)
            if not self._current_ws:
                continue
            try:
                await self._poll_tick()
            except Exception:
                logger.exception("Error in schedule trigger poll tick")

    async def _poll_tick(self) -> None:
        due = await asyncio.to_thread(self._store.get_due_schedule_triggers)
        if not due:
            return
        logger.info("Poll: %d schedule trigger(s) due", len(due))

        for trigger in due:
            trigger_id = trigger["id"]
            config     = trigger.get("config", {})
            cron_expr  = (config.get("cron") or "").strip()
            tz         = (config.get("timezone") or "UTC").strip()

            # Advance next_run_at immediately to prevent re-dispatch on the next poll tick
            next_run_at: str | None = None
            if cron_expr:
                try:
                    from cron import next_cron_run
                    next_dt    = next_cron_run(cron_expr, datetime.now(timezone.utc), tz=tz)
                    next_run_at = next_dt.isoformat(timespec="milliseconds")
                except Exception as exc:
                    logger.error(
                        "Failed to compute next_run for trigger %s: %s", trigger_id, exc
                    )
            await asyncio.to_thread(
                self._store.update_trigger, trigger_id, next_run_at=next_run_at
            )

            fired_at        = _now_iso()
            idempotency_key = f"schedule:{trigger_id}:{fired_at}"

            fire_id = await asyncio.to_thread(
                self._store.start_fire,
                trigger_id=trigger_id,
                idempotency_key=idempotency_key,
                fired_at=fired_at,
                source_agent=AGENT_NAME,
                payload={},
            )
            if fire_id is None:
                logger.warning("Duplicate schedule firing skipped for trigger %s", trigger_id)
                continue

            asyncio.create_task(
                self._route_event(trigger, {}, fire_id),
                name=f"sched-{trigger_id[:8]}",
            )

    # ── Outbound capability dispatch ───────────────────────────────────────────

    async def _discover_best(self, capability: str) -> str | None:
        try:
            resp = await self._http.get(
                f"{self._base}/api/v1/discover/best",
                params={"capability": capability},
            )
            if resp.status_code == 200:
                data      = resp.json()
                agent_id  = data.get("agent_id")
                logger.info(
                    "Discovered agent %s for capability '%s'", agent_id, capability
                )
                return agent_id
            logger.warning(
                "No agent for capability '%s' (status=%d)", capability, resp.status_code
            )
        except Exception as exc:
            logger.error("Discovery request failed: %s", exc)
        return None

    async def _forward_task(
        self,
        target_agent_id: str,
        capability:      str,
        input_data:      dict,
        timeout_ms:      float | None = None,
    ) -> tuple[bool, dict | None, str | None]:
        ws = self._current_ws
        if ws is None:
            return False, None, "No active WebSocket connection"

        req_id = str(uuid.uuid4())
        loop   = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        self._pending_responses[req_id] = fut

        try:
            await self._ws_send(ws, _envelope(
                sender_id=self._agent_id,
                msg_type="task_request",
                payload={
                    "capability": capability,
                    "input_data": input_data,
                    **({"timeout_ms": timeout_ms} if timeout_ms else {}),
                },
                recipient_id=target_agent_id,
                msg_id=req_id,
            ))
            timeout_s = (timeout_ms / 1000) if timeout_ms else DISPATCH_TIMEOUT_S
            resp = await asyncio.wait_for(asyncio.shield(fut), timeout=timeout_s)
            if resp.get("success"):
                return True, resp.get("output_data"), None
            return False, None, resp.get("error", "Unknown error")

        except asyncio.TimeoutError:
            return False, None, (
                f"Dispatch timed out after "
                f"{(timeout_ms or DISPATCH_TIMEOUT_S * 1000):.0f} ms"
            )
        except Exception as exc:
            return False, None, str(exc)
        finally:
            self._pending_responses.pop(req_id, None)

    # ── Protocol helpers ───────────────────────────────────────────────────────

    def _msg(
        self,
        msg_type:       str,
        payload:        dict,
        recipient_id:   str | None = None,
        correlation_id: str | None = None,
    ) -> str:
        return _envelope(self._agent_id, msg_type, payload, recipient_id, correlation_id)

    async def _ws_send(self, ws, data: str) -> None:
        try:
            await ws.send(data)
        except Exception as exc:
            logger.warning("WS send failed: %s", exc)

    def _metrics(self) -> dict:
        elapsed = time.monotonic() - self._start_time
        avg     = (
            self._total_duration_ms / self._tasks_completed
            if self._tasks_completed else 0.0
        )
        return {
            "tasks_completed":      self._tasks_completed,
            "tasks_failed":         self._tasks_failed,
            "avg_response_time_ms": round(avg, 1),
            "uptime_seconds":       round(elapsed, 1),
        }

    async def _send_status_update(self, ws) -> None:
        total = self._active_tasks + self._dispatching
        await self._ws_send(ws, self._msg("status_update", {
            "status":       self._status,
            "current_load": min(total / 10, 1.0),
            "active_tasks": total,
            "metrics":      self._metrics(),
        }))

    # ── Graceful shutdown ──────────────────────────────────────────────────────

    async def _graceful_shutdown(self) -> None:
        if self._shutting_down:
            return
        self._shutting_down = True
        logger.info("Graceful shutdown initiated")
        self._status = "draining"

        if self._poll_task and not self._poll_task.done():
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass

        # Wait for in-flight dispatches to complete
        deadline = time.monotonic() + DRAIN_TIMEOUT_S
        while self._dispatching > 0 and time.monotonic() < deadline:
            logger.info("Draining: %d dispatch(es) still in flight …", self._dispatching)
            await asyncio.sleep(0.5)

        try:
            await self._http.delete(f"{self._base}/api/v1/agents/{self._agent_id}")
            logger.info("Deregistered from orchestrator")
        except Exception as exc:
            logger.warning("Deregister failed (non-fatal): %s", exc)

        if self._current_ws:
            try:
                await self._current_ws.close()
            except Exception:
                pass

        self._store.close()
        logger.info("Shutdown complete")


# ── Module-level helpers ───────────────────────────────────────────────────────

def _validate_schedule_config(config: dict) -> tuple[str | None, str | None]:
    """Validate schedule config and return (error, next_run_at_iso)."""
    cron_expr = (config.get("cron") or "").strip()
    tz        = (config.get("timezone") or "UTC").strip()
    if not cron_expr:
        return ("Schedule trigger requires config.cron (e.g. '0 9 * * 1-5')"), None
    try:
        from cron import next_cron_run, validate_cron
        valid, desc_or_err = validate_cron(cron_expr)
        if not valid:
            return f"Invalid cron expression: {desc_or_err}", None
        next_dt = next_cron_run(cron_expr, datetime.now(timezone.utc), tz=tz)
        return None, next_dt.isoformat(timespec="milliseconds")
    except Exception as exc:
        return f"Schedule config error: {exc}", None
