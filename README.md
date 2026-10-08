# Duel contracts

The smart contracts of [Duel](https://divine.sh/duel), DIVINE's launchpad on Robinhood Chain: every launch is a
perpetual duel between two tokens, traded in three Uniswap V4 pools whose hook runs four-hour rounds, and each round's
pot buys back and burns the side that won it. This is the code deployed on Robinhood Chain (version 1, "Petunia"), byte
for byte; the [documentation](https://divine.sh/docs/duel/contracts/overview) explains it for traders and integrators.

Solidity 0.8.26, Foundry, Uniswap V4 (v4-core v4.0.0), OpenZeppelin 5.7. [MIT licensed](LICENSE). A vulnerability is
reported privately, and rewarded: see [SECURITY.md](SECURITY.md).

| Contract | Role |
| --- | --- |
| `DuelToken` | Plain fixed-supply ERC-20 (1B, burnable) with EIP-2612 permits, signed in an EIP-712 domain named `Duel`. No owner, no taxes, no transfer hooks. |
| `DuelHook` | V4 hook shared by the three pools of every pair: fees in ETH, anti-snipe tax, burned switch fee, zero-fee internal arbitrage, gauge oracle, four-hour rounds and buyback-and-burn of the winner, with all-time volume and buyback totals per pair. Liquidity can only be added by the factory and never removed. |
| `DuelFactory` | Creates a pair in one transaction (two tokens, three pools, locked positions, creator launch buys), with its category: a number the app names (`CreateParams.category`, kept in the hook's pair and its `PairRegistered`; 0 for none, any other accepted so that the list can grow). Owns the bounded configuration, which only changes after a 48-hour delay; a launch commits to the configuration its launcher read (`configHash`), and reverts `ConfigChanged` if another applied meanwhile. Its owner sets the protocol's rate of its fee share, at once (`setProtocolRate`). |
| `DuelRouter` | Exact-input router used by the app: a swap in one pool (`swapExactIn`), or a switch through ETH in one transaction (`swapThroughEth`: the side sold in its ETH pool, all the ETH spent in the other's without leaving the PoolManager); each also with the caller's permit for the token sold (`swapExactInWithPermit`, `swapThroughEthWithPermit`), a sale in one transaction. A sale into an ETH pool that stops at the pool's launch price, its ETH spent, is sent again for the rest once the hook's realignment has bought back from the pool what the pool between the sides takes, up to `SALE_PASSES` (8) swaps. What the realignment can no longer buy back (dust under its threshold, or more when the other side's pool lacks the ETH that would refill this one), `sell` takes on through the pool between the sides into the other side's ETH pool, where the realignments moved the ETH that pays for it (`sellWithPermit` with a permit): a holder leaves whole in one transaction. Any V4 router (Universal Router, terminals) works too, in one swap: a sale bigger than what the pool pays for leaves the rest with the seller (see Fork tests). |
| `DuelLens` | Read-only aggregation for the app. |
| `DuelSimulator` | Never deployed: the app places its code on the trader's address for one `eth_call` (a state override), to run a trade or a switch through ETH as the trader and read the split after it. |
| `DuelMath` | Launch prices, liquidity sizing, closed-form optimal arbitrage, snipe tax curve, EMA, gauge. |

## Deployments

Robinhood Chain (chain id 4663), deployed in block 80,705,328, the sources verified on
[robin.etherscan.io](https://robin.etherscan.io):

| Contract | Address |
| --- | --- |
| `DuelFactory` | [`0x3c6e7f9Bc507a442237AF1721B2294686495BD54`](https://robin.etherscan.io/address/0x3c6e7f9Bc507a442237AF1721B2294686495BD54) |
| `DuelHook` | [`0x5F746B7B1722e9bb3849EEa97061Df50F715AAEc`](https://robin.etherscan.io/address/0x5F746B7B1722e9bb3849EEa97061Df50F715AAEc) |
| `DuelRouter` | [`0x9e484C17E7d263F084Ab226a72FCdf301145d6D1`](https://robin.etherscan.io/address/0x9e484C17E7d263F084Ab226a72FCdf301145d6D1) |
| `DuelLens` | [`0x1677d3C0a1F9Ae00519AD08C68674f63fe945389`](https://robin.etherscan.io/address/0x1677d3C0a1F9Ae00519AD08C68674f63fe945389) |

The factory is owned by a Safe, `0x427980911ad32b2b2FA6F5E2894Fa950783f84F2`, which is also the treasury. Each duel's two
tokens are `DuelToken`s the factory creates. [`deployments/robinhood.json`](deployments/robinhood.json) lists the same,
with the transactions that created them, and `node scripts/check-deployed.mjs` (after `forge build`) checks that the
code at each address is this repository's, byte for byte, the values set at deployment (immutables) aside.

## Economics (v1 defaults)

| | |
| --- | --- |
| Pools | ETH/A and ETH/B hold 98% of their side's supply (single-sided, virtual liquidity); A/B holds 2% of each at 1:1 |
| Swap fee on ETH pools | 1.2%, taken in ETH: 33% protocol, 33% creator, 34% round pot; the protocol takes its rate of its 33% (`protocolRateBps`, all of it by default), the rest goes to the pot |
| Switches | through ETH: a sale and a purchase in one transaction, each paying the swap fee; the smallest through the cross pool |
| Switch fee (cross pool) | 0.5%, burned in the token the trader leaves |
| Launch fee | 0.01 ETH per pair, to the treasury |
| Anti-snipe tax | 98% at launch, halving 1.4 times a second (49% after one, 6% after three, under 1% from five), nothing from 10 s on; to the round pot |
| Internal arbitrage | attempted after every swap, from the first buy of either side; successful cycles send their profit to the round pot |
| Rounds | end every four hours, at midnight, 4 AM, 8 AM, noon, 4 PM and 8 PM UTC (a first round leaves at least four hours of trading); the time-weighted ETH price-ratio tick determines the winner; the pot may buy it back and burn what it buys at a price no higher than about 10% above its reference, its 30-minute tick EMA or its price when that is lower |

Fees and taxes are the same share of what a trader pays or receives whether the swap is exact-input or exact-output:
on an exact-output swap the hook grosses its cut up instead of taking it from the pool's side of the trade.
Swaps whose fee is taken before execution must consume their entire specified amount after that fee; otherwise the
transaction reverts with `PartialFill`. Swaps charged on the amount actually executed can still fill partially.

The cross pool holds 2% of each supply at 1:1 (`crossShareBps`, the smallest the factory allows), and the internal
arbitrage attempts to align it with the ratio of the two ETH prices. A cycle below its threshold, limited by available
ETH, or failing execution may leave a discrepancy; the cross price does not enter the round oracle. When one side is
pumped, the arbitrage sells the cross pool's stock of that side into its ETH pool and buys the other side: the two sides
are coupled, and the bigger the cross pool, the tighter. With 2%, an immediate round trip costs a buyer about 5% for 1
ETH on a fresh pair, 10% for 5 ETH and 22% for 20 ETH, and taking the lead from a side four times bigger costs about 8
ETH. With 10% it cost about 16%, 30% and 60%, and 32 ETH to take the lead, most of which lifted the leader.

On a lopsided pair the cross pool no longer holds 2% of the side behind: as the leader rose, the arbitrage sold the
cross pool's stock of it and kept the other side in its place, 29% of B's supply with A at a market cap of $10M and B at
$50K (ETH at $2,750). Whoever pumps the side behind has that stock sold into the buy. In one swap of 100 or 1,000 ETH,
more than 85% of the ETH goes to the pot and the split hardly moves: A keeps more than 98%. In small swaps a lone buyer
takes the lead, but for 1,818 ETH, almost twenty-five times the 74 ETH that separate the two pools: the arbitrage buys
the leader back with that ETH, and A's pool ends at 930 ETH instead of 78. The leader's holders can then sell into what
it lifted: if they sell everything while the buyer holds, they leave with 921 ETH for their 78, and 75 ETH stays in B's
pool for its 1,818. With two independent ETH pools, about the 74 ETH gap would have been enough to lead, and their sales
would not have touched the buyer: where one side dominates, the coupling makes a lone buyer of the other pay for the
comeback, and hands the leader's holders an exit. On a small pair it is loose. With 10 ETH from 20 holders on A and 30
ETH from one buyer on B, leading by more than three to one, the buyer collects in a day of the crowd's trading (10 ETH a
round, bought and sold) 1.66 ETH of buybacks, more than five times what its own trades put in the pot, and ends 0.67
ETH ahead; if the crowd sells everything instead, it loses 7.4 ETH. If the buyer is the duel's creator, a third of every
fee comes back to it: the same day leaves it 1.18 ETH ahead, of which about 0.24 ETH is the third of its own trades'
fees (the crowd's third a creator earns anyway). On that small pair, where A holds 97% of the split, an immediate round trip costs
a buyer of A about 2.4%, 2.7%, 3.8% and 6.8% for 0.1, 1, 5 and 20 ETH, and a buyer of B 3.6%, 12%, 32% and 61%: ahead, the
arbitrage has little of A left to sell; behind, it sells its stock of B into the buy. `test/audit/DuelLoneWhale.t.sol`
keeps these measurements, and the fresh pair's round trips above.

The cross pool is also too shallow for switches. On a pair with 1 and 0.5 ETH bought, a 0.1 ETH switch kept 41% of its
value through it and 90% through ETH; on 3 and 2 ETH, a 1.2 ETH switch kept 14% against 62%. The app quotes both roads
and trades the better, which is the cross pool only below about 0.002 to 0.02 ETH.

Rounds and the live gauge read only the two ETH pool ticks, capped at their common launch tick when a side is sold
out. The oracle integrates their difference, in cross currency order, over the round. An ETH swap activates the
round; a cross-pool trade activates it only if its own realignment changes an effective ETH tick. Buyback
realignment does not activate the next round.
At settlement, the accumulated tick difference is divided by the round duration and truncated toward zero to a
whole tick. Zero gives a draw, including a mean advantage smaller than one tick; an inactive round also draws. This
is a time-weighted average of logarithmic price ratios, not an arithmetic average of the displayed percentage.
The buyback reference is an exponential average of each ETH pool's tick with a 30-minute time constant, kept to
1/65,536 of a tick. It is not a sliding 30-minute price window.

## Security

The hook holds the ETH of every pot, creator and the protocol as ERC-6909 claims in the PoolManager; nobody can remove
the pools' liquidity positions. This does not disable V4's temporary advances during `unlock`: all participants must
settle their currency deltas before it ends, otherwise the whole operation reverts. The hook reads pool prices and
liquidity, not the PoolManager's temporary cash balance; it takes tokens out of the PoolManager only to burn them (a
switch fee, a buyback), and with that stock borrowed away inside an unlock its swap reverts rather than misaccount.
What protects them:

- Only the factory can initialize a pool on the hook, register a pair or add liquidity; nobody can remove liquidity or
  donate. Every hook callback checks it is called by the PoolManager, and the hook's own swaps skip its callbacks.
- The pot, the creator fees and the protocol fees are paid to their designated recipients (the buyback into the
  winner's pool, the pair's current creator, the current treasury). The contracts are not upgradeable. The factory
  owner can pause new pairs and propose bounded configuration changes, 48 hours ahead; paused, the factory launches
  for its owner alone, and it is deployed paused: the first pair, id 1, is its owner's, who then opens the launches
  (`setPaused`). Pair fee terms remain frozen; a
  treasury change also affects protocol fees already accumulated. The owner can also lower the protocol's part of
  every pair's swap fee at once (`DuelFactory.setProtocolRate`, `DuelHook.protocolRateBps`), down to nothing, and
  raise it back, never above the share a pair's terms give the protocol: what it leaves goes to the round pot, and
  neither the fee traders pay nor the creator's share changes. A creator can offer its role to a new address, which
  must accept it; unclaimed and future creator fees then belong to that address. A creator can also give its share of
  the fees to come to the round pots, for good (`DuelHook.giveUpCreatorFees`): the pair becomes a supporter pair, as
  one launched so, and nothing turns it back, not its creator, a later holder of the role nor the owner; the creator
  fees taken until then stay claimable. Two things the owner must not do:
  name a treasury that refuses ETH, which blocks every launch (the launch fee is sent to it) and the protocol's claim
  until another applies, 48 hours later (the deployment's check refuses one); and call `renounceOwnership`
  (OpenZeppelin's, still callable), which leaves the terms, the treasury, the pause and the protocol's rate as they
  are for good.
- A round is settled by the first swap after its end, before that swap changes any price. A price excursion reversed
  within the same transaction has no time weight in the oracle; this does not establish resistance to every economic
  strategy involving borrowed capital. Its winner comes only from the time-weighted difference of the two ETH pool
  ticks: the cross pool price never counts, and a cross-only swap that changes no ETH tick does not activate a quiet
  round. The buyback's ceiling is about 10% (953 ticks) above the winner's reference price: its 30-minute tick EMA,
  or its price as soon as that is lower (the reference follows a price down at once, up at the EMA's pace). So it
  never climbs more than that from the price it finds, whatever the average was; a price already past the ceiling
  skips the buyback, and what it does not spend stays in the pot. A realignment is attempted immediately after it; it
  may fail without changing the settled winner. A buyback can be made to wait, for about 2.6% of what it would have
  spent: a buy that takes the winner past its ceiling a second before the close, or a sale and its purchase back a
  second apart (the reference follows the dip). Nothing is taken: the pot stays for the round after, whoever wins it.
- The switch fee is taken out of the PoolManager, to be burned, before the trader's tokens come in. A switch whose fee
  is more than all the PoolManager holds of that token reverts (one wallet holding more than about 99.5% of a side,
  out of the pools, and switching it in one swap: it goes through in two), and so does a router that pays in before
  a swap in the cross pool rather than after it, as the Universal Router and Duel's do.
- The internal arbitrage never runs at a loss, never sells more into an ETH pool than that pool's ETH pays for, and
  reverts rather than leave the hook holding tokens; it runs in a `try`: a failure of its own never blocks a swap,
  while a swap or a settlement that leaves it too little gas reverts (`ArbitrageStarved`) rather than skip it.
- A sale through the router makes more swaps only into an ETH pool, only while the pool's price is under the swaps'
  limit (one sold out stays there, and a swap from there would revert), and `SALE_PASSES` at most, whatever refills
  the pool after each: each pass pays the hook's fee on its own ETH, the minimum counts them all, and the router pulls
  only what they sold. Into a pool sold out to that limit the router makes no swap at all, even when a round waits
  whose buyback would refill it: settle the round first (`DuelHook.settle`, or any other trade of the pair).
- `sell` sells into the side's own ETH pool as `swapExactIn` does, then what is left through the pool between the
  sides, full range, which takes it all (its switch fee burned, as on any switch), and into the other side's ETH pool,
  pass after pass too. Its minimum counts the ETH of both pools. What the other side's pool cannot buy back either is
  paid to the recipient in that side's token, which the minimum does not count. The router checks the pools'
  currencies (two ETH pools, and the pool between their tokens), not that they are one duel's.
- The router only pulls tokens from its caller. Its exact-input swap refunds to that caller what is left of the ETH
  it sent, and only that: ETH already on the router (it has no `receive`; a self-destruct pays it all the same) stays
  there, nobody's, and stops no caller, one that cannot take ETH included (such a caller still fails on change of its
  own: `RefundFailed`). A switch through ETH leaves its ETH in the PoolManager for the second pool to
  spend (a Duel pool spends it all, or the hook reverts the swap: `PartialFill`; on another pool, what it cannot spend
  is paid back to the caller), and the minimum is checked on the output delta, net
  of hook fees. For Duel's standard ERC-20 tokens this equals the amount received. Output tokens charging transfer fees
  do not have a guaranteed minimum net receipt.
- An assumption, which nothing in the contracts checks: Uniswap's own protocol fee stays off the duels' pools. The
  PoolManager's fee controller can set one of up to 0.1% a swap on any pool, and the hook's own swaps would pay it. The
  arbitrage sizes its cycle for none: with 0.1% on a duel's three pools, a misalignment under about 0.6% would no
  longer be realigned (the cycle loses, reverts and is skipped), and the buyback would pay the fee too. Trades,
  settlements and the books would stay exact, and no funds would be at risk. `ProtocolFeeUpdated` for a duel's pool id
  is the event to watch.

`test/audit/DuelAttacks.t.sol` keeps the attacks tried during the review as tests: exact-output sniping, a gas-starved
swap or settlement (a caller bounding the gas of `PoolManager.swap` itself used to skip the arbitrage), a one-sided launch, the first buyer of the other side, sandwiching the buyback, the settling swap, oversold
pools, pumping one side to lift the other, the triangle over and over (one side bought, switched whole into the other
through the A/B pool, all of it sold: it drains neither ETH pool, and 98% of what it loses lands in the pot), a
launcher that launches again from its refund (the factory and the hook log before any ETH leaves them, so their events
stay in order). `test/audit/DuelMev.t.sol` fuzzes the triangle over the duel's state, its size, its count and its
direction: it never pays, and the other side's pool and holders keep their ETH but for what the realignment leaves out
of line under its threshold (0.003% of the pool's depth at most, in 300 drawn triangles; the test allows 0.1%). `test/audit/DuelBuybackBot.t.sol` measures a searcher
that buys the winner a second before each close and sells it right after, into the buyback, sized for the most it can
take: at the 10% ceiling it keeps about 2.0% of what each buyback spends (0.06% of the pool's ETH), whether or not the
winner's price fell under its average before the close (anchored to the average alone, the ceiling let it keep 6 to 21%
after a 10 to 50% dip, and a wallet that pumped the winner for hours and dumped most of it a second before the close
took a third of a buyback nine times its usual size; the reference now follows the price down, and what that wallet
keeps is a few percent of a band-sized buyback), nothing when the
buyback moves the price less than two fees, and the pot still runs dry, in more closes; searchers competing for that
margin keep about 0.85% of the pot. `test/audit/DuelLoneWhale.t.sol` measures a lone buyer of the side behind against a
crowd holding the leader: buys in one swap, taking the lead, the leader's holders selling into it, a small pair where
it collects the pot the crowd's trades fill, as the duel's creator too, and the round trips of a fresh and a lopsided
pair (see Economics). `test/audit/DuelSaleRoute.t.sol` puts the sale that ends through the other side (`sell`) in
states nobody chose: runs on a duel where everyone but the last holders leaves into its side's own pool, random
histories, pools parked past their launch price by a swap's own price limit, rounds closing on the way, dust. The sale
takes every token asked, never gives less ETH than the side's own pool alone, pays what its quote said to the wei,
leaves nothing in the router, lets every holder out, stays under its gas bound, and only ever spends its caller's
tokens (an approval given to the router, a permit replayed or sent ahead, a pool of the caller's making, a recipient
that calls back). `test/audit/DuelGasUnderLoad.t.sol` measures a transaction's gas against what Robinhood Chain allows
one (32,000,000, read from the chain), however busy a duel is: six hundred trades in one round, a hundred of them in
one second, cost of each kind what the first ones did (about 250,000 to 290,000, nothing in the hook looping or growing
with the trades), the lens spends the same on the duel after them, the buy that then settles the round and spends its
pot stays under a million, the largest launch the factory takes uses under a third of a transaction, and twenty of the
largest duels fit five times in what a node gives a read (50,000,000). `test/audit/DuelFeeTerms.t.sol` draws launch
terms anywhere the factory allows them, launches two
duels under different terms on the one hook, and checks every kind of trade against the rule written out in the test:
the fee, the tax, the three shares and the pot, to the wei. `test/unit/DuelHookRoundEdges.t.sol` covers
rounds at their edges: a traded round left pending through a round nobody traded, late settlements (they give the
same result as on-time ones), the exact close, two swaps in the closing block, a duel asleep for years, launch buys, a
duel nobody traded, a pot of one wei, and several duels settled side by side.

`test/invariant/DuelInvariants.t.sol` lets random traders buy, sell and switch both ways, through both routers and
through ETH, wait for seconds or for weeks, settle and claim, and checks after every call that the hook's ETH claims
equal exactly what it owes, that no ETH or token is left in the hook, the factory or the router, that rounds end on
their four-hour boundaries and never run past their close unsettled, and that `settle` never fails. A ghost oracle
records the ETH price-ratio tick apart from the hook: every settlement's average and winner must match it.
Each successive supply decrease must also match its ERC-20 burn transfers and the hook events that explain it;
claims must actually pay their recipients, and creator handovers must change the role. The campaign requires
positive payments, burns and handovers, so failed calls or no-ops cannot stand in for those paths.
`test/invariant/DuelSearcher.t.sol` adds a searcher whose round trips in one call (a buy and its sale, a switch and
back, through ETH and back, the triangle in one swap or the router's passes) must never pay, and traders who leave a
side whole through the router: it never stops while the pool could still pay, and leaves at most dust (a thousandth and
a token) unless the pool sold out.

The four `test/unit/*Security.t.sol` suites add 59 local defensive regressions for permit signatures and rollback,
accounting and payment failures, an independent EMA reference, numerical boundaries and deployment attestation.
To run this battery without an RPC:

```bash
forge test --offline --match-path 'test/unit/*Security.t.sol'
FOUNDRY_INVARIANT_RUNS=256 forge test --offline --match-path 'test/invariant/DuelInvariants.t.sol' --invariant-depth 500 --fuzz-seed 0x000000000000000000000000000000000000000000000000000000000000d0e1
```

## Commands

```bash
forge build
forge test                                   # unit, attack, invariant and fork tests (fork tests need an RPC)
forge test --no-match-path "test/fork/*"     # without the fork tests
scripts/coverage.sh                          # the 100% gate: forge coverage --ir-minimum without the fork, invariant and
                                             # e2e tests and the optimized build's gas and size bounds
scripts/snapshots.sh                         # storage layout and tests' gas as committed in snapshots/ (--update)
node scripts/mutation.mjs --sample 120       # mutation testing: a test must fail on each of 120 mutants (40 min)
node scripts/check-deployed.mjs              # the code on Robinhood Chain is this build's, byte for byte
```

Coverage of `src/`: **100% lines, statements, branches and functions**, measured again on 2026-10-03.
`scripts/coverage.sh` checks it. Tests and coverage say what the code does, not that its economics hold: that takes an
independent review.

Coverage says every line runs; mutation testing, whether a test notices when one changes. `scripts/mutation.mjs`
makes mutants of `src/` by eight small rules (a comparison, an operator or a literal changed, a guard or a `!` removed,
a return of zero), applies one at a time and runs on it every test that needs no node, then puts the source back. It
builds with the `mutation` profile (via-IR with the optimizer down to what `--ir-minimum` keeps: half the time, and
every test passes on it but the gas and size bounds of the optimized build) and without forge's dynamic test linking,
which would leave in the deploy script the hook's creation code as it was. On 2026-10-04, of 210 mutants drawn from the
hook, the router, the math library and the factory, the tests killed 186 and one did not compile. Of the 23 left, 13
change nothing a trade can see, or only in states no trade reaches: the PoolManager refuses a swap of nothing before
the hook sees it, a return value nobody reads, a gas threshold between the two a failed arbitrage leaves, a price
limit only an emptied pool reaches. Tests added then kill the 10 others (the arbitrage's margin, a switch fee of one
wei, the router's eight passes, a minimum met exactly, a caller that cannot take ETH, a buy bigger than its pool or
from one sold out, the liquidity over any range), and the arbitrage's threshold of 0.1%, which a first trial let by.

`snapshots/storage-layout.txt` lists each contract's storage, a struct's members included: a variable inserted before
others moves them, and a test that writes a slot by its number (`vm.store`) or a state override would then write the
wrong one. `snapshots/gas.txt` is `forge snapshot` of the tests that need no node, the fuzzed ones drawn from a fixed
seed so that two runs agree. It builds every source first (the fuzzer reads its dictionary in the compiled sources: a
build of some suites alone drew other inputs) and without forge's dynamic test linking, under which an incremental build
and a clean one gave other gas and other fuzzed inputs, and leaves out the one test whose gas depends on the checkout's
path (it reads a build artifact that names it). `scripts/snapshots.sh` fails on any difference, or on a test the
snapshot lacks; after an intended change, `--update` writes both again, and the diff shows what moved.

Forge 1.8 links tests dynamically by default: after a change inside a function of `src/`, a plain `forge test` keeps the
deploy script's copy of the hook as it was, and the deployment's attestation test fails on it. `forge test
--no-dynamic-test-linking` (or `forge build --force` first) builds everything again.

### Fork tests

`test/fork/DuelFork.t.sol` runs against the live Uniswap V4 deployment of Robinhood Chain: the hook and the factory are
deployed as the script deploys them, then pairs trade through the real Universal Router (including Permit2), the
real V4 Quoter is checked against execution, and a round is settled and paid out.

It also pins what third-party apps and aggregators get through the Universal Router, which makes one swap where Duel's
router sells pass after pass. A sale bigger than what the pool pays for sells what all the pool's ETH pays for, down to
its launch price: the swap runs on to the router's price limit, the hook charges a sale on the ETH paid out (its
`PartialFill` rule binds only fees taken before a swap), and Permit2 pulls only what was settled, so the rest stays in
the seller's wallet. The hook's books are checked to the wei (the fee's shares, and what the realignment after the sale
captures for the pot), and the rest, sold in a second transaction into what that realignment bought back, brings the
seller exactly what Duel's router gives in one. The live quoter refuses to quote such a sale (`NotEnoughLiquidity`), and
the router checks a minimum against the ETH of its one swap: a minimum of what the whole amount is worth fails, but 0.5%
under it lets the partial sale through. An exact-output buy gets exactly its tokens for the quoter's price, never above
its maximum, and pays the hook the rate of an exact-input buy, anti-snipe tax included; an exact-output sale gets
exactly its ETH, or reverts (`PartialFill`) when the pool cannot pay it with the fee on top.

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
```

### The live deployment, end to end

`test/e2e/DuelDeployed.t.sol` takes a deployment's addresses and trades a duel's whole life on it, in a fork: a launch and
its anti-snipe window, buys and sales by several traders, switches both ways, a round's close and its settlement with
the buyback and the burn, the creator's and the treasury's claims, and the books of every duel after it. Nothing is
sent. On Robinhood Chain's:

```bash
DUEL_E2E=true DUEL_HOOK=0x5F746B7B1722e9bb3849EEa97061Df50F715AAEc DUEL_FACTORY=0x3c6e7f9Bc507a442237AF1721B2294686495BD54 \
DUEL_ROUTER=0x9e484C17E7d263F084Ab226a72FCdf301145d6D1 DUEL_LENS=0x1677d3C0a1F9Ae00519AD08C68674f63fe945389 \
  forge test --match-path "test/e2e/*" --fork-url https://rpc.mainnet.chain.robinhood.com
```

## Local chain

A fork of Robinhood Chain has the live PoolManager, Universal Router, V4 Quoter and Permit2 at their addresses, and
`script/Deploy.s.sol` deploys Duel on it with anvil's unlocked default accounts: no key is involved. The public node
keeps a past block's state only a little while (it is no archive node): a fork lasts about an hour.

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com
DUEL_CHAIN_ID=4663 DUEL_OWNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 DUEL_TREASURY=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
  --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

## Deployment

```bash
export DUEL_CHAIN_ID=4663    # the chain it is for: the script sends nothing to another
export DUEL_OWNER=0x...      # multisig owning the configuration
export DUEL_TREASURY=0x...   # receiver of protocol fees
forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast
```

The script checks the chain and the PoolManager's code before sending anything (Robinhood Chain's is pinned in
`script/DuelDeploy.sol`; another PoolManager on a public chain needs `POOL_MANAGER_CODEHASH`), then every link of what
it deployed, and a treasury that takes ETH (one wei, in the simulation). `script/Verify.s.sol` checks the same on the
chain itself once the receipts are in, sending nothing; on the live deployment, whose owner has opened launches since
(`DUEL_LAUNCH_STATE=false` leaves aside the state a deployment starts in):

```bash
DUEL_CHAIN_ID=4663 DUEL_LAUNCH_STATE=false \
DUEL_OWNER=0x427980911ad32b2b2FA6F5E2894Fa950783f84F2 DUEL_TREASURY=0x427980911ad32b2b2FA6F5E2894Fa950783f84F2 \
DUEL_FACTORY=0x3c6e7f9Bc507a442237AF1721B2294686495BD54 DUEL_HOOK=0x5F746B7B1722e9bb3849EEa97061Df50F715AAEc \
DUEL_ROUTER=0x9e484C17E7d263F084Ab226a72FCdf301145d6D1 DUEL_LENS=0x1677d3C0a1F9Ae00519AD08C68674f63fe945389 \
  forge script script/Verify.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
```

`--rpc-url robinhood` reads the node's address from `ROBINHOOD_RPC_URL`. The sources go to Etherscan with the
broadcast (`--verify --verifier etherscan --chain 4663`, an Etherscan API key in `ETHERSCAN_API_KEY`), and each duel's
tokens with `forge verify-contract`.

On the testnet (chain 46630, the same PoolManager and V4Quoter), `--rpc-url robinhood_testnet`, and
the sources verified on its Blockscout with
`--verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/`.

The hook's address must carry its permission flags (`0x2AEC`), and the hook and the factory name each other: one
transaction deploys both, through `script/DuelBootstrap.sol`, a contract the deployer's account creates. It deploys
the hook with CREATE2 at the salt the script mined for its own address, then the factory with CREATE at the address the
hook was built for. Nobody else can create at those addresses (a shared CREATE2 deployer let anyone deploy the same hook
first), and a nonce used between the simulation and the broadcast only makes that transaction fail, deploying nothing:
the bootstrap checks the hook landed at the address the script planned, as its flags alone would also hold at one
address in 16,384. Its creation code carries the hook's and the factory's: it must stay under EIP-3860's 49,152 bytes,
which a test checks. With its arguments it weighs 48,871 bytes, 281 to spare: the limit that binds any addition to the
hook or the factory, well before their own (2,947 and 1,684 bytes under EIP-170's 24,576).

## Robinhood Chain references

| | |
| --- | --- |
| Chain ID | 4663 (testnet 46630) |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Universal Router 2.1.2 | `0x204FAca1764B154221e35c0d20aBb3c525710498` |
| V4 Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

## Contributing

Issues and pull requests are welcome; a vulnerability is reported privately, as [SECURITY.md](SECURITY.md) says, never
in an issue. A change keeps `forge test`, `scripts/coverage.sh` (100%) and `scripts/snapshots.sh` passing, and says in
its description what it changes for traders. The deployed contracts cannot be upgraded: a change here only reaches a
launchpad deployed after it (version 2).

## License

[MIT](LICENSE). The libraries under `lib/` keep their own licenses.
