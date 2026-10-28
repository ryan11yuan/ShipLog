"""Deploy records in Azure Table Storage, plus the DORA metric math."""
import uuid
from datetime import datetime

from azure.data.tables import TableClient


class DeployStore:
    def __init__(self, table: TableClient):
        self.table = table

    def add(self, deploy: dict) -> None:
        self.table.create_entity({
            "PartitionKey": deploy["service"],
            "RowKey": uuid.uuid4().hex,
            "commit_sha": deploy["commit_sha"],
            "status": deploy["status"],
            "duration_seconds": deploy["duration_seconds"],
            # "Timestamp" is reserved by Table Storage (last-modified time)
            "deployed_at": deploy["timestamp"],
        })

    def query(self, service: str | None = None, since: datetime | None = None) -> list[dict]:
        """Deploys newest first, optionally filtered by service and start time."""
        filters, params = [], {}
        if service:
            filters.append("PartitionKey eq @service")
            params["service"] = service
        if since:
            filters.append("deployed_at ge @since")
            params["since"] = since
        if filters:
            entities = self.table.query_entities(" and ".join(filters), parameters=params)
        else:
            entities = self.table.list_entities()

        deploys = [
            {
                "service": e["PartitionKey"],
                "commit_sha": e["commit_sha"],
                "status": e["status"],
                "duration_seconds": e["duration_seconds"],
                "timestamp": e["deployed_at"],
            }
            for e in entities
        ]
        return sorted(deploys, key=lambda d: d["timestamp"], reverse=True)


def compute_metrics(deploys: list[dict], days: int) -> dict:
    total = len(deploys)
    failed = sum(1 for d in deploys if d["status"] == "failure")
    return {
        "days": days,
        "total_deploys": total,
        "failed_deploys": failed,
        # How often we successfully ship; a failed run shipped nothing
        "deployment_frequency_per_day": round((total - failed) / days, 2),
        # None rather than 0 when there is no data: 0 would claim a perfect record
        "change_failure_rate": round(failed / total, 2) if total else None,
    }
