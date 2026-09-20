"""add bandwidth_settings table

Holds the panel-wide cap that every address gets on its own (the "global
limit"). One row, created on first read. Purely additive: a new table nothing
else references, so an older panel keeps working on the same database. Skipped
when the table already exists, so it is safe on panels updated by hand.

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-09-20 12:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'e5f6a7b8c9d0'
down_revision = 'd4e5f6a7b8c9'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if 'bandwidth_settings' in inspector.get_table_names():
        return

    op.create_table(
        'bandwidth_settings',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('global_enabled', sa.Boolean(), server_default=sa.text('0'), nullable=False),
        sa.Column('global_mbps', sa.Integer(), server_default=sa.text('200'), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if 'bandwidth_settings' not in inspector.get_table_names():
        return

    op.drop_table('bandwidth_settings')
