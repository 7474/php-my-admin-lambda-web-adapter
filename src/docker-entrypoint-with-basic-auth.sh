#!/bin/bash

# Create runtime directories under /tmp that Apache and phpMyAdmin need.
# Lambda mounts a fresh writable /tmp on every cold start, so directories
# baked into the image layer are not present at runtime.
mkdir -p /tmp/apache2-locks /tmp/phpmyadmin
chown -R 33:33 /tmp/apache2-locks /tmp/phpmyadmin
chmod 700 /tmp/apache2-locks /tmp/phpmyadmin

htpasswd -cb /tmp/.htpasswd "$BACIC_AUTH_USER" "$BACIC_AUTH_PASSWORD"
chmod 600 /tmp/.htpasswd

/docker-entrypoint.sh "$@"
