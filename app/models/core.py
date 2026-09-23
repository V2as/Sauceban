from typing import Optional

from pydantic import BaseModel


class CoreStats(BaseModel):
    version: str
    started: bool
    logs_websocket: str
    # GOMEMLIMIT of the running core, null when it runs uncapped
    memory_limit: Optional[str] = None
