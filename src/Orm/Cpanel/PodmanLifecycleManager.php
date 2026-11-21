<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Inspects EA Podman setup and manages existing Redis/Valkey containers for their owners. */
final class PodmanLifecycleManager
{
    private const SCRIPT = '/usr/local/cpanel/scripts/ea-podman';
    private const TIMEOUT_SECONDS = 30;
    private const SETUP_CHECK_TIMEOUT_SECONDS = 4;
    private const MAX_SETUP_OUTPUT_BYTES = 8192;

    /**
     * Inspect the fixed EA4 package inventory from the authenticated account context.
     * The command is read-only; package installation is left to the account's normal
     * cPanel Terminal/SSH session so a web request never waits for an image pull.
     *
     * @return array{status:string,redis:?string,valkey:?string,host_platform:string}
     */
    public static function inspectSetup(
        string $username,
        ?callable $runner = null,
        ?callable $identityResolver = null,
        ?callable $scriptResolver = null,
        ?callable $platformResolver = null
    ): array {
        $unknown = ['status' => 'unavailable', 'redis' => null, 'valkey' => null, 'host_platform' => 'unknown'];
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1) {
            return ['status' => 'identity-unverified', 'redis' => null, 'valkey' => null, 'host_platform' => 'unknown'];
        }
        $identityResolver ??= static function (string $expected): ?array {
            if (!function_exists('posix_geteuid') || !function_exists('posix_getpwuid')) {
                return null;
            }
            $record = posix_getpwuid(posix_geteuid());
            if (!is_array($record) || ($record['name'] ?? null) !== $expected
                || !is_string($record['dir'] ?? null) || !is_string($record['shell'] ?? null)) {
                return null;
            }
            return ['home' => $record['dir'], 'shell' => $record['shell']];
        };
        try {
            $identity = $identityResolver($username);
        } catch (\Throwable) {
            return ['status' => 'identity-unverified', 'redis' => null, 'valkey' => null, 'host_platform' => 'unknown'];
        }
        if (!is_array($identity) || !is_string($identity['home'] ?? null)
            || !is_string($identity['shell'] ?? null)) {
            return ['status' => 'identity-unverified', 'redis' => null, 'valkey' => null, 'host_platform' => 'unknown'];
        }
        try {
            $hostPlatform = $platformResolver !== null ? $platformResolver() : self::hostPlatform();
        } catch (\Throwable) {
            $hostPlatform = 'unknown';
        }
        if (!in_array($hostPlatform, ['almalinux', 'rocky', 'ubuntu', 'cloudlinux', 'unsupported', 'unknown'], true)) {
            $hostPlatform = 'unknown';
        }
        $platformLabel = match ($hostPlatform) {
            'almalinux' => 'AlmaLinux',
            'rocky' => 'Rocky Linux',
            'ubuntu' => 'Ubuntu',
            'cloudlinux' => 'CloudLinux',
            'unsupported' => 'unsupported',
            default => 'unknown',
        };
        $setupResult = static fn (string $status, ?string $redis, ?string $valkey): array => [
            'status' => $status, 'redis' => $redis, 'valkey' => $valkey, 'host_platform' => $platformLabel,
        ];
        if (in_array($hostPlatform, ['cloudlinux', 'unsupported'], true)) {
            return $setupResult('unsupported-host', null, null);
        }
        $shell = $identity['shell'];
        $allowedShells = @file('/etc/shells', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!is_array($allowedShells) || !in_array($shell, $allowedShells, true)
            || preg_match('~/(?:nologin|false|jailshell)\z~i', $shell) === 1) {
            return $setupResult('unsupported-shell', null, null);
        }
        try {
            $script = $scriptResolver !== null ? $scriptResolver() : self::trustedEaPodmanScript();
        } catch (\Throwable) {
            $script = null;
        }
        if (!is_string($script) || $script === '') {
            return $setupResult('ea-podman-unavailable', null, null);
        }
        $env = [
            'HOME' => $identity['home'], 'USER' => $username, 'LOGNAME' => $username,
            'SHELL' => $shell, 'PATH' => '/usr/local/bin:/usr/bin:/bin', 'LANG' => 'C', 'LC_ALL' => 'C',
        ];
        $runner ??= [self::class, 'runSetupInventory'];
        try {
            $result = $runner([$script, 'avail'], $env, self::SETUP_CHECK_TIMEOUT_SECONDS);
        } catch (\Throwable) {
            return $setupResult($unknown['status'], null, null);
        }
        if (!is_array($result) || ($result['timeout'] ?? false) === true) {
            return $setupResult('timeout', null, null);
        }
        if (($result['exit_code'] ?? null) !== 0 || !is_string($result['stdout'] ?? null)) {
            return $setupResult($unknown['status'], null, null);
        }
        $inventory = $result['stdout'];
        $hasPackageEntry = preg_match('/\bea-(?:redis62|valkey72)\b/i', $inventory) === 1;
        if (!$hasPackageEntry) {
            return $setupResult('inventory-unrecognized', null, null);
        }
        $redis = preg_match('/\bea-redis62\b/i', $inventory) === 1 ? 'available' : 'not-listed';
        $valkey = preg_match('/\bea-valkey72\b/i', $inventory) === 1 ? 'available' : 'not-listed';
        return $setupResult('checked', $redis, $valkey);
    }

    private static function hostPlatform(): string
    {
        if (PHP_OS_FAMILY !== 'Linux' || !is_readable('/etc/os-release')) {
            return 'unknown';
        }
        $contents = @file_get_contents('/etc/os-release', false, null, 0, 16384);
        if (!is_string($contents)) {
            return 'unknown';
        }
        foreach (preg_split('/\r?\n/', $contents) ?: [] as $line) {
            if (preg_match('/\AID=(?:"([^"]*)"|\'([^\']*)\'|([^\s#]+))\z/', trim($line), $matches) !== 1) {
                continue;
            }
            $id = strtolower($matches[1] !== '' ? $matches[1] : ($matches[2] !== '' ? $matches[2] : $matches[3]));
            return match ($id) {
                'almalinux' => 'almalinux',
                'rocky' => 'rocky',
                'ubuntu' => 'ubuntu',
                'cloudlinux' => 'cloudlinux',
                default => 'unsupported',
            };
        }
        return 'unknown';
    }

    /** @param list<string> $argv @param array<string,string> $env @return array{exit_code:?int,timeout:bool,stdout:string} */
    public static function runSetupInventory(array $argv, array $env, int $timeout): array
    {
        if (!function_exists('proc_open') || count($argv) !== 2 || $argv[1] !== 'avail'
            || !is_string($argv[0] ?? null) || self::trustedEaPodmanScript() !== $argv[0]) {
            return ['exit_code' => null, 'timeout' => false, 'stdout' => ''];
        }
        $process = @proc_open($argv, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);
        if (!is_resource($process)) {
            return ['exit_code' => null, 'timeout' => false, 'stdout' => ''];
        }
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $stdout = '';
        $totalBytes = 0;
        $deadline = microtime(true) + min(max(1, $timeout), self::SETUP_CHECK_TIMEOUT_SECONDS);
        $timedOut = false;
        $observedExitCode = null;
        do {
            foreach ([1, 2] as $index) {
                $remaining = self::MAX_SETUP_OUTPUT_BYTES - $totalBytes;
                $chunk = (string)stream_get_contents($pipes[$index], max(1, $remaining + 1));
                $totalBytes += strlen($chunk);
                if ($index === 1 && strlen($stdout) < self::MAX_SETUP_OUTPUT_BYTES) {
                    $stdout .= substr($chunk, 0, self::MAX_SETUP_OUTPUT_BYTES - strlen($stdout));
                }
            }
            $status = proc_get_status($process);
            if (!$status['running']) {
                $observedExitCode = is_int($status['exitcode'] ?? null) && $status['exitcode'] >= 0
                    ? $status['exitcode'] : null;
                break;
            }
            if (microtime(true) >= $deadline || $totalBytes > self::MAX_SETUP_OUTPUT_BYTES) {
                $timedOut = microtime(true) >= $deadline;
                proc_terminate($process);
                usleep(100000);
                if ((proc_get_status($process)['running'] ?? false) === true) {
                    proc_terminate($process, 9);
                }
                break;
            }
            usleep(50000);
        } while (true);
        stream_get_contents($pipes[1]);
        stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $closedExitCode = proc_close($process);
        return [
            'exit_code' => $timedOut ? null : ($observedExitCode ?? ($closedExitCode >= 0 ? $closedExitCode : null)),
            'timeout' => $timedOut,
            'stdout' => $stdout,
        ];
    }

    /** @return array{success:bool,reason:string} */
    public static function manage(
        string $username,
        string $container,
        string $action,
        ?callable $runner = null,
        ?callable $identityResolver = null
    ): array {
        if (!in_array($action, ['start', 'stop', 'restart'], true)) {
            return ['success' => false, 'reason' => 'invalid'];
        }
        $identityResolver ??= static function (string $expected): ?array {
            if (!function_exists('posix_geteuid') || !function_exists('posix_getpwuid')) {
                return null;
            }
            $uid = posix_geteuid();
            $record = posix_getpwuid($uid);
            if (!is_array($record) || ($record['name'] ?? null) !== $expected
                || !is_string($record['dir'] ?? null) || !is_string($record['shell'] ?? null)) {
                return null;
            }
            return ['uid' => $uid, 'home' => $record['dir'], 'shell' => $record['shell']];
        };
        $identity = $identityResolver($username);
        if (!is_array($identity) || !is_int($identity['uid'] ?? null)
            || !is_string($identity['home'] ?? null) || !is_string($identity['shell'] ?? null)) {
            return ['success' => false, 'reason' => 'identity'];
        }
        $shell = $identity['shell'];
        $allowedShells = @file('/etc/shells', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (!is_array($allowedShells) || !in_array($shell, $allowedShells, true)
            || preg_match('~/(?:nologin|false|jailshell)\z~i', $shell) === 1) {
            return ['success' => false, 'reason' => 'unsupported-shell'];
        }
        $info = PodmanCacheDiscovery::containerForIdentity($username, $identity['home'], $identity['uid'], $container);
        if ($info === null) {
            return ['success' => false, 'reason' => 'container'];
        }
        $scriptPath = self::SCRIPT;
        if ($runner === null) {
            $trustedScript = self::trustedEaPodmanScript();
            if ($trustedScript === null) {
                return ['success' => false, 'reason' => 'unavailable'];
            }
            $scriptPath = $trustedScript;
        }
        $argv = [$scriptPath, $action, $container];
        $env = [
            'HOME' => $identity['home'], 'USER' => $username, 'LOGNAME' => $username,
            'SHELL' => $shell, 'PATH' => '/usr/local/bin:/usr/bin:/bin', 'LANG' => 'C', 'LC_ALL' => 'C',
        ];
        $runtime = '/run/user/' . $identity['uid'];
        $runtimeStat = @lstat($runtime);
        if (is_array($runtimeStat) && (($runtimeStat['mode'] & 0170000) === 0040000)
            && $runtimeStat['uid'] === $identity['uid'] && ($runtimeStat['mode'] & 0022) === 0
            && @realpath($runtime) === $runtime) {
            $env['XDG_RUNTIME_DIR'] = $runtime;
        }
        $runner ??= [self::class, 'run'];
        try {
            $result = $runner($argv, $env, self::TIMEOUT_SECONDS);
        } catch (\Throwable) {
            return ['success' => false, 'reason' => 'failed'];
        }
        if (!is_array($result)) {
            return ['success' => false, 'reason' => 'failed'];
        }
        if (($result['timeout'] ?? false) === true) {
            return ['success' => false, 'reason' => 'timeout'];
        }
        return ($result['exit_code'] ?? null) === 0
            ? ['success' => true, 'reason' => 'ok']
            : ['success' => false, 'reason' => 'failed'];
    }

    private static function trustedEaPodmanScript(): ?string
    {
        $entry = @lstat(self::SCRIPT);
        $entryType = is_array($entry) ? ($entry['mode'] & 0170000) : 0;
        if (!is_array($entry) || !in_array($entryType, [0100000, 0120000], true) || $entry['uid'] !== 0
            || !self::hasSafeRootOwnedDirectoryChain(dirname(self::SCRIPT))) {
            return null;
        }
        $resolved = @realpath(self::SCRIPT);
        if (!is_string($resolved) || str_contains($resolved, "\0")
            || !(str_starts_with($resolved, '/usr/local/cpanel/')
                || str_starts_with($resolved, '/usr/local/opt/cpanel/')
                || str_starts_with($resolved, '/opt/cpanel/'))
            || !self::hasSafeRootOwnedDirectoryChain(dirname($resolved))) {
            return null;
        }
        $target = @stat($resolved);
        if (!is_array($target) || (($target['mode'] & 0170000) !== 0100000)
            || $target['uid'] !== 0 || ($target['mode'] & 0022) !== 0 || !is_executable($resolved)) {
            return null;
        }
        return $resolved;
    }

    private static function hasSafeRootOwnedDirectoryChain(string $directory): bool
    {
        while (true) {
            $stat = @lstat($directory);
            if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0040000)
                || $stat['uid'] !== 0 || ($stat['mode'] & 0022) !== 0 || @realpath($directory) !== $directory) {
                return false;
            }
            if ($directory === '/') {
                return true;
            }
            $parent = dirname($directory);
            if ($parent === $directory) {
                return false;
            }
            $directory = $parent;
        }
    }

    /** @param list<string> $argv @param array<string,string> $env @return array{exit_code:?int,timeout:bool} */
    private static function run(array $argv, array $env, int $timeout): array
    {
        if (!function_exists('proc_open')) {
            return ['exit_code' => null, 'timeout' => false];
        }
        $process = @proc_open($argv, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);
        if (!is_resource($process)) {
            return ['exit_code' => null, 'timeout' => false];
        }
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $deadline = microtime(true) + $timeout;
        $timedOut = false;
        $observedExitCode = null;
        do {
            // Drain output without retaining or exposing cPanel command diagnostics.
            stream_get_contents($pipes[1]);
            stream_get_contents($pipes[2]);
            $status = proc_get_status($process);
            if (!$status['running']) {
                $observedExitCode = is_int($status['exitcode'] ?? null) && $status['exitcode'] >= 0
                    ? $status['exitcode'] : null;
                break;
            }
            if (microtime(true) >= $deadline) {
                $timedOut = true;
                proc_terminate($process);
                usleep(100000);
                $status = proc_get_status($process);
                if ($status['running']) {
                    proc_terminate($process, 9);
                }
                break;
            }
            usleep(50000);
        } while (true);
        stream_get_contents($pipes[1]);
        stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $closedExitCode = proc_close($process);
        $exitCode = $observedExitCode ?? ($closedExitCode >= 0 ? $closedExitCode : null);
        return ['exit_code' => $timedOut ? null : $exitCode, 'timeout' => $timedOut];
    }
}
