from typing import List

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import PlainTextResponse

from app.db import Session, crud, get_db
from app.models.admin import Admin
from app.models.notification_scheduler import (
    NotificationSchedulerCreate,
    NotificationSchedulerModify,
    NotificationSchedulerResponse,
)
from app.models.notification_scheduler import PushMetricsPayload
from app.utils import responses
from app.utils.metrics import collect_metrics, render_prometheus_text

router = APIRouter(
    tags=["Notification Schedulers"],
    prefix="/api/notification",
    responses={401: responses._401, 403: responses._403},
)


def _trigger_sync() -> None:
    """Ask the push-metrics manager to reconcile jobs immediately."""
    try:
        from app.jobs.send_push_metrics import request_sync
        request_sync()
    except Exception:
        # the periodic reconciler will pick the change up on its next tick
        pass


@router.get("/schedulers", response_model=List[NotificationSchedulerResponse])
def get_notification_schedulers(
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """List all push-statistics schedulers with their current status."""
    return crud.get_notification_schedulers(db)


@router.post("/schedulers", response_model=NotificationSchedulerResponse)
def create_notification_scheduler(
    new_scheduler: NotificationSchedulerCreate,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Create a new push-statistics scheduler (webhook target)."""
    dbscheduler = crud.create_notification_scheduler(db, new_scheduler)
    _trigger_sync()
    return dbscheduler


@router.get(
    "/schedulers/{scheduler_id}",
    response_model=NotificationSchedulerResponse,
    responses={404: responses._404},
)
def get_notification_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Get a single scheduler by id."""
    dbscheduler = crud.get_notification_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    return dbscheduler


@router.put(
    "/schedulers/{scheduler_id}",
    response_model=NotificationSchedulerResponse,
    responses={404: responses._404},
)
def modify_notification_scheduler(
    scheduler_id: int,
    modified_scheduler: NotificationSchedulerModify,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Modify a scheduler (enable/disable, change interval, secret, etc.)."""
    dbscheduler = crud.get_notification_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    dbscheduler = crud.update_notification_scheduler(db, dbscheduler, modified_scheduler)
    _trigger_sync()
    return dbscheduler


@router.delete("/schedulers/{scheduler_id}", responses={404: responses._404})
def delete_notification_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Delete a scheduler."""
    dbscheduler = crud.get_notification_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    crud.delete_notification_scheduler(db, dbscheduler)
    _trigger_sync()
    return {"detail": "Scheduler successfully deleted"}


@router.post(
    "/schedulers/{scheduler_id}/trigger",
    responses={404: responses._404},
)
def trigger_notification_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Immediately collect metrics and push them for this scheduler (test/run-now)."""
    dbscheduler = crud.get_notification_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")

    from app.jobs.send_push_metrics import deliver

    payload = collect_metrics(
        include_users=dbscheduler.include_users,
        scheduler_id=dbscheduler.id,
        scheduler_name=dbscheduler.name,
        use_cache=False,
    )
    success, status_code, error = deliver(
        dbscheduler.webhook_url, dbscheduler.secret_key, payload
    )
    crud.record_notification_scheduler_run(db, scheduler_id, success, status_code, error)
    return {
        "success": success,
        "status_code": status_code,
        "error": error,
    }


@router.get("/metrics/preview", response_model=PushMetricsPayload)
def preview_metrics_payload(
    include_users: bool = True,
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Preview the exact JSON payload that would be pushed to a webhook."""
    return collect_metrics(include_users=include_users, use_cache=False)
