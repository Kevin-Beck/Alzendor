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
| Data | Redis in a Docker volume on the instance's disk. It survives deploys and reboots; it doesn't survive destroying the instance |

Players register in the game itself (a name and a password), so there's
nothing else to set up for them. The server trusts CloudFront's
`CloudFront-Viewer-Address` for each player's address (sign-up and login
limits), and only accepts browsers from `https://iterbotgames.com`.

## Setting it up (once)

```sh
aws sso login --profile admin-dev --use-device-code
cd deploy/iterbotgames
terraform init
terraform apply            # the server, its name, the bucket (a few minutes to boot)
./cloudfront.sh            # the /alzendor/* route (CloudFront takes a few minutes)
ALZ_ADMINS=kev ./deploy.sh # the game itself
```

Terraform's state is local (`terraform.tfstate` here, not in git): keep it.
The CloudFront distribution isn't Terraform's: `cloudfront.sh` adds and
updates only Alzendor's origin and behavior, and running it again is safe.

## Everyday use

```sh
git commit ...             # deploy.sh sends the committed code (HEAD)
./deploy.sh                # upload, swap in and rebuild over SSM, then report
```

A shell on the server, if you need one:

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)" --profile admin-dev
sudo docker compose -f /opt/alzendor/release/deploy/iterbotgames/compose.yml logs -f server
```

Admin commands in the game (`announce`, `goto`, `setweather`, `setclock`) are for the accounts in
`ALZ_ADMINS`, set at deploy time. To wipe a character from a shell on the
server: `sudo docker compose ... exec redis redis-cli FCALL reset_character 0 <name>`.

## Taking it down

`./cloudfront.sh` doesn't remove its route: delete the `/alzendor/*`
behavior and the `alzendor` origin in the CloudFront console (or with
`get-distribution-config` / `update-distribution`), then `terraform destroy`.

## Cost

About $10 a month: the instance (~$6), its public IPv4 address (~$3.60),
12 GB of disk (~$1), and pennies for the bucket and CloudFront.
