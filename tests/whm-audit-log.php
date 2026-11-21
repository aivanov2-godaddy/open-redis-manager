<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/WhmAuditLog.php';

use Orm\Security\WhmAuditLog;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$now = time();
$journal = static function (string $identifier, string $message, int $timestamp) use ($assert): string {
    $encoded = json_encode([
        'SYSLOG_IDENTIFIER' => $identifier,
        'MESSAGE' => $message,
        '__REALTIME_TIMESTAMP' => (string) ($timestamp * 1_000_000),
    ], JSON_THROW_ON_ERROR);
    $assert(is_string($encoded), 'Encode journal fixtures as JSON.');
    return $encoded;
};
$brokerLines = [
    $journal('orm-broker', 'fleet_operation actor_uid=0 account=acct01 action=diagnostics.read result=success state=running', $now - 30),
    $journal('orm-broker', 'account_auth actor_uid=1000 account=acct01 action=auth.rotate result=success state=running', $now - 20),
    $journal('orm-broker', 'account_auth actor_uid=1000 account=acct01 action=auth.enable result=success state=running', $now - 22),
    $journal('orm-broker', 'provider_policy actor_uid=43210 account=acct01 action=policy.violation result=warn state=memory_limit_exceeded', $now - 18),
    $journal('orm-broker', 'fleet_operation actor_uid=0 account=acct01 action=diagnostics.info_memory result=success state=running', $now - 25),
    $journal('orm-broker', 'provider_policy actor_uid=43210 account=acct01 action=policy.violation result=warn state=client_limit_exceeded', $now - 17),
    $journal('orm-broker', 'provider_policy actor_uid=43210 account=acct01 action=policy.violation result=warn state=database_limit_exceeded', $now - 16),
    $journal('orm-broker', 'fleet_operation actor_uid=0 account=acct07 action=recovery.config_rebuild result=success state=stopped', $now - 3),
    $journal('orm-broker', 'account_operation actor_uid=1000 account=acct01 action=instance.provision result=success state=running', $now - 53),
    $journal('orm-broker', 'account_operation actor_uid=1000 account=acct01 action=instance.configure result=failure state=running', $now - 52),
    $journal('orm-broker', 'account_operation actor_uid=1000 account=acct01 action=instance.start result=success state=starting', $now - 51),
    $journal('orm-broker', 'account_operation actor_uid=1000 account=acct01 action=instance.stop result=success state=stopped', $now - 50),
    $journal('orm-broker', 'ORM raw message password=do-not-export', $now - 10),
    json_encode(['SYSLOG_IDENTIFIER' => 'other-service', 'MESSAGE' => 'fleet_operation actor_uid=0 account=acct01 action=start result=success state=running', '__REALTIME_TIMESTAMP' => (string) ($now * 1_000_000)], JSON_THROW_ON_ERROR),
];
$whmLines = [
    $journal('orm-whm', 'provider_events actor_uid=0 account=global action=provider.events.configure result=success state=enabled,key_rotated', $now - 1),
    $journal('orm-whm', 'backend_policy actor_uid=0 account=global action=backend.select result=success state=valkey', $now - 15),
    $journal('orm-whm', 'provider_policy actor_uid=0 account=global action=provider.package.save result=success state=updated', $now - 5),
    $journal('orm-whm', 'security_report actor_uid=0 account=global action=security.report result=success state=generated', $now - 2),
    $journal('orm-whm', 'security_report_policy actor_uid=0 account=global action=security.thresholds.update result=success state=updated', $now - 40),
];
$reader = new WhmAuditLog(static fn (string $identifier): array => [
    'status' => 'ok', 'lines' => $identifier === 'orm-broker' ? $brokerLines : $whmLines,
]);
$result = $reader->read($now - 3600, $now, []);
$assert($result['success'] && $result['record_count'] === 16, 'Parse known records and omit unknown, malformed-source, and unrelated journal rows.');
$assert($result['records'][0]['action'] === 'provider.events.configure' && $result['records'][0]['account'] === 'global'
    && $result['records'][0]['state'] === 'enabled,key_rotated', 'Recognize fixed metadata-only provider event configuration audits.');
$assert($result['records'][11]['action'] === 'security.thresholds.update' && $result['records'][11]['result'] === 'success',
    'Recognize fixed metadata-only security threshold policy updates.');
$assert($result['records'][3]['action'] === 'provider.package.save' && $result['records'][3]['source'] === 'orm-whm', 'Sort newest first and normalize WHM policy events.');
$assert($result['records'][2]['action'] === 'recovery.config_rebuild' && $result['records'][2]['state'] === 'stopped',
    'Recognize the fixed metadata-only config rebuild recovery audit event.');
