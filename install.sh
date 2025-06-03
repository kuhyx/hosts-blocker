#!/bin/bash

# Enable systemd-resolved
sudo systemctl enable systemd-resolved

# Remove all attributes from /etc/hosts to allow modifications
sudo chattr -i -a /etc/hosts 2>/dev/null || true

# Download the hosts file from StevenBlack's repository
echo "Downloading hosts file from StevenBlack repository..."
sudo curl -o /etc/hosts https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts

# Set restrictive permissions (read-only for owner, no access for group/others)
sudo chmod 600 /etc/hosts

# Make the file immutable (prevents deletion, renaming, and most modifications)
sudo chattr +i /etc/hosts

# Also set append-only attribute as additional protection
# Note: This requires removing immutable first, then setting both
sudo chattr -i /etc/hosts
sudo chattr +a /etc/hosts

# Flush DNS caches
sudo systemd-resolve --flush-caches