"""Server settings, read from ALZ_* environment variables."""

import os
import socket
from dataclasses import dataclass, field
from pathlib import Path


def _list(value: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in value.split(",") if part.strip())


@dataclass(frozen=True)
class Config:
    host: str = "0.0.0.0"
    port: int = 8000
    redis_url: str = "redis://localhost:6379/0"
    server_id: str = field(default_factory=socket.gethostname)
    seed_file: Path = Path("world/seed.json")
    # Account names (lowercase) allowed to use admin commands.
    admins: frozenset[str] = frozenset()
    # Browser origins allowed to open a WebSocket, e.g. https://alzendor.example.
    # Empty allows any origin, which is only appropriate for local development.
    allowed_origins: tuple[str, ...] = ()
    # Trust X-Forwarded-For from a reverse proxy in front of the server.
    trust_proxy: bool = False
    heartbeat_seconds: int = 10
    # How long a dropped connection keeps its player in the world, so a client
    # can reconnect (to any server) without leaving and re-entering the room.
    linkdead_seconds: int = 60
    # A connected player who sends no commands for this long leaves the world
    # (lying down to sleep, unless they're somewhere safe). 0 turns it off.
    idle_minutes: int = 30
    session_ttl_days: int = 7
    # New accounts allowed per client address per hour. Players behind one
    # network (or every local client, via Docker's gateway) share an address.
    signups_per_hour: int = 20
    log_level: str = "INFO"

    @classmethod
    def from_env(cls, env=os.environ) -> "Config":
        def get(name, default):
            return env.get(f"ALZ_{name}", default)

        defaults = cls()
        return cls(
            host=get("HOST", defaults.host),
            port=int(get("PORT", defaults.port)),
            redis_url=get("REDIS_URL", defaults.redis_url),
            server_id=get("SERVER_ID", defaults.server_id),
            seed_file=Path(get("SEED_FILE", defaults.seed_file)),
            admins=frozenset(name.lower() for name in _list(get("ADMINS", ""))),
            allowed_origins=_list(get("ALLOWED_ORIGINS", "")),
            trust_proxy=get("TRUST_PROXY", "false").lower() in ("1", "true", "yes"),
            heartbeat_seconds=int(get("HEARTBEAT_SECONDS", defaults.heartbeat_seconds)),
            linkdead_seconds=int(get("LINKDEAD_SECONDS", defaults.linkdead_seconds)),
            idle_minutes=int(get("IDLE_MINUTES", defaults.idle_minutes)),
            session_ttl_days=int(get("SESSION_TTL_DAYS", defaults.session_ttl_days)),
            signups_per_hour=int(get("SIGNUPS_PER_HOUR", defaults.signups_per_hour)),
            log_level=get("LOG_LEVEL", defaults.log_level).upper(),
        )
