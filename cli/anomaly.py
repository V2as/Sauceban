from typing import Optional, Union

import typer
from rich.console import Console
from rich.table import Table

from app.db import GetDB, crud
from app.db.models import AnomalyScheduler
from app.models.anomaly import (
    AnomalySchedulerCreate,
    AnomalySchedulerModify,
    AnomalySettingsModify,
    AnomalySettingsResponse,
)

from . import utils

app = typer.Typer(no_args_is_help=True)
console = Console()


def _status_icon(scheduler: AnomalyScheduler) -> str:
    if not scheduler.is_enabled:
        return "⏸ disabled"
    if scheduler.last_status == "success":
        return "✔️ ok"
    if scheduler.last_status == "failed":
        return "✖️ failed"
    return "… pending"


@app.command(name="settings")
def show_settings():
    """Shows the traffic-anomaly monitor settings."""
    with GetDB() as db:
        s = crud.get_anomaly_settings(db)

        table = Table(show_header=False)
        table.add_row("Monitoring", "✔️ enabled" if s.is_enabled else "✖️ disabled")
        table.add_row("Sample interval", f"{s.sample_interval}s")
        table.add_row("Window", f"{s.window_seconds}s")
        table.add_row("Max concurrent networks",
                      str(s.max_concurrent_networks) if s.max_concurrent_networks else "off")
        table.add_row("Max networks in window",
                      str(s.max_subnets) if s.max_subnets else "off")
        table.add_row("Max IPs in window", str(s.max_ips) if s.max_ips else "off")
        table.add_row("Sustained samples", str(s.min_hits))
        table.add_row("Traffic gate",
                      f"{s.min_traffic_rate_mbps} Mbps" if s.min_traffic_rate_mbps else "off")
        table.add_row("Traffic spike ratio",
                      f"x{s.traffic_spike_ratio}" if s.traffic_spike_ratio else "off")
        table.add_row("Cooldown", f"{s.cooldown_seconds}s")
        table.add_row("Include IPs in report", "✔️" if s.include_ips else "✖️")
        table.add_row("Max IPs per report", str(s.max_ips_in_report))
        console.print(table)


@app.command(name="configure")
def configure(
    enabled: Optional[bool] = typer.Option(None, "--enabled/--disabled",
                                           help="Turn monitoring on or off"),
    sample_interval: Optional[int] = typer.Option(None, "--sample-interval",
                                                  help="Seconds between snapshots"),
    window: Optional[int] = typer.Option(None, "--window",
                                         help="Sliding window in seconds"),
    max_concurrent_networks: Optional[int] = typer.Option(
        None, "--max-concurrent-networks",
        help="Networks allowed online at the same instant (0 = rule off)"),
    max_subnets: Optional[int] = typer.Option(
        None, "--max-subnets", help="Networks allowed in the window (0 = rule off)"),
    max_ips: Optional[int] = typer.Option(
        None, "--max-ips", help="Source IPs allowed in the window (0 = rule off)"),
    min_hits: Optional[int] = typer.Option(
        None, "--min-hits", help="Consecutive samples a rule must fire on"),
    min_traffic_rate_mbps: Optional[float] = typer.Option(
        None, "--min-rate", help="Only report above this rate in Mbps (0 = off)"),
    traffic_spike_ratio: Optional[float] = typer.Option(
        None, "--spike-ratio", help="Report at this multiple of the user's baseline (0 = off)"),
    cooldown: Optional[int] = typer.Option(None, "--cooldown",
                                           help="Per-user re-report suppression in seconds"),
    include_ips: Optional[bool] = typer.Option(None, "--include-ips/--no-include-ips",
                                               help="Send raw source IPs as evidence"),
):
    """Updates the monitor settings (only the options you pass)."""
    with GetDB() as db:
        try:
            crud.update_anomaly_settings(
                db,
                AnomalySettingsModify(
                    is_enabled=enabled,
                    sample_interval=sample_interval,
                    window_seconds=window,
                    max_concurrent_networks=max_concurrent_networks,
                    max_subnets=max_subnets,
                    max_ips=max_ips,
                    min_hits=min_hits,
                    min_traffic_rate_mbps=min_traffic_rate_mbps,
                    traffic_spike_ratio=traffic_spike_ratio,
                    cooldown_seconds=cooldown,
                    include_ips=include_ips,
                ),
            )
        except Exception as err:
            utils.error(f"Failed to update settings: {err}")
    utils.success("Anomaly monitor settings updated.")
    show_settings()


