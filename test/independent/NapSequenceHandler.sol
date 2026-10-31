// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {HamsterNapHook} from "src/HamsterNapHook.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {RejectingWinner} from "../mocks/RejectingWinner.sol";
import {SequenceCore} from "./SequenceCore.sol";

/// @dev Independent linear history model. It never derives expected fees or awards from hook counters.
contract NapSequenceHandler is Test {
    struct Purchase {
        uint64 round;
        uint256 fee;
        address qualifyingBuyer;
    }

    HamsterNapHook public immutable hook;
    SequenceCore public immutable core;
    Swapper public immutable router;
    RejectingWinner public immutable rejecting;
    PoolKey private key;
    address[4] public actors;
    Purchase[] private history;

    uint256 public fees;
    uint256 public allocated;
    mapping(address => uint256) public awards;
    address public latest;
    uint64 public cursor;
    uint64 public zeros;
    uint64 public napStart;
    uint256 public naps;
    uint256 public lastAdvanceTime;
    uint256 public buys;
    uint256 public sells;
    uint256 public claims;
    uint256 public failsafes;
    uint256 public withdrawals;

    constructor(HamsterNapHook h, SequenceCore c, Swapper r, PoolKey memory k) {
        hook = h;
        core = c;
        router = r;
        key = k;
        rejecting = new RejectingWinner();
        actors = [makeAddr("sequence.alice"), makeAddr("sequence.bob"), makeAddr("sequence.carol"), address(rejecting)];
        lastAdvanceTime = vm.getBlockTimestamp();
    }

    function buy(uint256 amountSeed, uint8 actorSeed, uint8 kind) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = _amount(amountSeed, kind);
        vm.prank(actor, actor);
        BalanceDelta delta =
            kind % 2 == 0 ? router.swap(key, true, amount) : router.swapExact(key, true, int256(amount));
        uint256 gross = uint256(uint128(-delta.amount0()));
        assertGt(delta.amount1(), 0, "funded swaps must deliver tokens");
        if (kind % 2 == 0) assertEq(gross, amount, "this campaign has enough liquidity for full fills");
        else assertEq(uint256(uint128(delta.amount1())), amount);
        _start();
        bool qualifies = gross >= 0.001 ether;
        if (qualifies) latest = actor;
        uint256 paidFee = gross / 50;
        fees += paidFee;
        history.push(Purchase(_round(), paidFee, qualifies ? actor : address(0)));
        buys++;
    }

    function sell(uint96 amountSeed, uint8 actorSeed, bool exactOutput) external {
        uint256 amount = bound(amountSeed, 100, 0.001 ether);
        address actor = actors[actorSeed % 4];
        vm.prank(actor, actor);
        BalanceDelta delta =
            exactOutput ? router.swapExact(key, false, int256(amount)) : router.swap(key, false, amount);
        assertGt(delta.amount0(), 0);
        _start();
        sells++;
    }

    function advanceAndCertify(uint16 secondsSeed, uint8 countSeed, uint16 workBits) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 3600));
        uint64 available = _round() - 1 - core.frontier();
        if (available > 16) available = 16;
        uint64 count = uint64(bound(countSeed, 0, available));
        if (count > 0) {
            core.certify(count, workBits);
            lastAdvanceTime = vm.getBlockTimestamp();
        }
    }

    function coreStatus(uint8 status) external {
        core.setStatus(status % 3 == 1, status % 3 == 2);
    }

    function settle(uint8 pagesSeed) external {
        uint256 pages = bound(pagesSeed, 1, 3);
        if (cursor == 0) {
            vm.expectRevert(HamsterNapHook.GameNotStarted.selector);
            hook.settleNaps(pages);
            return;
        }
        if (core.unavailable()) {
            vm.expectRevert(SequenceCore.Unavailable.selector);
            hook.settleNaps(pages);
            return;
        }
        uint256 oldNaps = naps;
        uint64 end = cursor + uint64(pages * 16) - 1;
        if (end > core.frontier()) end = core.frontier();
        while (cursor <= end) {
            if (core.worked(cursor)) {
                zeros = 0;
            } else {
                if (zeros == 0) napStart = cursor;
                zeros++;
                if (zeros == 3) {
                    _allocateNap(napStart);
                    naps++;
                }
            }
            cursor++;
        }
        assertEq(hook.settleNaps(pages), naps - oldNaps, "independent nap count");
        claims++;
    }

    function redeem() external {
        hook.redeemClaims();
    }

    function receiverStatus(bool accept) external {
        rejecting.setAccepting(accept);
    }

    function withdraw(uint8 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 debt = hook.owed(actor);
        if (debt == 0) {
            vm.expectRevert(HamsterNapHook.NothingOwed.selector);
        } else if (actor == address(rejecting) && !rejecting.accepting()) {
            vm.expectRevert(HamsterNapHook.TransferFailed.selector);
        } else {
            withdrawals++;
        }
        vm.prank(actor);
        hook.withdrawOwed();
    }

    function takeFailsafeAfterSevenUnchangedDays() external {
        // This exercises a valid stale interval. Premature release after a recent old-round
        // certification is a separate failing proof in the findings, not a blessed property.
        uint256 at = lastAdvanceTime + 7 days;
        if (at > vm.getBlockTimestamp()) vm.warp(at);
        if (cursor == 0) {
            vm.expectRevert(HamsterNapHook.GameNotStarted.selector);
        } else if (latest == address(0)) {
            vm.expectRevert(HamsterNapHook.NoQualifyingBuyer.selector);
        } else if (fees == allocated) {
            vm.expectRevert(HamsterNapHook.NothingToPay.selector);
        } else {
            awards[latest] += fees - allocated;
            allocated = fees;
            failsafes++;
        }
        hook.failsafe();
    }

    function checkModel() external view {
        assertEq(hook.cumulativeFees(), fees, "fees computed from actual swap ETH");
        assertEq(hook.cumulativePaid(), allocated, "only eligible buys fund awards");
        assertEq(hook.pot(), fees - allocated);
        assertEq(hook.latestBuyer(), latest);
        assertEq(hook.scanRound(), cursor);
        assertEq(hook.napsSettled(), naps);
        assertEq(hook.firstNapSettled(), naps > 0);
        assertEq(hook.zeroRun(), zeros);
        uint256 totalDebt;
        uint256 paid;
        for (uint256 i; i < actors.length; i++) {
            uint256 debt = hook.owed(actors[i]);
            assertEq(actors[i].balance + debt, awards[actors[i]], "wrong winner or duplicate payment");
            totalDebt += debt;
            paid += actors[i].balance;
        }
        assertEq(hook.totalOwed(), totalDebt);
        assertEq(paid + totalDebt, allocated);
        assertEq(address(hook).balance + hook.claimsHeld() + paid, fees, "every fee wei is accounted for");
    }

    function _allocateNap(uint64 start) private {
        // A linear sum over actual trade history is deliberately different from the hook's
        // binary search over cumulative checkpoints.
        uint256 eligible;
        address winner;
        for (uint256 i; i < history.length; i++) {
            Purchase memory p = history[i];
            if (p.round >= start) break;
            eligible += p.fee;
            if (p.qualifyingBuyer != address(0)) winner = p.qualifyingBuyer;
        }
        if (winner != address(0) && eligible > allocated) {
            awards[winner] += eligible - allocated;
            allocated = eligible;
        }
    }

    function _start() private {
        if (cursor == 0) cursor = _round();
    }

    function _round() private view returns (uint64) {
        return uint64((vm.getBlockTimestamp() - 1793022600) / 600 + 1);
    }

    function _amount(uint256 seed, uint8 kind) private pure returns (uint256) {
        uint256[6] memory edges = [uint256(49), 50, 51, 0.001 ether - 1, 0.001 ether, 0.001 ether + 1];
        if (kind % 3 == 0) return edges[seed % edges.length];
        return bound(seed, 100, 1 ether);
    }
}
