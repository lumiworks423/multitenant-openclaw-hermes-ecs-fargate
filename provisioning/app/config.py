import os

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
DYNAMODB_SLOTS_TABLE = os.environ.get("DYNAMODB_SLOTS_TABLE", "openclaw-mt-slots")
DYNAMODB_USERS_TABLE = os.environ.get("DYNAMODB_USERS_TABLE", "openclaw-mt-users")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin")
CLOUDFRONT_DOMAIN = os.environ.get("CLOUDFRONT_DOMAIN", "localhost")
SLOT_COUNT = int(os.environ.get("SLOT_COUNT", "5"))
JWT_SECRET = os.environ.get("JWT_SECRET", "openclaw-mt-jwt-secret-change-me")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24

# Cognito OIDC
COGNITO_USER_POOL_ID = os.environ.get("COGNITO_USER_POOL_ID", "")
COGNITO_CLIENT_ID = os.environ.get("COGNITO_CLIENT_ID", "")
COGNITO_CLIENT_SECRET = os.environ.get("COGNITO_CLIENT_SECRET", "")
COGNITO_DOMAIN = os.environ.get("COGNITO_DOMAIN", "")
OIDC_ENABLED = bool(COGNITO_CLIENT_ID)
