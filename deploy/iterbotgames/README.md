# Alzendor on iterbotgames.com

The game at **https://iterbotgames.com/alzendor/**, on the lightest setup that
real players can log in to: one small server behind the site's CloudFront.

```
browser ── https ──▶ CloudFront (iterbotgames.com)
                        ├─ /alzendor/*  ──▶ alzendor-origin.iterbotgames.com:443
                        │                    Caddy (TLS, strips /alzendor)
                        │                      └─ game server ── Redis
                        └─ everything else ──▶ the S3 site, as before
```

| Piece | What |
|---|---|
| Server | one `t4g.micro` (ARM, 1 GB + 1 GB swap), Ubuntu 24.04, Docker Compose: Redis, one game server, Caddy |
| Network | default VPC; 443 open to CloudFront only (its managed prefix list), 80 open for certificate challenges and redirects |
| Name | Elastic IP, `alzendor-origin.iterbotgames.com` (Route 53) for CloudFront's origin; Caddy gets its certificate |
| Access | no SSH: commands go over SSM (the instance role has `AmazonSSMManagedInstanceCore`) |
| Releases | a private S3 bucket (`alzendor-releases-…`), kept 30 days |
| CloudFront | distribution `E1HHTSHZV5KSH8`: an `alzendor` origin and a `/alzendor/*` behavior (no caching; the `alzendor-origin` request policy from main.tf passes the websocket handshake, Origin and `CloudFront-Viewer-Address`, not Host) |
| Data | Redis in a Docker volume on the instance's disk. It survives deploys and reboots; it doesn't survive destroying the instance, so the disk is snapshotted daily (kept 7 days) and every deploy saves a copy first (see Backups) |

Players register in the game itself (a name and a password), so there's
nothing else to set up for them. The server trusts CloudFront's
`CloudFront-Viewer-Address` for each player's address (sign-up and login
limits), and only accepts browsers from `https://iterbotgames.com`. Port 443
is open to all of CloudFront, so our distribution also sends a secret header
(`X-Alzendor-Origin`, kept in `origin-secret` here, not in git) and Caddy
refuses anything without it: only iterbotgames.com's CloudFront reaches the
game.

## Setting it up (once)

```sh
aws sso login --profile admin-dev --use-device-code
cd deploy/iterbotgames
terraform init
terraform plan -out=tfplan # the server, its name, the bucket, CloudFront's request policy
terraform apply tfplan     # (a few minutes to boot)
./cloudfront.sh --dryrun   # see the change to the distribution first
./cloudfront.sh            # the /alzendor/* route and the secret header (a few minutes)
ALZ_ADMINS=kev ./deploy.sh # the game itself
```

Terraform's state is local (`terraform.tfstate` here, not in git): keep it.
The CloudFront distribution isn't Terraform's: `cloudfront.sh` adds and
updates only Alzendor's origin and behavior, and running it again is safe.

## Everyday use

```sh
git commit ...             # deploy.sh sends the committed code (HEAD)
./deploy.sh                # back up, upload, swap in, rebuild, wait for health, report
```

A deploy first saves Redis to `/opt/alzendor/backups/pre-<sha>-<time>.rdb` on
the server (the last ten are kept), then waits up to two minutes for the new
server's health check. If it doesn't pass, the deploy fails ("Deploy Failed.")
and prints the server's last log lines. The admins carry over from the last
release; `ALZ_ADMINS=name,name ./deploy.sh` changes them (`ALZ_ADMINS=` alone
can't clear them: edit `.env` on the server for that).

A shell on the server, if you need one:

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)" --profile admin-dev
sudo docker compose -f /opt/alzendor/release/deploy/iterbotgames/compose.yml logs -f server
```

Admin commands in the game (`announce`, `goto`, `setweather`, `setclock`) are for the accounts in
`ALZ_ADMINS`, set at deploy time and kept by later deploys. To wipe a character from a shell on the
server: `sudo docker compose ... exec redis redis-cli FCALL reset_character 0 <name>`.

## The origin secret

`cloudfront.sh` makes `origin-secret` the first time it runs and gives it to
CloudFront; `deploy.sh` passes it to Caddy, and won't deploy without it.
**Order matters:** run `./cloudfront.sh` and wait for CloudFront to finish
rolling out (a few minutes) before the first deploy that requires the
header, or Caddy refuses every request until it has. To change the secret,
delete the file, run `./cloudfront.sh`, wait, then `./deploy.sh`; players are
refused in between. Keep the file with the Terraform state: a deploy from
another machine needs both.

## Rolling back

Redeploy a commit you know was good: `git checkout <good sha> && ./deploy.sh`
(it sends HEAD), then `git checkout -` to come back. That's the usual way.

If deploying isn't possible, on the server (`aws ssm start-session ...`, then
`sudo -i`):

```sh
cd /opt/alzendor
mv release release.bad && mv release.old release
cd release/deploy/iterbotgames
docker tag alzendor:previous alzendor:latest    # the image before the last deploy
docker compose up -d --no-build --wait
```

If the bad release also damaged players' data, restore a backup (below).

## Backups

Two kinds, both on the server's side:

- **Before each deploy**: `/opt/alzendor/backups/pre-<sha>-<time>.rdb`, the
  last ten. Restoring one stops the game for a few seconds:
  ```sh
  sh /opt/alzendor/release/deploy/iterbotgames/restore-redis.sh /opt/alzendor/backups/<file>.rdb
  ```
  (Don't just copy a dump.rdb into the volume: Redis keeps an append-only file,
  and starts empty rather than load the dump. The script handles that.)
- **Daily disk snapshots** (Data Lifecycle Manager, main.tf), kept 7 days:
  `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:alzendor-backup,Values=daily --profile admin-dev`.
  To restore, create a volume from the snapshot in the instance's zone, stop
  the instance, swap it in as the root volume (EC2 console: *Replace root
  volume* takes a snapshot directly), and start it again.

## Taking it down

`./cloudfront.sh` doesn't remove its route: delete the `/alzendor/*`
behavior and the `alzendor` origin in the CloudFront console (or with
`get-distribution-config` / `update-distribution`), then `terraform destroy`.

## Cost

About $10 a month: the instance (~$6), its public IPv4 address (~$3.60),
12 GB of disk (~$1), and pennies for the bucket, the week of snapshots and CloudFront.
