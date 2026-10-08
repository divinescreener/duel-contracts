#!/usr/bin/env bash
# Coverage gate: the contracts stay at 100% of lines, branches and functions (and statements). Fails as soon as one of
# them drops below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# built first: a test of the deployment's attestation reads the router's artifact in out/
# (vm.getArtifactPathByDeployedCode), which forge coverage does not write, and a fresh checkout has none
forge build >/dev/null
# the gas and size bounds hold for the optimized build, not for the instrumented one: the settling swap's headroom
# and a transaction's gas under load (test/audit), a whole exit's gas and the bootstrap's code under the initcode limit
# (test/unit)
forge coverage --ir-minimum --no-match-path "test/{fork,invariant,e2e}/*" \
  --no-match-test "Headroom|WholeExitStaysWithinItsGas|fitsTheInitcodeLimit|underLoad" \
  --no-match-coverage "(^test/|^script/|^lib/)" --report summary --report lcov
awk -F: '
  /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
  /^BRF:/ { bf += $2 } /^BRH:/ { bh += $2 }
  /^FNF:/ { ff += $2 } /^FNH:/ { fh += $2 }
  END {
    printf "contracts: lines %d/%d, branches %d/%d, functions %d/%d\n", lh, lf, bh, bf, fh, ff
    exit (lh == lf && bh == bf && fh == ff) ? 0 : 1
  }' lcov.info
