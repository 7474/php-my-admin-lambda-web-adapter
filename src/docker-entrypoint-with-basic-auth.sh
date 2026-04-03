#!/bin/bash

set -eu

# Create runtime directories under /tmp that Apache and phpMyAdmin need.
# Lambda mounts a fresh writable /tmp on every cold start, so directories
# baked into the image layer are not present at runtime.
mkdir -p /tmp/apache2-locks /tmp/phpmyadmin

CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"

if [ "$CURRENT_UID" = "0" ]; then
    # Running as root: set ownership to www-data (uid/gid 33) so Apache
    # worker processes can access them.
    chown 33:33 /tmp/apache2-locks /tmp/phpmyadmin
else
    # Running as non-root (Lambda may run containers without root).
    # Override Apache's run user to match the current UID/GID so it can
    # access the directories it created.
    export APACHE_RUN_USER="#${CURRENT_UID}"
    export APACHE_RUN_GROUP="#${CURRENT_GID}"
fi
chmod 700 /tmp/apache2-locks /tmp/phpmyadmin

# Prefer correctly named BASIC_AUTH_* vars; keep BACIC_AUTH_* for compatibility.
AUTH_USER="${BASIC_AUTH_USER:-${BACIC_AUTH_USER:-}}"
AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-${BACIC_AUTH_PASSWORD:-}}"

if [ -n "$AUTH_USER" ] && [ -n "$AUTH_PASSWORD" ]; then
    htpasswd -cb /tmp/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
    if [ "$CURRENT_UID" = "0" ]; then
        chown root:33 /tmp/.htpasswd
    fi
    chmod 640 /tmp/.htpasswd
fi

/docker-entrypoint.sh "$@"
