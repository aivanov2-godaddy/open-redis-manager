<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/AccountCreateHook.php';

use Orm\Cpanel\AccountCreateHook;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$valid = json_encode([
    'context' => 'Whostmgr::Accounts::Create',
    'data' => ['username' => 'newacct', 'plan' => 'provider-package', 'domain' => 'private.example'],
], JSON_THROW_ON_ERROR);
$assert(AccountCreateHook::request($valid) === ['username' => 'newacct'],
    'extract only the account username from an account-create event.');
$assert(AccountCreateHook::request(json_encode([
    'context' => 'Whostmgr::Accounts::Create', 'data' => ['user' => 'newacct'],
], JSON_THROW_ON_ERROR)) === ['username' => 'newacct'],
    'accept cPanel event envelopes that name the account with the user field.');
$assert(AccountCreateHook::request(json_encode([
    'context' => 'Whostmgr::Accounts::Create', 'data' => ['user' => 'newacct', 'username' => 'newacct'],
], JSON_THROW_ON_ERROR)) === ['username' => 'newacct'],
    'accept duplicate matching identity fields.');
$assert(AccountCreateHook::request(json_encode([
    'context' => 'Whostmgr::Accounts::Create', 'data' => ['user' => 'newacct', 'username' => 'otheracct'],
], JSON_THROW_ON_ERROR)) === null,
    'reject ambiguous conflicting identity fields.');
$assert(AccountCreateHook::request('{bad json') === null,
    'reject malformed event JSON.');
$assert(AccountCreateHook::request(json_encode([
    'context' => 'Whostmgr::Accounts::Remove', 'data' => ['username' => 'newacct'],
], JSON_THROW_ON_ERROR)) === null,
    'reject events outside the exact create-account context.');
$assert(AccountCreateHook::request(json_encode([
    'context' => 'Whostmgr::Accounts::Create', 'data' => ['username' => 'bad/name'],
], JSON_THROW_ON_ERROR)) === null,
    'reject an unsafe account name.');
$assert(AccountCreateHook::request(str_repeat('x', 16385)) === null,
    'reject an event larger than the retained input limit.');
$assert(AccountCreateHook::brokerFrame(['username' => 'newacct'])
    === "{\"operation\":\"fleet.auto_provision\",\"username\":\"newacct\",\"version\":1}\n",
    'emit only the fixed broker operation and validated account name.');
$assert(AccountCreateHook::brokerFrame(['username' => 'bad/name']) === null,
    'refuse to build a broker frame for an unsafe name.');

fwrite(STDOUT, "Account create hook checks passed: {$checks}\n");
