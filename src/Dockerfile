# phpMyAdmin のビルド部分は https://github.com/phpmyadmin/docker/blob/master/apache/Dockerfile をベースにしている。
# 公式イメージ (phpmyadmin/phpmyadmin) は再ビルドが遅れ、脆弱性を含む PHP イメージのまま配布されることがあるため、
# PHP 公式イメージから直接ビルドする。
# phpMyAdmin 5.2.x のサポート対象は PHP < 8.4 のため 8.3 系を使う。
# https://www.phpmyadmin.net/downloads/
FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 AS lambda-adapter

FROM php:8.3-apache

ENV UPLOAD_PROGRESS_EXT_URL="https://github.com/php/pecl-php-uploadprogress/archive/refs/tags/uploadprogress-2.0.2.tar.gz"
ENV UPLOAD_PROGRESS_SHA256="fe3f6cdfcedad563c970c4fd1cda31e422cfc0df5cc9a217d8c80ed3c8d137f5"

# Install dependencies
RUN set -ex; \
    \
    apt-get update; \
    # ベースイメージの再ビルドを待たずに Debian のセキュリティ更新を取り込む
    apt-get upgrade -y --no-install-recommends; \
    apt-get install -y --no-install-recommends \
        gnupg \
        dirmngr \
    ; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get install -y --no-install-recommends \
        libbz2-dev \
        libfreetype6-dev \
        libjpeg-dev \
        libpng-dev \
        libwebp-dev \
        libxpm-dev \
        libzip-dev \
    ; \
    \
    mkdir -p /tmp/uploadprogress; \
    curl -fsSL -o /tmp/uploadprogress/uploadprogress.tar.gz "$UPLOAD_PROGRESS_EXT_URL"; \
    echo "$UPLOAD_PROGRESS_SHA256 /tmp/uploadprogress/uploadprogress.tar.gz" | sha256sum -c -; \
    tar -xf /tmp/uploadprogress/uploadprogress.tar.gz -C /tmp/uploadprogress --strip-components=1; \
    \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-xpm; \
    docker-php-ext-install -j "$(nproc)" \
        bz2 \
        gd \
        mysqli \
        opcache \
        zip \
        bcmath \
        /tmp/uploadprogress \
    ; \
    \
    rm -r /tmp/uploadprogress; \
    \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    extdir="$(php -r 'echo ini_get("extension_dir");')"; \
    ldd "$extdir"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u \
        | xargs -r dpkg-query -S \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    \
    a2enmod remoteip; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    ldd "$extdir"/*.so | grep -qzv "=> not found" || (echo "Sanity check failed: missing libraries:"; ldd "$extdir"/*.so | grep " => not found"; exit 1); \
    ldd "$extdir"/*.so | grep -q "libzip.so.* => .*/libzip.so.*" || (echo "Sanity check failed: libzip.so is not referenced"; ldd "$extdir"/*.so; exit 1); \
    err="$(php --version 3>&1 1>&2 2>&3)"; \
    [ -z "$err" ] || (echo "Sanity check failed: php returned errors; $err"; exit 1;);

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
ENV PMA_SSL_DIR=/etc/phpmyadmin/ssl
ENV MAX_EXECUTION_TIME=600
ENV MEMORY_LIMIT=512M
ENV UPLOAD_LIMIT=2048K
ENV TZ=UTC
ENV SESSION_SAVE_PATH=/sessions
RUN set -ex; \
    mkdir $SESSION_SAVE_PATH; \
    mkdir -p $PMA_SSL_DIR; \
    chmod 1777 $SESSION_SAVE_PATH; \
    chmod 755 $PMA_SSL_DIR; \
    chown www-data:www-data /etc/phpmyadmin; \
    chown www-data:www-data $PMA_SSL_DIR; \
    chown www-data:www-data $SESSION_SAVE_PATH; \
    \
    { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
        echo 'opcache.fast_shutdown=1'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini; \
    \
    { \
        echo 'session.cookie_httponly=1'; \
        echo 'session.use_strict_mode=1'; \
    } > $PHP_INI_DIR/conf.d/session-strict.ini; \
    \
    { \
        echo 'allow_url_fopen=Off'; \
        echo 'max_execution_time=${MAX_EXECUTION_TIME}'; \
        echo 'max_input_vars=10000'; \
        echo 'memory_limit=${MEMORY_LIMIT}'; \
        echo 'post_max_size=${UPLOAD_LIMIT}'; \
        echo 'upload_max_filesize=${UPLOAD_LIMIT}'; \
        echo 'date.timezone=${TZ}'; \
        echo 'session.save_path=${SESSION_SAVE_PATH}'; \
    } > $PHP_INI_DIR/conf.d/phpmyadmin-misc.ini

USER www-data:www-data

# Calculate download URL
ENV VERSION=5.2.3
ENV SHA256=57881348297c4412f86c410547cf76b4d8a236574dd2c6b7d6a2beebe7fc44e3
ENV URL=https://files.phpmyadmin.net/phpMyAdmin/${VERSION}/phpMyAdmin-${VERSION}-all-languages.tar.xz

LABEL org.opencontainers.image.title="phpMyAdmin for AWS Lambda Web Adapter" \
    org.opencontainers.image.description="phpMyAdmin (Apache) image for AWS Lambda Web Adapter." \
    org.opencontainers.image.documentation="https://github.com/7474/php-my-admin-lambda-web-adapter#readme" \
    org.opencontainers.image.version="${VERSION}" \
    org.opencontainers.image.url="https://github.com/7474/php-my-admin-lambda-web-adapter#readme" \
    org.opencontainers.image.source="https://github.com/7474/php-my-admin-lambda-web-adapter.git"

# Download tarball, verify it using gpg and extract
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    export GPGKEY="3D06A59ECE730EB71B511C17CE752F178259BD92"; \
    curl -fsSL -o phpMyAdmin.tar.xz $URL; \
    curl -fsSL -o phpMyAdmin.tar.xz.asc $URL.asc; \
    echo "$SHA256 *phpMyAdmin.tar.xz" | sha256sum -c -; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$GPGKEY" \
        || gpg --batch --keyserver pgp.mit.edu --recv-keys "$GPGKEY" \
        || gpg --batch --keyserver keyserver.pgp.com --recv-keys "$GPGKEY" \
        || gpg --batch --keyserver keys.openpgp.org --recv-keys "$GPGKEY"; \
    gpg --batch --verify phpMyAdmin.tar.xz.asc phpMyAdmin.tar.xz; \
    tar -xf phpMyAdmin.tar.xz -C /var/www/html --strip-components=1; \
    mkdir -p /var/www/html/tmp; \
    gpgconf --kill all; \
    rm -r "$GNUPGHOME" phpMyAdmin.tar.xz phpMyAdmin.tar.xz.asc; \
    rm -r -v /var/www/html/setup/ /var/www/html/examples/ /var/www/html/js/src/ /var/www/html/babel.config.json /var/www/html/doc/html/_sources/ /var/www/html/RELEASE-DATE-$VERSION /var/www/html/CONTRIBUTING.md; \
    grep -q -F "'configFile' => ROOT_PATH . 'config.inc.php'," /var/www/html/libraries/vendor_config.php; \
    sed -i "s@'configFile' => .*@'configFile' => '/etc/phpmyadmin/config.inc.php',@" /var/www/html/libraries/vendor_config.php; \
    grep -q -F "'configFile' => '/etc/phpmyadmin/config.inc.php'," /var/www/html/libraries/vendor_config.php; \
    php -l /var/www/html/libraries/vendor_config.php; \
    find /var/www/html -type d -exec chmod 555 {} \;; \
    find /var/www/html -type f -exec chmod 444 {} \;; \
    chmod 1777 /var/www/html/tmp;

# Copy configuration
COPY --chown=www-data:www-data config.inc.php /etc/phpmyadmin/config.inc.php
COPY --chown=www-data:www-data helpers.php /etc/phpmyadmin/helpers.php

USER root

# Lambda Web Adapter
COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

# Ensure config.user.inc.php is readable by www-data. Permissions: 644 (world readable).
COPY config.user.inc.php /etc/phpmyadmin/config.user.inc.php
RUN chmod 644 /etc/phpmyadmin/config.user.inc.php
COPY cookie-session-handler.php /etc/phpmyadmin/cookie-session-handler.php

# Use our own copy of the upstream entrypoint that omits the unconditional
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

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
