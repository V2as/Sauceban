"""add anomaly_settings and anomaly_schedulers tables

Adds the traffic-anomaly monitor: one settings row (thresholds + master
switch) and N independent webhook targets that receive anomaly reports. Purely
additive; no existing table is touched. Both steps are skipped when the table
already exists, so the migration is safe to run on panels that were updated
by hand.

Revision ID: b7c8d9e0f1a2
Revises: f1a2b3c4d5e6
Create Date: 2026-09-06 12:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b7c8d9e0f1a2'
down_revision = 'f1a2b3c4d5e6'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    tables = inspector.get_table_names()

    if 'anomaly_settings' not in tables:
        op.create_table(
            'anomaly_settings',
            sa.Column('id', sa.Integer(), nullable=False),
            sa.Column('is_enabled', sa.Boolean(), server_default=sa.text('0'), nullable=False),
            sa.Column('sample_interval', sa.Integer(), server_default=sa.text('30'), nullable=False),
            sa.Column('window_seconds', sa.Integer(), server_default=sa.text('300'), nullable=False),
            sa.Column('max_ips', sa.Integer(), server_default=sa.text('6'), nullable=False),
            sa.Column('max_subnets', sa.Integer(), server_default=sa.text('3'), nullable=False),
            sa.Column('max_concurrent_networks', sa.Integer(), server_default=sa.text('2'), nullable=False),
            sa.Column('min_hits', sa.Integer(), server_default=sa.text('2'), nullable=False),
            sa.Column('min_traffic_rate_mbps', sa.Float(), server_default=sa.text('0'), nullable=False),
            sa.Column('traffic_spike_ratio', sa.Float(), server_default=sa.text('0'), nullable=False),
            sa.Column('cooldown_seconds', sa.Integer(), server_default=sa.text('900'), nullable=False),
            sa.Column('include_ips', sa.Boolean(), server_default=sa.text('1'), nullable=False),
            sa.Column('max_ips_in_report', sa.Integer(), server_default=sa.text('20'), nullable=False),
            sa.Column('created_at', sa.DateTime(), nullable=True),
            sa.Column('updated_at', sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint('id'),
        )

    if 'anomaly_schedulers' not in tables:
        op.create_table(
            'anomaly_schedulers',
            sa.Column('id', sa.Integer(), nullable=False),
            sa.Column('name', sa.String(length=128), nullable=False),
            sa.Column('webhook_url', sa.String(length=1024), nullable=False),
            sa.Column('secret_key', sa.String(length=256), nullable=True),
            sa.Column('interval', sa.Integer(), server_default=sa.text('60'), nullable=False),
            sa.Column('is_enabled', sa.Boolean(), server_default=sa.text('1'), nullable=False),
            sa.Column('min_severity', sa.String(length=16), server_default='low', nullable=False),
            sa.Column('send_empty', sa.Boolean(), server_default=sa.text('0'), nullable=False),
            sa.Column('last_run_at', sa.DateTime(), nullable=True),
            sa.Column('last_status', sa.String(length=16), nullable=True),
            sa.Column('last_status_code', sa.Integer(), nullable=True),
            sa.Column('last_error', sa.String(length=1024), nullable=True),
            sa.Column('total_runs', sa.BigInteger(), server_default=sa.text('0'), nullable=False),
            sa.Column('failed_runs', sa.BigInteger(), server_default=sa.text('0'), nullable=False),
            sa.Column('total_anomalies_sent', sa.BigInteger(), server_default=sa.text('0'), nullable=False),
            sa.Column('created_at', sa.DateTime(), nullable=True),
            sa.Column('updated_at', sa.DateTime(), nullable=True),
            sa.PrimaryKeyConstraint('id'),
        )


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    tables = inspector.get_table_names()

    if 'anomaly_schedulers' in tables:
        op.drop_table('anomaly_schedulers')
    if 'anomaly_settings' in tables:
        op.drop_table('anomaly_settings')
