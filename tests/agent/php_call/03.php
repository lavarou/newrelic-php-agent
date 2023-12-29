<?php
/*
 * Copyright 2020 New Relic Corporation. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

/*DESCRIPTION
Test nr_php_call_user_func: user function does not exists.
*/

/*SKIPIF*/

/*INI
newrelic.framework = wordpress
newrelic.framework.wordpress.hooks = true
newrelic.framework.wordpress.plugins = true
newrelic.framework.wordpress.core = true
;newrelic.loglevel=verbosedebug
newrelic.special=show_executes, show_execute_params, show_execute_returns
*/

/*ENVIRONMENT
REQUEST_METHOD=GET
*/

/*EXPECT_METRICS_EXIST*/
/*
Supportability/InstrumentedFunction/apply_filters
Supportability/InstrumentedFunction/do_action
WebTransaction/Action/template
Framework/WordPress/Hook/template_include
Framework/WordPress/Hook/init
Framework/WordPress/Plugin/mock-theme
*/

/*EXPECT_ERROR_EVENTS null */

//require_once __DIR__.'/wp-content/themes/mock-theme.php';
//require_once __DIR__.'/wp-includes/functions.php';

// Mock WordPress hooks; only a single callback for a given hook can be defined
$wp_filters = [];

function add_filter($hook_name, $callback) {
  global $wp_filters;
  $wp_filters[$hook_name] = $callback;
}

function apply_filters($hook_name, $value, ...$args) {
  global $wp_filters;
  return call_user_func_array($wp_filters[$hook_name], array($value, $args));
}

// Called in fw_wordpress via nr_php_call_user_func
function get_theme_roots() {
    trigger_error("Cannot get theme roots error");
}

function identity_filter($value) {
  return $value;
}

// Register custom plugin filter
add_filter("template_include", "identity_filter");

// Emulate WordPress loading a template to render a page:
$template = apply_filters("template_include", "./path/to/templates/template.php");

echo "this should not print";
