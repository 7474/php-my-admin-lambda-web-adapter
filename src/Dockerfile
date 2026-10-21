ARG BASE_IMAGE=phpmyadmin/phpmyadmin:5.2.3

FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 AS lambda-adapter

FROM ${BASE_IMAGE}

COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

# Ensure config.user.inc.php is readable by www-data. Permissions: 644 (world readable).
COPY config.user.inc.php /etc/phpmyadmin/config.user.inc.php
RUN chmod 644 /etc/phpmyadmin/config.user.inc.php
COPY cookie-session-handler.php /etc/phpmyadmin/cookie-session-handler.php

# Replace the upstream entrypoint with our own copy that omits the unconditional
# `chgrp www-data /etc/phpmyadmin/config.secret.inc.php` call.  Lambda mounts
# image layers as a read-only filesystem, so that chgrp always fails at runtime.
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Pre-create config.secret.inc.php so our entrypoint's `if [ ! -f ... ]` guard
# skips the creation step (which would also fail on Lambda's read-only filesystem).
# The blowfish secret is read from the PMA_BLOWFISH_SECRET environment variable at
# runtime so it can be rotated without rebuilding the image.
# Permissions: 644 (world readable). Lambda may execute the container under a
# runtime UID/GID that is not in www-data, so group-only readability is brittle.
# This file contains only logic that reads PMA_BLOWFISH_SECRET from env at
# runtime; it does not embed any static secret value.
RUN printf '<?php\n$env = getenv("PMA_BLOWFISH_SECRET");\nif ($env !== false && $env !== "") {\n    $cfg["blowfish_secret"] = $env;\n}\n' \
    > /etc/phpmyadmin/config.secret.inc.php \
    && chown root:www-data /etc/phpmyadmin/config.secret.inc.php \
    && chmod 644 /etc/phpmyadmin/config.secret.inc.php

# Change Apache listening port from 80 to 8080 for Lambda Web Adapter
RUN sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-enabled/000-default.conf

# Redirect Apache runtime files to /tmp for Lambda's read-only root filesystem.
# Base image variants may or may not predefine these variables in envvars.
# Replace existing lines when present, otherwise append them.
RUN if grep -Eq '^export APACHE_PID_FILE=' /etc/apache2/envvars; then \
        sed -i 's|^export APACHE_PID_FILE=.*|export APACHE_PID_FILE=/tmp/apache2.pid|' /etc/apache2/envvars; \
    else \
        printf '\nexport APACHE_PID_FILE=/tmp/apache2.pid\n' >> /etc/apache2/envvars; \
    fi \
    && if grep -Eq '^export APACHE_LOCK_DIR=' /etc/apache2/envvars; then \
        sed -i 's|^export APACHE_LOCK_DIR=.*|export APACHE_LOCK_DIR=/tmp/apache2-locks|' /etc/apache2/envvars; \
    else \
        printf 'export APACHE_LOCK_DIR=/tmp/apache2-locks\n' >> /etc/apache2/envvars; \
    fi \
    && grep -Fxq 'export APACHE_PID_FILE=/tmp/apache2.pid' /etc/apache2/envvars \
    && grep -Fxq 'export APACHE_LOCK_DIR=/tmp/apache2-locks' /etc/apache2/envvars

# Set a global ServerName to suppress the "Could not reliably determine the
# server's fully qualified domain name" startup warning.
RUN echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername

# Override PHP session settings. z- prefix ensures this ini loads after
# phpmyadmin-misc.ini, overriding its SESSION_SAVE_PATH.
# auto_prepend_file registers the cookie-based session handler before phpMyAdmin
# calls session_start(), making sessions stateless across Lambda instances.
# session.save_path is kept as a fallback when PMA_BLOWFISH_SECRET is not set.
RUN printf 'session.save_path = /tmp\nauto_prepend_file = /etc/phpmyadmin/cookie-session-handler.php\n' \
    > /usr/local/etc/php/conf.d/z-lambda-sessions.ini

# Use numeric UID/GID for Apache's worker process instead of the name "www-data".
# In some Lambda execution environments getpwnam("www-data") returns NULL, which
# causes Apache to abort with AH00543 ("bad user name www-data").
# /etc/apache2/envvars uses `: ${APACHE_RUN_USER:=www-data}` (POSIX := expansion),
# so pre-setting these environment variables takes precedence over the default.
ENV APACHE_RUN_USER=#33 \
    APACHE_RUN_GROUP=#33

# Apache no longer needs the www-data name for its own privilege drop because it
# now runs as numeric UID/GID 33. Keep the passwd/group entries anyway for
# compatibility with scripts, tools, and ownership metadata in the base image
# that may still refer to www-data by name.
RUN if ! getent group www-data > /dev/null; then \
        groupadd --gid 33 www-data; \
    fi \
    && if ! getent passwd www-data > /dev/null; then \
        useradd --uid 33 --gid 33 --home-dir /var/www --shell /usr/sbin/nologin www-data; \
    fi

ENV PORT=8080
EXPOSE 8080

CMD ["apache2-foreground"]
