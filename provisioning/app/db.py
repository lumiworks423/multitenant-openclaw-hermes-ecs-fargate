"""DynamoDB client for slots and users tables."""
import boto3
from boto3.dynamodb.conditions import Key, Attr
from app.config import AWS_REGION, DYNAMODB_SLOTS_TABLE, DYNAMODB_USERS_TABLE

_ddb = boto3.resource("dynamodb", region_name=AWS_REGION)
_slots_table = _ddb.Table(DYNAMODB_SLOTS_TABLE)
_users_table = _ddb.Table(DYNAMODB_USERS_TABLE)


# ── Slots ──

def get_slot(slot_id: str) -> dict | None:
    resp = _slots_table.get_item(Key={"slot_id": slot_id})
    return resp.get("Item")


def list_slots(status: str | None = None) -> list[dict]:
    if status:
        resp = _slots_table.query(
            IndexName="status-index",
            KeyConditionExpression=Key("status").eq(status),
        )
    else:
        resp = _slots_table.scan()
    return resp.get("Items", [])


def assign_slot(slot_id: str, username: str) -> bool:
    """Atomically assign a slot to a user (only if currently available)."""
    from datetime import datetime, timezone
    try:
        _slots_table.update_item(
            Key={"slot_id": slot_id},
            UpdateExpression="SET #s = :assigned, assigned_username = :u, assigned_at = :t",
            ConditionExpression="#s = :available",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":assigned": "assigned",
                ":available": "available",
                ":u": username,
                ":t": datetime.now(timezone.utc).isoformat(),
            },
        )
        return True
    except _ddb.meta.client.exceptions.ConditionalCheckFailedException:
        return False


def find_available_slot() -> dict | None:
    """Find the first available slot."""
    items = list_slots(status="available")
    return items[0] if items else None


def update_slot(slot_id: str, updates: dict):
    expr_parts = []
    attr_names = {}
    attr_values = {}
    for i, (k, v) in enumerate(updates.items()):
        alias = f"#k{i}"
        val_alias = f":v{i}"
        expr_parts.append(f"{alias} = {val_alias}")
        attr_names[alias] = k
        attr_values[val_alias] = v
    _slots_table.update_item(
        Key={"slot_id": slot_id},
        UpdateExpression="SET " + ", ".join(expr_parts),
        ExpressionAttributeNames=attr_names,
        ExpressionAttributeValues=attr_values,
    )


# ── Users ──

def get_user(username: str) -> dict | None:
    resp = _users_table.get_item(Key={"username": username})
    return resp.get("Item")


def create_user(username: str, password_hash: str, role: str = "user") -> dict:
    from datetime import datetime, timezone
    item = {
        "username": username,
        "password_hash": password_hash,
        "role": role,
        "slot_id": "",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    _users_table.put_item(Item=item)
    return item


def update_user(username: str, updates: dict):
    expr_parts = []
    attr_names = {}
    attr_values = {}
    for i, (k, v) in enumerate(updates.items()):
        alias = f"#k{i}"
        val_alias = f":v{i}"
        expr_parts.append(f"{alias} = {val_alias}")
        attr_names[alias] = k
        attr_values[val_alias] = v
    _users_table.update_item(
        Key={"username": username},
        UpdateExpression="SET " + ", ".join(expr_parts),
        ExpressionAttributeNames=attr_names,
        ExpressionAttributeValues=attr_values,
    )


def list_users() -> list[dict]:
    resp = _users_table.scan()
    return resp.get("Items", [])
