#!/bin/bash
# First boot: swap (the box has 1 GB), Docker with Compose, and a home for the
# game. deploy.sh does the rest, over SSM (the Ubuntu image has its agent).
set -euxo pipefail
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 curl
systemctl enable --now docker
mkdir -p /opt/alzendor
