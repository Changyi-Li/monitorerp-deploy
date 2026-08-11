#!/bin/sh
# Let's Encrypt renewal deploy hook: reload nginx after certbot renews a
# certificate so the new cert is picked up (nginx caches certs in memory
# until reload).
#
# Install on the server (once):
#   sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
#   sudo cp nginx-reload-hook.sh /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#   sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#
# certbot (snap) runs all executable files in renewal-hooks/deploy/ after
# each successful renewal. Reload is a no-op for certs that did not change.

docker exec server-nginx-nginx-1 nginx -s reload 2>/dev/null || true
