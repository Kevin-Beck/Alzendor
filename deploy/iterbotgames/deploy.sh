#!/usr/bin/env bash
# Publishes the committed code (git HEAD) to the Alzendor server: uploads it to
# the releases bucket, then, over SSM, the server downloads it with a
# short-lived link, swaps it in and rebuilds (docker compose up --build).
# Redis data lives in a Docker volume, so it survives every deploy.
#
# Usage:  ./deploy.sh                 (ALZ_ADMINS=name,name ./deploy.sh to set admins)
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

# On the server: unpack beside the running release, swap, rebuild. The compose
# project is always "alzendor", so its volumes carry over.
SCRIPT=$(cat <<SH
set -euo pipefail
cd /opt/alzendor
curl -fsSL '$URL' -o release.tar.gz
rm -rf release.new && mkdir release.new && tar -xzf release.tar.gz -C release.new && rm release.tar.gz
printf 'ALZ_ORIGIN_DOMAIN=%s\nALZ_ADMINS=%s\n' '$ORIGIN' '${ALZ_ADMINS:-}' > release.new/deploy/iterbotgames/.env
rm -rf release.old
if [ -d release ]; then mv release release.old; fi
mv release.new release
cd release/deploy/iterbotgames
docker compose up -d --build --remove-orphans
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
