<?php
/*
 * Copyright 2020 New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

/*DESCRIPTION
 call a function and trigger an exception that is caught
*/

/*INI
display_errors=1
log_errors=0
*/

/*EXPECT
ok - followup(0)
*/


/*EXPECT_ERROR_EVENTS null */


require_once(__DIR__.'/functions.inc');
require_once(__DIR__.'/../include/tap.php');

$retval = followup(0);

newrelic_end_transaction();

tap_equal(1, $retval, 'followup(0)');
