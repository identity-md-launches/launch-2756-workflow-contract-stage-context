# Hamster Nap (NAP)

A last-buyer-before-bedtime game on Squeektoshi, SqueekChain's real hamster, as one Uniswap v4
hook on Ethereum Sepolia. Every buy of NAP pays 2% of its ETH into a pot the hook holds and makes
the buyer the latest buyer. When SqueekCore certifies a nap, the last buyer before the nap began
takes the pot. An unofficial community game with Sepolia test tokens of no value, not affiliated
with SqueekChain.

This repository is the contract stage: the token, the hook, their tests and ABI documentation.
The launch (publish, attest, admit, deploy) and the website come after it.

## What the launch deploys

| Contract | File | Constructor arguments |
| --- | --- | --- |
| `NapToken` | `src/NapToken.sol` | none |
| `HamsterNapHook` | `src/HamsterNapHook.sol` | `IPoolManager poolManager` = `$poolManager`, `address factory` = `$factory` |

`NapToken` is the standard launch token: name "Hamster Nap", symbol "NAP", 18 decimals,
exactly 1,000,000,000 tokens (10^27 minor units) minted once to its deployer, the launch factory.
No owner, mint, pause, blocklist, fee or upgrade. The brief asks for nothing else of the token;
the game's fee is the hook's.

`HamsterNapHook` has no owner. It takes no owner argument because the brief forbids owner powers:
no pause, no upgrade, no signer, no keeper, no withdrawal by anyone but winners. The pot is the
hook itself (its ETH balance plus any ERC-6909 ETH claims on the PoolManager), exposed through
`pot()`; there is no third contract.

Pool terms the manifest step writes: native ETH pair (`pairedCurrency` zero), LP fee 12500
(1.25%), tick spacing 60. The hook accepts any LP fee the factory opens the pool with; it checks
only that the sender is the factory, that the pool is paired with native ETH, and that no pool is
bound yet. The deployer sets the opening price.

## Hook configuration

Permissions, in the OpenZeppelin Wizard's shape:

```json
{
  "hook": "BaseHook",
  "name": "HamsterNapHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "access": "none (the brief forbids owner powers)",
  "info": { "license": "MIT" }
}
```

Address flags: `0x20CC` (8396). The hook's address must carry exactly these bits; the deployer
mines the CREATE2 salt, and the tests mine one the same way.

Callbacks and why each is there:

- `beforeInitialize` (added for the launch): only the launch factory (`$factory`) may open the
  pool, once, paired with native ETH. It binds the pool id and reads the token from the PoolKey.
  Nobody can open the predicted pool before the factory deploys the hook.
- `beforeSwap` + `beforeSwapReturnDelta`: on an exact-input buy the fee is carved out of the
  specified ETH input, so the pool swaps the remaining 98%. Runs the mainnet-only Sworn check.
- `afterSwap` + `afterSwapReturnDelta`: on an exact-output buy the fee is added to the ETH the
  buyer pays (the unspecified side). For both buy kinds this callback collects the fee in ETH,
  records the buy, updates the latest buyer and observes the core's frontier.
- No remove-liquidity callbacks: the factory's fee collect (a zero liquidity change) passes
  untouched. Every callback refuses callers other than the PoolManager.

`BaseHook` is a minimal base of our own in `src/base/BaseHook.sol` (the current v4-periphery no
longer ships one); it validates the address flags in the constructor and calls no other contract.

## The game

Rules as implemented, with the constants in `HamsterNapHook`:

1. **Buy fee.** A buy (ETH in, NAP out; ETH is always `currency0`) pays `FEE_BPS` = 200 basis
   points, 2% of the ETH the buyer really spends, fee included. Exact input: `beforeSwap` reserves
   2% of the offered input and the pool swaps the other 98%; `afterSwap` reads the ETH the pool
   actually consumed from the pool's own delta. On a full fill the fee is the reservation. On a
   partial fill (a price limit or exhausted liquidity left part of the input unused) the fee is
   pool ETH × 200 / 9800, 2% of the executed gross, and the unused part of the reservation is
   credited to the buyer in `owed` (event `FeeRefunded`), pulled with `withdrawOwed()`. Nothing is
   pushed to anyone during the swap, so the refund cannot fail or be griefed. Exact output: fee =
   pool ETH × 200 / 9800 on the ETH actually paid, so a partial fill is right by construction.
   Sells pay no game fee. The fee is settled in ETH inside the swap: the hook takes native ETH
   when the PoolManager's ETH balance covers it, and mints itself an ERC-6909 ETH claim when it
   does not (a fresh manager or a pool seeded with tokens only). Claims are redeemed into ETH
   before any payout, and anyone may call `redeemClaims()`. Nothing is ever left in NAP.
