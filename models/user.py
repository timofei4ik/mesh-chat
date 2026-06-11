from dataclasses import dataclass
import time


@dataclass
class User:
    name: str
    ip: str
    port: int
    last_seen: float = time.time()