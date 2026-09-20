"""
router.py

SQLite-backed store for the trigger-router.

Tables
------
  triggers          — trigger definitions (type, config, workflow/planner binding)
  trigger_fire_log  — immutable audit log of every trigger firing
"""
from __future__ import annotations

import json
import logging
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

DB_PATH = Path("triggers.db")

VALID_TRIGGER_TYPES: frozenset[str] = frozenset({
    "schedule",
    "webhook",
    "conversation",
    "email",
    "condition",
    "workflow_event",
    "data_change",
    "manual",
})

FIRE_STATUS_PENDING    = "pending"
FIRE_STATUS_DISPATCHED = "dispatched"
FIRE_STATUS_FAILED     = "failed"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class TriggerStore:
    """Thread-safe SQLite store for trigger definitions and fire log.

    Open with ``open()`` before use and close with ``close()`` on shutdown.
    All methods are synchronous — call them from a thread or via
    ``asyncio.to_thread`` from async code.
    """

    def __init__(self, db_path: Path = DB_PATH) -> None:
        self._db_path = db_path
        self._conn: sqlite3.Connection | None = None

    # ── Lifecycle ──────────────────────────────────────────────────────────

    def open(self) -> None:
        self._conn = sqlite3.connect(str(self._db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("""
            CREATE TABLE IF NOT EXISTS triggers (
                id              TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                type            TEXT NOT NULL,
                owner_id        TEXT NOT NULL,
                config          TEXT NOT NULL DEFAULT '{}',
                workflow_id     TEXT,
                goal_template   TEXT,
                active          INTEGER NOT NULL DEFAULT 1,
                next_run_at     TEXT,
                last_fired_at   TEXT,
                fire_count      INTEGER NOT NULL DEFAULT 0,
                created_at      TEXT NOT NULL,
                updated_at      TEXT NOT NULL
            )
        """)
        self._conn.execute("""
            CREATE TABLE IF NOT EXISTS trigger_fire_log (
                id              TEXT PRIMARY KEY,
                trigger_id      TEXT NOT NULL,
                fired_at        TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                status          TEXT NOT NULL DEFAULT 'pending',
                source_agent    TEXT,
                payload         TEXT NOT NULL DEFAULT '{}',
                dispatch_result TEXT,
                error           TEXT,
                duration_ms     REAL,
                created_at      TEXT NOT NULL
            )
        """)
        self._conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_idempotency "
            "ON trigger_fire_log(idempotency_key)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fire_trigger_time "
            "ON trigger_fire_log(trigger_id, created_at DESC)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_trigger_schedule "
            "ON triggers(active, type, next_run_at)"
        )
        self._conn.commit()
        logger.info("TriggerStore opened at %s", self._db_path)

    def close(self) -> None:
        if self._conn:
            self._conn.close()
            self._conn = None

    def _db(self) -> sqlite3.Connection:
        if self._conn is None:
            raise RuntimeError("TriggerStore not opened")
        return self._conn

    # ── Trigger CRUD ──────────────────────────────────────────────────────

    def create_trigger(
        self,
        *,
        name: str,
        type: str,
        owner_id: str,
        config: dict,
        workflow_id: str | None = None,
        goal_template: str | None = None,
        next_run_at: str | None = None,
        active: bool = True,
    ) -> str:
        trigger_id = str(uuid.uuid4())
        now = _now_iso()
        self._db().execute(
            """
            INSERT INTO triggers
              (id, name, type, owner_id, config, workflow_id, goal_template,
               active, next_run_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                trigger_id, name, type, owner_id,
                json.dumps(config), workflow_id, goal_template,
                1 if active else 0, next_run_at, now, now,
            ),
        )
        self._db().commit()
        return trigger_id

    def get_trigger(self, trigger_id: str) -> dict | None:
        row = self._db().execute(
            "SELECT * FROM triggers WHERE id = ?", (trigger_id,)
        ).fetchone()
        return _row_to_trigger(row) if row else None

    def list_triggers(
        self,
        owner_id: str | None = None,
        type: str | None = None,
        active: bool | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        clauses: list[str] = []
        params: list = []
        if owner_id:
            clauses.append("owner_id = ?"); params.append(owner_id)
        if type:
            clauses.append("type = ?");  params.append(type)
        if active is not None:
            clauses.append("active = ?"); params.append(1 if active else 0)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        rows = self._db().execute(
            f"SELECT * FROM triggers {where} ORDER BY created_at DESC LIMIT ? OFFSET ?",
            params + [limit, offset],
        ).fetchall()
        return [_row_to_trigger(r) for r in rows]

    def count_triggers(
        self,
        owner_id: str | None = None,
        type: str | None = None,
        active: bool | None = None,
    ) -> int:
        clauses: list[str] = []
        params: list = []
        if owner_id:
            clauses.append("owner_id = ?"); params.append(owner_id)
        if type:
            clauses.append("type = ?");  params.append(type)
        if active is not None:
            clauses.append("active = ?"); params.append(1 if active else 0)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        return self._db().execute(
            f"SELECT COUNT(*) FROM triggers {where}", params
        ).fetchone()[0]

    # Sentinel for "caller did not supply this argument" — distinct from None
    _MISSING = object()

    def update_trigger(
        self,
        trigger_id: str,
        *,
        name: str | None = None,
        config: dict | None = None,
        workflow_id=_MISSING,
        goal_template=_MISSING,
        active: bool | None = None,
        next_run_at=_MISSING,
    ) -> bool:
        sets: list[str] = []
        params: list = []
        now = _now_iso()

        if name is not None:
            sets.append("name = ?"); params.append(name)
        if config is not None:
            sets.append("config = ?"); params.append(json.dumps(config))
        if workflow_id is not TriggerStore._MISSING:
            sets.append("workflow_id = ?"); params.append(workflow_id)
        if goal_template is not TriggerStore._MISSING:
            sets.append("goal_template = ?"); params.append(goal_template)
        if active is not None:
            sets.append("active = ?"); params.append(1 if active else 0)
        if next_run_at is not TriggerStore._MISSING:
            sets.append("next_run_at = ?"); params.append(next_run_at)

        if not sets:
            return False

        sets.append("updated_at = ?"); params.append(now)
        params.append(trigger_id)
        cur = self._db().execute(
            f"UPDATE triggers SET {', '.join(sets)} WHERE id = ?", params
        )
        self._db().commit()
        return cur.rowcount > 0

    def delete_trigger(self, trigger_id: str) -> bool:
        cur = self._db().execute("DELETE FROM triggers WHERE id = ?", (trigger_id,))
        self._db().commit()
        return cur.rowcount > 0

    def bump_fire_count(self, trigger_id: str, next_run_at=_MISSING) -> None:
        now = _now_iso()
        if next_run_at is not TriggerStore._MISSING:
            self._db().execute(
                "UPDATE triggers SET fire_count=fire_count+1, last_fired_at=?, "
                "next_run_at=?, updated_at=? WHERE id=?",
                (now, next_run_at, now, trigger_id),
            )
        else:
            self._db().execute(
                "UPDATE triggers SET fire_count=fire_count+1, last_fired_at=?, "
                "updated_at=? WHERE id=?",
                (now, now, trigger_id),
            )
        self._db().commit()

    def get_due_schedule_triggers(self) -> list[dict]:
        """Return active schedule triggers whose next_run_at is now or in the past."""
        now = _now_iso()
        rows = self._db().execute(
            "SELECT * FROM triggers "
            "WHERE type='schedule' AND active=1 AND next_run_at IS NOT NULL AND next_run_at <= ?",
            (now,),
        ).fetchall()
        return [_row_to_trigger(r) for r in rows]

    # ── Fire log ──────────────────────────────────────────────────────────

    def start_fire(
        self,
        *,
        trigger_id: str,
        idempotency_key: str,
        fired_at: str,
        source_agent: str | None,
        payload: dict,
    ) -> str | None:
        """Insert a fire-log entry.

        Returns the ``fire_id`` on success, or ``None`` when the
        ``idempotency_key`` is a duplicate (fire already recorded).
        """
        fire_id = str(uuid.uuid4())
        now = _now_iso()
        try:
            self._db().execute(
                """
                INSERT INTO trigger_fire_log
                  (id, trigger_id, fired_at, idempotency_key, status,
                   source_agent, payload, created_at)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                (
                    fire_id, trigger_id, fired_at, idempotency_key,
                    FIRE_STATUS_PENDING, source_agent,
                    json.dumps(payload), now,
                ),
            )
            self._db().commit()
            return fire_id
        except sqlite3.IntegrityError:
            logger.warning(
                "Duplicate trigger firing ignored: key=%s trigger=%s",
                idempotency_key, trigger_id,
            )
            return None

    def complete_fire(
        self,
        fire_id: str,
        status: str,
        dispatch_result: dict | None = None,
        error: str | None = None,
        duration_ms: float | None = None,
    ) -> None:
        self._db().execute(
            "UPDATE trigger_fire_log "
            "SET status=?, dispatch_result=?, error=?, duration_ms=? WHERE id=?",
            (
                status,
                json.dumps(dispatch_result) if dispatch_result else None,
                error,
                round(duration_ms, 1) if duration_ms is not None else None,
                fire_id,
            ),
        )
        self._db().commit()

    def list_fire_log(self, trigger_id: str, limit: int = 20) -> list[dict]:
        rows = self._db().execute(
            "SELECT * FROM trigger_fire_log "
            "WHERE trigger_id=? ORDER BY created_at DESC LIMIT ?",
            (trigger_id, limit),
        ).fetchall()
        return [_row_to_fire(r) for r in rows]


# ── Row helpers (module-level so they can be used without an instance) ─────────

def _row_to_trigger(row: sqlite3.Row) -> dict:
    d = dict(row)
    try:
        d["config"] = json.loads(d.get("config") or "{}")
    except json.JSONDecodeError:
        d["config"] = {}
    d["active"] = bool(d.get("active", 1))
    return d


def _row_to_fire(row: sqlite3.Row) -> dict:
    d = dict(row)
    for key in ("payload", "dispatch_result"):
        raw = d.get(key)
        if raw:
            try:
                d[key] = json.loads(raw)
            except json.JSONDecodeError:
                pass
    return d
