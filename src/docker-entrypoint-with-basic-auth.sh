#!/bin/bash

htpasswd -cb /tmp/.htpasswd "$BACIC_AUTH_USER" "$BACIC_AUTH_PASSWORD"
chmod 600 /tmp/.htpasswd

/docker-entrypoint.sh "$@"
