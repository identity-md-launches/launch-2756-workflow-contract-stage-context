// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNapHook} from "../src/HamsterNapHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RejectingWinner} from "./mocks/RejectingWinner.sol";

contract HamsterNapHookTest is HookTestBase {
    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        // The hamster worked every round up to and including the current frontier.
        workThrough(1, 649);
    }

    // ---------------------------------------------------------------- wiring

    function test_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity);
        assertEq(HookFlags.fromPermissions(p), HOOK_FLAGS);
        assertEq(HookFlags.flagsOf(address(hook)), HOOK_FLAGS);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), factory);
        assertEq(Currency.unwrap(hook.token()), address(token));
        assertTrue(hook.poolBound());
    }

    function test_callbacksRefuseNonManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, 1), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, 1), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_unlockCallbackRefusesNonManager() public {
        vm.expectRevert(HamsterNapHook.NotFromPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_receiveRefusesStrangers() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_initializeRefusesNonFactory() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesSecondPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesTokenPair() public {
        HamsterNapHook fresh = deployHook(manager, factory);
        MockERC20 a = new MockERC20("A", "A", 0);
        (address c0, address c1) =
            address(a) < address(token) ? (address(a), address(token)) : (address(token), address(a));
        PoolKey memory pair =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(fresh)));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(pair, SQRT_PRICE_1_1);
        assertFalse(fresh.poolBound());
    }

    function test_initializeAcceptsListedFeeFromFactory() public {
        HamsterNapHook fresh = deployHook(manager, factory);
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(fresh.poolBound());
        assertEq(PoolId.unwrap(fresh.poolId()), PoolId.unwrap(k.toId()));
    }

    // ---------------------------------------------------------------- fees and buyers

    function test_buyExactInputPaysTwoPercentAndBecomesLatestBuyer() public {
        uint256 before = address(swapper).balance;
        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.Buy(alice, 1 ether, 0.02 ether, 650, true);
        BalanceDelta delta = buy(alice, 1 ether);
        assertEq(delta.amount0(), -1 ether, "buyer pays exactly the input");
        assertGt(delta.amount1(), 0, "buyer receives tokens");
        assertEq(before - address(swapper).balance, 1 ether);
        assertEq(hook.pot(), 0.02 ether);
        assertEq(address(hook).balance, 0.02 ether, "fee settled as ETH");
        assertEq(hook.claimsHeld(), 0);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 1);
        assertEq(hook.scanRound(), 650, "game starts at the first swap's round");
        assertBacked();
    }

    function test_buyExactOutputPaysTwoPercentOfGross() public {
        BalanceDelta delta = buyExactOut(bob, 1000 ether);
        assertEq(delta.amount1(), 1000 ether, "exact token output");
        uint256 gross = uint256(uint128(-delta.amount0()));
        uint256 potAfter = hook.pot();
        // The fee is 2% of what the buyer spent, within rounding of a wei.
        assertApproxEqAbs(potAfter, gross * 200 / 10_000, 1);
        assertEq(address(hook).balance, potAfter);
        assertEq(hook.latestBuyer(), bob);
        assertBacked();
    }

    function test_sellPaysNoFeeAndKeepsLatestBuyer() public {
        buy(alice, 1 ether);
        uint256 potBefore = hook.pot();
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta delta = sell(bob, 500 ether);
        assertGt(delta.amount0(), 0, "seller receives ETH");
        assertEq(address(swapper).balance - ethBefore, uint256(uint128(delta.amount0())));
        assertEq(hook.pot(), potBefore);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 1);
    }

    function test_dustBuyPaysFeeButDoesNotQualify() public {
        buy(alice, 1 ether);
        buy(bob, 0.0005 ether);
        assertEq(hook.pot(), fee(1 ether) + fee(0.0005 ether));
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 2, "dust buys are recorded for the pot");
        assertEq(hook.buyAt(1).latestBuyer, alice);
    }

    function test_qualifyingThreshold() public {
        buy(alice, 0.001 ether - 1);
        assertEq(hook.latestBuyer(), address(0));
        buy(bob, 0.001 ether);
        assertEq(hook.latestBuyer(), bob);
    }

    function test_tinyBuyWithZeroFeeIsNotRecorded() public {
        buy(alice, 40);
        assertEq(hook.pot(), 0);
        assertEq(hook.buyCount(), 0);
    }

    function test_latestBuyerIsTheTransactionOrigin() public {
        // The router is msg.sender of the swap; the wallet is tx.origin.
        vm.prank(bob, alice);
        swapper.swap(key, true, 1 ether);
        assertEq(hook.latestBuyer(), alice);
    }

    // ---------------------------------------------------------------- partial fills

    /// @dev The fee and the threshold follow the ETH a buy really spent, not the input it offered.
    function test_partialDustFillDoesNotQualifyAndPaysFeeOnExecutedEth() public {
        buy(alice, 1 ether);
        // Bob offers 0.001 ETH but a tight price limit lets the pool take only a sliver of it.
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(0.001 ether);
        BalanceDelta delta = buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertGt(delta.amount1(), 0, "Bob did receive tokens");
        assertLt(paid, 0.001 ether, "the fill is dust");
        // The buyer settled pool ETH plus the whole reservation; the hook keeps 2% of the real spend.
        uint256 poolEth = paid - reserved;
        uint256 due = poolEth * 200 / 9800;
        assertGt(due, 0);
        assertEq(hook.cumulativeFees(), fee(1 ether) + due, "fee on executed ETH only");
        assertEq(hook.owed(bob), reserved - due, "the unused reservation is Bob's");
        assertEq(hook.totalOwed(), reserved - due);
        assertEq(hook.latestBuyer(), alice, "a dust fill does not take the position");
        assertEq(hook.buyCount(), 2);
        assertEq(hook.buyAt(1).latestBuyer, alice);
        assertBacked();

        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.OwedWithdrawn(bob, reserved - due);
        hook.withdrawOwed();
        assertEq(bob.balance, reserved - due);
        assertEq(hook.totalOwed(), 0);
        assertBacked();

        // Alice, not Bob, wins the nap that follows.
        workThrough(650, 650);
        sleepThrough(651, 653);
        warpToRound(654);
        uint256 potBefore = hook.pot();
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, potBefore);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_partialFillEmitsExecutedAmountsAndRefund() public {
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(0.001 ether);
        // Dry run on a snapshot to learn the fill, then expect exactly those figures in the events.
        uint256 snapshot = vm.snapshotState();
        BalanceDelta delta = buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
        uint256 poolEth = uint256(uint128(-delta.amount0())) - reserved;
        vm.revertToState(snapshot);
        uint256 due = poolEth * 200 / 9800;

        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.FeeRefunded(bob, reserved - due);
        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.Buy(bob, poolEth + due, due, 650, false);
        buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
    }

    function test_partialFillThatStillSpendsEnoughQualifies() public {
        buy(alice, 1 ether);
        // Bob offers 10 ETH; the limit stops the pool after roughly 1 ETH.
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(10 ether);
        BalanceDelta delta = buyWithLimit(bob, -int256(10 ether), price - price / 1e6);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertLt(paid, 10 ether, "partial");
        uint256 poolEth = paid - reserved;
        uint256 due = poolEth * 200 / 9800;
        assertGe(poolEth + due, 0.001 ether);
        assertEq(hook.cumulativeFees(), fee(1 ether) + due);
        assertEq(hook.owed(bob), reserved - due);
        assertEq(hook.latestBuyer(), bob, "a partial fill above the threshold still qualifies");
        assertBacked();
    }

    function test_nearZeroFillRefundsTheWholeReservationAndRecordsNothing() public {
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(1 ether);
        // One tick of sqrt price: the pool fills a few wei at most, too little for a 1 wei fee.
        BalanceDelta delta = buyWithLimit(bob, -int256(1 ether), price - 1);
        uint256 poolEth = uint256(uint128(-delta.amount0())) - reserved;
        assertLt(poolEth, 49, "no fee is due on so small a fill");
        assertEq(hook.cumulativeFees(), fee(1 ether), "no fee charged");
        assertEq(hook.owed(bob), reserved, "the whole reservation comes back");
        assertEq(hook.buyCount(), 1, "nothing recorded");
        assertEq(hook.latestBuyer(), alice);
        assertBacked();
    }

    function test_partialExactOutputFillPaysFeeOnExecutedEth() public {
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        BalanceDelta delta = buyWithLimit(bob, int256(1_000_000 ether), price - price / 1e9);
        assertLt(delta.amount1(), 1_000_000 ether, "partial output");
        uint256 gross = uint256(uint128(-delta.amount0()));
        uint256 due = hook.cumulativeFees() - fee(1 ether);
        assertApproxEqAbs(due, gross * 200 / 10_000, 1, "2% of what was spent");
        assertEq(hook.owed(bob), 0, "exact output never over-reserves");
        assertEq(hook.latestBuyer(), gross >= 0.001 ether ? bob : alice);
        assertBacked();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_partialFillFeeIsTwoPercentOfExecutedEth(uint96 offered, uint32 limitSteps) public {
        buy(alice, 1 ether);
        uint256 amount = bound(uint256(offered), 50, 100 ether);
        // A limit between one tick below the price and one percent below it.
        uint160 price = currentSqrtPrice();
        uint256 steps = bound(uint256(limitSteps), 1, 1e6);
        uint160 limit = uint160(uint256(price) - uint256(price) / 100 * steps / 1e6);
        if (limit >= price) limit = price - 1;
        uint256 reserved = fee(amount);
        BalanceDelta delta = buyWithLimit(bob, -int256(amount), limit);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertLe(paid, amount);
        uint256 poolEth = paid - reserved;
        uint256 due = hook.cumulativeFees() - fee(1 ether);
        if (paid == amount) {
            assertEq(due, reserved, "a full fill pays the reservation");
            assertEq(hook.owed(bob), 0);
        } else {
            assertEq(due, poolEth * 200 / 9800 > reserved ? reserved : poolEth * 200 / 9800);
            assertEq(hook.owed(bob), reserved - due);
        }
        assertEq(hook.latestBuyer(), poolEth + due >= 0.001 ether ? bob : alice);
        assertBacked();
    }

    // ---------------------------------------------------------------- claims

    function test_claimBeforeAnySwapReverts() public {
        vm.expectRevert(HamsterNapHook.GameNotStarted.selector);
        hook.settleNaps(1);
        vm.expectRevert(HamsterNapHook.GameNotStarted.selector);
        hook.failsafe();
        vm.expectRevert(HamsterNapHook.ZeroPages.selector);
        hook.settleNaps(0);
    }

    function test_roundBoundary_lastSecondBeforeNapCounts_firstSecondDoesNot() public {
        uint64 s = 660;
        vm.warp(roundStart(s) - 1);
        buy(alice, 1 ether); // round s-1: counts
        vm.warp(roundStart(s));
        buy(bob, 2 ether); // round s: does not
        assertEq(hook.buyAt(0).round, s - 1);
        assertEq(hook.buyAt(1).round, s);

        workThrough(650, s - 1);
        sleepThrough(s, s + 2);
        warpToRound(s + 4);

        vm.expectEmit(true, true, false, true);
        emit HamsterNapHook.NapSettled(s, alice, fee(1 ether));
        uint256 settled = hook.settleNaps(10);
        assertEq(settled, 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), fee(2 ether), "bob's fee stays for the next game");
        assertEq(hook.latestBuyer(), bob);
        assertTrue(hook.firstNapSettled());
        assertEq(hook.napsSettled(), 1);
        assertBacked();
    }

    function test_napOfTwoRoundsPaysNothing() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 661);
        workThrough(662, 670);
        warpToRound(671);
        assertEq(hook.settleNaps(10), 0);
        assertEq(hook.napsSettled(), 0);
        assertEq(alice.balance, 0);
        assertEq(hook.pot(), fee(1 ether));
        assertEq(hook.scanRound(), 671);
        assertFalse(hook.firstNapSettled());
    }

    function test_napOfThreeRoundsPays() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        assertEq(hook.settleNaps(10), 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), 0);
    }

    function test_napNotYetFullySettledWaits() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 661); // frontier at 661: two zero rounds certified so far
        warpToRound(663);
        assertEq(hook.settleNaps(10), 0);
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.zeroRunStart(), 660);
        assertEq(hook.scanRound(), 662);
        assertEq(alice.balance, 0);

        sleepThrough(662, 662); // the third round settles
        assertEq(hook.settleNaps(10), 1);
        assertEq(alice.balance, fee(1 ether));
    }

    function test_longNapPaysOnce() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 700);
        warpToRound(701);
        assertEq(hook.settleNaps(10), 1);
        buy(bob, 1 ether); // a buy during the still-running nap
        sleepThrough(701, 720);
        warpToRound(721);
        assertEq(hook.settleNaps(10), 0, "the same nap does not pay again");
        assertEq(hook.pot(), fee(1 ether));
        assertEq(hook.napsSettled(), 1);
    }

    function test_buysDuringNapCountForNextGame() public {
        uint64 s = 660;
        warpToRound(655);
        buy(alice, 1 ether);
        warpToRound(s + 1);
        buy(carol, 3 ether); // during the nap, before it is settled
        workThrough(650, s - 1);
        sleepThrough(s, s + 2);
        warpToRound(s + 3);
        hook.settleNaps(10);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), fee(3 ether));
        assertEq(hook.latestBuyer(), carol);

        // The hamster wakes, then naps again: carol wins the second game.
        workThrough(s + 3, s + 10);
        sleepThrough(s + 11, s + 13);
        warpToRound(s + 14);
        hook.settleNaps(10);
        assertEq(carol.balance, fee(3 ether));
        assertEq(hook.pot(), 0);
        assertEq(hook.napsSettled(), 2);
        assertBacked();
    }

    function test_severalNapsClaimedInOrderInOneCall() public {
        warpToRound(651);
        buy(alice, 1 ether);
        warpToRound(671);
        buy(bob, 2 ether);
        warpToRound(691);
        buy(carol, 4 ether);
        workThrough(650, 659);
        sleepThrough(660, 665);
        workThrough(666, 679);
        sleepThrough(680, 682);
        workThrough(683, 699);
        sleepThrough(700, 702);
        workThrough(703, 705);
        warpToRound(706);

        vm.expectEmit(true, true, false, true);
        emit HamsterNapHook.NapSettled(660, alice, fee(1 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNapHook.NapSettled(680, bob, fee(2 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNapHook.NapSettled(700, carol, fee(4 ether));
        assertEq(hook.settleNaps(10), 3);
        assertEq(alice.balance, fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(carol.balance, fee(4 ether));
        assertEq(hook.pot(), 0);
        assertEq(hook.scanRound(), 706);
        assertBacked();
    }

    function test_paginationKeepsProgressAcrossCalls() public {
        warpToRound(651);
        buy(alice, 1 ether);
        workThrough(650, 699);
        sleepThrough(700, 702);
        warpToRound(703);
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 667, "16 rounds from 651");
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 683);
        assertEq(hook.settleNaps(2), 1);
        assertEq(hook.scanRound(), 703);
        assertEq(alice.balance, fee(1 ether));
        // Nothing more to scan: a call is harmless.
        assertEq(hook.settleNaps(5), 0);
        assertEq(hook.scanRound(), 703);
    }

    function test_napWithNoQualifyingBuyerKeepsPot() public {
        warpToRound(651);
        buy(alice, 0.0001 ether); // dust only: a pot, no qualifying buyer
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        vm.expectEmit(true, true, false, true);
        emit HamsterNapHook.NapSettled(660, address(0), 0);
        assertEq(hook.settleNaps(10), 1);
        assertEq(hook.pot(), fee(0.0001 ether), "the pot waits for a qualifying buyer");
        assertTrue(hook.firstNapSettled());
    }

    function test_winnerBeforeView() public {
        warpToRound(651);
        buy(alice, 1 ether);
        warpToRound(655);
        buy(bob, 2 ether);
        (address w, uint256 a) = hook.winnerBefore(652);
        assertEq(w, alice);
        assertEq(a, fee(1 ether));
        (w, a) = hook.winnerBefore(656);
        assertEq(w, bob);
        assertEq(a, fee(3 ether));
        (w, a) = hook.winnerBefore(651);
        assertEq(w, address(0));
        assertEq(a, 0);
    }

    // ---------------------------------------------------------------- failsafe

    function test_failsafePaysLastQualifyingBuyerAfterSevenStaleDays() public {
        uint256 firstSeen = block.timestamp;
        buy(alice, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        buy(bob, 0.5 ether); // the frontier did not move: the clock still runs from the first sighting
        assertEq(hook.lastSeenFrontier(), 649);
        assertEq(hook.frontierSeenAt(), firstSeen);
        uint256 opensAt = firstSeen + 7 days;
        assertGt(opensAt, roundEnd(649) + 7 days, "the sighting, 17 seconds into round 650, is the later date");
        assertEq(hook.failsafeOpensAt(), opensAt);

        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, opensAt));
        hook.failsafe();

        vm.warp(opensAt);
        vm.prank(carol); // anyone may trigger it; only the last qualifying buyer is paid
        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.FailsafeTaken(bob, fee(1.5 ether), 649);
        hook.failsafe();
        assertEq(bob.balance, fee(1.5 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        vm.expectRevert(HamsterNapHook.NothingToPay.selector);
        hook.failsafe();
    }

    function test_failsafeNotOpenWhileCoreAdvances() public {
        buy(alice, 1 ether);
        vm.warp(roundEnd(649) + 7 days);
        // The core kept settling: its frontier is current. The failsafe reads it, sees the advance
        // for the first time now, and stays shut for another seven days.
        uint64 current = hook.currentRound();
        workThrough(650, current - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
        // The reverted call kept nothing; a claim call records the same sighting.
        hook.settleNaps(1);
        assertEq(hook.lastSeenFrontier(), current - 1);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days);
    }

    function test_failsafeRestartsWhenABuyObservesAFreshAdvance() public {
        // Round 650, frontier 649. Nobody touches the hook for eight days while the core catches up.
        buy(alice, 1 ether);
        assertEq(hook.lastSeenFrontier(), 649);
        vm.warp(block.timestamp + 8 days);
        // The core advances one round, far behind the clock. Bob's buy observes the advance.
        core.setFrontier(650);
        buy(bob, 0.001 ether);
        assertEq(hook.lastSeenFrontier(), 650);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        uint256 opensAt = block.timestamp + 7 days;
        assertEq(hook.failsafeOpensAt(), opensAt);
        // Round 650 ended more than eight days ago, but the frontier moved just now: not stale.
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, opensAt));
        hook.failsafe();
        // Seven unchanged days later the pot goes to the last qualifying buyer.
        vm.warp(opensAt);
        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.FailsafeTaken(bob, fee(1.001 ether), 650);
        hook.failsafe();
        assertEq(bob.balance, fee(1.001 ether));
        assertBacked();
    }

    function test_failsafeRestartsWhenItObservesAFreshAdvanceItself() public {
        buy(alice, 1 ether);
        vm.warp(block.timestamp + 8 days);
        core.setFrontier(650);
        // No swap or claim saw the advance; the failsafe call itself does, and stays shut.
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
        // A claim call that finds no nap still records the sighting and restarts the clock the same way.
        vm.warp(block.timestamp + 6 days);
        core.setFrontier(651);
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.lastSeenFrontier(), 651);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
    }

    function test_failsafeWorksWhenCoreReverts() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        // The core stopped answering right after the buy that saw frontier 649: dated from that buy.
        vm.warp(hook.failsafeOpensAt() - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, hook.failsafeOpensAt()));
        hook.failsafe();
        vm.warp(hook.failsafeOpensAt());
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
    }

    function test_failsafeWithNeverReadableCoreDatesFromTheGameStart() public {
        // The core has no code from the start: the frontier stays at zero and nothing is observed.
        vm.etch(address(core), "");
        vm.warp(roundStart(700) + 5);
        uint256 gameStart = block.timestamp;
        buy(alice, 1 ether);
        assertEq(hook.lastSeenFrontier(), 0);
        assertEq(hook.frontierSeenAt(), gameStart);
        // Genesis is long past, but the clock runs from the game's start, not from round zero's end.
        assertEq(hook.failsafeOpensAt(), gameStart + 7 days);
        vm.warp(gameStart + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNapHook.CoreNotStale.selector, gameStart + 7 days));
        hook.failsafe();
        vm.warp(gameStart + 7 days);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
    }

    function test_failsafeNeedsAQualifyingBuyer() public {
        buy(alice, 0.0001 ether);
        vm.warp(hook.failsafeOpensAt());
        vm.expectRevert(HamsterNapHook.NoQualifyingBuyer.selector);
        hook.failsafe();
    }

    // ---------------------------------------------------------------- a reverting or paused core

    function test_sellsAndBuysWorkWhileCoreReverts() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        BalanceDelta sold = sell(bob, 100 ether);
        assertGt(sold.amount0(), 0);
        buy(carol, 1 ether);
        assertEq(hook.latestBuyer(), carol);
        assertEq(hook.pot(), fee(2 ether));
        vm.expectRevert();
        hook.settleNaps(1);
        core.setReverting(false);
        hook.settleNaps(1);
    }

    function test_coreWithNoCodeDoesNotBreakSwaps() public {
        vm.etch(address(core), "");
        buy(alice, 1 ether);
        sell(bob, 100 ether);
        assertEq(hook.lastSeenFrontier(), 0);
    }

    function test_pausedCoreStillReads() public {
        core.setPaused(true);
        buy(alice, 1 ether);
        sell(bob, 100 ether);
        assertEq(hook.lastSeenFrontier(), 649);
        assertEq(hook.settleNaps(1), 0);
    }

    // ---------------------------------------------------------------- a winner that rejects ETH

    function test_winnerThatRejectsEthIsCreditedAndDoesNotBlock() public {
        RejectingWinner rejecting = new RejectingWinner();
        warpToRound(651);
        buy(address(rejecting), 1 ether); // the last qualifying buyer before the nap at 660
        warpToRound(665);
        buy(bob, 2 ether); // the last one before the nap at 670
        workThrough(650, 659);
        sleepThrough(660, 662);
        workThrough(663, 669);
        sleepThrough(670, 672);
        warpToRound(673);

        vm.expectEmit(true, false, false, true);
        emit HamsterNapHook.PayoutDeferred(address(rejecting), fee(1 ether));
        assertEq(hook.settleNaps(10), 2, "the second nap still settled");
        assertEq(hook.owed(address(rejecting)), fee(1 ether));
        assertEq(hook.totalOwed(), fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        vm.expectRevert(HamsterNapHook.TransferFailed.selector);
        rejecting.withdrawFrom(address(hook));
        rejecting.setAccepting(true);
        rejecting.withdrawFrom(address(hook));
        assertEq(address(rejecting).balance, fee(1 ether));
        assertEq(hook.totalOwed(), 0);
        assertBacked();

        vm.expectRevert(HamsterNapHook.NothingOwed.selector);
        hook.withdrawOwed();
    }

    // ---------------------------------------------------------------- accounting

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_potEqualsFeesInMinusPayouts(uint96[8] memory amounts, uint8 kinds) public {
        uint256 expectedFees;
        address[4] memory buyers = [alice, bob, carol, dave];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(uint256(amounts[i]), 1, 100 ether);
            uint8 kind = uint8((kinds >> (i * 2)) & 0x3) % 3;
            if (i == 0) kind = 0;
            if (kind == 0) {
                buy(buyers[i % 4], amount);
                expectedFees += fee(amount);
            } else if (kind == 1) {
                BalanceDelta d = buyExactOut(buyers[i % 4], amount);
                uint256 poolEth = uint256(uint128(-d.amount0()));
                uint256 f = hook.cumulativeFees() - expectedFees;
                assertApproxEqAbs(f, (poolEth - f) * 200 / 9800, 1);
                expectedFees += f;
            } else {
                sell(buyers[i % 4], amount);
            }
            assertEq(hook.cumulativeFees(), expectedFees);
            assertBacked();
        }
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        uint256 potBefore = hook.pot();
        address winner = hook.latestBuyer();
        uint256 winnerBefore = winner.balance;
        assertEq(hook.settleNaps(10), 1);
        if (winner == address(0)) {
            // Only dust buys: the pot waits for a qualifying buyer.
            assertEq(hook.cumulativePaid(), 0);
            assertEq(hook.pot(), potBefore);
        } else {
            assertEq(hook.cumulativePaid(), potBefore);
            assertEq(winner.balance - winnerBefore, potBefore);
            assertEq(hook.pot(), 0);
        }
        assertBacked();
    }

    function test_reentrancyFromWinnerIsRefused() public {
        ReentrantWinner attacker = new ReentrantWinner(hook);
        warpToRound(651);
        buy(address(attacker), 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        hook.settleNaps(10);
        // The re-entrant call was refused; the payout itself went through once.
        assertTrue(attacker.sawReentrancyRevert());
        assertEq(address(attacker).balance, fee(1 ether));
        assertEq(hook.owed(address(attacker)), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }
}

contract ReentrantWinner {
    HamsterNapHook private immutable hook;
    bool public sawReentrancyRevert;

    constructor(HamsterNapHook hook_) {
        hook = hook_;
    }

    receive() external payable {
        try hook.settleNaps(1) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == HamsterNapHook.Reentrancy.selector) sawReentrancyRevert = true;
        }
        try hook.failsafe() {}
        catch (bytes memory reason) {
            if (bytes4(reason) != HamsterNapHook.Reentrancy.selector) sawReentrancyRevert = false;
        }
    }
}
