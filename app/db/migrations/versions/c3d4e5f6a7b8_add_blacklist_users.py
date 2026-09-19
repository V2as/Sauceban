"""add blacklist_users table

Per-user bandwidth caps ("blacklist" in the dashboard). Purely additive: a new
table with a FK to `users`, no existing table is touched, so an older panel
keeps working on the same database. Skipped when the table already exists, so
it is safe on panels that were updated by hand.

Revision ID: c3d4e5f6a7b8
Revises: b7c8d9e0f1a2
Create Date: 2026-09-19 15:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'c3d4e5f6a7b8'
down_revision = 'b7c8d9e0f1a2'
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if 'blacklist_users' in inspector.get_table_names():
        return

    op.create_table(
        'blacklist_users',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('user_id', sa.Integer(), nullable=False),
        sa.Column('limit_mbps', sa.Integer(), nullable=False),
        sa.Column('is_enabled', sa.Boolean(), server_default=sa.text('1'), nullable=False),
        sa.Column('reason', sa.String(length=500), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=True),
        sa.Column('updated_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_blacklist_users_user_id'), 'blacklist_users', ['user_id'], unique=True
    )


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    if 'blacklist_users' not in inspector.get_table_names():
        return

    op.drop_index(op.f('ix_blacklist_users_user_id'), table_name='blacklist_users')
    op.drop_table('blacklist_users')