$assert($result['records'][5]['action'] === 'policy.violation' && $result['records'][5]['actor'] === '43210', 'Normalize broker provider policy events using their trusted account actor.');
$assert($result['records'][8]['action'] === 'auth.enable', 'Recognize fixed metadata-only AUTH enable events.');
$assert($result['records'][9]['action'] === 'diagnostics.info_memory' && $result['records'][9]['actor'] === '0'
    && $result['records'][9]['account'] === 'acct01', 'Expose the exact selected diagnostics command class in audit history.');
$assert($result['records'][12]['action'] === 'instance.stop' && $result['records'][12]['actor'] === '1000'
    && $result['records'][12]['account'] === 'acct01' && $result['records'][12]['state'] === 'stopped'
    && $result['records'][13]['action'] === 'instance.start'
    && $result['records'][14]['action'] === 'instance.configure' && $result['records'][14]['result'] === 'failure'
    && $result['records'][15]['action'] === 'instance.provision',
    'Normalize metadata-only cPanel lifecycle and configuration events from the authenticated account UID.');
$assert($result['sources'][0]['status'] === 'partial' && $result['sources'][0]['unrecognized_rows'] === 3, 'Mark sources partial when rows cannot be safely recognized.');
$filtered = $reader->read($now - 3600, $now, ['account' => 'acct01', 'action' => 'auth.rotate', 'result' => 'success']);
$assert($filtered['record_count'] === 1 && $filtered['records'][0]['actor'] === '1000', 'Filter normalized records by account, action, and result.');
$accountOperations = $reader->read($now - 3600, $now, ['account' => 'acct01', 'action' => 'instance.configure', 'result' => 'failure']);
$assert($accountOperations['record_count'] === 1 && $accountOperations['records'][0]['state'] === 'running',
    'Filter account lifecycle audit events by fixed action and normalized result.');
$autoProvisionReader = new WhmAuditLog(static fn (): array => [
    'status' => 'ok',
    'lines' => [$journal('orm-broker', 'fleet_operation actor_uid=0 account=acct02 action=auto_provision result=success state=running', $now - 1)],
]);
$autoProvisionAudit = $autoProvisionReader->read($now - 60, $now, ['account' => 'acct02', 'action' => 'auto_provision']);
$assert($autoProvisionAudit['record_count'] === 1 && $autoProvisionAudit['records'][0]['action'] === 'auto_provision',
    'Recognize and filter metadata-only automatic provisioning audit events.');
$assert(WhmAuditLog::normalizeFilters(['account' => '../root']) === null
    && WhmAuditLog::normalizeFilters(['action' => 'redis-cli']) === null
    && WhmAuditLog::normalizeFilters(['arbitrary' => 'value']) === null, 'Reject unsafe and unknown filters.');
$assert(!$reader->read($now - 604800, $now, [])['success'], 'Reject ranges of seven full days or more.');
$unavailable = new WhmAuditLog(static fn (): array => ['status' => 'unavailable', 'lines' => []]);
$missing = $unavailable->read($now - 60, $now, []);
$assert($missing['partial'] && $missing['sources'][0]['status'] === 'unavailable', 'Expose missing journal sources as incomplete coverage.');
$truncated = new WhmAuditLog(static fn (string $identifier): array => [
    'status' => $identifier === 'orm-broker' ? 'timed_out' : 'truncated', 'lines' => [],
]);
$limited = $truncated->read($now - 60, $now, []);
$assert($limited['partial'] && $limited['sources'][0]['reason'] === 'journal query timed out'
    && $limited['sources'][1]['truncated'], 'Report timeouts and bounded/truncated reads.');
$json = WhmAuditLog::toJson($result);
$assert(is_string($json) && str_contains($json, 'schema_version') && !str_contains($json, 'do-not-export')
    && !str_contains($json, 'raw message') && !str_contains($json, 'other-service'), 'Export normalized records without raw or unrelated journal data.');
$tampered = $result;
$tampered['records'][0]['raw_message'] = 'secret-value';
$tampered['sources'][0]['host_path'] = '/private/path';
$safeJson = WhmAuditLog::toJson($tampered);
$assert(is_string($safeJson) && !str_contains($safeJson, 'raw_message') && !str_contains($safeJson, 'secret-value')
    && !str_contains($safeJson, 'host_path'), 'Project exports onto fixed schemas even if internal rows contain extra fields.');
$assert(WhmAuditLog::toJson(['success' => false]) === null, 'Refuse exporting failed query results.');

fwrite(STDOUT, "WHM audit log checks passed: {$checks}\n");
