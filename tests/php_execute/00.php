<?php
/*
 * Copyright 2020 New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

/*DESCRIPTION
 happy path - pass argument that will not throw exception.
*/

/*INI
display_errors=1
log_errors=0
*/

/*EXPECT
ok - uncaught(1)
*/


/*EXPECT_ERROR_EVENTS null */


require_once(__DIR__.'/functions.inc');
require_once(__DIR__.'/../include/tap.php');

// call a function and don't trigger an exception
$retval = uncaught(1);

tap_equal(1, $retval, 'uncaught(1)');
