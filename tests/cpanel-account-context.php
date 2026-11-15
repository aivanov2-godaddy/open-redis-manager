<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/AuthenticatedAccountContext.php';

use Orm\Cpanel\AuthenticatedAccountContext;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    $checks++;
    if (!$condition) {
        throw new RuntimeException($message);
    }
};

$validApi = new class {
    public function uapi(string $module, string $function, array $parameters): array
    {
        if ($module !== 'Variables' || $function !== 'get_user_information' || $parameters !== ['name' => 'user']) {
            throw new RuntimeException('Unexpected UAPI request.');
        }
        return ['cpanelresult' => ['result' => ['status' => 1, 'data' => ['user' => 'account123']]]];
    }
};
$context = AuthenticatedAccountContext::fromLiveApi($validApi);
$assert($context?->username() === 'account123', 'Read the authenticated account from LiveAPI.');

foreach (['', '../root', 'name;id', 'account name', str_repeat('a', 17), 'user@example'] as $invalidUsername) {
    $api = new class($invalidUsername) {
        public function __construct(private string $username) {}
        public function uapi(string $module, string $function, array $parameters): array
        {
            return ['cpanelresult' => ['result' => ['status' => 1, 'data' => ['user' => $this->username]]]];
        }
    };
    $assert(AuthenticatedAccountContext::fromLiveApi($api) === null, 'Reject invalid username: ' . $invalidUsername);
}

$nonStringApi = new class {
    public function uapi(string $module, string $function, array $parameters): array
    {
        return ['cpanelresult' => ['result' => ['status' => 1, 'data' => ['user' => ['account123']]]]];
    }
};
$assert(AuthenticatedAccountContext::fromLiveApi($nonStringApi) === null, 'Reject non-string LiveAPI result.');

$failedApi = new class {
    public function uapi(string $module, string $function, array $parameters): array
    {
        return ['cpanelresult' => ['result' => ['status' => 0, 'data' => ['user' => 'account123']]]];
    }
};
$assert(AuthenticatedAccountContext::fromLiveApi($failedApi) === null, 'Reject unsuccessful UAPI result.');

$missingUserApi = new class {
    public function uapi(string $module, string $function, array $parameters): array
    {
        return ['cpanelresult' => ['result' => ['status' => 1, 'data' => []]]];
    }
};
$assert(AuthenticatedAccountContext::fromLiveApi($missingUserApi) === null, 'Reject a successful response without a user.');

$throwingApi = new class {
    public function uapi(string $module, string $function, array $parameters): never { throw new RuntimeException('Unavailable'); }
};
$assert(AuthenticatedAccountContext::fromLiveApi($throwingApi) === null, 'Fail closed when LiveAPI throws.');
$assert(AuthenticatedAccountContext::fromLiveApi(new stdClass()) === null, 'Fail closed when LiveAPI is unavailable.');

fwrite(STDOUT, "cPanel account context checks passed: {$checks}\n");
