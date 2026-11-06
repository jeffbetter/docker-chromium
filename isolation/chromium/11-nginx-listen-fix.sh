#!/bin/sh
# jlesage 10-nginx.sh emits `listen 0.0.0.0:unix:/...` when WEB_LISTENING_PORT=-1.
# Rewrite to a unix-only listen so nginx can start with the web GUI disabled.
set -eu
if [ "${WEB_LISTENING_PORT:-5800}" -eq -1 ]; then
    mkdir -p /var/tmp/nginx /var/run/nginx
    printf 'listen unix:/var/run/nginx/nginx.sock default_server;\n' > /var/tmp/nginx/listen.conf
fi
