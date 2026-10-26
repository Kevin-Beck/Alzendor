"""Accounts, passwords and session tokens.

- Passwords are hashed on the server with Argon2id (argon2-cffi's defaults,
  RFC 9106's low-memory profile), with a random salt per account. Hashes are
  upgraded on login when the parameters change.
- Login failures give one message whether or not the account exists, and an
  unknown account still costs one hash verification so timing doesn't tell.
- Failed logins are rate limited per client address and per account;
  account creation is rate limited per client address.
- A successful login issues a random session token for reconnecting. Only its
  SHA-256 is stored, with a sliding expiry, and logging out revokes it.
"""

import asyncio
import hashlib
import re
import secrets
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from redis.asyncio import Redis

NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]{2,15}$")
RESERVED_NAMES = {"admin", "all", "everyone", "me", "self", "server", "someone", "system"}
PASSWORD_MIN, PASSWORD_MAX = 8, 128

LOGIN_FAILURES_PER_ADDRESS = 20
LOGIN_FAILURES_PER_ACCOUNT = 10
LOGIN_WINDOW_SECONDS = 15 * 60
ACCOUNT_WINDOW_SECONDS = 60 * 60


class AuthError(Exception):
    """A failure whose message is safe to show the client."""


class Auth:
    def __init__(self, redis: Redis, session_ttl_seconds: int, signups_per_hour: int = 20):
        self.redis = redis
        self.session_ttl = session_ttl_seconds
        self.signups_per_hour = signups_per_hour
        self.hasher = PasswordHasher()
        self._dummy_hash = self.hasher.hash(secrets.token_hex(16))

    async def register(self, name: str, password: str, address: str) -> str:
        name = name.strip()
        if not NAME_RE.match(name) or name.lower() in RESERVED_NAMES:
            raise AuthError("Names are 3-16 letters or digits and start with a letter.")
        if not PASSWORD_MIN <= len(password) <= PASSWORD_MAX:
            raise AuthError(f"Passwords must be {PASSWORD_MIN}-{PASSWORD_MAX} characters.")
        if password.lower() == name.lower():
            raise AuthError("Your password can't be your name.")
        limit_key = f"RATE:register:{address}"
        if await self._count(limit_key) >= self.signups_per_hour:
            raise AuthError("Too many new accounts from your address. Try again later.")

        pid = name.lower()
        digest = await asyncio.to_thread(self.hasher.hash, password)
        if not await self.redis.hsetnx(f"ACCOUNT:{pid}", "hash", digest):
            raise AuthError("That name is taken.")
        await self.redis.hset(f"ACCOUNT:{pid}", mapping={"name": name, "created": int(time.time())})
        await self._bump(limit_key, ACCOUNT_WINDOW_SECONDS)
        return pid

    async def login(self, name: str, password: str, address: str) -> str:
        pid = name.strip().lower()
        address_key, account_key = f"RATE:login:addr:{address}", f"RATE:login:acct:{pid}"
        if (
            await self._count(address_key) >= LOGIN_FAILURES_PER_ADDRESS
            or await self._count(account_key) >= LOGIN_FAILURES_PER_ACCOUNT
        ):
            raise AuthError("Too many failed attempts. Try again in a few minutes.")

        stored = await self.redis.hget(f"ACCOUNT:{pid}", "hash") if NAME_RE.match(pid) else None
        if not await asyncio.to_thread(self._verify, stored, password):
            await self._bump(address_key, LOGIN_WINDOW_SECONDS)
            await self._bump(account_key, LOGIN_WINDOW_SECONDS)
            raise AuthError("Invalid name or password.")

        await self.redis.delete(account_key)
        if self.hasher.check_needs_rehash(stored):
            digest = await asyncio.to_thread(self.hasher.hash, password)
            await self.redis.hset(f"ACCOUNT:{pid}", "hash", digest)
        return pid

    async def issue_token(self, pid: str) -> str:
        token = secrets.token_urlsafe(32)
        await self.redis.set(self._token_key(token), pid, ex=self.session_ttl)
        return token

    async def resume(self, token: str) -> str | None:
        """Returns the player a token belongs to, extending its expiry."""
        return await self.redis.getex(self._token_key(token), ex=self.session_ttl)

    async def revoke(self, token: str) -> None:
        await self.redis.delete(self._token_key(token))

    def _verify(self, stored: str | None, password: str) -> bool:
        if len(password) > PASSWORD_MAX:
            return False
        try:
            return self.hasher.verify(stored or self._dummy_hash, password) and stored is not None
        except (VerificationError, InvalidHashError):
            return False

    @staticmethod
    def _token_key(token: str) -> str:
        return "TOKEN:" + hashlib.sha256(token.encode()).hexdigest()

    async def _count(self, key: str) -> int:
        return int(await self.redis.get(key) or 0)

    async def _bump(self, key: str, window: int) -> None:
        async with self.redis.pipeline(transaction=True) as pipe:
            await pipe.incr(key).expire(key, window, nx=True).execute()
