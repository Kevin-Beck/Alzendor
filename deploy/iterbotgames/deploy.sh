#!/usr/bin/env bash
# Publishes the committed code (git HEAD) to the Alzendor server: uploads it to
# the releases bucket, then, over SSM, the server downloads it with a
# short-lived link, swaps it in and rebuilds (docker compose up --build).
# Redis data lives in a Docker volume, so it survives every deploy.
#
# Usage:  ./deploy.sh                 (ALZ_ADMINS=name,name ./deploy.sh to change the admins;
#                                      without it the last release's admins carry over)
# Needs:  terraform apply done here, and an AWS session:
#         aws sso login --profile admin-dev --use-device-code
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${AWS_PROFILE:-admin-dev}
export PATH="$HOME/.local/bin:$PATH"

if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  echo "AWS session expired. Run: aws sso login --profile $PROFILE --use-device-code" >&2
  exit 1
fi

INSTANCE=$(terraform output -raw instance_id)
BUCKET=$(terraform output -raw bucket)
ORIGIN=$(terraform output -raw origin_domain)
[ -s origin-secret ] || { echo "No origin secret here: run ./cloudfront.sh first (it makes one and gives it to CloudFront)." >&2; exit 1; }
SECRET=$(cat origin-secret)
REPO=$(git rev-parse --show-toplevel)
SHA=$(git -C "$REPO" rev-parse --short HEAD)
if ! git -C "$REPO" diff --quiet HEAD; then
  echo "Note: uncommitted changes aren't deployed; this sends $SHA." >&2
fi

TARBALL=$(mktemp --suffix=.tar.gz)
trap 'rm -f "$TARBALL"' EXIT
git -C "$REPO" archive --format=tar.gz -o "$TARBALL" HEAD
aws s3 cp "$TARBALL" "s3://$BUCKET/alzendor-$SHA.tar.gz" --profile "$PROFILE" --only-show-errors
URL=$(aws s3 presign "s3://$BUCKET/alzendor-$SHA.tar.gz" --expires-in 900 --profile "$PROFILE")

# On the server: back up Redis, unpack beside the running release, swap,
# rebuild, and wait for the new server's health check. The compose project is
# always "alzendor", so its volumes carry over. Admins carry over from the last
# release unless ALZ_ADMINS is set here. A failed health check fails the deploy;
# README.md, "Rolling back", says how to go back.
SCRIPT=$(cat <<SH
set -eu  # SSM runs this with sh (dash): no pipefail
cd /opt/alzendor
mkdir -p backups
if [ -d release ]; then
  if (cd release/deploy/iterbotgames && docker compose exec -T redis redis-cli SAVE >/dev/null \
      && docker compose cp redis:/data/dump.rdb "/opt/alzendor/backups/pre-$SHA-\$(date -u +%Y%m%dT%H%M%SZ).rdb"); then
    echo "Backed up Redis to /opt/alzendor/backups."
  else
    echo "Couldn't back up Redis; stopping." >&2; exit 1
  fi
  ls -1t backups/*.rdb | tail -n +11 | xargs -r rm -f  # keep the last ten
fi
curl -fsSL '$URL' -o release.tar.gz
rm -rf release.new && mkdir release.new && tar -xzf release.tar.gz -C release.new && rm release.tar.gz
ADMINS='${ALZ_ADMINS:-}'
if [ -z "\$ADMINS" ] && [ -f release/deploy/iterbotgames/.env ]; then
  ADMINS=\$(sed -n 's/^ALZ_ADMINS=//p' release/deploy/iterbotgames/.env)
fi
printf 'ALZ_ORIGIN_DOMAIN=%s\nALZ_ORIGIN_SECRET=%s\nALZ_ADMINS=%s\n' '$ORIGIN' '$SECRET' "\$ADMINS" > release.new/deploy/iterbotgames/.env
echo "Admins: \${ADMINS:-none}"
rm -rf release.old
if [ -d release ]; then mv release release.old; fi
mv release.new release
docker tag alzendor:latest alzendor:previous 2>/dev/null || true  # kept for a rollback without a rebuild
cd release/deploy/iterbotgames
if ! docker compose up -d --build --remove-orphans --wait --wait-timeout 120; then
  docker compose logs --tail 30 server >&2 || true
  echo "The new server didn't come up healthy. To roll back: see deploy/iterbotgames/README.md, Rolling back." >&2
  exit 1
fi
docker image prune -f >/dev/null
echo "Deployed $SHA."
SH
)
PARAMS=$(jq -n --arg s "$SCRIPT" '{commands: [$s], executionTimeout: ["1200"]}')
CMD=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
  --comment "alzendor $SHA" --parameters "$PARAMS" --profile "$PROFILE" --query Command.CommandId --output text)
echo "Deploying $SHA to $INSTANCE (SSM command $CMD)..."

while true; do
  sleep 5
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" --profile "$PROFILE" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in
    Pending|InProgress|Delayed) continue ;;
  esac
  aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" --profile "$PROFILE" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text | tail -20
  [ "$STATUS" = Success ] || { echo "Deploy $STATUS." >&2; exit 1; }
  echo "Live at https://iterbotgames.com/alzendor/"
  break
done
