import sqlite3
import uuid
from datetime import datetime, timezone

DB_PATH = "audit.db"


def _connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = _connect()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS audit_log (
            content_id TEXT PRIMARY KEY,
            creator_id TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            attribution TEXT NOT NULL,
            confidence REAL NOT NULL,
            llm_score REAL NOT NULL,
            llm_reason TEXT NOT NULL,
            heuristics_score REAL,
            heuristics_detail TEXT,
            status TEXT NOT NULL DEFAULT 'classified',
            appeal_reason TEXT,
            appeal_timestamp TEXT
        )
    """)
    conn.commit()
    conn.close()


def log_submission(
    creator_id: str,
    attribution: str,
    confidence: float,
    llm_score: float,
    llm_reason: str,
    heuristics_score: float | None = None,
    heuristics_detail: str | None = None,
) -> str:
    content_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()
    conn = _connect()
    conn.execute(
        """
        INSERT INTO audit_log (content_id, creator_id, timestamp, attribution, confidence, llm_score, llm_reason, heuristics_score, heuristics_detail)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (content_id, creator_id, timestamp, attribution, confidence, llm_score, llm_reason, heuristics_score, heuristics_detail),
    )
    conn.commit()
    conn.close()
    return content_id


def get_log(limit: int = 20):
    conn = _connect()
    rows = conn.execute(
        "SELECT * FROM audit_log ORDER BY timestamp DESC LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return [dict(row) for row in rows]


def submission_exists(content_id: str) -> bool:
    conn = _connect()
    row = conn.execute(
        "SELECT 1 FROM audit_log WHERE content_id = ?",
        (content_id,),
    ).fetchone()
    conn.close()
    return row is not None


def has_appeal(content_id: str) -> bool:
    conn = _connect()
    row = conn.execute(
        "SELECT appeal_reason FROM audit_log WHERE content_id = ?",
        (content_id,),
    ).fetchone()
    conn.close()
    return row is not None and row["appeal_reason"] is not None


def log_appeal(content_id: str, creator_reasoning: str) -> bool:
    timestamp = datetime.now(timezone.utc).isoformat()
    conn = _connect()
    cursor = conn.execute(
        """
        UPDATE audit_log
        SET status = 'under_review', appeal_reason = ?, appeal_timestamp = ?
        WHERE content_id = ?
        """,
        (creator_reasoning, timestamp, content_id),
    )
    conn.commit()
    updated = cursor.rowcount > 0
    conn.close()
    return updated