2. **Latest buyer.** A buy whose executed gross (pool ETH plus fee) is at least
   `MIN_QUALIFYING_BUY` = 0.001 ETH makes the transaction's sender wallet, `tx.origin`, the latest
   buyer, as the brief specifies. The input a buyer offered but the pool did not use counts for
   nothing: a 0.001 ETH order that fills for a sliver is a dust buy. Smaller buys still pay the fee
   into the pot. The buy's SqueekCore round is recorded with it.
3. **Nap.** `NAP_ROUNDS` = 3 consecutive settled rounds with zero work. It begins at its first
   zero-work round `s`. A run of more than three zero-work rounds is one nap and pays once; the
   next nap can only begin after a round with work.
4. **Winner and pot.** The winner of the nap at `s` is the latest qualifying buyer as of the last
   buy recorded in a round before `s`. The pot paid is all fees from buys in rounds before `s`
   that have not been paid out yet. Fees from buys during or after the nap stay for the next
   game. If no qualifying buyer existed before `s` (dust only), the nap settles with no payout and
   the pot waits.
5. **Claim.** `settleNaps(maxPages)` may be called by anyone. It reads `state()` for the certified
   frontier and `roundPage` 16 rounds at a time from the last scanned round, pays every nap found
   in order, and keeps its position between calls, so a long gap can be worked through in several
   transactions. A nap whose third round is not yet certified waits. When the core cannot be
   read (`state()` or `roundPage` reverts, has no code, or no longer decodes) the call reverts
   with `CoreUnreadable` and keeps nothing.
