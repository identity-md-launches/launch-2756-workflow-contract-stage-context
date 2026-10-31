// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {NapToken} from "src/NapToken.sol";
import {HamsterNapHook} from "src/HamsterNapHook.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {SepoliaRounds} from "./fixtures/SepoliaRounds.sol";

/// @notice Reads the unmodified live proxy at the assignment's pinned block. The pool is local.
contract HamsterNapHookForkTest is HookTestBase {
    uint256 private constant FORK_BLOCK = 12030457;
    ISqueekCore private liveCore;
    uint256 private forkTimestamp;

    function setUp() public override {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.chainid, 11155111);
        forkTimestamp = block.timestamp;
        manager = new PoolManager(address(this));
        // Deterministic local deployment addresses can already have ETH on the fork.
        vm.deal(address(manager), 0);
        token = new NapToken();
        hook = deployHook(manager, factory);
        liveCore = hook.CORE();
        assertGt(address(liveCore).code.length, 0, "live proxy must exist");
        key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), POOL_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        swapper = new Swapper(manager);
        vm.deal(address(swapper), 2_000_000 ether);
        token.transfer(address(swapper), 900_000_000 ether);
        seedTokensOnly(1_000_000 ether);
    }

    function testFork_configurationAndCertifiedFrontier() public view {
        ISqueekCore.CoreConfiguration memory config = liveCore.configuration();
        ISqueekCore.CoreState memory state = liveCore.state();
        assertEq(config.genesisTimestamp, GENESIS);
        assertEq(config.roundDuration, ROUND);
        assertEq(config.maxRoundsPerBatch, 16);
        assertGe(state.settledThroughRound, 642);
        assertLt(state.settledThroughRound, hook.currentRound(), "only closed rounds are certified");
        assertLe(hook.roundEnd(state.settledThroughRound), forkTimestamp);
    }

    function testFork_everyCapturedRoundMatchesLivePages() public {
        // The capture models work and cumulative work only; synthetic hashes/block units are not compared.
        MockSqueekCore captured = new MockSqueekCore();
        SepoliaRounds.load(captured);
        for (uint64 from = 482; from < 642; from += 16) {
            ISqueekCore.RoundPage memory expected = captured.roundPage(from, from + 16, 16);
            ISqueekCore.RoundPage memory actual = liveCore.roundPage(from, from + 16, 16);
            assertEq(actual.certifiedThroughRound, expected.certifiedThroughRound);
            assertEq(actual.start.cumulativeWork, expected.start.cumulativeWork);
            assertEq(actual.end.cumulativeWork, expected.end.cumulativeWork);
            assertEq(actual.rounds.length, expected.rounds.length);
            for (uint256 i; i < expected.rounds.length; i++) {
                assertEq(actual.rounds[i].roundId, expected.rounds[i].roundId);
                assertEq(actual.rounds[i].cumulativeWork, expected.rounds[i].cumulativeWork);
            }
        }
    }

    function testFork_pageBoundsAndSparseNapAreReal() public {
        ISqueekCore.RoundPage memory page = liveCore.roundPage(502, 505, 16);
        assertEq(page.certifiedThroughRound, 505);
        assertEq(page.rounds.length, 0);
        assertEq(page.start.cumulativeWork, page.end.cumulativeWork);
        page = liveCore.roundPage(530, 546, 16);
        assertEq(page.rounds.length, 1);
        assertEq(page.rounds[0].roundId, 539);
        uint64 frontier = liveCore.state().settledThroughRound;
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(610, 600, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(frontier, frontier + 1, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(600, 620, 17);
    }

    function testFork_livePagesSettleBoundaryBuysInOrder() public {
        // Local buy timestamps replay the historical window; the fork block and live core are never changed.
        vm.warp(roundStart(503) - 1);
        buy(alice, 1 ether);
        warpToRound(503);
        buy(bob, 2 ether);
        warpToRound(539);
        buy(carol, 4 ether);
        vm.warp(forkTimestamp);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 carolBefore = carol.balance;
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNapHook.NapSettled(503, alice, 0.02 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 502..517
        assertEq(alice.balance - aliceBefore, 0.02 ether);
        assertEq(bob.balance, bobBefore);
        assertEq(hook.pot(), 0.12 ether);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNapHook.NapSettled(519, bob, 0.04 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 518..533
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNapHook.NapSettled(540, carol, 0.08 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 534..549
        assertEq(bob.balance - bobBefore, 0.04 ether);
        assertEq(carol.balance - carolBefore, 0.08 ether);
        assertEq(hook.pot(), 0);
        assertEq(hook.claimsHeld(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertBacked();
    }

    function testFork_currentBuysObserveCoreAndSellsPreservePot() public {
        uint64 frontier = liveCore.state().settledThroughRound;
        BalanceDelta bought = buy(alice, 0.001 ether);
        assertGt(bought.amount1(), 0);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.lastSeenFrontier(), frontier);
        assertEq(hook.claimsHeld(), 0.00002 ether);
        hook.redeemClaims();
        BalanceDelta sold = sell(bob, uint256(uint128(bought.amount1())) / 2);
        assertGt(sold.amount0(), 0);
        assertEq(hook.settleNaps(1), 0, "current round is not certified");
        assertEq(hook.pot(), 0.00002 ether);
        assertEq(hook.latestBuyer(), alice);
        assertBacked();
    }
}
