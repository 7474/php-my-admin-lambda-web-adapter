<?php
// for PlanetScale
if (! empty($_ENV['PMA_SSL'])) {
    for ($i = 1; isset($hosts[$i - 1]); $i++) {
        $cfg['Servers'][$i]['ssl_ca'] = '/etc/ssl/certs/ca-certificates.crt';
        $cfg['Servers'][$i]['ssl'] = true;
    }
}

// Redirect phpMyAdmin's temp directory to /tmp (Lambda's root filesystem is
// read-only; the default /var/www/html/tmp/ is not writable at runtime).
$cfg['TempDir'] = '/tmp/phpmyadmin';
