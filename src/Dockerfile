FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.0 AS lambda-adapter

FROM phpmyadmin/phpmyadmin:5.2.3

COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

COPY config.user.inc.php /etc/phpmyadmin/config.user.inc.php

# Pre-create config.secret.inc.php so the phpmyadmin entrypoint never tries to
# write it at runtime (Lambda's root filesystem is read-only; only /tmp is writable)
RUN printf '<?php\n$cfg["blowfish_secret"] = "%s";\n' "$(openssl rand -base64 32)" \
    > /etc/phpmyadmin/config.secret.inc.php \
    && chown root:root /etc/phpmyadmin/config.secret.inc.php \
    && chmod 640 /etc/phpmyadmin/config.secret.inc.php

COPY basic-auth.conf /etc/apache2/conf-available/basic-auth.conf
RUN a2enconf basic-auth

# Change Apache listening port from 80 to 8080 for Lambda Web Adapter
RUN sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf \
    && sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8080>/' /etc/apache2/sites-enabled/000-default.conf

# Run Apache as root to avoid "AH00543: bad user name www-data" in Lambda's
# execution environment where named-user lookups are not always available
RUN sed -i 's/export APACHE_RUN_USER=www-data/export APACHE_RUN_USER=root/' /etc/apache2/envvars \
    && sed -i 's/export APACHE_RUN_GROUP=www-data/export APACHE_RUN_GROUP=root/' /etc/apache2/envvars

COPY docker-entrypoint-with-basic-auth.sh /docker-entrypoint-with-basic-auth.sh
RUN chmod +x /docker-entrypoint-with-basic-auth.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/docker-entrypoint-with-basic-auth.sh"]
CMD ["apache2-foreground"]
