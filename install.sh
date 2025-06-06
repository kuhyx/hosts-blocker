#!/bin/bash

# Enable systemd-resolved
sudo systemctl enable systemd-resolved

# Remove all attributes from /etc/hosts to allow modifications
sudo chattr -i -a /etc/hosts 2>/dev/null || true

# Download the hosts file from StevenBlack's repository
echo "Downloading hosts file from StevenBlack repository..."
sudo curl -o /etc/hosts https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn-social/hosts

# Comment out any 4chan blocking entries from the downloaded file
echo "Allowing 4chan by commenting out any blocking entries..."
sudo sed -i 's/^0\.0\.0\.0 4chan\.com/#0.0.0.0 4chan.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.com/#0.0.0.0 www.4chan.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 4chan\.org/#0.0.0.0 4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 boards\.4chan\.org/#0.0.0.0 boards.4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 sys\.4chan\.org/#0.0.0.0 sys.4chan.org/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 www\.4chan\.org/#0.0.0.0 www.4chan.org/' /etc/hosts

# Add custom entries for YouTube and Discord
echo "Adding custom entries for YouTube and Discord..."
sudo cat >> /etc/hosts << 'EOF'

# Custom blocking entries
# YouTube
0.0.0.0 youtube.com
0.0.0.0 www.youtube.com
0.0.0.0 m.youtube.com
0.0.0.0 youtu.be
0.0.0.0 youtube-nocookie.com
0.0.0.0 www.youtube-nocookie.com
0.0.0.0 youtubei.googleapis.com
0.0.0.0 youtube.googleapis.com
0.0.0.0 yt3.ggpht.com
0.0.0.0 ytimg.com
0.0.0.0 i.ytimg.com
0.0.0.0 s.ytimg.com
0.0.0.0 i9.ytimg.com
0.0.0.0 googlevideo.com
0.0.0.0 r1---sn-4g5e6nls.googlevideo.com
0.0.0.0 r1---sn-4g5lne7s.googlevideo.com

# Discord (selective blocking - media only, voice chat allowed)
0.0.0.0 cdn.discordapp.com
0.0.0.0 media.discordapp.net
0.0.0.0 images-ext-1.discordapp.net
0.0.0.0 images-ext-2.discordapp.net
0.0.0.0 attachments-1.discordapp.net
0.0.0.0 attachments-2.discordapp.net
0.0.0.0 tenor.com
0.0.0.0 giphy.com
EOF

# Set proper permissions (readable by all, writable only by root)
sudo chmod 644 /etc/hosts

# Make the file immutable (prevents deletion, renaming, and most modifications)
sudo chattr +i /etc/hosts

# Also set append-only attribute as additional protection
# Note: This requires removing immutable first, then setting both
sudo chattr -i /etc/hosts
sudo chattr +a /etc/hosts

# Flush DNS caches
sudo systemd-resolve --flush-caches
sudo systemctl restart NetworkManager.service