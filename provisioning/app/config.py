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
