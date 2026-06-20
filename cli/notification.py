from typing import Optional, Union

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from app.db import GetDB, crud
from app.db.models import NotificationScheduler
from app.models.notification_scheduler import (
    NotificationSchedulerCreate,
    NotificationSchedulerModify,
)

from . import utils

app = typer.Typer(no_args_is_help=True)


def _status_icon(scheduler: NotificationScheduler) -> str:
    if not scheduler.is_enabled:
        return "⏸ disabled"
    if scheduler.last_status == "success":
        return "✔️ ok"
    if scheduler.last_status == "failed":
        return "✖️ failed"
    return "… pending"


@app.command(name="list")
def list_schedulers():
    """Displays a table of push-statistics schedulers."""
    with GetDB() as db:
        schedulers = crud.get_notification_schedulers(db)
        utils.print_table(
            table=Table(
                "ID", "Name", "Webhook", "Interval", "Users", "Secret",
                "Status", "Runs", "Failed", "Last run"
            ),
            rows=[
                (
                    str(s.id),
                    str(s.name),
                    (s.webhook_url[:40] + "…") if len(s.webhook_url) > 41 else s.webhook_url,
                    f"{s.interval}s",
                    "✔️" if s.include_users else "✖️",
                    "✔️" if s.secret_key else "✖️",
                    _status_icon(s),
                    str(s.total_runs or 0),
                    str(s.failed_runs or 0),
                    utils.readable_datetime(s.last_run_at),
                )
                for s in schedulers
            ],
        )


@app.command(name="show")
def show_scheduler(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Show full details (including status) of a single scheduler."""
    with GetDB() as db:
        s: Union[NotificationScheduler, None] = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")

        table = Table(show_header=False)
        table.add_row("ID", str(s.id))
        table.add_row("Name", str(s.name))
        table.add_row("Webhook URL", str(s.webhook_url))
        table.add_row("Secret key", "***set***" if s.secret_key else "-")
        table.add_row("Interval", f"{s.interval}s")
        table.add_row("Enabled", "✔️" if s.is_enabled else "✖️")
        table.add_row("Include users", "✔️" if s.include_users else "✖️")
        table.add_row("Last status", str(s.last_status or "-"))
        table.add_row("Last status code", str(s.last_status_code or "-"))
        table.add_row("Last error", str(s.last_error or "-"))
        table.add_row("Total runs", str(s.total_runs or 0))
        table.add_row("Failed runs", str(s.failed_runs or 0))
        table.add_row("Last run at", utils.readable_datetime(s.last_run_at))
        table.add_row("Created at", utils.readable_datetime(s.created_at))
        Console().print(table)


@app.command(name="create")
def create_scheduler(
    name: str = typer.Option(..., "--name", "-n", prompt=True),
    webhook_url: str = typer.Option(..., "--webhook-url", "-w", prompt="Webhook URL"),
    interval: int = typer.Option(60, "--interval", "-i", help="Send interval in seconds"),
    secret_key: str = typer.Option("", "--secret", "-s", help="Webhook secret key"),
    include_users: bool = typer.Option(True, "--include-users/--no-include-users"),
    enabled: bool = typer.Option(True, "--enabled/--disabled"),
):
    """Creates a push-statistics scheduler."""
    with GetDB() as db:
        try:
            scheduler = crud.create_notification_scheduler(
                db,
                NotificationSchedulerCreate(
                    name=name,
                    webhook_url=webhook_url,
                    secret_key=secret_key or None,
                    interval=interval,
                    is_enabled=enabled,
                    include_users=include_users,
                ),
            )
        except Exception as err:
            utils.error(f"Failed to create scheduler: {err}")
        utils.success(f'Scheduler "{name}" created successfully with id {scheduler.id}.')


@app.command(name="update")
def update_scheduler(
    scheduler_id: int = typer.Argument(..., help="Scheduler ID"),
    name: Optional[str] = typer.Option(None, "--name", "-n"),
    webhook_url: Optional[str] = typer.Option(None, "--webhook-url", "-w"),
    interval: Optional[int] = typer.Option(None, "--interval", "-i"),
    secret_key: Optional[str] = typer.Option(None, "--secret", "-s",
                                             help="Set secret key (use '0' to clear)"),
    include_users: Optional[bool] = typer.Option(None, "--include-users/--no-include-users"),
    enabled: Optional[bool] = typer.Option(None, "--enabled/--disabled"),
):
    """Updates the specified scheduler."""
    with GetDB() as db:
        s = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")

        if secret_key == "0":
            secret_key = ""

        try:
            crud.update_notification_scheduler(
                db, s,
                NotificationSchedulerModify(
                    name=name,
                    webhook_url=webhook_url,
                    interval=interval,
                    secret_key=secret_key,
                    include_users=include_users,
                    is_enabled=enabled,
                ),
            )
        except Exception as err:
            utils.error(f"Failed to update scheduler: {err}")
        utils.success(f"Scheduler {scheduler_id} updated successfully.")


@app.command(name="enable")
def enable_scheduler(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Enables the specified scheduler."""
    with GetDB() as db:
        s = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")
        crud.update_notification_scheduler(db, s, NotificationSchedulerModify(is_enabled=True))
        utils.success(f"Scheduler {scheduler_id} enabled.")


@app.command(name="disable")
def disable_scheduler(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Disables the specified scheduler."""
    with GetDB() as db:
        s = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")
        crud.update_notification_scheduler(db, s, NotificationSchedulerModify(is_enabled=False))
        utils.success(f"Scheduler {scheduler_id} disabled.")


@app.command(name="delete")
def delete_scheduler(
    scheduler_id: int = typer.Argument(..., help="Scheduler ID"),
    yes_to_all: bool = typer.Option(False, *utils.FLAGS["yes_to_all"], help="Skips confirmations"),
):
    """Deletes the specified scheduler."""
    with GetDB() as db:
        s = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")

        if yes_to_all or typer.confirm(f'Are you sure about deleting scheduler "{s.name}" (#{scheduler_id})?', default=False):
            crud.delete_notification_scheduler(db, s)
            utils.success(f"Scheduler {scheduler_id} deleted successfully.")
        else:
            utils.error("Operation aborted!")


@app.command(name="send-now")
def send_now(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Collects metrics and pushes them immediately for the scheduler (test run)."""
    from app.jobs.send_push_metrics import deliver
    from app.utils.metrics import collect_metrics

    with GetDB() as db:
        s = crud.get_notification_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no scheduler with id {scheduler_id}!")

        payload = collect_metrics(
            include_users=s.include_users,
            scheduler_id=s.id,
            scheduler_name=s.name,
            use_cache=False,
        )
        success, status_code, error = deliver(s.webhook_url, s.secret_key, payload)
        crud.record_notification_scheduler_run(db, scheduler_id, success, status_code, error)

    if success:
        utils.success(f"Push delivered successfully (HTTP {status_code}).")
    else:
        utils.error(f"Push failed (HTTP {status_code}): {error}")
