from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.store import DeployStore

KEY = {"X-API-Key": "test-key"}


class FakeStore:
    """In-memory stand-in for DeployStore, so API tests never touch Azure."""

    def __init__(self):
        self.deploys = []

    def add(self, deploy):
        self.deploys.append(deploy)

    def query(self, service=None, since=None):
        rows = [d for d in self.deploys
                if (not service or d["service"] == service) and (not since or d["timestamp"] >= since)]
        return sorted(rows, key=lambda d: d["timestamp"], reverse=True)


@pytest.fixture
def client():
    # Not entering TestClient as a context manager skips startup, so Key Vault is never called
    app.state.api_key = "test-key"
    app.state.store = FakeStore()
    return TestClient(app)


def deploy(status="success", days_ago=0, sha="abc1234"):
    when = datetime.now(timezone.utc) - timedelta(days=days_ago)
    return {"service": "shiplog", "commit_sha": sha, "status": status,
            "duration_seconds": 42, "timestamp": when.isoformat()}


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_post_rejects_missing_or_wrong_key(client):
    assert client.post("/deploys", json=deploy()).status_code == 401
    assert client.post("/deploys", json=deploy(), headers={"X-API-Key": "wrong"}).status_code == 401


def test_post_rejects_invalid_status(client):
    assert client.post("/deploys", json=deploy(status="maybe"), headers=KEY).status_code == 422


def test_deploys_are_listed_newest_first(client):
    client.post("/deploys", json=deploy(days_ago=2, sha="0000001"), headers=KEY)
    client.post("/deploys", json=deploy(days_ago=0, sha="0000002"), headers=KEY)
    shas = [d["commit_sha"] for d in client.get("/deploys?service=shiplog").json()]
    assert shas == ["0000002", "0000001"]


def test_metrics(client):
    for status in ["success", "success", "success", "failure"]:
        client.post("/deploys", json=deploy(status=status, days_ago=1), headers=KEY)
    client.post("/deploys", json=deploy(status="failure", days_ago=10), headers=KEY)  # outside window

    body = client.get("/metrics?service=shiplog&days=7").json()
    assert body["total_deploys"] == 4
    assert body["change_failure_rate"] == 0.25
    assert body["deployment_frequency_per_day"] == round(3 / 7, 2)


def test_metrics_with_no_deploys(client):
    body = client.get("/metrics?service=shiplog").json()
    assert body["total_deploys"] == 0
    assert body["change_failure_rate"] is None


def test_startup_reads_api_key_from_key_vault(monkeypatch):
    monkeypatch.setenv("KEY_VAULT_URL", "https://kv.example")
    monkeypatch.setenv("TABLE_ENDPOINT", "https://st.example")
    monkeypatch.setenv("TABLE_NAME", "deploys")
    secret_client = MagicMock()
    secret_client.return_value.get_secret.return_value.value = "from-vault"
    monkeypatch.setattr("app.main.DefaultAzureCredential", MagicMock())
    monkeypatch.setattr("app.main.SecretClient", secret_client)
    monkeypatch.setattr("app.main.TableClient", MagicMock())

    with TestClient(app) as c:  # entering the context manager runs startup
        response = c.post("/deploys", json=deploy(), headers={"X-API-Key": "from-vault"})

    assert response.status_code == 201
    secret_client.return_value.get_secret.assert_called_once_with("shiplog-api-key")


def test_store_add_writes_entity():
    table = MagicMock()
    when = datetime.now(timezone.utc)
    DeployStore(table).add({"service": "shiplog", "commit_sha": "abc1234", "status": "success",
                            "duration_seconds": 42.0, "timestamp": when})
    entity = table.create_entity.call_args.args[0]
    assert entity["PartitionKey"] == "shiplog"
    assert entity["deployed_at"] == when


def test_store_query_uses_parameters_not_string_building():
    table = MagicMock()
    table.query_entities.return_value = []
    since = datetime.now(timezone.utc)
    DeployStore(table).query("shiplog", since)
    table.query_entities.assert_called_once_with(
        "PartitionKey eq @service and deployed_at ge @since",
        parameters={"service": "shiplog", "since": since},
    )
