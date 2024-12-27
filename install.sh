#!/bin/bash
sudo cp hosts /etc/hosts
sudo systemd-resolve --flush-caches
