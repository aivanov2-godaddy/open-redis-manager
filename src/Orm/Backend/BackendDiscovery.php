<?php
declare(strict_types=1);

namespace Orm\Backend;

/** Read-only discovery of common Redis-compatible binaries and systemd units. */
final class BackendDiscovery
{
    private const BACKENDS = [
        'redis' => [
            'label' => 'Redis',
            'server_paths' => [
                '/usr/bin/redis-server',
                '/usr/sbin/redis-server',
                '/usr/local/bin/redis-server',
                '/usr/local/sbin/redis-server',
            ],
            'client_paths' => [
                '/usr/bin/redis-cli',
                '/usr/sbin/redis-cli',
                '/usr/local/bin/redis-cli',
                '/usr/local/sbin/redis-cli',
            ],
            'units' => ['redis.service', 'redis-server.service'],
        ],
        'valkey' => [
            'label' => 'Valkey',
            'server_paths' => [
                '/usr/bin/valkey-server',
                '/usr/sbin/valkey-server',
                '/usr/local/bin/valkey-server',
                '/usr/local/sbin/valkey-server',
            ],
            'client_paths' => [
                '/usr/bin/valkey-cli',
                '/usr/sbin/valkey-cli',
                '/usr/local/bin/valkey-cli',
                '/usr/local/sbin/valkey-cli',
            ],
            'units' => ['valkey.service', 'valkey-server.service'],
        ],
    ];

    private const SYSTEMCTL_PATHS = ['/usr/bin/systemctl', '/bin/systemctl'];
    private const PROCESS_TIMEOUT_SECONDS = 2.0;
    private const MAX_PROCESS_OUTPUT_BYTES = 4096;

    /** @return array<string, mixed> */
    public function discover(): array
    {
        $report = [
            'schema_version' => 1,
            'observed_at' => gmdate('Y-m-d\TH:i:s\Z'),
            'platform' => PHP_OS_FAMILY,
            'status' => PHP_OS_FAMILY === 'Linux' ? 'supported-platform' : 'unsupported-platform',
            'read_only' => true,
            'backends' => [],
            'limitations' => [
                'Discovery checks only fixed common binary paths and known systemd unit names.',
                'A detected backend does not mean ORM manages any account instances.',
                'Managed account counts and account configuration are not inspected.',
            ],
        ];

        if (PHP_OS_FAMILY !== 'Linux') {
            $report['limitations'][] = 'cPanel/WHM backend discovery is supported only on Linux hosts.';
            return $report;
        }

        $systemctl = $this->firstExecutable(self::SYSTEMCTL_PATHS);
        foreach (self::BACKENDS as $id => $definition) {
            $server = $this->firstExecutable($definition['server_paths']);
            $client = $this->firstExecutable($definition['client_paths']);
            $version = $server === null
                ? ['value' => null, 'status' => 'not-checked']
                : $this->readVersion($server);

            $report['backends'][] = [
                'id' => $id,
                'label' => $definition['label'],
                'status' => self::availabilityStatus($server, $client),
                'server_binary' => $server,
                'client_binary' => $client,
                'version' => $version['value'],
                'version_status' => $version['status'],
                'service' => $this->readServiceState($systemctl, $definition['units']),
                'managed_account_count' => null,
            ];
        }

        return $report;
    }

    /**
     * A server alone is insufficient for ORM lifecycle and health checks; the
     * matching fixed CLI is required as well. Preserve partial detection for
     * the setup wizard instead of presenting it as either ready or absent.
     */
    public static function availabilityStatus(?string $server, ?string $client): string
    {
        if ($server !== null && $client !== null) {
            return 'detected';
        }
        if ($server !== null) {
            return 'server-only';
        }
        if ($client !== null) {
            return 'client-only';
        }
        return 'not-detected';
    }

    /** @param list<string> $paths */
    private function firstExecutable(array $paths): ?string
    {
        foreach ($paths as $path) {
            if (is_file($path) && is_executable($path)) {
                return $path;
            }
        }

        return null;
    }

    /** @return array{value: ?string, status: string} */
    private function readVersion(string $binary): array
    {
        $result = $this->run([$binary, '--version']);
        if ($result['timed_out']) {
            return ['value' => null, 'status' => 'timed-out'];
        }
        if ($result['output_limited']) {
            return ['value' => null, 'status' => 'output-limited'];
        }
        if ($result['launch_failed'] || $result['exit_code'] !== 0) {
            return ['value' => null, 'status' => 'unavailable'];
        }

        $text = trim($result['stdout'] . "\n" . $result['stderr']);
        if (preg_match('/\b(?:Redis|Valkey)\s+server\s+v=([0-9][A-Za-z0-9.+~:-]*)/i', $text, $matches) !== 1) {
            return ['value' => null, 'status' => 'unrecognized-output'];
        }

        return ['value' => $matches[1], 'status' => 'available'];
    }

