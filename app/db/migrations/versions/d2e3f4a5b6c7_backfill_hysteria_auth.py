"""backfill per-user auth for hysteria proxies

Earlier Hysteria support stored an empty settings object because it relied on a
single shared inbound "auth". Hysteria 2 now uses a per-user auth string, so any
pre-existing Hysteria proxy rows need a stable auth value persisted; otherwise a
new random auth would be generated on every load.

Revision ID: d2e3f4a5b6c7
Revises: c1d2e3f4a5b6
Create Date: 2026-06-19 16:10:00.000000

"""
import json
import secrets

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'd2e3f4a5b6c7'
down_revision = 'c1d2e3f4a5b6'
branch_labels = None
depends_on = None


def upgrade():
    conn = op.get_bind()
    rows = conn.execute(
        sa.text("SELECT id, settings FROM proxies WHERE type = 'Hysteria'")
    ).fetchall()

    for row in rows:
        proxy_id, raw = row[0], row[1]
        try:
            settings = json.loads(raw) if isinstance(raw, (str, bytes)) else (raw or {})
        except (TypeError, ValueError):
            settings = {}
        if not isinstance(settings, dict):
            settings = {}

        if not settings.get('auth'):
            settings['auth'] = secrets.token_urlsafe(16)
            conn.execute(
                sa.text("UPDATE proxies SET settings = :settings WHERE id = :id"),
                {"settings": json.dumps(settings), "id": proxy_id},
            )


def downgrade():
    # No-op: dropping the generated auth would lock out existing Hysteria users.
    pass
