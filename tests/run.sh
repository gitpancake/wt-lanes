#!/usr/bin/env bash
# Run the whole wt-lanes test suite. Exit non-zero if any file fails.
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "$dir"/test-*.sh; do
  printf '\n== %s ==\n' "$(basename "$t")"
  bash "$t" || rc=1
done
exit $rc
