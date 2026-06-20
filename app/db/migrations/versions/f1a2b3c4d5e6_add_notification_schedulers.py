"""add notification_schedulers table for push metrics webhooks

Adds a table that stores configurable push-statistics schedulers. Each row
represents an independent webhook target with its own interval, secret key and
toggles. This change is purely additive and does not touch any existing tables.

Revision ID: f1a2b3c4d5e6
Revises: d2e3f4a5b6c7
Create Date: 2026-06-20 18:30:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'f1a2b3c4d5e6'
down_revision = 'd2e3f4a5b6c7'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if 'notification_schedulers' in inspector.get_table_names():
        return

    op.create_table(
        'notification_schedulers',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('name', sa.String(length=128), nullable=False),
        sa.Column('webhook_url', sa.String(length=1024), nullable=False),
        sa.Column('secret_key', sa.String(length=256), nullable=True),
        sa.Column('interval', sa.Integer(), server_default=sa.text('60'), nullable=False),
        sa.Column('is_enabled', sa.Boolean(), server_default=sa.text('1'), nullable=False),
        sa.Column('include_users', sa.Boolean(), server_default=sa.text('1'), nullable=False),
        sa.Column('last_run_at', sa.DateTime(), nullable=True),
        sa.Column('last_status', sa.String(length=16), nullable=True),
        sa.Column('last_status_code', sa.Integer(), nullable=True),
        sa.Column('last_error', sa.String(length=1024), nullable=True),
        sa.Column('total_runs', sa.BigInteger(), server_default=sa.text('0'), nullable=False),
        sa.Column('failed_runs', sa.BigInteger(), server_default=sa.text('0'), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if 'notification_schedulers' in inspector.get_table_names():
        op.drop_table('notification_schedulers')
