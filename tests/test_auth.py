import pytest

from alzendor.auth import LOGIN_FAILURES_PER_ACCOUNT, Auth, AuthError


@pytest.fixture
def auth(redis):
    return Auth(redis, session_ttl_seconds=60)


async def test_register_then_log_in(auth, redis):
    assert await auth.register("Kevin", "correct horse", "1.2.3.4") == "kevin"
    assert await auth.login("KEVIN", "correct horse", "1.2.3.4") == "kevin"
    account = await redis.hgetall("ACCOUNT:kevin")
    assert account["name"] == "Kevin"
    assert account["hash"].startswith("$argon2id$")
    assert "correct horse" not in str(account)


async def test_names_are_owned(auth):
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    with pytest.raises(AuthError, match="taken"):
        await auth.register("kevin", "another password", "1.2.3.4")


@pytest.mark.parametrize(
    "name, password",
    [("ab", "long enough"), ("1abc", "long enough"), ("system", "long enough"), ("Kevin", "short"), ("Kevin", "kevin")],
)
async def test_register_rejects_bad_names_and_passwords(auth, name, password):
    with pytest.raises(AuthError):
        await auth.register(name, password, "1.2.3.4")


async def test_login_failures_do_not_reveal_whether_an_account_exists(auth):
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    with pytest.raises(AuthError) as wrong_password:
        await auth.login("kevin", "wrong password", "1.2.3.4")
    with pytest.raises(AuthError) as no_account:
        await auth.login("nobody", "wrong password", "1.2.3.4")
    assert str(wrong_password.value) == str(no_account.value) == "Invalid name or password."


async def test_repeated_failures_are_rate_limited(auth):
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    for _ in range(LOGIN_FAILURES_PER_ACCOUNT):
        with pytest.raises(AuthError, match="Invalid"):
            await auth.login("kevin", "wrong password", "5.6.7.8")
    with pytest.raises(AuthError, match="Too many"):
        await auth.login("kevin", "correct horse", "5.6.7.8")


async def test_account_creation_is_rate_limited_per_address(redis):
    auth = Auth(redis, session_ttl_seconds=60, signups_per_hour=2)
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    with pytest.raises(AuthError):
        await auth.register("x", "correct horse", "1.2.3.4")  # failures don't count
    await auth.register("Mara", "correct horse", "1.2.3.4")
    with pytest.raises(AuthError, match="Too many new accounts"):
        await auth.register("Ida", "correct horse", "1.2.3.4")
    assert await auth.register("Ida", "correct horse", "5.6.7.8") == "ida"


async def test_session_tokens(auth, redis):
    token = await auth.issue_token("kevin")
    assert await auth.resume(token) == "kevin"
    assert not await redis.exists(f"TOKEN:{token}")  # only the hash is stored
    await auth.revoke(token)
    assert await auth.resume(token) is None
    assert await auth.resume("made-up") is None


async def test_a_taken_name_costs_no_hash_and_counts_towards_the_limit(redis):
    auth = Auth(redis, session_ttl_seconds=60, signups_per_hour=3)
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    hashes = []

    class Counting:
        def __init__(self, hasher):
            self.hasher = hasher

        def hash(self, password):
            hashes.append(password)
            return self.hasher.hash(password)

    auth.hasher = Counting(auth.hasher)
    for _ in range(2):
        with pytest.raises(AuthError, match="taken"):
            await auth.register("kevin", "another password", "1.2.3.4")
    assert hashes == []
    with pytest.raises(AuthError, match="Too many"):
        await auth.register("kevin", "another password", "1.2.3.4")


async def test_signup_time_is_kept_apart_from_the_character_flag(auth, redis):
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    account = await redis.hgetall("ACCOUNT:kevin")
    assert int(account["registered"]) > 1_700_000_000
    assert "created" not in account  # set to "1" by create_character, and only then


async def test_resuming_slides_the_token_expiry(auth, redis):
    token = await auth.issue_token("kevin")
    key = auth._token_key(token)
    await redis.expire(key, 5)
    assert await auth.resume(token) == "kevin"
    assert await redis.ttl(key) > 50


async def test_a_good_login_clears_the_account_failures(auth):
    await auth.register("Kevin", "correct horse", "1.2.3.4")
    for _ in range(LOGIN_FAILURES_PER_ACCOUNT - 1):
        with pytest.raises(AuthError, match="Invalid"):
            await auth.login("kevin", "wrong password", "5.6.7.8")
    await auth.login("kevin", "correct horse", "5.6.7.8")
    with pytest.raises(AuthError, match="Invalid"):
        await auth.login("kevin", "wrong password", "9.9.9.9")
    assert await auth.login("kevin", "correct horse", "9.9.9.9") == "kevin"
