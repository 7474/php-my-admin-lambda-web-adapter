<?php
/**
 * Cookie-based PHP session handler for stateless environments (AWS Lambda).
 *
 * Session data is AES-256-CBC encrypted and HMAC-SHA256 authenticated (Encrypt-
 * then-MAC), then stored as a single HttpOnly, SameSite=Strict cookie.  Because
 * no server-side storage is involved, sessions survive Lambda cold starts and
 * work correctly across multiple concurrent Lambda instances.
 *
 * Registered via PHP auto_prepend_file so the handler is in place before
 * phpMyAdmin calls session_start().
 *
 * Required env var: PMA_BLOWFISH_SECRET (or SESSION_SECRET as a fallback).
 * If neither is set the handler is not registered and PHP falls back to the
 * filesystem path configured by session.save_path.
 */

class CookieSessionHandler implements SessionHandlerInterface
{
    private const CIPHER      = 'aes-256-cbc';
    private const COOKIE_NAME = 'PMA_SESS';

    /** @var string 32-byte binary key derived from the secret */
    private string $key;

    public function __construct(string $secret)
    {
        // Derive a fixed 32-byte key regardless of secret length.
        $this->key = hash('sha256', $secret, true);
    }

    public function open(string $savePath, string $sessionName): bool
    {
        return true;
    }

    public function close(): bool
    {
        return true;
    }

    public function gc(int $max_lifetime): int|false
    {
        // No server-side storage; nothing to garbage-collect.
        return 0;
    }

    public function read(string $id): string|false
    {
        $raw = $_COOKIE[self::COOKIE_NAME] ?? '';
        if ($raw === '') {
            return '';
        }

        $data = base64_decode($raw, true);
        if ($data === false) {
            return '';
        }

        $ivLen = openssl_cipher_iv_length(self::CIPHER);
        // Layout: [ IV (ivLen bytes) | HMAC (32 bytes) | ciphertext ]
        if (strlen($data) < $ivLen + 32) {
            return '';
        }

        $iv        = substr($data, 0, $ivLen);
        $hmac      = substr($data, $ivLen, 32);
        $encrypted = substr($data, $ivLen + 32);

        // Verify integrity before decrypting.
        $expected = hash_hmac('sha256', $encrypted, $this->key, true);
        if (!hash_equals($expected, $hmac)) {
            return '';
        }

        $plain = openssl_decrypt($encrypted, self::CIPHER, $this->key, OPENSSL_RAW_DATA, $iv);
        return $plain !== false ? $plain : '';
    }

    public function write(string $id, string $data): bool
    {
        $ivLen = openssl_cipher_iv_length(self::CIPHER);
        $iv    = random_bytes($ivLen);

        $encrypted = openssl_encrypt($data, self::CIPHER, $this->key, OPENSSL_RAW_DATA, $iv);
        if ($encrypted === false) {
            return false;
        }

        $hmac    = hash_hmac('sha256', $encrypted, $this->key, true);
        $payload = base64_encode($iv . $hmac . $encrypted);

        // Treat the connection as HTTPS when behind CloudFront / API Gateway
        // (X-Forwarded-Proto) even if $_SERVER['HTTPS'] is not set.
        $secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
               || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');

        setcookie(self::COOKIE_NAME, $payload, [
            'expires'  => 0,          // session cookie (cleared when browser closes)
            'path'     => '/',
            'secure'   => $secure,
            'httponly' => true,
            'samesite' => 'Strict',
        ]);

        // Keep $_COOKIE in sync so that read() works correctly if the session
        // is closed and re-opened within the same request (e.g. phpMyAdmin's
        // session round-trip test in Session::setUp).
        $_COOKIE[self::COOKIE_NAME] = $payload;

        return true;
    }

    public function destroy(string $id): bool
    {
        setcookie(self::COOKIE_NAME, '', [
            'expires'  => time() - 3600,
            'path'     => '/',
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
        unset($_COOKIE[self::COOKIE_NAME]);
        return true;
    }
}

$_cookieSessionSecret = getenv('PMA_BLOWFISH_SECRET') ?: (getenv('SESSION_SECRET') ?: '');
if ($_cookieSessionSecret !== '') {
    session_set_save_handler(new CookieSessionHandler($_cookieSessionSecret), true);
}
unset($_cookieSessionSecret);
