<?php
/*
 * Copyright 2020 New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

/*DESCRIPTION
 call a function and trigger an exception
*/

/*INI
display_errors=1
log_errors=0
*/

/*EXPECT_REGEX
^\s*Fatal error: Uncaught.*RuntimeException.*Division by zero.*
*/

/*EXPECT_ERROR_EVENTS
[
  "?? agent run id",
  {
    "reservoir_size": 100,
    "events_seen": 1
  },
  [
    "?? error event"
  ]
]*/


require_once(__DIR__.'/functions.inc');
require_once(__DIR__.'/../include/tap.php');

// call a function and don't trigger an exception
$retval = uncaught(1);

// call a function and trigger an exception
$retval = uncaught(0);

newrelic_end_transaction();
