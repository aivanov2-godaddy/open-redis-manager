<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Builds connection details only for a verified, provisioned cPanel account. */
final class ConnectionDetails
{
    private const CONFIGURED_STATES = ['stopped', 'starting', 'running', 'stopping', 'failed'];

    /**
     * @param null|array{success?:bool,state?:string} $instanceStatus
     * @return null|array{socket_path:string,database:int,authentication:string,php_example:string,node_example:string,python_example:string,wordpress_example:string,litespeed_example:string,laravel_example:string,magento_values:string}
     */
    public static function forAccount(string $username, ?array $instanceStatus): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || ($instanceStatus['success'] ?? false) !== true
            || !in_array($instanceStatus['state'] ?? null, self::CONFIGURED_STATES, true)) {
            return null;
        }

        $socketPath = '/var/lib/orm-instances/' . $username . '/redis.sock';
        $phpExample = "\$redis = new Redis();\n"
            . '$redis->connect(' . var_export($socketPath, true) . ");\n"
            . "\$redis->select(0);\n";
        $nodeExample = "import { createClient } from 'redis';\n"
            . 'const client = createClient({ socket: { path: '
            . json_encode($socketPath, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES)
            . " } });\n"
            . "await client.connect();\n";
        $pythonExample = "import redis\n\n"
            . 'client = redis.Redis(unix_socket_path=' . var_export($socketPath, true) . ", db=0)\n"
            . "client.ping()\n";
        $wordpressExample = "define( 'WP_REDIS_SCHEME', 'unix' );\n"
            . "define( 'WP_REDIS_PATH', " . var_export($socketPath, true) . " );\n"
            . "define( 'WP_REDIS_DATABASE', 0 );\n"
            . "define( 'WP_REDIS_PREFIX', 'replace_with_site_prefix:' );\n";
        $litespeedExample = "Method: Redis\n"
            . 'Host: ' . $socketPath . "\n"
            . "Port: 0\n"
            . "Redis Database ID: 0\n"
            . "Password: leave blank (ORM uses socket permissions)\n";
        $laravelExample = "REDIS_CLIENT=phpredis\n"
            . 'REDIS_HOST=' . $socketPath . "\n"
            . "REDIS_PORT=0\n"
            . "REDIS_DB=0\n";
        $magentoValues = 'server=' . $socketPath . "\n"
            . "port=0\n"
            . "default_cache_database=0\n"
            . "page_cache_database=1 (if enabled)\n"
            . "session_database=2 (if enabled)\n";

        return [
            'socket_path' => $socketPath,
            'database' => 0,
            'authentication' => 'unix_socket_permissions',
            'php_example' => $phpExample,
            'node_example' => $nodeExample,
            'python_example' => $pythonExample,
            'wordpress_example' => $wordpressExample,
            'litespeed_example' => $litespeedExample,
            'laravel_example' => $laravelExample,
            'magento_values' => $magentoValues,
        ];
    }
}
