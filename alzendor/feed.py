"""A player's view of the world: the events of every channel they're subscribed
to, read from Redis streams in one global order.

Every event's stream ID is its global sequence number, so a connection's whole
position in the world is a single number (`cursor`): everything up to it has
been delivered. Each read asks every subscribed stream for what comes after the
cursor (or after the point the player joined that channel, if later), then
delivers the combined result sorted by sequence number. One XREAD is atomic
across streams, so nothing that happened before the newest returned event is
missing from the batch.

Subscription changes arrive as `control` events on the player's own stream.
When one is reached, the change is applied and the rest of the batch is dropped;
the next read fetches it again with the new subscriptions, so an event is never
delivered from a channel the player has left or missed from one they've joined.
"""

import json

from redis.asyncio import Redis

# How long one read waits for new events. The Redis client's socket timeout
# must be longer (see server.open_redis).
FEED_BLOCK_MS = 5000


class Feed:
    def __init__(self, redis: Redis, session_id: str, cursor: int, subs: dict[str, int]):
        self.redis = redis
        self.session_id = session_id
        self.cursor = cursor
        self.subs = subs  # channel -> sequence number it was joined at
        self.ended: str | None = None  # set when this connection has been told to close

    @classmethod
    async def open(cls, redis: Redis, pid: str, session_id: str, cursor: int) -> "Feed":
        subs = await redis.hgetall(f"PLAYER:{pid}:subs")
        return cls(redis, session_id, cursor, {ch: int(seq) for ch, seq in subs.items()})

    async def read(self, block_ms: int = FEED_BLOCK_MS) -> list[dict]:
        """Waits for and returns the next events, in sequence order."""
        streams = {ch: f"{max(self.cursor, joined)}-0" for ch, joined in self.subs.items()}
        reply = await self.redis.xread(streams, block=block_ms)
        entries = sorted(
            (int(entry_id.split("-")[0]), fields["e"])
            for _stream, items in reply or ()
            for entry_id, fields in items
        )

        events = []
        for seq, raw in entries:
            event = json.loads(raw)
            event["seq"] = seq
            self.cursor = seq
            if event["type"] != "control":
                events.append(event)
            elif event["op"] == "kick":
                if event["session"] == self.session_id:
                    self.ended = event.get("reason") or "Disconnected."
                    break
            elif event["op"] == "subs":
                for channel in event["remove"]:
                    self.subs.pop(channel, None)
                for channel in event["add"]:
                    self.subs[channel] = seq
                break
        return events
