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
sudo sed -i 's/^0\.0\.0\.0 www\.facebook\.com/#0.0.0.0 www.facebook.com/' /etc/hosts
sudo sed -i 's/^0\.0\.0\.0 messenger\.com/#0.0.0.0 messenger.com/' /etc/hosts

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

# Steam Store
0.0.0.0 store.steampowered.com

# Discord (selective blocking - media only, voice chat allowed)
0.0.0.0 cdn.discordapp.com
0.0.0.0 media.discordapp.net
0.0.0.0 images-ext-1.discordapp.net
0.0.0.0 images-ext-2.discordapp.net
0.0.0.0 attachments-1.discordapp.net
0.0.0.0 attachments-2.discordapp.net
0.0.0.0 tenor.com
0.0.0.0 giphy.com

# Food Delivery Services
# Polish services
0.0.0.0 pyszne.pl
0.0.0.0 www.pyszne.pl
0.0.0.0 m.pyszne.pl
0.0.0.0 glovo.com
0.0.0.0 www.glovo.com
0.0.0.0 m.glovo.com
0.0.0.0 bolt.eu
0.0.0.0 food.bolt.eu
0.0.0.0 woltwojta.pl
0.0.0.0 www.woltwojta.pl
0.0.0.0 wolt.com
0.0.0.0 www.wolt.com
0.0.0.0 m.wolt.com

# International services
0.0.0.0 ubereats.com
0.0.0.0 www.ubereats.com
0.0.0.0 m.ubereats.com
0.0.0.0 uber.com
0.0.0.0 www.uber.com
0.0.0.0 m.uber.com
0.0.0.0 deliveroo.com
0.0.0.0 www.deliveroo.com
0.0.0.0 m.deliveroo.com
0.0.0.0 deliveroo.co.uk
0.0.0.0 www.deliveroo.co.uk
0.0.0.0 foodpanda.com
0.0.0.0 www.foodpanda.com
0.0.0.0 m.foodpanda.com
0.0.0.0 grubhub.com
0.0.0.0 www.grubhub.com
0.0.0.0 m.grubhub.com
0.0.0.0 doordash.com
0.0.0.0 www.doordash.com
0.0.0.0 m.doordash.com
0.0.0.0 justeat.com
0.0.0.0 www.justeat.com
0.0.0.0 m.justeat.com
0.0.0.0 justeat.co.uk
0.0.0.0 www.justeat.co.uk
0.0.0.0 postmates.com
0.0.0.0 www.postmates.com
0.0.0.0 seamless.com
0.0.0.0 www.seamless.com
0.0.0.0 menulog.com.au
0.0.0.0 www.menulog.com.au
0.0.0.0 delivery.com
0.0.0.0 www.delivery.com

# Fast food chain apps and websites
0.0.0.0 mcdonalds.com
0.0.0.0 www.mcdonalds.com
0.0.0.0 m.mcdonalds.com
0.0.0.0 mcdonalds.pl
0.0.0.0 www.mcdonalds.pl
0.0.0.0 kfc.com
0.0.0.0 www.kfc.com
0.0.0.0 m.kfc.com
0.0.0.0 kfc.pl
0.0.0.0 www.kfc.pl
0.0.0.0 burgerking.com
0.0.0.0 www.burgerking.com
0.0.0.0 m.burgerking.com
0.0.0.0 burgerking.pl
0.0.0.0 www.burgerking.pl
0.0.0.0 pizzahut.com
0.0.0.0 www.pizzahut.com
0.0.0.0 m.pizzahut.com
0.0.0.0 pizzahut.pl
0.0.0.0 www.pizzahut.pl
0.0.0.0 dominos.com
0.0.0.0 www.dominos.com
0.0.0.0 m.dominos.com
0.0.0.0 dominos.pl
0.0.0.0 www.dominos.pl
0.0.0.0 subway.com
0.0.0.0 www.subway.com
0.0.0.0 m.subway.com
0.0.0.0 subway.pl
0.0.0.0 www.subway.pl
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