import time
from typing import List

from fastapi import APIRouter, Depends, HTTPException

from app.db import Session, crud, get_db
from app.models.admin import Admin
from app.models.anomaly import (AnomalyReport, AnomalySchedulerCreate,
                                AnomalySchedulerModify,
                                AnomalySchedulerResponse,
                                AnomalySettingsModify,
                                AnomalySettingsResponse, AnomalyUserActivity)
from app.utils import responses
from app.utils.anomaly import monitor

router = APIRouter(
    tags=["Traffic Anomaly Monitor"],
    prefix="/api/anomaly",
    responses={401: responses._401, 403: responses._403},
)


def _trigger_sync() -> None:
    """Ask the anomaly monitor manager to reconcile its job immediately."""
    try:
        from app.jobs.detect_anomalies import request_sync
        request_sync()
    except Exception:
        # the periodic reconciler will pick the change up on its next tick
        pass


def _report(db: Session, include_suppressed: bool = True) -> AnomalyReport:
    from app.jobs.detect_anomalies import build_report

    started = time.perf_counter()
    settings = AnomalySettingsResponse.model_validate(crud.get_anomaly_settings(db))
    findings = monitor.evaluate(settings, mutate=False)
    if not include_suppressed:
        findings = [f for f in findings if not f.suppressed]
    return build_report(
        settings, findings,
        collected_in_ms=round((time.perf_counter() - started) * 1000, 2),
    )


@router.get("/settings", response_model=AnomalySettingsResponse)
def get_anomaly_settings(
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Get the traffic-anomaly monitor settings (thresholds + master switch)."""
    return crud.get_anomaly_settings(db)


@router.put("/settings", response_model=AnomalySettingsResponse)
def modify_anomaly_settings(
    modified_settings: AnomalySettingsModify,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Turn monitoring on/off and tune the detection thresholds at runtime."""
    dbsettings = crud.update_anomaly_settings(db, modified_settings)
    _trigger_sync()
    return dbsettings


@router.get("/schedulers", response_model=List[AnomalySchedulerResponse])
def get_anomaly_schedulers(
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """List all anomaly webhook targets with their current status."""
    return crud.get_anomaly_schedulers(db)


@router.post("/schedulers", response_model=AnomalySchedulerResponse)
def create_anomaly_scheduler(
    new_scheduler: AnomalySchedulerCreate,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Create a new anomaly webhook target."""
    dbscheduler = crud.create_anomaly_scheduler(db, new_scheduler)
    _trigger_sync()
    return dbscheduler


@router.get(
    "/schedulers/{scheduler_id}",
    response_model=AnomalySchedulerResponse,
    responses={404: responses._404},
)
def get_anomaly_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Get a single anomaly webhook target by id."""
    dbscheduler = crud.get_anomaly_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    return dbscheduler


@router.put(
    "/schedulers/{scheduler_id}",
    response_model=AnomalySchedulerResponse,
    responses={404: responses._404},
)
def modify_anomaly_scheduler(
    scheduler_id: int,
    modified_scheduler: AnomalySchedulerModify,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Modify an anomaly webhook target (enable/disable, severity, secret...)."""
    dbscheduler = crud.get_anomaly_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    dbscheduler = crud.update_anomaly_scheduler(db, dbscheduler, modified_scheduler)
    _trigger_sync()
    return dbscheduler


@router.delete("/schedulers/{scheduler_id}", responses={404: responses._404})
def delete_anomaly_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Delete an anomaly webhook target."""
    dbscheduler = crud.get_anomaly_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")
    crud.delete_anomaly_scheduler(db, dbscheduler)
    _trigger_sync()
    return {"detail": "Scheduler successfully deleted"}


@router.post(
    "/schedulers/{scheduler_id}/trigger",
    responses={404: responses._404},
)
def trigger_anomaly_scheduler(
    scheduler_id: int,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Push the current anomaly report to this target right now (test/run-now).

    Sends whatever the monitor currently sees, ignoring `is_enabled`, the
    per-target `min_severity` and the push spacing.
    """
    dbscheduler = crud.get_anomaly_scheduler(db, scheduler_id)
    if not dbscheduler:
        raise HTTPException(status_code=404, detail="Scheduler not found")

    from app.jobs.detect_anomalies import deliver_report

    settings = AnomalySettingsResponse.model_validate(crud.get_anomaly_settings(db))
    findings = monitor.evaluate(settings, mutate=False)
    success, status_code, error = deliver_report(dbscheduler, settings, findings)
    return {
        "success": success,
        "status_code": status_code,
        "error": error,
        "anomalies_sent": len(findings),
    }


@router.get("/report", response_model=AnomalyReport)
def get_anomaly_report(
    include_suppressed: bool = True,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """The report as it looks right now, without pushing it anywhere.

    Read-only: sustained-hit counters and per-user cooldowns are left alone,
    so polling this endpoint cannot affect what the webhooks receive.
    """
    return _report(db, include_suppressed=include_suppressed)


@router.get(
    "/users/{username}/activity",
    response_model=AnomalyUserActivity,
    responses={404: responses._404},
)
def get_user_anomaly_activity(
    username: str,
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Live window state for one user: current source IPs, nodes, throughput."""
    state = monitor.user_state(username)
    if state is None:
        raise HTTPException(
            status_code=404,
            detail="No sampled activity for this user (offline, or monitoring is off)",
        )
    return state
