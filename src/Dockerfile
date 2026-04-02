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

COPY basic-auth.conf /etc/apache2/conf-available/basic-auth.conf
RUN a2enconf basic-auth

# Change Apache listening port from 80 to 8080 for Lambda Web Adapter
RUN sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-enabled/000-default.conf

# Ensure the www-data user and group entries exist so Apache can drop privileges
# correctly, even in environments where name lookups may be unusual (e.g. Lambda).
RUN if ! getent group www-data > /dev/null; then \
        echo 'www-data:x:33:' >> /etc/group; \
    fi \
    && if ! getent passwd www-data > /dev/null; then \
        echo 'www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin' >> /etc/passwd; \
    fi

COPY docker-entrypoint-with-basic-auth.sh /docker-entrypoint-with-basic-auth.sh
RUN chmod +x /docker-entrypoint-with-basic-auth.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint-with-basic-auth.sh"]
CMD ["apache2-foreground"]
