#!/bin/bash

htpasswd -cb /tmp/.htpasswd "$BACIC_AUTH_USER" "$BACIC_AUTH_PASSWORD"

/docker-entrypoint.sh "$@"
