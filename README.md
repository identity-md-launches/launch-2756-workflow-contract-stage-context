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
   points, 2% of the ETH the buyer spends, fee included. Exact input: fee = 2% of the input.
   Exact output: fee = pool ETH × 200 / 9800, so the fee is 2% of the gross. Sells pay no game fee.
   The fee is settled in ETH inside the swap: the hook takes native ETH when the PoolManager's ETH
   balance covers it, and mints itself an ERC-6909 ETH claim when it does not (a fresh manager or
   a pool seeded with tokens only). Claims are redeemed into ETH before any payout, and anyone may
   call `redeemClaims()`. Nothing is ever left in NAP.
2. **Latest buyer.** A buy of at least `MIN_QUALIFYING_BUY` = 0.001 ETH (gross) makes the
   transaction's sender wallet, `tx.origin`, the latest buyer, as the brief specifies. Smaller
   buys still pay the fee into the pot. The buy's SqueekCore round is recorded with it.
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
   transactions. A nap whose third round is not yet certified waits.
6. **Winners that cannot receive ETH** are credited in `owed` and pull with `withdrawOwed()`.
   The game never blocks on a payout.
7. **Failsafe.** When the core's `settledThroughRound` has stood still for `FAILSAFE_DELAY` =
   7 days (the frontier round ended 7 days ago or more), `failsafe()` sends the whole pot to the
   last qualifying buyer. Anyone may trigger it; only that buyer is paid. If the core reverts, the
   last frontier the hook saw is used.
8. **First game, mainnet only.** On chain id 1, until the first nap is settled, a buy requires
   `balanceOf(tx.origin) >= 1` on the Sworn registry `0x0da2679000ea5380d1361cc3cca7d4e8c881f766`,
   read live on every buy. On Sepolia and every other chain the check is skipped. Sells always
   work, also when the registry has no code.
9. **The core is read only at swap and claim time.** Buys read `state()` through a staticcall
   that tolerates a reverting or codeless core; sells never read it. Constructors read nothing.

Events: `Buy` for every recorded buy (with `qualifying`), `NapSettled`, `FailsafeTaken`,
`PayoutDeferred`, `OwedWithdrawn`, `ClaimsRedeemed`, `FrontierSeen`, `GameStarted`, `PoolBound`.

### Where the ETH goes

Every wei of fee goes into the pot and leaves it only to a nap winner or the failsafe winner.
Nothing goes to the owner, the requester, IMD or any other address. Invariant kept by the tests:
`hook ETH balance + claimsHeld == pot() + totalOwed`.

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

`forge test` runs 58 tests in five suites (the verifier re-runs them with
`FOUNDRY_FUZZ_SEED=0xfbaf61498d090e9328f47570cd503c9b9f7a6967092682129c4f05d58ca2d30c`):

- `test/HamsterNapHook.t.sol`: permissions, callback access, initialization from the factory
  only and once, native pair only; fees on exact-input and exact-output buys, no fee on sells,
  dust buys, the 0.001 ETH threshold, `tx.origin` as the buyer; the round boundary (a buy in the
  last second before round `s` against the first second of `s`), naps of 2 against 3 rounds, a
  nap not yet fully settled, a long nap paying once, buys during a nap, several naps in one call,
  pagination, a nap with no qualifying buyer; the failsafe (closed, open, with a reverting core,
  without a buyer); a reverting, codeless or paused core with sells and buys still working; a
  winner contract that rejects ETH and later withdraws; a re-entrant winner; and a fuzzed ETH
  accounting run (pot = fees in − payouts) over mixed buys, exact-output buys and sells.
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
- The failsafe is callable by anyone but pays only the last qualifying buyer; "not advanced for 7
  days" is measured as the frontier round's end plus 7 days, which needs no observation history.
- The hook accepts ETH only from the PoolManager, so stray transfers cannot muddle the pot.
- Payouts forward all gas with a reentrancy lock and state updated before the call; a failing
  payout is credited, never retried automatically.
- The Sworn check reverts a buy when the registry call fails on mainnet; sells are unaffected.
  On Sepolia, this launch, the check never runs.

## Operational responsibilities

- **Nobody runs this contract.** No keys, no admin. After launch the only maintenance calls are
  permissionless: `settleNaps(maxPages)` when a nap has settled, `redeemClaims()` if claims sit
  idle, `failsafe()` after seven stale days. The website should offer the first two as buttons.
- **Gas for claims.** A page costs one `roundPage` call of up to 16 records; `settleNaps(10)`
  covers about a day. After a long idle stretch call it repeatedly; progress is kept.
- **Winner that cannot receive ETH.** A contract wallet without a payable fallback is credited
  in `owed` and must call `withdrawOwed()` itself.
- **Dependency risk.** If SqueekCore pauses or breaks, buys and sells keep working, claims revert
  until it returns, and the failsafe opens after seven days. If it is upgraded with a different
  read ABI, claims revert and the failsafe is the way out.
- **Security.** Tests passing are not an audit. The brief asks for an independent adversarial
  review of the hook and its tests before release; this stage delivers the code and tests only.

## After launch

Nothing to set: the hook has no owner-settable values. All outside addresses the brief gives
(the SqueekCore proxy, the Sworn registry) are constants, and the PoolManager and factory come
from the launch as `$poolManager` and `$factory`.
