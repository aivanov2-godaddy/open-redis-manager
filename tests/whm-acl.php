<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/WhmAcl.php';

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$assert(\Orm\Security\WhmAcl::allowsAdministrativeAccess('root'), 'allow root without consulting the reseller file');
$assert(!\Orm\Security\WhmAcl::allowsAdministrativeAccess(null), 'deny a missing authenticated WHM identity');
$assert(!\Orm\Security\WhmAcl::allowsAdministrativeAccess('bad/name'), 'reject unsafe authenticated usernames');

$aclDecision = new ReflectionMethod(\Orm\Security\WhmAcl::class, 'resellerFileAllowsAdministrativeAccess');
$allows = static fn (string $user, string $contents): bool =>
    $aclDecision->invoke(null, $user, $contents);

$assert($allows('reseller', "reseller:all\n"), 'allow an exact reseller entry with the all ACL');
$assert($allows('reseller', "other:all\nreseller:reports, all\n"), 'match the exact reseller and trim ACL separators');
$assert(!$allows('reseller', "reseller:reports, list\n"), 'deny a reseller without the all ACL');
$assert(!$allows('reseller', "other:all\n"), 'deny when only another reseller has the all ACL');
$assert(!$allows('reseller', "reseller:notall\n"), 'require the exact all ACL token');
$assert(!$allows('reseller', "malformed\nreseller\n"), 'ignore malformed reseller records');
$assert($allows('reseller', "reseller:reports\r\nreseller:all\r\n"), 'parse CRLF reseller records');
$assert(!$allows('reseller', str_repeat('x', 4_194_305)), 'fail closed when reseller contents exceed the byte limit');

$source = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$assert(is_string($source), 'read the WHM entry point');
$assert(str_contains($source, '$rootAuthorized = $authorized && $authenticatedUser === \'root\';'),
    'derive privileged controls only from an authorized root identity');
$assert(str_contains($source, '$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)'),
    'require root authorization and a valid WHM request guard for mutation controls');

fwrite(STDOUT, "WHM ACL checks passed: {$checks}\n");
