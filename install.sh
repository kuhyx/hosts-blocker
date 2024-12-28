#!/bin/bash
sudo systemctl enable systemd-resolved
sudo cp hosts /etc/hosts
sudo systemd-resolve --flush-caches
