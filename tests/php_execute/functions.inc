<?php

function three($a) {
    if (0 == $a) { 
        throw new RuntimeException('Division by zero');
    } else {
        return $a;
    }
}

function two($a) { 
    return three($a);
}

function uncaught($a) { 
    return two($a);
}

function caught($a) {
    try {
        two($a);
    } catch (Exception $e) {
        return 1;
    }
    return 1;
}

function followup($a) {
    try {
        two($a);
    } catch (Exception $e) {
        return three(1);
    }
    return three(1);
}

function followup_uncaught($a) {
    try {
        two($a);
    } catch (Exception $e) {
        return three(0);
    }
    return three(1);
}

function rethrow($a) {
    try {
        two($a);
    } catch (Exception $e) {
        throw new RuntimeException('Rethrown caught exception: '. $e->getMessage());
    }
    return three(1);
}
