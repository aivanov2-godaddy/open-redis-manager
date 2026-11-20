<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Starts, stops, or restarts an existing EA Podman Redis/Valkey container for its owner. */
final class PodmanLifecycleManager
{
    private const SCRIPT = '/usr/local/cpanel/scripts/ea-podman';
    private const TIMEOUT_SECONDS = 30;

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
