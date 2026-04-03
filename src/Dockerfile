FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.0 AS lambda-adapter

FROM phpmyadmin/phpmyadmin:5.2.3

COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

COPY config.user.inc.php /etc/phpmyadmin/config.user.inc.php

# Pre-create config.secret.inc.php so the phpmyadmin entrypoint never tries to
# write it at runtime (Lambda's root filesystem is read-only; only /tmp is writable).
# The blowfish secret is read from the PMA_BLOWFISH_SECRET environment variable at
# runtime so it can be rotated without rebuilding the image.
RUN printf '<?php\n$env = getenv("PMA_BLOWFISH_SECRET");\nif ($env !== false && $env !== "") {\n    $cfg["blowfish_secret"] = $env;\n}\n' \
    > /etc/phpmyadmin/config.secret.inc.php \
    && chown root:www-data /etc/phpmyadmin/config.secret.inc.php \
    && chmod 640 /etc/phpmyadmin/config.secret.inc.php

# The phpmyadmin entrypoint calls `chgrp www-data` on config.secret.inc.php
# unconditionally at runtime.  Lambda's root filesystem is read-only, so that
# call always fails.  Remove the line from the entrypoint at build time; the
# file already has the correct group from the chown above.
RUN grep -Fq 'chgrp www-data /etc/phpmyadmin/config.secret.inc.php' /docker-entrypoint.sh \
    && sed -i '/chgrp www-data \/etc\/phpmyadmin\/config\.secret\.inc\.php/d' /docker-entrypoint.sh \
    && ! grep -Fq 'chgrp www-data /etc/phpmyadmin/config.secret.inc.php' /docker-entrypoint.sh

COPY basic-auth.conf /etc/apache2/conf-available/basic-auth.conf
RUN a2enconf basic-auth

# Change Apache listening port from 80 to 8080 for Lambda Web Adapter
RUN sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-enabled/000-default.conf

# Redirect Apache runtime files to /tmp for Lambda's read-only root filesystem.
# /etc/apache2/envvars exports APACHE_PID_FILE and APACHE_LOCK_DIR with plain
# `export VAR=value` (not the `: ${VAR:=default}` guard used for APACHE_RUN_USER/
# GROUP), so Docker ENV cannot override them.  Patch the file at build time.
RUN grep -Eq '^export APACHE_PID_FILE=.*' /etc/apache2/envvars \
    && sed -i 's|^export APACHE_PID_FILE=.*|export APACHE_PID_FILE=/tmp/apache2.pid|' /etc/apache2/envvars \
    && grep -Fxq 'export APACHE_PID_FILE=/tmp/apache2.pid' /etc/apache2/envvars \
    && grep -Eq '^export APACHE_LOCK_DIR=.*' /etc/apache2/envvars \
    && sed -i 's|^export APACHE_LOCK_DIR=.*|export APACHE_LOCK_DIR=/tmp/apache2-locks|' /etc/apache2/envvars \
    && grep -Fxq 'export APACHE_LOCK_DIR=/tmp/apache2-locks' /etc/apache2/envvars

# Set a global ServerName to suppress the "Could not reliably determine the
# server's fully qualified domain name" startup warning.
RUN echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername

# Redirect PHP session storage from /var/lib/php/sessions/ (read-only in Lambda)
# to /tmp.
RUN echo 'session.save_path = /tmp' > /usr/local/etc/php/conf.d/lambda-sessions.ini

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

COPY docker-entrypoint-with-basic-auth.sh /docker-entrypoint-with-basic-auth.sh
RUN chmod +x /docker-entrypoint-with-basic-auth.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint-with-basic-auth.sh"]
CMD ["apache2-foreground"]