6. **Winners that cannot receive ETH** are credited in `owed` and pull with `withdrawOwed()`.
   The game never blocks on a payout: the payout call gives the winner's wallet a bounded
   `PAYOUT_GAS` = 100,000 gas (plus the EVM's 2,300 for a value transfer) and copies none of its
   return data, so a wallet that reverts, burns gas or answers with a payload sized to its gas
   (an EOA carrying EIP-7702 code can do all three) only fails its own payout and is credited.
   `withdrawOwed()` forwards all gas, so a wallet that needs more than the stipend collects
   there. `owed` also holds partial-fill fee refunds (rule 1).
7. **Failsafe.** When the core's `settledThroughRound` has stood still for `FAILSAFE_DELAY` =
   7 days, `failsafe()` pays the failsafe winner: the last qualifying buyer whose buy happened
   before the failsafe's cutoff, `failsafeCutoff()` = max(`failsafeOpensAt()`, now − 7 days).
   It pays the fees collected through that buyer's last recorded buy before the cutoff that are
   not yet paid out; fees from later buys stay in the pot. Anyone may trigger it; only that buyer
   is paid. A buy after the cutoff pays its fee into the pot but cannot take the failsafe
   position now, so the pot cannot be sniped with a 0.001 ETH buy placed ahead of the failsafe
   call; it still counts as a normal buy for the next nap if the core turns out to be alive. The
   cutoff rolls forward with time while the core stands still, so if the core never returns the
   failsafe can be called again: seven days after a later buy, its fee (and any dust fees since
   the previous payout) goes to the buyer who was the last qualifying buyer when it was paid, and
   a buyer who first qualified after the opening is paid once their buy is seven days old. No
   fee is ever locked and no earlier winner is paid twice. `failsafeWinner()` shows who the
   failsafe would pay now and how much; `NothingToPay` means nothing is payable yet.
   Before paying, the failsafe settles every nap the core certified before it stalled, through
   `lastSeenFrontier`, each to its own winner, so a nap that nobody claimed during the stall is
   not swept into the failsafe: it scans up to `FAILSAFE_SCAN_PAGES` = 8 pages (128 rounds, about
   21 hours) itself and reverts with `NapsUnsettled(scanRound, frontier)` when more is pending,
   in which case `settleNaps` must catch up first. When the core's pages cannot be read at all
   (a reverting, codeless or re-ABI'd core), nothing in the backlog can be certified and the
   fees through the cutoff all go to the failsafe winner.
   The hook sees the frontier only when it reads the core (every buy,
   every claim call and the failsafe itself), so it dates staleness conservatively from
   `frontierSeenAt`, the moment it last saw the frontier advance, or from the frontier round's end
   if that is later: `failsafeOpensAt()` = max(`roundEnd(lastSeenFrontier)`, `frontierSeenAt`) +
   7 days. An advance the failsafe call itself finds restarts the 7 days, so a core recovering a
   backlog is never stale however old the rounds it is settling. Until the core has been read once
   (a core unreadable from the start), the clock runs from the game's start, not from genesis. If
   the core reverts, the last frontier and sighting the hook recorded are used.
8. **First game, mainnet only.** On chain id 1, until the first nap is settled, a buy requires
   `balanceOf(tx.origin) >= 1` on the Sworn registry `0x0da2679000ea5380d1361cc3cca7d4e8c881f766`,
   read live on every buy. On Sepolia and every other chain the check is skipped. Sells always
   work, also when the registry has no code.
9. **The core is read only at swap and claim time.** Buys read `state()` through a staticcall
   that tolerates a reverting or codeless core; sells never read it. Constructors read nothing.

Events: `Buy` for every recorded buy (with the executed gross, the fee and `qualifying`),
`NapSettled`, `FailsafeTaken`, `PayoutDeferred`, `FeeRefunded`, `OwedWithdrawn`,
`ClaimsRedeemed`, `FrontierSeen`, `GameStarted`, `PoolBound`.

Views for the website: `pot()`, `latestBuyer()`, `buyCount()` / `buyAt(i)` (round, timestamp,
fees through it, latest buyer then), `winnerBefore(napStart)`, `failsafeWinner()`,
`failsafeOpensAt()`, `failsafeCutoff()`, `scanRound()`, `zeroRun()`, `lastSeenFrontier()`,
`owed(wallet)`.
`decodeRoundPage(bytes)` is a pure helper the hook calls on itself to read the core's pages
tolerantly; it has no state and nothing to protect.

### Where the ETH goes

Every wei of fee goes into the pot and leaves it only to a nap winner or the failsafe winner.
Nothing goes to the owner, the requester, IMD or any other address. The only other ETH the hook
holds is what it owes back: deferred payouts and partial-fill refunds, both in `owed`. Invariant
kept by the tests: `hook ETH balance + claimsHeld == pot() + totalOwed`.

## SqueekCore facts used

Verified on Sepolia on 2026-10-31 at block 12030371 against the live proxy
`0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44` (implementation at
`0x284747c4664af2203e7a90a2ee76f22b6b5e6889`):

- `configuration()`: `genesisTimestamp` 1793022600, `roundDuration` 600, `maxRoundsPerBatch` 16.
- `state().settledThroughRound` was 642 at timestamp 1793407932, which is round 643 under
  "round 1 starts at genesis": `round(t) = (t - genesis) / 600 + 1`. The docs say the same.
- `roundPage(after, through, max)` returns only rounds with work, start exclusive, end
  inclusive, and reverts with `InvalidRoundPageBounds` on a reversed range, an end past the
  frontier, or more than 16 records (all three reproduced live). `roundPage(0, 0, 0)` returns the
  launch position.
- The published ABI is copied to `docs/abi/SqueekCore.json`; `src/interfaces/ISqueekCore.sol`
  declares the three reads from it.

These are constants in the hook (`CORE`, `GENESIS_TIMESTAMP`, `ROUND_DURATION`), as the brief
requires. If SqueekChain ever changes the core's address, genesis or round length, this hook does
not follow; the failsafe is the exit.

## Tests

`forge test` runs 78 tests in five suites (the verifier re-runs them with
`FOUNDRY_FUZZ_SEED=0xfbaf61498d090e9328f47570cd503c9b9f7a6967092682129c4f05d58ca2d30c`):

- `test/HamsterNapHook.t.sol`: permissions, callback access, initialization from the factory
  only and once, native pair only; fees on exact-input and exact-output buys, no fee on sells,
  dust buys, the 0.001 ETH threshold, `tx.origin` as the buyer; partial fills against a price
  limit (a 0.001 ETH order that fills for dust pays 2% of the executed ETH, gets the rest of its
  reservation back through `owed`, does not take the latest-buyer position and does not win the
  nap; a partial fill above the threshold still qualifies; a near-zero fill pays nothing and is
  not recorded; a partial exact-output fill; the exact `Buy` and `FeeRefunded` figures; a fuzz
  over offered amounts and limits); the round boundary (a buy in the last second before round `s`
  against the first second of `s`), naps of 2 against 3 rounds, a nap not yet fully settled, a
  long nap paying once, buys during a nap, several naps in one call, pagination, a nap with no
  qualifying buyer; the failsafe (closed, open, shut again when a buy or the failsafe call itself
  sees the frontier advance after eight idle days, dated from the game's start with a core that
  was never readable, with a reverting core, without a buyer; a certified but unclaimed nap paid
  to its own winner before the failsafe pays the rest; `NapsUnsettled` over a 22-page backlog
  until `settleNaps` catches up; the whole pot when the backlog cannot be read from a reverting
  or codeless core; a buy at the moment the failsafe opens, or later, not taking the pot while a
  buy one second earlier does, its own fee waiting in the pot and reaching it seven days later;
  with a dead core, a buyer who qualifies after an earlier payout paid once their buy is seven
  days old and the earlier winner not paid again, and a game opened by dust only paying the
  first later qualifying buyer; such a late buy still counting for a later nap when the core
  proves alive); a reverting, codeless, paused or re-ABI'd core with sells and buys still
  working and claims reverting with `CoreUnreadable`; a winner contract that rejects ETH and
  later withdraws; a winner wallet that answers the payout with a gas-sized revert or return
  payload (the EIP-7702 return bomb) at 30M gas, credited and not blocking the next nap or the
  failsafe, then collecting through `withdrawOwed`; the payout gas bound (an ordinary wallet gets
  the whole stipend and never more, a wallet that needs 150k gas is credited); a re-entrant
  winner; and a fuzzed ETH accounting run (pot = fees in − payouts) over mixed buys,
  exact-output buys and sells.
- `test/HamsterNapHook.claims.t.sol`: a fresh PoolManager whose pool was seeded with tokens only:
  the first buy's fee becomes an ERC-6909 claim, later fees come as ETH, claims are redeemed by
  anyone, by a nap payout and by the failsafe.
- `test/HamsterNapHook.sworn.t.sol`: the mainnet-only Sworn check, read live, skipped on Sepolia,
  lifted after the first nap; sells always work.
- `test/HamsterNapHook.sepolia.t.sol`: the game replayed over real round pages captured from the
  live core (`test/fixtures/SepoliaRounds.sol`, rounds 483–642): the three real naps at 503, 519
  and 540 are found and paid in order, the single zero-work rounds 498 and 640 are not naps, the
  mock reproduces the captured pages and the documented error cases.
- `test/NapToken.t.sol`: supply, decimals, a transfer, no mint.

`test/mocks/MockSqueekCore.sol` reproduces the documented read behaviour of the core and can be
switched to revert or report `paused`. No fork test is included: the task names no RPC and tests
read no environment variables. A fork run of `test/HamsterNapHook.sepolia.t.sol`'s scenario
against the live core at block 12030371 is still owed before launch and belongs to the review.

The protected floor tests (`.imd/reads/protected/univ4_hook/*.t.sol`) compile against this tree
(`src/HookFlags.sol`, `test/mocks/MockERC20.sol`, `test/mocks/Swapper.sol`,
`test/floor/OwnerChecks.sol`) and passed locally against the built creation code: 13 of 13.

## Build

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`optimizer_runs = 44444444`, `via_ir = false`; no `ffi`, no `fs_permissions`. Dependencies are
vendored as plain files under `lib/` (no submodules): Uniswap v4-core `src/`, forge-std `src/`,
OpenZeppelin Contracts v5.4.0 `contracts/` (mocks removed), and solmate's `Owned.sol`, which
v4-core's `ProtocolFees` imports. v4-periphery is not used.

## Assumptions and choices

- The buyer is `tx.origin`, as the brief specifies. A smart-wallet or relayed buy records the
  relaying EOA. Using `tx.origin` is a known pattern to avoid for authorization; here it only
  decides who the latest buyer is and was a stated requirement.
- The game starts at the pool's first swap of either direction (the round it happens in is where
  the nap scan begins). A nap in progress at that moment counts as beginning there and has no
  winner, which ends the first game.
- A nap is a maximal run of zero-work rounds; one payout per run. A settled round missing from a
  page is zero work, per the docs. Rounds past the frontier are unknown and are not scanned.
- Exact-output buys pay a fee equal to 2% of the gross (net × 200 / 9800), so both buy kinds pay
  the same rate on what the buyer spends.
- v4 lets a hook change the specified side of a swap only in `beforeSwap`, before the fill is
  known, so an exact-input buy's 2% is reserved on the offered input and reconciled in
  `afterSwap` against the pool's real fill. The unused reservation is refunded as a credit in
  `owed`, not pushed during the swap: a push to the router would be lost by most routers, a push
  to the wallet could fail or re-enter, and a credit never blocks the swap. The buyer settles the
  full reservation with the PoolManager and pulls the difference with `withdrawOwed()`. The
  website should show a wallet's `owed` balance next to the buy panel.
- The failsafe is callable by anyone but pays only the last qualifying buyer before its cutoff.
  "Not advanced for 7 days" is dated from the hook's last sighting of an advance
  (`frontierSeenAt`), or from the frontier round's end if later. The sighting is an upper bound
  on when the core really settled that round, so the failsafe can open late but never early.
  Between interactions the hook sees nothing, so a core that advanced while nobody traded is
  noticed, and the clock restarted, by the very call that tries the failsafe. The brief's rule 5
  says only "the last qualifying buyer can take the pot"; reading it as the last buyer *before
  the cutoff* (the opening, or seven days ago if later) rather than at the moment of the call is
  our choice: the alternative made the failsafe a race that any 0.001 ETH buy in front of the
  real buyer's transaction would win. The cutoff rolls with time rather than staying at the
  first opening so that, with a core that never returns, a buyer who qualifies later is still
  the one paid for the fees through their buy, once it is seven days old: a cutoff frozen at
  the opening paid every later fee to the first winner, or locked them when nobody had
  qualified before the opening. The failsafe therefore pays the fees through the winner's last
  buy before the cutoff, not the whole pot; later fees wait for their own seven days.
- The failsafe pays what certified naps leave, never a certified nap's own pot: a nap the core
  certified before stalling (its three rounds inside `lastSeenFrontier`) belongs to the last
  buyer before it under rule 4, whoever bought later. Beyond 8 unscanned pages the failsafe
  asks for `settleNaps` first instead of scanning without bound in one transaction.
- The hook accepts ETH only from the PoolManager, so stray transfers cannot muddle the pot.
- Payouts give the winner's wallet 100,000 gas, copy no return data, run under a reentrancy
  lock with state updated before the call, and credit a failing payout instead of retrying it.
  Forwarding all gas and copying the return data (what a plain `call{value}` does) let a
  winner's EIP-7702 code answer with a payload the hook could not afford to copy, freezing every
  later nap behind it; the bounded, copy-free call cannot be made to fail from the callee's side.
- The partial-fill refund of an exact-input buy (rule 1) is credited to `tx.origin`, the brief's
  buyer, not to the router or smart account that settled the ETH with the PoolManager. v4 lets
  `afterSwap` return value only in the unspecified currency (NAP on a buy), so the unused ETH
  reservation cannot be handed back inside the swap; crediting the router would strand it in
  most routers. For a relayed or ERC-4337 buy the relaying EOA therefore holds the credit, as it
  holds the latest-buyer position; the amount is at most 2% of the unfilled input. Buyers who
  trade through a relayer should use exact-output orders or a limit that fills.
- Both fee formulas round down: a buy below 50 wei pays no fee and is not recorded, and every
  buy underpays by less than 1 wei. The leak is sub-wei per swap and a sub-50-wei buy cannot
  qualify, so this is intended, not corrected.
- The Sworn check reverts a buy when the registry call fails on mainnet; sells are unaffected.
  On Sepolia, this launch, the check never runs.

## Operational responsibilities

- **Nobody runs this contract.** No keys, no admin. After launch the only maintenance calls are
  permissionless: `settleNaps(maxPages)` when a nap has settled, `redeemClaims()` if claims sit
  idle, `failsafe()` after seven stale days. The website should offer the first two as buttons.
- **Gas for claims.** A page costs one `roundPage` call of up to 16 records; `settleNaps(10)`
  covers about a day. After a long idle stretch call it repeatedly; progress is kept.
- **Winner that cannot receive ETH.** A contract wallet without a payable fallback, or one whose
  receive needs more than 100,000 gas, is credited in `owed` and must call `withdrawOwed()`
  itself. The website should show a wallet's `owed` balance with a withdraw button.
- **Failsafe with a backlog.** If `failsafe()` reverts with `NapsUnsettled`, call
  `settleNaps(maxPages)` until `scanRound` passes `lastSeenFrontier`, then call it again. The
  website's Claim button covers the first step; `failsafeWinner()` shows who the failsafe pays.
- **Failsafe after the core is gone for good.** Buys keep working and keep paying fees. Call
  `failsafe()` again whenever `failsafeWinner()` shows an amount: seven days after the latest
  buy, the fees since the previous payout go to the buyer who was last when they were paid.
  `NothingToPay` means the fees in the pot are not seven days old yet.
- **Partial-fill refunds.** A buyer whose exact-input buy stopped at a price limit has the unused
  fee reservation in `owed` and pulls it with `withdrawOwed()`; it never expires.
- **Dependency risk.** If SqueekCore pauses or breaks, buys and sells keep working, claims revert
  until it returns, and the failsafe opens after seven days. If it is upgraded with a different
  read ABI, claims revert and the failsafe is the way out.
- **Security.** Tests passing are not an audit. The brief asks for an independent adversarial
  review of the hook and its tests before release; this stage delivers the code and tests only.

## After launch

Nothing to set: the hook has no owner-settable values. All outside addresses the brief gives
(the SqueekCore proxy, the Sworn registry) are constants, and the PoolManager and factory come
from the launch as `$poolManager` and `$factory`.

## Changes in the review revisions

The second review reopened the revised version with one reproducible defect, fixed here with
regression tests (`.imd-responses.json` answers each finding):

- With a dead core the failsafe winner was frozen at the first opening: every later qualifying
  buyer's fee went to that first winner at every later `failsafe()` call, and when nobody had
  qualified before the opening every later fee was locked behind `NoQualifyingBuyer`. The
  failsafe's cutoff now rolls, max(opening, now − 7 days), and the failsafe pays the fees
  through the winner's last buy before it instead of the whole pot (rule 7, `failsafeCutoff()`).
  The anti-sniping property is kept: a buy in front of the failsafe call still wins nothing.

The first review reopened the first accepted version with two reproducible defects, both
fixed with regression tests:

- A winner's wallet answering the payout with a gas-sized payload made `settleNaps` and
  `failsafe` run out of memory gas at any gas limit, freezing every later nap. Payouts now use
  a bounded, copy-free call (`PAYOUT_GAS`), credit on failure, and the review's proof passes.
- `failsafe` paid the whole pot, a certified but unclaimed nap's share included, to whoever
  bought last. It now settles certified naps through `lastSeenFrontier` first (or asks for
  `settleNaps` beyond 8 pages, or proceeds when the core's pages cannot be read) and pays only
  what is left.
- Advisory, also changed: the failsafe winner is fixed at the moment the failsafe opened
  (`BuyRecord.time`, `failsafeWinner()`), closing a 0.001 ETH buy-and-call race for the pot.
  The second revision replaced that fixed moment with the rolling cutoff above, which keeps the
  race closed.
- Advisory, documented and kept: the partial-fill refund goes to `tx.origin`, and fees round
  down (see Assumptions).
