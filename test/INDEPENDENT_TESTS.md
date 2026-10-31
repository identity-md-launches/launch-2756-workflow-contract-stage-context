# Independent Hamster Nap tests

These tests supplement the accepted implementation's suite. Production contracts,
configuration, dependencies, and ABI exports are unchanged.

| File | Coverage |
| --- | --- |
| `HamsterNapHook.independent.t.sol` | 1,000 fuzz cases at the last-second/first-second boundary; dust before and during a nap; delayed third-round certification; interrupted zero runs; multiple naps spanning page boundaries; atomic rollback after a later page reverts; accumulating rejected payouts, failed and repeated withdrawals; failsafe/deferred-debt isolation and recovery; malformed core responses; exact-input/output sells and LP fee collection with an unavailable core. |
| `HamsterNapHook.fork.t.sol` | Five live-core tests at Sepolia block **12030457**, including every captured work record in rounds 483–642, configuration/frontier and invalid page bounds, three historical naps paid in order, and fresh token-only pool claim redemption. |
| `HamsterNapHook.invariant.t.sol` | Two campaigns, each **256 runs × 96 calls**, with unexpected handler reverts treated as failures. One explores ordinary settlement and one also introduces seven-day outages and failsafes. |
| `independent/NapSequenceHandler.sol` | Random exact-input/output buys and sells, time advances, append-only certification, reverting/paused core, page-limited settlement, claim redemption, receiver rejection and withdrawals. |
| `independent/SequenceCore.sol` | Efficient offline model of sparse settled-round pages. Only closed rounds can be certified, and certified work never changes. |

The invariant oracle keeps its own linear trade history. It computes fees from actual
ETH debits, determines winners and eligible fees independently of the hook's cumulative
checkpoints, and compares awards to each receiver's ETH plus deferred debt. It also
checks the actual PoolManager ERC-6909 balance against `claimsHeld`, fee conservation,
the pot and debt backing, scan progress, nap counts, and NAP supply/balances. The handler
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

## Reported defects and limits

Two high-severity findings are reported in the assignment's `.imd-findings.json`,
with complete standalone offline Foundry proofs that were run and failed for the
stated reasons:

1. A partial exact-input fill uses the requested maximum for the fee and qualifying
   threshold. A buy spending **21,012,659,207,850 wei**, below the **10^15 wei** minimum,
   can win a **20,020,000,000,000,000 wei** pot. The ordinary invariant campaign uses
   fully filled trades; it does not claim that partial fills are correct.
2. The failsafe dates staleness from the certified round's end, so an advancement
   observed now can still permit an immediate payout if that round is old. The
   campaign tests valid seven-day unchanged intervals. The accepted suite's
   round-end-based failsafe expectations do not establish the workflow requirement.

Failing proofs are embedded in the findings rather than committed as failing test
entry points. Passing tests do not resolve these defects or imply launch readiness.
