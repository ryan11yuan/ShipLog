"""ShipLog: records deploys and serves deploy history and DORA metrics."""
import json
import logging
import os
import secrets
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Literal

from azure.data.tables import TableClient
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from pydantic import AwareDatetime, BaseModel, Field

from app.store import DeployStore, compute_metrics

API_KEY_SECRET = "shiplog-api-key"


class JsonFormatter(logging.Formatter):
    """One JSON object per line, so Log Analytics can query each field."""

    def format(self, record):
        entry = {
            "time": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "message": record.getMessage(),
            **getattr(record, "fields", {}),
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logging.getLogger("uvicorn").handlers = [handler]  # uvicorn's own messages as JSON too
logging.getLogger("azure").setLevel(logging.WARNING)  # the SDK logs every HTTP call at INFO
log = logging.getLogger("shiplog")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Managed identity in Azure (AZURE_CLIENT_ID picks which one); your az login locally
    credential = DefaultAzureCredential()
    vault = SecretClient(os.environ["KEY_VAULT_URL"], credential)
    app.state.api_key = vault.get_secret(API_KEY_SECRET).value
    table = TableClient(os.environ["TABLE_ENDPOINT"], os.environ["TABLE_NAME"], credential=credential)
    app.state.store = DeployStore(table)
    log.info("startup complete")
    yield


app = FastAPI(title="ShipLog", lifespan=lifespan)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = time.perf_counter()
    status = 500  # stays 500 if the endpoint raises
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        fields = {
            "method": request.method,
            "path": request.url.path,
            "status": status,
            "duration_ms": round((time.perf_counter() - start) * 1000, 1),
        }
        log.log(logging.ERROR if status >= 500 else logging.INFO, "request", extra={"fields": fields})


def require_api_key(request: Request, x_api_key: str = Header(default="")):
    # compare_digest takes the same time whether the first or last character differs,
    # so an attacker can't guess the key one character at a time by timing responses
    if not secrets.compare_digest(x_api_key.encode(), request.app.state.api_key.encode()):
        raise HTTPException(status_code=401, detail="invalid or missing API key")


class Deploy(BaseModel):
    service: str = Field(pattern=r"^[a-z0-9-]{1,63}$")  # also safe as a PartitionKey
    commit_sha: str = Field(pattern=r"^[0-9a-f]{7,40}$")
    status: Literal["success", "failure"]
    duration_seconds: float = Field(ge=0)
    # Must include a timezone: "12:00" alone is ambiguous
    timestamp: AwareDatetime = Field(default_factory=lambda: datetime.now(timezone.utc))


@app.get("/health")
def health():
    # APP_VERSION is the commit SHA baked into the image, so the pipeline can tell
    # the new revision is serving and not the old one
    return {"status": "ok", "version": os.environ.get("APP_VERSION", "dev")}


@app.post("/deploys", status_code=201, dependencies=[Depends(require_api_key)])
def record_deploy(deploy: Deploy, request: Request):
    request.app.state.store.add(deploy.model_dump())
    log.info("deploy recorded", extra={"fields": deploy.model_dump(mode="json")})
    return deploy


@app.get("/deploys")
def list_deploys(request: Request, service: str | None = None, limit: int = Query(50, ge=1, le=500)):
    return request.app.state.store.query(service)[:limit]


@app.get("/metrics")
def metrics(request: Request, service: str | None = None, days: int = Query(7, ge=1, le=90)):
    since = datetime.now(timezone.utc) - timedelta(days=days)
    return compute_metrics(request.app.state.store.query(service, since), days)
