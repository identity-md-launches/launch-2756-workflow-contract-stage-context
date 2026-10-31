# Independent Hamster Nap tests

These tests supplement the accepted implementation's suite. Production contracts,
configuration, dependencies, and ABI exports are unchanged.

| File | Coverage |
| --- | --- |
| `HamsterNapHook.independent.t.sol` | 1,000 fuzz cases at the last-second/first-second boundary; dust before and during a nap; delayed third-round certification; interrupted zero runs; multiple naps spanning page boundaries; atomic rollback after a later page reverts; accumulating rejected payouts, failed and repeated withdrawals; failsafe/deferred-debt isolation and recovery; malformed core responses; exact-input/output sells and LP fee collection with an unavailable core; price-limited partial fills (exact input and exact output) on both sides of the boundary second, their refunds to a rejecting sender wallet, a late backlog that restarts the failsafe clock, and sells that cannot move it; a failsafe over a partly readable backlog that pays the certified nap to its own winner first; 512 fuzz cases at the failsafe's opening second (a buy one second before counts, a buy at or after it wins nothing). |
| `HamsterNapHook.fork.t.sol` | Five live-core tests at Sepolia block **12030457**, including every captured work record in rounds 483–642, configuration/frontier and invalid page bounds, three historical naps paid in order, and fresh token-only pool claim redemption. |
| `HamsterNapHook.invariant.t.sol` | Two campaigns, each **256 runs × 96 calls**, with unexpected handler reverts treated as failures. One explores ordinary settlement and one also introduces seven-day outages and failsafes. Three deterministic companions prove a deferred payout, withdrawal, failsafe, partial-fill refund, an unseen-advance `CoreNotStale`, a failsafe that settles a certified nap first, and a `NapsUnsettled` refusal over a 160-round backlog are reachable. |
| `independent/NapSequenceHandler.sol` | Random exact-input/output buys (full and price-limited partial fills) and sells, time advances, append-only certification, reverting/paused core, page-limited settlement, claim redemption, receiver rejection and withdrawals. |
| `independent/SequenceCore.sol` | Efficient offline model of sparse settled-round pages. Only closed rounds can be certified, and certified work never changes. |

The invariant oracle keeps its own linear trade history. It computes fees from actual
ETH debits, determines winners and eligible fees independently of the hook's cumulative
checkpoints, and compares awards to each receiver's ETH plus deferred debt. It also
models partial exact-input fills from the router's actual debit (fee = 2% of the ETH really
spent, the rest of the reservation owed back to `tx.origin`), and keeps its own record of when
a hook call last read a higher frontier, so the failsafe is expected to open seven days after
that sighting (or the sighted round's end) and to revert `CoreNotStale` while an advance is
unseen. For the failsafe it walks the certified backlog itself: more than eight pages (128 rounds)
unscanned must revert `NapsUnsettled` with the exact scan position, otherwise every certified nap is
paid to its own winner first (rolled back with the call if it then reverts `NothingToPay`), and the
rest goes to the last qualifying buyer whose buy happened strictly before the failsafe opened. A
reverting core skips the scan and the whole pot goes to that buyer. `settleNaps` on an unreadable
core must revert `CoreUnreadable`. It checks the actual PoolManager ERC-6909 balance against `claimsHeld`, fee and refund
conservation, the pot and debt backing, `lastSeenFrontier` / `frontierSeenAt`, scan progress,
nap counts, and NAP supply/balances. The handler
does not catch unexpected errors. A deterministic companion proves that a deferred
payout, successful withdrawal, and failsafe are reachable.

The inherited test router is a prefunded simulation: trader identities are pranked
while settlement comes from the router. Contract origins model a sender wallet with
code (for example delegated-account behavior); the workflow explicitly selects
`tx.origin` as the buyer. These helpers are not production routers.

## Fork and offline execution

The fork suite reads `vm.envOr("SEPOLIA_RPC_URL", string(""))` and calls
`vm.createSelectFork(url, 12030457)`. Only an empty variable causes a skip. A bad
endpoint, absent live contract, ABI mismatch, or failed assertion fails the test.
No endpoint or key is stored in this repository, and no test modifies the environment.

The live SqueekCore proxy is never etched, mocked, or given altered storage on the
fork. Historical buys use local timestamps over the fixed live ledger; they do not
roll to another block. The PoolManager, token, hook, and router are locally deployed.
The ordinary suite and captured-round replay remain fully offline.

Run with the assignment seed:

```sh
FOUNDRY_FUZZ_SEED=0xfbaf61498d090e9328f47570cd503c9b9f7a6967092682129c4f05d58ca2d30c forge build
FOUNDRY_FUZZ_SEED=0xfbaf61498d090e9328f47570cd503c9b9f7a6967092682129c4f05d58ca2d30c forge test
```

## Findings from the previous round, settled

Both high-severity findings reported last round are fixed in the current tree, and these tests
check the fixes rather than restating the findings:

1. **Partial exact-input dust fills.** The fee and the 0.001 ETH threshold now follow the pool's
   fill; the unused reservation is credited to the buyer. Checked by
   `test_partialFillsAroundTheBoundaryFollowExecutedEth` (a dust fill offering 1 ETH in the last
   second before round 651 cannot displace Alice, who receives exactly the fees before 651),
   `test_partialRefundToRejectingOriginIsHeldAndDoesNotBlockNap`, and the `buyLimited` handler
   action in both invariant campaigns.
2. **Failsafe dated from the round end.** The failsafe now counts from the hook's last sighting of
   a frontier advance. Checked by `test_lateBacklogSeenByClaimRestartsFailsafeClock`,
   `test_onlyBuysAndClaimsMoveFailsafeClock` and the recovery campaign's observation-dated model.

## Finding this round

The implementation changed after the last round: the failsafe now settles certified naps first and
pays the last qualifying buyer *before the failsafe opened*. The tests above cover that design. One
consequence is reported in `.imd-findings.json` (medium) and is not asserted anywhere in this suite.
With a dead core the opening moment never moves. So after one failsafe payout, every later fee goes
to the same stale buyer, failsafe after failsafe. And if no qualifying buy came before the opening,
`failsafe()` reverts `NoQualifyingBuyer` for ever, which locks every later fee. Both break rule 5
("the last qualifying buyer can take the pot"). The finding carries a self-contained proof that fails
on the current code. The invariant model only calls the failsafe at its opening moment, so it never
hits this case.

## Remaining limits (not defects)

- The hook cannot learn when the core really advanced, so the failsafe can open up to seven days
  late, never early. An advance that only the `failsafe()` call itself finds reverts with
  `CoreNotStale`, and that revert also undoes the sighting. So the failsafe stays shut until a buy
  (dust is enough) or a `settleNaps` call records it. That is the conservative direction, and a
  way out always exists, because buys read the core even when `roundPage` does not work.
- If the core advances and then starts reverting before any hook call sees the advance, the hook
  dates the failsafe from its last successful sighting. This is the documented exit for a dead core.

Passing tests do not imply launch readiness.
