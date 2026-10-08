#!/usr/bin/env bash
# Snapshot gate: the contracts' storage layout and their tests' gas stay as committed in snapshots/. A change
# fails with its diff, to review: `--update` writes both again, to commit with the change that explains them.
#
# The layout is each contract's storage, slot by slot and member by member: a variable inserted before others moves
# them, and whatever writes a slot by its number (a test's vm.store, a state override) then writes the wrong one. The gas
# is each test's in the optimized build, the fuzzed ones drawn from a fixed seed, so that two runs give the same numbers:
# a cost that moves, or a test with none in the snapshot, fails. Built without forge's dynamic test linking (on by
# default since forge 1.x), which leaves a test's own code as an earlier build linked it: an incremental build and a
# clean one gave other gas, and other fuzzed inputs (the fuzzer draws from the bytecode's constants).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONTRACTS=(DuelHook DuelFactory DuelRouter DuelLens DuelToken DuelSimulator)
# each variable as "slot:offset name type", then the members of the structs it holds, a mapping's or an array's entries
# counted from the entry ("+slot:offset"): the compiler's numbering of types and declarations left out
LAYOUT='
.types as $types
| def at($slot; $offset; $rel): "\(if $rel then "+" else "" end)\($slot):\($offset)";
  def expand($t; $path; $slot; $rel):
    $types[$t] as $ty
    | if $ty.members then
        $ty.members[]
        | ($slot + (.slot | tonumber)) as $s
        | "  \(at($s; .offset; $rel)) \($path).\(.label) \($types[.type].label)",
          expand(.type; "\($path).\(.label)"; $s; $rel)
      elif $ty.encoding == "mapping" then expand($ty.value; "\($path)[\($types[$ty.key].label)]"; 0; true)
      elif $ty.encoding == "dynamic_array" then expand($ty.base; "\($path)[]"; 0; true)
      else empty end;
  .storage[]
  | "  \(at(.slot | tonumber; .offset; false)) \(.label) \($types[.type].label)",
    expand(.type; .label; (.slot | tonumber); false)
'
layout() {
  for contract in "${CONTRACTS[@]}"; do
    echo "$contract"
    forge inspect "$contract" storageLayout --json | jq -r "$LAYOUT"
  done
}

# the tests that run without a node, but the fork tests, the invariants (their runs are random walks), test/e2e, and one
# test whose gas depends on where the checkout lies (it reads an artifact of the build, which names its path)
GAS=(--no-match-path "test/{fork,invariant,e2e}/*" --no-match-test "RejectsInconsistentOccurrencesOfAnImmutable"
  --fuzz-seed 0xd0e1)
export FOUNDRY_DYNAMIC_TEST_LINKING=false
# every source built first: the fuzzer draws its inputs from a dictionary read in the compiled sources, and a build of
# some test suites alone (one run with --match-path, the end-to-end run's) drew others, the gate then refusing a
# snapshot written after it, or writing one the next whole build refuses
forge build >/dev/null

if [ "${1:-}" = "--update" ]; then
  mkdir -p snapshots
  layout >snapshots/storage-layout.txt
  forge snapshot "${GAS[@]}" --snap snapshots/gas.txt
  echo "snapshots/ written: review the diff and commit it"
  exit 0
fi

echo "Storage layout"
if ! diff -u snapshots/storage-layout.txt <(layout); then
  echo "The storage layout changed: if that is intended, run scripts/snapshots.sh --update and commit the snapshot" >&2
  exit 1
fi
echo "Gas"
if ! forge snapshot "${GAS[@]}" --check snapshots/gas.txt; then
  echo "The tests' gas changed: if that is intended, run scripts/snapshots.sh --update and commit the snapshot" >&2
  exit 1
fi
echo "Storage layout and gas as committed"