@app.command(name="enable")
def enable_monitor():
    """Turns anomaly monitoring on."""
    with GetDB() as db:
        crud.update_anomaly_settings(db, AnomalySettingsModify(is_enabled=True))
    utils.success("Anomaly monitoring enabled.")


@app.command(name="disable")
def disable_monitor():
    """Turns anomaly monitoring off (window state is dropped)."""
    with GetDB() as db:
        crud.update_anomaly_settings(db, AnomalySettingsModify(is_enabled=False))
    utils.success("Anomaly monitoring disabled.")


@app.command(name="report")
def report(
    include_suppressed: bool = typer.Option(
        True, "--include-suppressed/--only-new",
        help="Also show findings currently held back by their cooldown"),
):
    """Shows what the monitor sees right now (does not push anything).

    Only meaningful inside the running panel process — a separate CLI process
    has its own empty window state.
    """
    from app.utils.anomaly import monitor

    with GetDB() as db:
        settings = AnomalySettingsResponse.model_validate(crud.get_anomaly_settings(db))

    findings = monitor.evaluate(settings, mutate=False)
    if not include_suppressed:
        findings = [f for f in findings if not f.suppressed]

    status = monitor.status()
    console.print(
        f"[bold]monitoring:[/bold] {'on' if settings.is_enabled else 'off'}  "
        f"[bold]ip source:[/bold] {status['ip_source']}  "
        f"[bold]tracked:[/bold] {status['tracked_users']}  "
        f"[bold]online:[/bold] {status['users_online']}"
    )
    for warning in status["warnings"]:
        console.print(f"[yellow]warning:[/yellow] {warning}")

    utils.print_table(
        table=Table("User", "Severity", "Score", "IPs", "Networks",
                    "Peak now", "Mbps", "Rules", "Held"),
        rows=[
            (
                f.username,
                f.severity,
                str(f.score),
                str(f.distinct_ips),
                str(f.distinct_subnets),
                str(f.peak_concurrent_networks),
                f"{f.traffic_rate_bytes_per_sec * 8 / 1_000_000:.1f}",
                ", ".join(r.rule for r in f.reasons),
                "✔️" if f.suppressed else "",
            )
            for f in findings
        ],
    )


@app.command(name="list")
def list_schedulers():
    """Displays a table of anomaly webhook targets."""
    with GetDB() as db:
        schedulers = crud.get_anomaly_schedulers(db)
        utils.print_table(
            table=Table(
                "ID", "Name", "Webhook", "Min severity", "Spacing", "Empty",
                "Secret", "Status", "Runs", "Failed", "Sent", "Last run"
            ),
            rows=[
                (
                    str(s.id),
                    str(s.name),
                    (s.webhook_url[:40] + "…") if len(s.webhook_url) > 41 else s.webhook_url,
                    str(s.min_severity),
                    f"{s.interval}s",
                    "✔️" if s.send_empty else "✖️",
                    "✔️" if s.secret_key else "✖️",
                    _status_icon(s),
                    str(s.total_runs or 0),
                    str(s.failed_runs or 0),
                    str(s.total_anomalies_sent or 0),
                    utils.readable_datetime(s.last_run_at),
                )
                for s in schedulers
            ],
        )


