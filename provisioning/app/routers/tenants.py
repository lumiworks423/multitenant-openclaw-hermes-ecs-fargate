"""Tenant (slot) assignment and management endpoints."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db
from app.auth import get_current_user, require_admin
from app.config import CLOUDFRONT_DOMAIN

router = APIRouter(prefix="/api", tags=["tenants"])


class SlotInfo(BaseModel):
    slot_id: str
    status: str
    gateway_token: str = ""
    access_url: str = ""
    openwebui_url: str = ""
    assigned_username: str = ""


class AssignResponse(BaseModel):
    slot_id: str
    access_url: str
    openwebui_url: str
    gateway_token: str


# ── User endpoints ──

@router.get("/me")
def get_me(user: dict = Depends(get_current_user)):
    slot_id = user.get("slot_id", "")
    slot = db.get_slot(slot_id) if slot_id else None
    return {
        "username": user["username"],
        "role": user.get("role", "user"),
        "slot_id": slot_id,
        "instance": _format_slot(slot) if slot else None,
    }


@router.post("/assign", response_model=AssignResponse)
def assign_instance(user: dict = Depends(get_current_user)):
    # Check if user already has a slot
    if user.get("slot_id"):
        slot = db.get_slot(user["slot_id"])
        if slot:
            return AssignResponse(
                slot_id=slot["slot_id"],
                access_url=_build_openclaw_url(slot),
                openwebui_url=_build_openwebui_url(slot),
                gateway_token=slot.get("gateway_token", ""),
            )

    # Find and assign an available slot
    slot = db.find_available_slot()
    if not slot:
        raise HTTPException(status_code=503, detail="No available instances. Please try again later.")

    success = db.assign_slot(slot["slot_id"], user["username"])
    if not success:
        raise HTTPException(status_code=503, detail="Assignment race condition. Please retry.")

    # Update user record
    db.update_user(user["username"], {"slot_id": slot["slot_id"]})

    return AssignResponse(
        slot_id=slot["slot_id"],
        access_url=_build_openclaw_url(slot),
        openwebui_url=_build_openwebui_url(slot),
        gateway_token=slot.get("gateway_token", ""),
    )


# ── Admin endpoints ──

@router.get("/tenants", response_model=list[SlotInfo])
def list_all_slots(admin: dict = Depends(require_admin)):
    slots = db.list_slots()
    return [_format_slot(s) for s in slots]


class BatchCreateRequest(BaseModel):
    count: int = 1
    username_prefix: str = "user"


class BatchCreateResponse(BaseModel):
    created: list[dict]


@router.post("/tenants/batch", response_model=BatchCreateResponse)
def batch_create(req: BatchCreateRequest, admin: dict = Depends(require_admin)):
    """Admin: batch create users and assign slots.
    Each call creates NEW users starting from the next available number.
    e.g. if user-01 to user-06 exist, next batch creates user-07, user-08, ...
    """
    import re
    import secrets
    from app.auth import hash_password

    # Find the highest existing number for this prefix
    all_users = db.list_users()
    max_num = 0
    pattern = re.compile(rf"^{re.escape(req.username_prefix)}-(\d+)$")
    for u in all_users:
        m = pattern.match(u["username"])
        if m:
            max_num = max(max_num, int(m.group(1)))

    created = []
    for i in range(max_num + 1, max_num + 1 + req.count):
        username = f"{req.username_prefix}-{i:02d}"
        password = secrets.token_hex(8)

        # Create user
        hashed = hash_password(password)
        db.create_user(username, hashed, role="user")

        # Assign slot
        slot = db.find_available_slot()
        if slot and db.assign_slot(slot["slot_id"], username):
            db.update_user(username, {"slot_id": slot["slot_id"]})
            created.append({
                "username": username,
                "password": password,
                "slot_id": slot["slot_id"],
                "access_url": _build_openclaw_url(slot),
                "openwebui_url": _build_openwebui_url(slot),
                "gateway_token": slot.get("gateway_token", ""),
            })
        else:
            created.append({
                "username": username,
                "password": password,
                "slot_id": "",
                "access_url": "",
                "openwebui_url": "",
                "gateway_token": "",
                "error": "No available slots",
            })

    return BatchCreateResponse(created=created)


@router.get("/tenants/users")
def list_all_users(admin: dict = Depends(require_admin)):
    users = db.list_users()
    result = []
    for u in users:
        slot = db.get_slot(u.get("slot_id", "")) if u.get("slot_id") else None
        result.append({
            "username": u["username"],
            "role": u.get("role", "user"),
            "slot_id": u.get("slot_id", ""),
            "access_url": _build_openclaw_url(slot) if slot else "",
            "openwebui_url": _build_openwebui_url(slot) if slot else "",
            "created_at": u.get("created_at", ""),
        })
    return result


# ── Helpers ──

def _build_openclaw_url(slot: dict | None) -> str:
    if not slot:
        return ""
    token = slot.get("gateway_token", "")
    slot_id = slot["slot_id"]
    return f"https://{CLOUDFRONT_DOMAIN}/i/{slot_id}/?token={token}"


def _build_openwebui_url(slot: dict | None) -> str:
    if not slot:
        return ""
    slot_id = slot["slot_id"]
    return f"https://{CLOUDFRONT_DOMAIN}/h/{slot_id}/"


def _format_slot(slot: dict | None) -> SlotInfo:
    if not slot:
        return SlotInfo(slot_id="", status="unknown")
    return SlotInfo(
        slot_id=slot["slot_id"],
        status=slot.get("status", "unknown"),
        gateway_token=slot.get("gateway_token", ""),
        access_url=_build_openclaw_url(slot),
        openwebui_url=_build_openwebui_url(slot),
        assigned_username=slot.get("assigned_username", ""),
    )
