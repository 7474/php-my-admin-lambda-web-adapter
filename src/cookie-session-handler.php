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

// Defense in depth for direct Function URL access: when a secret is configured,
// reject requests that do not carry the exact X-Origin-Verify header value.
$_originVerifySecret = getenv('CLOUDFRONT_ORIGIN_SECRET') ?: '';
if (PHP_SAPI !== 'cli' && $_originVerifySecret !== '') {
    $providedOriginVerify = $_SERVER['HTTP_X_ORIGIN_VERIFY'] ?? '';
    if (!hash_equals($_originVerifySecret, $providedOriginVerify)) {
        http_response_code(403);
        header('Content-Type: text/plain; charset=UTF-8');
        echo "Forbidden\n";
        exit;
    }
}
unset($_originVerifySecret, $providedOriginVerify);

class CookieSessionHandler implements SessionHandlerInterface
{
    private const CIPHER      = 'aes-256-cbc';
    private const COOKIE_NAME = 'PMA_SESS';

    /** @var string 32-byte binary key derived from the secret */
    private string $key;

    /**
     * Flag set by destroy() and cleared by write().  When close() is called
     * with this flag still set it means the session was truly destroyed (e.g.
     * logout) rather than regenerated, so the cookie must be deleted.
     *
     * Without this mechanism, session_regenerate_id(true) causes destroy() to
     * emit a deletion Set-Cookie *before* the final write() for the new
     * session, leaving the browser with PMA_SESS=deleted and no session data.
     */
    private bool $pendingDestroy = false;

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
        if ($this->pendingDestroy) {
            $this->pendingDestroy = false;

            $secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
                   || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');

            setcookie(self::COOKIE_NAME, '', [
                'expires'  => time() - 3600,
                'path'     => '/',
                'secure'   => $secure,
                'httponly'  => true,
                'samesite'  => 'Strict',
            ]);
        }
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
        // A write() after destroy() means session_regenerate_id(true) — the
        // session was not truly destroyed, so cancel the pending deletion.
        $this->pendingDestroy = false;

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
        // Do not emit the deletion cookie immediately.  If this destroy() is
        // part of session_regenerate_id(true), a subsequent write() for the
        // new session will clear the flag and the cookie will be overwritten
        // with the new session data instead.  If this is a genuine
        // session_destroy() (e.g. logout), close() will see the flag and
        // emit the deletion cookie at that point.
        $this->pendingDestroy = true;
        unset($_COOKIE[self::COOKIE_NAME]);
        return true;
    }
}

$_cookieSessionSecret = getenv('PMA_BLOWFISH_SECRET') ?: (getenv('SESSION_SECRET') ?: '');
if ($_cookieSessionSecret !== '') {
    session_set_save_handler(new CookieSessionHandler($_cookieSessionSecret), true);
}
unset($_cookieSessionSecret);
