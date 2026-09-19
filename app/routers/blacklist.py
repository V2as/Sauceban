from typing import Optional

from fastapi import APIRouter, Depends, HTTPException

from app.db import Session, crud, get_db
from app.db.models import BlacklistUser
from app.jobs.sync_blacklist import request_sync, shaped_ips, status
from app.models.admin import Admin
from app.models.blacklist import (BlacklistEntryCreate, BlacklistEntryModify,
                                  BlacklistEntryResponse, BlacklistResponse,
                                  BlacklistStatus)
from app.utils import responses
from app.utils.shaper import shaper

router = APIRouter(
    tags=["Bandwidth Blacklist"],
    prefix="/api/blacklist",
    responses={401: responses._401, 403: responses._403},
)


def _response(
    entry: BlacklistUser,
    ips: Optional[dict] = None,
    traffic: Optional[dict] = None,
) -> BlacklistEntryResponse:
    """One entry plus whatever the shaper knows about it right now."""
    ips = shaped_ips() if ips is None else ips
    traffic = shaper.traffic() if traffic is None else traffic
    counters = traffic.get(entry.user_id, {})
    return BlacklistEntryResponse(
        id=entry.id,
        user_id=entry.user_id,
        username=entry.user.username,
        limit_mbps=entry.limit_mbps,
        is_enabled=entry.is_enabled,
        reason=entry.reason,
        source=entry.source,
        expires_at=entry.expires_at,
        created_at=entry.created_at,
        updated_at=entry.updated_at,
        active_ips=ips.get(entry.user_id, []),
        shaped_bytes=counters.get("sent_bytes", 0),
        dropped_packets=counters.get("drops", 0),
    )


def _get_entry(db: Session, username: str) -> BlacklistUser:
    dbuser = crud.get_user(db, username)
    if not dbuser:
        raise HTTPException(status_code=404, detail="User not found")
    entry = crud.get_blacklist_entry(db, dbuser.id)
    if not entry:
        raise HTTPException(status_code=404, detail="User is not blacklisted")
    return entry


@router.get("", response_model=BlacklistResponse)
def get_blacklist(
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """The blacklist with the live state of its enforcement.

    `status` tells whether the caps are really applied: `available` false
    means the entries are bookkeeping only, and `unavailable_reason` says why.
    """
    entries = crud.get_blacklist_entries(db)
    ips, traffic = shaped_ips(), shaper.traffic()
    info = status()
    info["entries_total"] = len(entries)
    return BlacklistResponse(
        entries=[_response(entry, ips, traffic) for entry in entries],
        status=BlacklistStatus(**info),
    )


@router.get("/status", response_model=BlacklistStatus)
def get_blacklist_status(
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Enforcement state on its own, for polling without the whole list."""
    info = status()
    info["entries_total"] = len(crud.get_blacklist_entries(db))
    return BlacklistStatus(**info)


@router.post(
    "",
    response_model=BlacklistEntryResponse,
    responses={404: responses._404, 409: responses._409},
)
def add_to_blacklist(
    new_entry: BlacklistEntryCreate,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Cap a user's bandwidth at `limit_mbps` megabits per second.

    The cap applies to each direction separately and takes effect within one
    sync interval, as soon as the core reports where the user connects from.
    """
    dbuser = crud.get_user(db, new_entry.username)
    if not dbuser:
        raise HTTPException(status_code=404, detail="User not found")
    if crud.get_blacklist_entry(db, dbuser.id):
        raise HTTPException(status_code=409, detail="User is already blacklisted")

    entry = crud.create_blacklist_entry(
        db, dbuser,
        limit_mbps=new_entry.limit_mbps,
        is_enabled=new_entry.is_enabled,
        reason=new_entry.reason,
    )
    request_sync()
    return _response(entry)


@router.get(
    "/{username}",
    response_model=BlacklistEntryResponse,
    responses={404: responses._404},
)
def get_blacklist_entry(
    username: str,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """The cap of a single user."""
    return _response(_get_entry(db, username))


@router.put(
    "/{username}",
    response_model=BlacklistEntryResponse,
    responses={404: responses._404},
)
def modify_blacklist_entry(
    username: str,
    modified_entry: BlacklistEntryModify,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Change the cap, suspend it (`is_enabled`) or edit the reason."""
    entry = crud.update_blacklist_entry(db, _get_entry(db, username), modified_entry)
    request_sync()
    return _response(entry)


@router.delete("/{username}", responses={404: responses._404})
def remove_from_blacklist(
    username: str,
    db: Session = Depends(get_db),
    admin: Admin = Depends(Admin.check_sudo_admin),
):
    """Lift the cap and drop the user from the blacklist."""
    crud.remove_blacklist_entry(db, _get_entry(db, username))
    request_sync()
    return {"detail": "User removed from the blacklist"}
