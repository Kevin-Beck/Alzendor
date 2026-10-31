#!/usr/bin/env bash
# Adds Alzendor to the iterbotgames.com CloudFront distribution: an origin
# (the server's DNS name, HTTPS only) and a behavior sending /alzendor/* to it,
# uncached, with main.tf's origin request policy: the websocket handshake,
# Origin and the viewer's address, but not Host (so the origin's certificate
# matches). Run it again to update
# them; everything else in the distribution is left as it is. The existing
# index-rewrite function already redirects /alzendor to /alzendor/.
#
# Usage: ./cloudfront.sh [--dryrun]   (--dryrun shows the change without making it)
# Needs: terraform apply done here, and an AWS session (see deploy.sh).
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${AWS_PROFILE:-admin-dev}
DISTRIBUTION=E1HHTSHZV5KSH8
export PATH="$HOME/.local/bin:$PATH"
aws_() { aws --profile "$PROFILE" "$@"; }

ORIGIN=$(terraform output -raw origin_domain)
CACHE=$(aws_ cloudfront list-cache-policies --type managed \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingDisabled'].CachePolicy.Id" --output text)
REQUEST=$(terraform output -raw origin_request_policy) # main.tf: the handshake, Origin, the viewer's address
[ -n "$CACHE" ] && [ -n "$REQUEST" ] || { echo "Couldn't find the managed CloudFront policies." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
aws_ cloudfront get-distribution-config --id "$DISTRIBUTION" > "$WORK/current.json"
ETAG=$(jq -r .ETag "$WORK/current.json")

jq --arg origin "$ORIGIN" --arg cache "$CACHE" --arg request "$REQUEST" '
  .DistributionConfig
  | .Origins.Items = ([.Origins.Items[] | select(.Id != "alzendor")] + [{
      Id: "alzendor", DomainName: $origin, OriginPath: "",
      CustomHeaders: {Quantity: 0},
      CustomOriginConfig: {HTTPPort: 80, HTTPSPort: 443, OriginProtocolPolicy: "https-only",
        OriginSslProtocols: {Quantity: 1, Items: ["TLSv1.2"]}, OriginReadTimeout: 60, OriginKeepaliveTimeout: 5},
      ConnectionAttempts: 3, ConnectionTimeout: 10,
      OriginShield: {Enabled: false}, OriginAccessControlId: ""}])
  | .Origins.Quantity = (.Origins.Items | length)
  | .CacheBehaviors.Items = ([(.CacheBehaviors.Items // [])[] | select(.PathPattern != "/alzendor/*")] + [{
      PathPattern: "/alzendor/*", TargetOriginId: "alzendor", ViewerProtocolPolicy: "redirect-to-https",
      AllowedMethods: {Quantity: 2, Items: ["GET", "HEAD"], CachedMethods: {Quantity: 2, Items: ["GET", "HEAD"]}},
      SmoothStreaming: false, Compress: true, CachePolicyId: $cache, OriginRequestPolicyId: $request,
      LambdaFunctionAssociations: {Quantity: 0}, FunctionAssociations: {Quantity: 0}, FieldLevelEncryptionId: "",
      TrustedSigners: {Enabled: false, Quantity: 0}, TrustedKeyGroups: {Enabled: false, Quantity: 0}}])
  | .CacheBehaviors.Quantity = (.CacheBehaviors.Items | length)
' "$WORK/current.json" > "$WORK/new.json"

if [ "${1:-}" = "--dryrun" ]; then # show what would change, and stop
  diff <(jq -S .DistributionConfig "$WORK/current.json") <(jq -S . "$WORK/new.json") || true
  exit 0
fi
aws_ cloudfront update-distribution --id "$DISTRIBUTION" --if-match "$ETAG" \
  --distribution-config "file://$WORK/new.json" --query Distribution.Status --output text
echo "CloudFront is rolling out /alzendor/* to $ORIGIN (a few minutes)."
