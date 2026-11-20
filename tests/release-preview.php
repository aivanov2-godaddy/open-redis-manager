<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/SessionRequestGuard.php';
require dirname(__DIR__) . '/src/Orm/Update/ReleasePreview.php';

use Orm\Update\ReleasePreview;

$allowedTargets = [
    '/usr/local/cpanel/whostmgr/docroot/cgi/addon_open_redis_manager.php',
    '/etc/systemd/system/orm-broker.service',
];
$valid = [
    'schema' => 'orm-update-preview-v2',
    'verified' => true,
    'signatureVerified' => true,
    'mutationsApplied' => false,
    'targetComparison' => 'verified',
    'installedVersion' => '0.1.0-dev',
    'candidateVersion' => '0.2.0',
    'release' => [
        'channel' => 'stable',
        'stateMigrations' => 'none',
        'sourceCommit' => str_repeat('a', 40),
        'keyId' => 'orm-release-2026',
        'artifactSha256' => str_repeat('a', 64),
    ],
    'summary' => ['add' => 1, 'adopt' => 0, 'normalize' => 0, 'replace' => 2, 'unchanged' => 3, 'move' => 0, 'conflict' => 0, 'retire' => 0],
    'fileActions' => [[
        'key' => 'whm_cgi',
        'action' => 'replace',
        'target' => '/usr/local/cpanel/whostmgr/docroot/cgi/addon_open_redis_manager.php',
        'requiresReview' => false,
    ]],
];
$json = static fn (array $value): string => json_encode($value, JSON_THROW_ON_ERROR);
$assert = static function (bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$runnerCalled = false;
$runner = static function (array $argv, array $environment) use (&$runnerCalled): array {
    $runnerCalled = true;
    return ['exit_code' => 1, 'stdout' => ''];
};
$unauthorized = ReleasePreview::run('reseller', [
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess1234567890/cgi/addon_open_redis_manager.php',
], $runner);
$assert(($unauthorized['ok'] ?? true) === false && !$runnerCalled, 'resellers cannot execute the preview process');
$missingSession = ReleasePreview::run('root', [
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cgi/addon_open_redis_manager.php',
], $runner);
$assert(($missingSession['ok'] ?? true) === false && !$runnerCalled, 'non-cpsess requests cannot execute the preview process');

$result = ReleasePreview::validate($json($valid), '0.1.0-dev', $allowedTargets);
$assert(($result['ok'] ?? false) === true, 'verified candidate is accepted');
$assert($result['candidateVersion'] === '0.2.0', 'candidate version is returned');
$assert($result['fileActions'][0]['key'] === 'whm_cgi', 'file action is returned in normalized form');
$assert($result['release']['stateMigrations'] === 'none', 'signed no-migration contract is returned for operator review');
$assert($result['release']['sourceCommit'] === str_repeat('a', 40), 'signed source commit is returned for operator review');
$assert(!array_key_exists('mutationsApplied', $result), 'UI result does not expose arbitrary verifier fields');
$systemdAction = $valid;
$systemdAction['fileActions'][0]['target'] = '/etc/systemd/system/orm-broker.service';
$assert((ReleasePreview::validate($json($systemdAction), '0.1.0-dev', $allowedTargets)['ok'] ?? false) === true,
    'known managed systemd targets are accepted');
$adoptAction = $valid;
$adoptAction['summary']['adopt'] = 1;
$adoptAction['fileActions'][0]['action'] = 'adopt';
$adoptAction['fileActions'][0]['requiresReview'] = true;
$assert((ReleasePreview::validate($json($adoptAction), '0.1.0-dev', $allowedTargets)['ok'] ?? false) === true,
    'an explicitly reviewed adopt action is returned to the WHM operator');
$adoptWithoutReview = $adoptAction;
$adoptWithoutReview['fileActions'][0]['requiresReview'] = false;
$assert(!(ReleasePreview::validate($json($adoptWithoutReview), '0.1.0-dev', $allowedTargets)['ok'] ?? false),
    'adopt actions without explicit review are rejected');
$normalizeAction = $valid;
$normalizeAction['summary']['normalize'] = 1;
$normalizeAction['fileActions'][0]['action'] = 'normalize';
$normalizeAction['fileActions'][0]['requiresReview'] = true;
$normalizeAction['fileActions'][0]['observedSha256'] = str_repeat('b', 64);
$normalized = ReleasePreview::validate($json($normalizeAction), '0.1.0-dev', $allowedTargets);
$assert(($normalized['ok'] ?? false) === true && $normalized['fileActions'][0]['observedSha256'] === str_repeat('b', 64),
    'a reviewed CRLF-only normalize action retains its previous digest');
$normalizeWithoutReview = $normalizeAction;
$normalizeWithoutReview['fileActions'][0]['requiresReview'] = false;
$assert(!(ReleasePreview::validate($json($normalizeWithoutReview), '0.1.0-dev', $allowedTargets)['ok'] ?? false),
    'normalize actions without explicit review are rejected');
$normalizeWithoutDigest = $normalizeAction;
unset($normalizeWithoutDigest['fileActions'][0]['observedSha256']);
$assert(!(ReleasePreview::validate($json($normalizeWithoutDigest), '0.1.0-dev', $allowedTargets)['ok'] ?? false),
    'normalize actions without the previous digest are rejected');

$assert(!(ReleasePreview::validate($json($valid), '0.1.1', $allowedTargets)['ok'] ?? false), 'installed version must match');
foreach (['verified', 'signatureVerified', 'mutationsApplied'] as $field) {
    $invalid = $valid;
    $invalid[$field] = $field === 'mutationsApplied';
    $assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), "{$field} contract is enforced");
}
$invalid = $valid;
$invalid['fileActions'][0]['target'] = '/etc/passwd';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'unmanaged targets are rejected');
$invalid['fileActions'][0]['target'] = '/usr/local/cpanel/../etc/passwd';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'traversal targets are rejected');
$invalid = $valid;
$invalid['fileActions'][0]['key'] = '<script>alert(1)</script>';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'unsafe file keys are rejected');
$invalid = $valid;
$invalid['release']['artifactSha256'] = 'not-a-digest';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'invalid artifact digests are rejected');
$invalid = $valid;
$invalid['release']['stateMigrations'] = 'v1-to-v2';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'unsupported state migrations are rejected');
$invalid = $valid;
$invalid['release']['sourceCommit'] = 'not-a-commit';
$assert(!(ReleasePreview::validate($json($invalid), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'invalid source commits are rejected');
$assert(!(ReleasePreview::validate('{broken', '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'malformed JSON is rejected');
$assert(!(ReleasePreview::validate(str_repeat('x', 1048577), '0.1.0-dev', $allowedTargets)['ok'] ?? false), 'oversized output is rejected');

fwrite(STDOUT, "Release preview contract checks passed.\n");
