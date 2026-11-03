#!/bin/sh
# Restores the game's Redis from a backup .rdb, on the server (as root):
#   sh /opt/alzendor/release/deploy/iterbotgames/restore-redis.sh /opt/alzendor/backups/<file>.rdb
# Stops the game and Redis, replaces the data, and starts them again. Redis
# keeps an append-only file, and with one switched on it starts empty rather
# than load a dump.rdb; so this loads the dump with it off, then switches it on
# (which writes a fresh one from what was loaded). Checked against redis:7.4.
set -eu
BACKUP=$(realpath "$1")
cd "$(dirname "$0")"
docker compose stop server redis
docker run --rm -v alzendor_redis-data:/data -v "$BACKUP":/backup.rdb:ro redis:7.4-alpine sh -euc '
  rm -rf /data/appendonlydir
  cp /backup.rdb /data/dump.rdb
  redis-server --dir /data --appendonly no --daemonize yes --logfile /tmp/redis.log
  until redis-cli ping 2>/dev/null | grep -q PONG; do sleep 0.2; done
  redis-cli CONFIG SET appendonly yes >/dev/null
  until redis-cli INFO persistence | grep -q "aof_enabled:1" \
      && redis-cli INFO persistence | grep -q "aof_rewrite_in_progress:0" \
      && redis-cli INFO persistence | grep -q "aof_rewrite_scheduled:0"; do sleep 0.2; done
  redis-cli SHUTDOWN SAVE || true
  chown -R redis:redis /data'
docker compose up -d --no-build --wait
echo "Restored $BACKUP."
