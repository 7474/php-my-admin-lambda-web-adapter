#!/bin/bash

set -eu

# Create runtime directories under /tmp that Apache and phpMyAdmin need.
# Lambda mounts a fresh writable /tmp on every cold start, so directories
# baked into the image layer are not present at runtime.
mkdir -p /tmp/apache2-locks /tmp/phpmyadmin
chown -R 33:33 /tmp/apache2-locks /tmp/phpmyadmin
chmod 700 /tmp/apache2-locks /tmp/phpmyadmin

# Prefer correctly named BASIC_AUTH_* vars; keep BACIC_AUTH_* for compatibility.
AUTH_USER="${BASIC_AUTH_USER:-${BACIC_AUTH_USER:-}}"
AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-${BACIC_AUTH_PASSWORD:-}}"

if [ -n "$AUTH_USER" ] && [ -n "$AUTH_PASSWORD" ]; then
	htpasswd -cb /tmp/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
	chown root:33 /tmp/.htpasswd
	chmod 640 /tmp/.htpasswd
fi

/docker-entrypoint.sh "$@"
