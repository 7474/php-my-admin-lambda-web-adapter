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

    /** Encrypted payload staged by write(), emitted by close(). */
    private ?string $deferredPayload = null;

    /** True when destroy() was called and no subsequent write() overrode it. */
    private bool $shouldDelete = false;

    public function __construct(string $secret)
    {
        // Derive a fixed 32-byte key regardless of secret length.
        $this->key = hash('sha256', $secret, true);
    }

    public function open(string $savePath, string $sessionName): bool
    {
        return true;
    }

    /**
     * Emit the final PMA_SESS cookie for this session lifecycle.
     *
     * phpMyAdmin may open/close/destroy sessions multiple times in a single
     * request (e.g. session_write_close → session_start → session_destroy →
     * session_start).  Each cycle produces a close() call.  By deferring all
     * setcookie() calls to close() and removing stale PMA_SESS headers from
     * earlier cycles, we guarantee the browser sees exactly ONE PMA_SESS
     * Set-Cookie directive — the one from the *last* cycle.
     */
    public function close(): bool
    {
        $secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
               || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');

        if ($this->deferredPayload !== null) {
            // write() was the last operation — emit the session data cookie.
            $this->removeStaleCookieHeaders();
            setcookie(self::COOKIE_NAME, $this->deferredPayload, [
                'expires'  => 0,
                'path'     => '/',
                'secure'   => $secure,
                'httponly'  => true,
                'samesite' => 'Strict',
            ]);
            $this->deferredPayload = null;
            $this->shouldDelete    = false;
        } elseif ($this->shouldDelete) {
            // destroy() was the last operation (genuine session_destroy, not
            // session_regenerate_id) — delete the cookie.
            $this->removeStaleCookieHeaders();
            setcookie(self::COOKIE_NAME, '', [
                'expires'  => time() - 3600,
                'path'     => '/',
                'secure'   => $secure,
                'httponly'  => true,
                'samesite' => 'Strict',
            ]);
            $this->shouldDelete = false;
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
        $ivLen = openssl_cipher_iv_length(self::CIPHER);
        $iv    = random_bytes($ivLen);

        $encrypted = openssl_encrypt($data, self::CIPHER, $this->key, OPENSSL_RAW_DATA, $iv);
        if ($encrypted === false) {
            return false;
        }

        $hmac    = hash_hmac('sha256', $encrypted, $this->key, true);
        $payload = base64_encode($iv . $hmac . $encrypted);

        // Stage the cookie — don't call setcookie() here.  close() will emit
        // it and clean up any stale PMA_SESS headers from earlier cycles.
        $this->deferredPayload = $payload;
        $this->shouldDelete    = false;

        // Keep $_COOKIE in sync so that read() works correctly if the session
        // is closed and re-opened within the same request (e.g. phpMyAdmin's
        // session round-trip test in Session::setUp).
        $_COOKIE[self::COOKIE_NAME] = $payload;

        return true;
    }

    public function destroy(string $id): bool
    {
        $this->deferredPayload = null;
        $this->shouldDelete    = true;
        unset($_COOKIE[self::COOKIE_NAME]);
        return true;
    }

    /**
     * Remove any previously emitted Set-Cookie headers for PMA_SESS.
     *
     * PHP cannot remove a single Set-Cookie by name, so we remove ALL
     * Set-Cookie headers and re-add the ones that do not belong to PMA_SESS.
     */
    private function removeStaleCookieHeaders(): void
    {
        if (headers_sent()) {
            return;
        }

        $keep  = [];
        $found = false;

        foreach (headers_list() as $header) {
            if (stripos($header, 'Set-Cookie:') !== 0) {
                continue; // not a Set-Cookie header
            }
            if (strpos($header, self::COOKIE_NAME . '=') !== false) {
                $found = true; // stale PMA_SESS — will be dropped
            } else {
                $keep[] = $header; // preserve other cookies
            }
        }

        if (!$found) {
            return;
        }

        header_remove('Set-Cookie');

        foreach ($keep as $h) {
            header($h, false);
        }
    }
}

$_cookieSessionSecret = getenv('PMA_BLOWFISH_SECRET') ?: (getenv('SESSION_SECRET') ?: '');
if ($_cookieSessionSecret !== '') {
    session_set_save_handler(new CookieSessionHandler($_cookieSessionSecret), true);
}
unset($_cookieSessionSecret);
