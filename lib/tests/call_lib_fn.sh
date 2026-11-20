#!/usr/bin/env bash
# lib/tests/call_lib_fn.sh <lib> <function> [args...] — source one lib and call
# one of its functions in a fresh process, then print "rc=<status>".
#
# For functions that exit (or set an EXIT trap) and for runs that must be
# bounded by timeout(1): neither can be done safely inside the test's own shell.
# No "rc=" line means the function exited instead of returning.
# The lib is the first argument by design; there is no fixed path to follow.
# shellcheck source=/dev/null
. "$1"
shift
"$@"
rc=$?
echo "rc=$rc"
exit "$rc"