@app.command(name="show")
def show_scheduler(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Show full details (including status) of a single webhook target."""
    with GetDB() as db:
        s: Union[AnomalyScheduler, None] = crud.get_anomaly_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no anomaly scheduler with id {scheduler_id}!")

        table = Table(show_header=False)
        table.add_row("ID", str(s.id))
        table.add_row("Name", str(s.name))
        table.add_row("Webhook URL", str(s.webhook_url))
        table.add_row("Secret key", "***set***" if s.secret_key else "-")
        table.add_row("Min severity", str(s.min_severity))
        table.add_row("Min spacing", f"{s.interval}s")
        table.add_row("Enabled", "✔️" if s.is_enabled else "✖️")
        table.add_row("Send empty reports", "✔️" if s.send_empty else "✖️")
        table.add_row("Last status", str(s.last_status or "-"))
        table.add_row("Last status code", str(s.last_status_code or "-"))
        table.add_row("Last error", str(s.last_error or "-"))
        table.add_row("Total runs", str(s.total_runs or 0))
        table.add_row("Failed runs", str(s.failed_runs or 0))
        table.add_row("Anomalies sent", str(s.total_anomalies_sent or 0))
        table.add_row("Last run at", utils.readable_datetime(s.last_run_at))
        table.add_row("Created at", utils.readable_datetime(s.created_at))
        console.print(table)


@app.command(name="create")
def create_scheduler(
    name: str = typer.Option(..., "--name", "-n", prompt=True),
    webhook_url: str = typer.Option(..., "--webhook-url", "-w", prompt="Webhook URL"),
    interval: int = typer.Option(60, "--interval", "-i",
                                 help="Minimum seconds between pushes to this target"),
    secret_key: str = typer.Option("", "--secret", "-s", help="Webhook secret key"),
    min_severity: str = typer.Option("low", "--min-severity",
                                     help="low | medium | high | critical"),
    send_empty: bool = typer.Option(False, "--send-empty/--no-send-empty",
                                    help="Push heartbeats when nothing was found"),
    enabled: bool = typer.Option(True, "--enabled/--disabled"),
):
    """Creates an anomaly webhook target."""
    with GetDB() as db:
        try:
            scheduler = crud.create_anomaly_scheduler(
                db,
                AnomalySchedulerCreate(
                    name=name,
                    webhook_url=webhook_url,
                    secret_key=secret_key or None,
                    interval=interval,
                    is_enabled=enabled,
                    min_severity=min_severity,
                    send_empty=send_empty,
                ),
            )
        except Exception as err:
            utils.error(f"Failed to create scheduler: {err}")
        utils.success(f'Anomaly webhook "{name}" created successfully with id {scheduler.id}.')


@app.command(name="update")
def update_scheduler(
    scheduler_id: int = typer.Argument(..., help="Scheduler ID"),
    name: Optional[str] = typer.Option(None, "--name", "-n"),
    webhook_url: Optional[str] = typer.Option(None, "--webhook-url", "-w"),
    interval: Optional[int] = typer.Option(None, "--interval", "-i"),
    secret_key: Optional[str] = typer.Option(None, "--secret", "-s",
                                             help="Set secret key (use '0' to clear)"),
    min_severity: Optional[str] = typer.Option(None, "--min-severity"),
    send_empty: Optional[bool] = typer.Option(None, "--send-empty/--no-send-empty"),
    enabled: Optional[bool] = typer.Option(None, "--enabled/--disabled"),
):
    """Updates the specified webhook target."""
    with GetDB() as db:
        s = crud.get_anomaly_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no anomaly scheduler with id {scheduler_id}!")

        if secret_key == "0":
            secret_key = ""

        try:
            crud.update_anomaly_scheduler(
                db, s,
                AnomalySchedulerModify(
                    name=name,
                    webhook_url=webhook_url,
                    interval=interval,
                    secret_key=secret_key,
                    min_severity=min_severity,
                    send_empty=send_empty,
                    is_enabled=enabled,
                ),
            )
        except Exception as err:
            utils.error(f"Failed to update scheduler: {err}")
        utils.success(f"Anomaly webhook {scheduler_id} updated successfully.")


@app.command(name="delete")
def delete_scheduler(
    scheduler_id: int = typer.Argument(..., help="Scheduler ID"),
    yes_to_all: bool = typer.Option(False, *utils.FLAGS["yes_to_all"],
                                    help="Skips confirmations"),
):
    """Deletes the specified webhook target."""
    with GetDB() as db:
        s = crud.get_anomaly_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no anomaly scheduler with id {scheduler_id}!")

        if yes_to_all or typer.confirm(
            f'Are you sure about deleting anomaly webhook "{s.name}" (#{scheduler_id})?',
            default=False,
        ):
            crud.delete_anomaly_scheduler(db, s)
            utils.success(f"Anomaly webhook {scheduler_id} deleted successfully.")
        else:
            utils.error("Operation aborted!")


@app.command(name="send-now")
def send_now(scheduler_id: int = typer.Argument(..., help="Scheduler ID")):
    """Pushes the current report to the target immediately (test run).

    Run from a separate process this delivers an empty report — the sliding
    window lives in the panel process. Use it to verify the endpoint, the
    secret and the signature.
    """
    from app.jobs.detect_anomalies import deliver_report
    from app.utils.anomaly import monitor

    with GetDB() as db:
        s = crud.get_anomaly_scheduler(db, scheduler_id)
        if not s:
            utils.error(f"There's no anomaly scheduler with id {scheduler_id}!")

        settings = AnomalySettingsResponse.model_validate(crud.get_anomaly_settings(db))
        findings = monitor.evaluate(settings, mutate=False)
        success, status_code, error = deliver_report(s, settings, findings)

    if success:
        utils.success(
            f"Report delivered successfully (HTTP {status_code}), "
            f"{len(findings)} anomalies."
        )
    else:
        utils.error(f"Push failed (HTTP {status_code}): {error}")
