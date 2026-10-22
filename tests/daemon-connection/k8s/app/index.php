<?php
echo "topology=" . getenv('TOPOLOGY') . " host=" . gethostname() . " time=" . date('c') . "\n";

if (extension_loaded('newrelic')) {
    echo "newrelic extension: loaded\n";
} else {
    echo "newrelic extension: NOT loaded (expected until a ZTS build of newrelic.so is in place — see spec.md Known gaps)\n";
}
