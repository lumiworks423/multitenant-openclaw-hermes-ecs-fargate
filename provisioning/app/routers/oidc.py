"""OIDC (Cognito) login flow — Authorization Code Grant."""
import httpx
from fastapi import APIRouter, HTTPException
from fastapi.responses import RedirectResponse
from urllib.parse import urlencode

from app import db
from app.auth import create_token, hash_password
from app.config import (
    COGNITO_DOMAIN, COGNITO_CLIENT_ID, COGNITO_CLIENT_SECRET,
    CLOUDFRONT_DOMAIN, OIDC_ENABLED,
)

router = APIRouter(prefix="/api/auth/oidc", tags=["oidc"])

REDIRECT_URI = f"https://{CLOUDFRONT_DOMAIN}/api/auth/oidc/callback"


@router.get("/login")
def oidc_login():
    if not OIDC_ENABLED:
        raise HTTPException(status_code=404, detail="OIDC not configured")

    params = urlencode({
        "client_id": COGNITO_CLIENT_ID,
        "response_type": "code",
        "scope": "openid email profile",
        "redirect_uri": REDIRECT_URI,
    })
    return RedirectResponse(f"{COGNITO_DOMAIN}/oauth2/authorize?{params}")


@router.get("/callback")
async def oidc_callback(code: str = ""):
    if not code:
        raise HTTPException(status_code=400, detail="Missing authorization code")

    # Exchange code for tokens
    token_url = f"{COGNITO_DOMAIN}/oauth2/token"
    async with httpx.AsyncClient() as client:
        resp = await client.post(token_url, data={
            "grant_type": "authorization_code",
            "client_id": COGNITO_CLIENT_ID,
            "client_secret": COGNITO_CLIENT_SECRET,
            "code": code,
            "redirect_uri": REDIRECT_URI,
        }, headers={"Content-Type": "application/x-www-form-urlencoded"})

    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail="Token exchange failed")

    tokens = resp.json()

    # Get user info
    async with httpx.AsyncClient() as client:
        userinfo_resp = await client.get(
            f"{COGNITO_DOMAIN}/oauth2/userInfo",
            headers={"Authorization": f"Bearer {tokens['access_token']}"},
        )

    if userinfo_resp.status_code != 200:
        raise HTTPException(status_code=401, detail="Failed to get user info")

    userinfo = userinfo_resp.json()
    email = userinfo.get("email", "")
    username = email or userinfo.get("sub", "")

    if not username:
        raise HTTPException(status_code=401, detail="No user identifier in token")

    # Auto-create user on first login
    user = db.get_user(username)
    if not user:
        db.create_user(username, hash_password(""), role="user")
        user = db.get_user(username)

    # Issue our JWT and redirect to frontend with token
    jwt_token = create_token(username, user.get("role", "user"))
    redirect_url = f"https://{CLOUDFRONT_DOMAIN}/#token={jwt_token}"
    return RedirectResponse(redirect_url)


@router.get("/config")
def oidc_config():
    """Frontend calls this to know if OIDC is available."""
    return {
        "enabled": OIDC_ENABLED,
        "login_url": "/api/auth/oidc/login" if OIDC_ENABLED else None,
    }
