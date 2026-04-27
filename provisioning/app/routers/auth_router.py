"""Registration and login endpoints."""
from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from app import db
from app.auth import hash_password, verify_password, create_token
from app.config import ADMIN_PASSWORD

router = APIRouter(prefix="/api", tags=["auth"])


class RegisterRequest(BaseModel):
    username: str
    password: str


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    token: str
    username: str
    role: str


@router.post("/register", response_model=TokenResponse)
def register(req: RegisterRequest):
    if not req.username or not req.password:
        raise HTTPException(status_code=400, detail="Username and password required")
    if len(req.username) < 2 or len(req.username) > 30:
        raise HTTPException(status_code=400, detail="Username must be 2-30 characters")
    if db.get_user(req.username):
        raise HTTPException(status_code=409, detail="Username already exists")

    hashed = hash_password(req.password)
    db.create_user(req.username, hashed, role="user")
    token = create_token(req.username, "user")
    return TokenResponse(token=token, username=req.username, role="user")


@router.post("/login", response_model=TokenResponse)
def login(req: LoginRequest):
    # Admin login with master password
    if req.username == "admin" and req.password == ADMIN_PASSWORD:
        # Ensure admin user exists in DB with role=admin
        existing = db.get_user("admin")
        if not existing:
            db.create_user("admin", hash_password(ADMIN_PASSWORD), role="admin")
        elif existing.get("role") != "admin":
            db.update_user("admin", {"role": "admin"})
        token = create_token("admin", "admin")
        return TokenResponse(token=token, username="admin", role="admin")

    user = db.get_user(req.username)
    if not user or not verify_password(req.password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token = create_token(user["username"], user.get("role", "user"))
    return TokenResponse(token=token, username=user["username"], role=user.get("role", "user"))
