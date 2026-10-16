#!/bin/bash
# Single-node RKE2 on first boot. Everything else (storage, GPU Operator,
# workloads) is installed from the laptop through the SSH tunnel.
set -eux
[ -e /etc/rancher/rke2/rke2.yaml ] && exit 0
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.33.13+rke2r2 sh -
systemctl enable --now rke2-server
