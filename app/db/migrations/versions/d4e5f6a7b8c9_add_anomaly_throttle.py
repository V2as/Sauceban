"""add automatic throttling of anomalous users

Two additive changes, both on tables introduced by Sauce itself:

* `anomaly_settings` gains the knobs of the automatic response (on/off, cap,
  duration, severity floor);
* `blacklist_users` gains `source` and `expires_at`, so a cap knows whether an
  operator or the monitor put it there and when it lifts itself.

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-09-19 18:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'd4e5f6a7b8c9'
down_revision = 'c3d4e5f6a7b8'
branch_labels = None
depends_on = None


def _columns(inspector, table):
    if table not in inspector.get_table_names():
        return None
    return {column['name'] for column in inspector.get_columns(table)}


def upgrade():
    inspector = sa.inspect(op.get_bind())

    existing = _columns(inspector, 'anomaly_settings')
    if existing is not None:
        if 'throttle_enabled' not in existing:
            op.add_column('anomaly_settings', sa.Column(
                'throttle_enabled', sa.Boolean(), server_default=sa.text('0'),
                nullable=False,
            ))
        if 'throttle_mbps' not in existing:
            op.add_column('anomaly_settings', sa.Column(
                'throttle_mbps', sa.Integer(), server_default=sa.text('10'),
                nullable=False,
            ))
        if 'throttle_seconds' not in existing:
            op.add_column('anomaly_settings', sa.Column(
                'throttle_seconds', sa.Integer(), server_default=sa.text('3600'),
                nullable=False,
            ))
        if 'throttle_min_severity' not in existing:
            op.add_column('anomaly_settings', sa.Column(
                'throttle_min_severity', sa.String(length=16),
                server_default='high', nullable=False,
            ))

    existing = _columns(inspector, 'blacklist_users')
    if existing is not None:
        if 'source' not in existing:
            op.add_column('blacklist_users', sa.Column(
                'source', sa.String(length=16), server_default='manual',
                nullable=False,
            ))
        if 'expires_at' not in existing:
            op.add_column('blacklist_users', sa.Column(
                'expires_at', sa.DateTime(), nullable=True,
            ))
            op.create_index(
                op.f('ix_blacklist_users_expires_at'), 'blacklist_users',
                ['expires_at'], unique=False,
            )


def downgrade():
    inspector = sa.inspect(op.get_bind())

    existing = _columns(inspector, 'blacklist_users')
    if existing is not None:
        if 'expires_at' in existing:
            op.drop_index(
                op.f('ix_blacklist_users_expires_at'), table_name='blacklist_users'
            )
            op.drop_column('blacklist_users', 'expires_at')
        if 'source' in existing:
            op.drop_column('blacklist_users', 'source')

    existing = _columns(inspector, 'anomaly_settings')
    if existing is not None:
        for column in ('throttle_min_severity', 'throttle_seconds',
                       'throttle_mbps', 'throttle_enabled'):
            if column in existing:
                op.drop_column('anomaly_settings', column)
