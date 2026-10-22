<?php

echo "worker starting\n";

$handler = static function () {
    echo php_sapi_name(), PHP_EOL;
    echo gethostbyaddr(gethostbyname(gethostname())), PHP_EOL;
};

$running = true;
while ($running) {
    $running = \frankenphp_handle_request($handler);
}

echo "worker terminating\n";