    /** @param list<string> $units @return array<string, ?string> */
    private function readServiceState(?string $systemctl, array $units): array
    {
        if ($systemctl === null) {
            return ['status' => 'manager-unavailable', 'unit' => null];
        }

        foreach ($units as $unit) {
            $load = $this->run([$systemctl, 'show', '--property=LoadState', '--value', $unit]);
            if ($load['timed_out']) {
                return ['status' => 'unknown-timeout', 'unit' => $unit];
            }
            if ($load['launch_failed']) {
                return ['status' => 'unknown-unavailable', 'unit' => $unit];
            }

            $loadState = strtolower(trim($load['stdout']));
            if ($load['exit_code'] !== 0 && $loadState === '') {
                return ['status' => 'unknown-permission-or-manager-error', 'unit' => $unit];
            }
            if ($loadState === 'not-found') {
                continue;
            }
            if ($loadState !== 'loaded') {
                return ['status' => 'unknown-load-state', 'unit' => $unit];
            }

            $active = $this->run([$systemctl, 'is-active', $unit]);
            if ($active['timed_out']) {
                return ['status' => 'unknown-timeout', 'unit' => $unit];
            }
            if ($active['launch_failed']) {
                return ['status' => 'unknown-unavailable', 'unit' => $unit];
            }

            $activeState = strtolower(trim($active['stdout']));
            if (in_array($activeState, ['active', 'inactive', 'failed', 'activating', 'deactivating', 'reloading'], true)) {
                return ['status' => $activeState, 'unit' => $unit];
            }

            return ['status' => 'unknown-manager-response', 'unit' => $unit];
        }

        return ['status' => 'not-detected', 'unit' => null];
    }

    /**
     * Run only a server-authored argument vector. No shell, PATH lookup, or
     * request-controlled argument is involved.
     *
     * @param list<string> $arguments
     * @return array{stdout: string, stderr: string, exit_code: ?int, timed_out: bool, output_limited: bool, launch_failed: bool}
     */
    private function run(array $arguments): array
    {
        $empty = [
            'stdout' => '',
            'stderr' => '',
            'exit_code' => null,
            'timed_out' => false,
            'output_limited' => false,
            'launch_failed' => false,
        ];
        if (!function_exists('proc_open')) {
            $empty['launch_failed'] = true;
            return $empty;
        }

        $pipes = [];
        $process = @proc_open(
            $arguments,
            [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes,
            '/',
            [
                'PATH' => '/usr/bin:/bin',
                'LANG' => 'C',
                'LC_ALL' => 'C',
                'SYSTEMD_PAGER' => 'cat',
                'SYSTEMD_COLORS' => '0',
            ]
        );
        if (!is_resource($process)) {
            $empty['launch_failed'] = true;
            return $empty;
        }

        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $startedAt = microtime(true);
        $status = proc_get_status($process);

        while ($status['running']) {
            if ($this->collectOutput($pipes, $empty)) {
                $empty['output_limited'] = true;
                proc_terminate($process);
                break;
            }
            if (microtime(true) - $startedAt > self::PROCESS_TIMEOUT_SECONDS) {
                $empty['timed_out'] = true;
                proc_terminate($process);
                break;
            }

            usleep(20_000);
            $status = proc_get_status($process);
        }

        if ($empty['timed_out'] || $empty['output_limited']) {
            $terminateDeadline = microtime(true) + 0.2;
            do {
                $status = proc_get_status($process);
                if (!$status['running']) {
                    break;
                }
                usleep(20_000);
            } while (microtime(true) < $terminateDeadline);
            if ($status['running']) {
                proc_terminate($process, 9);
                $status = proc_get_status($process);
            }
        }

        if ($this->collectOutput($pipes, $empty)) {
            $empty['output_limited'] = true;
        }
        fclose($pipes[1]);
        fclose($pipes[2]);
        $closeCode = proc_close($process);
        $statusCode = is_array($status) && isset($status['exitcode']) ? (int)$status['exitcode'] : -1;
        $empty['exit_code'] = $statusCode >= 0 ? $statusCode : ($closeCode >= 0 ? $closeCode : null);

        return $empty;
    }

    /**
     * Read available output without retaining more than the process-wide cap.
     *
     * @param array<int, resource> $pipes
     * @param array<string, mixed> $result
     */
    private function collectOutput(array $pipes, array &$result): bool
    {
        foreach ([1 => 'stdout', 2 => 'stderr'] as $pipeIndex => $key) {
            $used = strlen($result['stdout']) + strlen($result['stderr']);
            $remaining = self::MAX_PROCESS_OUTPUT_BYTES - $used;
            $chunk = (string)stream_get_contents($pipes[$pipeIndex], max(1, $remaining + 1));
            if (strlen($chunk) > $remaining) {
                if ($remaining > 0) {
                    $result[$key] .= substr($chunk, 0, $remaining);
                }
                return true;
            }
            $result[$key] .= $chunk;
        }

        return false;
    }
}
