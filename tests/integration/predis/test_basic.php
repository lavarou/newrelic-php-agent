<?php
/*
 * Copyright 2020 New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

/*DESCRIPTION
The agent SHALL report Datastore metrics for Redis basic operations.
This Predis test is largely copied from the Redis version.
*/

/*INI
newrelic.datastore_tracer.database_name_reporting.enabled = 1
newrelic.datastore_tracer.instance_reporting.enabled = 1
*/

/*EXPECT
ok - set key
ok - get key
ok - delete key
ok - delete missing key
ok - reuse deleted key
ok - set duplicate key
ok - delete key
ok - trace nodes match
*/

/*EXPECT_METRICS
[
  "?? agent run id",
  "?? start time",
  "?? stop time",
  [
    [{"name":"DurationByCaller/Unknown/Unknown/Unknown/Unknown/all"},                    [1, "??", "??", "??", "??", "??"]],
    [{"name":"DurationByCaller/Unknown/Unknown/Unknown/Unknown/allOther"},               [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/all"},                                                           [8, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/allOther"},                                                      [8, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/Redis/all"},                                                     [8, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/Redis/allOther"},                                                [8, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/instance/Redis/ENV[REDIS_HOST]/6379"},                           [8, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/del"},                                           [3, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/del","scope":"OtherTransaction/php__FILE__"},    [3, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/exists"},                                        [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/exists","scope":"OtherTransaction/php__FILE__"}, [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/get"},                                           [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/get","scope":"OtherTransaction/php__FILE__"},    [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/set"},                                           [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/set","scope":"OtherTransaction/php__FILE__"},    [1, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/setnx"},                                         [2, "??", "??", "??", "??", "??"]],
    [{"name":"Datastore/operation/Redis/setnx","scope":"OtherTransaction/php__FILE__"},  [2, "??", "??", "??", "??", "??"]],
    [{"name":"OtherTransaction/all"},                                                    [1, "??", "??", "??", "??", "??"]],
    [{"name":"OtherTransaction/php__FILE__"},                                            [1, "??", "??", "??", "??", "??"]],
    [{"name":"OtherTransactionTotalTime"},                                               [1, "??", "??", "??", "??", "??"]],
    [{"name":"OtherTransactionTotalTime/php__FILE__"},                                   [1, "??", "??", "??", "??", "??"]],
    [{"name":"Supportability/library/Predis/detected"},                                  [1, "??", "??", "??", "??", "??"]],
    [{"name":"Supportability/library/Guzzle 4-5/detected"},                              [1, "??", "??", "??", "??", "??"]]
  ]
]
*/

/*EXPECT_TRACED_ERRORS null */

require_once(__DIR__.'/../../include/config.php');
require_once(__DIR__.'/../../include/helpers.php');
require_once(__DIR__.'/../../include/tap.php');
require_once(__DIR__.'/predis.inc');
require_once(realpath (dirname ( __FILE__ )) . '/../../include/integration.php');

use NewRelic\Integration\Transaction;

function test_basic() {
  global $REDIS_HOST, $REDIS_PORT;
  $client = new Predis\Client(array('host' => $REDIS_HOST, 'port' => $REDIS_PORT));

  try {
      $client->connect();
  } catch (Exception $e) {
      die("skip: " . $e->getMessage() . "\n");
  }

  /* Generate a unique key to use for this test run */
  $key = randstr(16);
  if ($client->exists($key)) {
      echo "key already exists: ${key}\n";
      exit(1);
  }

  /* The tests */
  $rval = $client->set($key, 'bar');
  tap_equal('OK', $rval->getPayload(), 'set key');
  tap_equal('bar', $client->get($key), 'get key');
  tap_equal(1, $client->del($key), 'delete key');
  tap_equal(0, $client->del($key), 'delete missing key');

  tap_assert($client->setnx($key, 'bar') == 1, 'reuse deleted key');
  tap_refute($client->setnx($key, 'bar') == 1, 'set duplicate key');

  /* Cleanup the key used by this test run */
  tap_equal(1, $client->del($key), 'delete key');

  /* Close connection */
  $client->disconnect();
}

test_basic();

function redis_datastore_instance_metric_exists(Transaction $txn)
{
  global $REDIS_HOST, $REDIS_PORT;

  $metrics = $txn->getUnscopedMetrics();
  $host = newrelic_is_localhost($REDIS_HOST) ? newrelic_get_hostname() : $REDIS_HOST;
  $port = (string) $REDIS_PORT;
  tap_assert(isset($metrics["Datastore/instance/Redis/$host/$port"]), 'datastore instance metric exists');
}

function redis_trace_nodes_match(Transaction $txn, array $operations)
{
  global $REDIS_HOST, $REDIS_PORT;

  $ok = true;
  $trace = $txn->getTrace();
  $nodes = iterator_to_array($trace->findSegmentsWithDatastoreInstances());

  /*
   *  array_flip() gives us an array with the expected operations as keys
   * (effectively a string set), which means we can do simple hashmap lookups
   * for each operation rather than walking the array each time.
  */
  $expected = array_flip($operations);

  /*
   * Ensure that there are no unexpected operation types, and that whatever
   * nodes exist have instance information. We can't do more than that because
   * extremely fast Redis operations may not generate trace nodes, which then
   * leads to test instability.
   *
   * Since we don't know how many nodes we're going to get, we can't use
   * tap_assert(), since it will generate a variable number of assertion
   * messages and the test runner isn't smart enough to figure that out.
   * Instead, if something fails, we'll use tap_not_ok() to generate an
   * unexpected failure message with (hopefully) useful state.
   */
  foreach ($nodes as $i => $node) {
    if (!array_key_exists($node->name, $expected)) {
      tap_not_ok("trace node $i operation is not in the expected list", implode('; ', $operations), $node->name);
      $ok = false;
    }

    $instance = $node->getDatastoreInstance();

    if (!$instance->isHost($REDIS_HOST)) {
      tap_not_ok("trace node $i host does not match", $REDIS_HOST, $instance->host);
      $ok = false;
    }

    if ($REDIS_PORT != $instance->portPathOrId) {
      tap_not_ok("trace node $i port does not match", $REDIS_PORT, $instance->portPathOrId);
      $ok = false;
    }

    if ('0' !== $instance->databaseName) {
      tap_not_ok("trace node $i database does not match", '0', $instance->databaseName);
      $ok = false;
    }
  }

  if ($ok) {
    tap_ok('trace nodes match');
  }
}

$txn = new Transaction;

redis_trace_nodes_match($txn, array(
  'Datastore/operation/Redis/del',
  'Datastore/operation/Redis/exists',
  'Datastore/operation/Redis/get',
  'Datastore/operation/Redis/set',
  'Datastore/operation/Redis/setnx',
));
