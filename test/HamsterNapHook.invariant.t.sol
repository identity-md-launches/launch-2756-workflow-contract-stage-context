// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {SequenceCore} from "./independent/SequenceCore.sol";
import {NapSequenceHandler} from "./independent/NapSequenceHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNapHookInvariantTest is HookTestBase {
    NapSequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        SequenceCore sequenceCore = SequenceCore(address(core));
        vm.etch(address(sequenceCore), address(new SequenceCore()).code);
        sequenceCore.initialize(649);
        // First buy mints claims, later trades usually take ETH. Both representations are exercised.
        seedTokensOnly(1_000_000 ether);
        handler = new NapSequenceHandler(hook, sequenceCore, swapper, key);
        handler.buy(1 ether, 0, 2);
        bytes4[] memory selectors = new bytes4[](_includeFailsafe() ? 9 : 8);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.advanceAndCertify.selector;
        selectors[3] = handler.coreStatus.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.redeem.selector;
        selectors[6] = handler.receiverStatus.selector;
        selectors[7] = handler.withdraw.selector;
        if (_includeFailsafe()) selectors[8] = handler.takeFailsafeAfterSevenUnchangedDays.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _includeFailsafe() internal pure virtual returns (bool) {
        return false;
    }

    function invariant_valueAndWinnerModelMatchesAfterEverySequence() public view {
        handler.checkModel();
        assertEq(manager.balanceOf(address(hook), 0), hook.claimsHeld(), "actual ERC6909 backing");
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), hook.pot() + hook.totalOwed());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(swapper)) + token.balanceOf(address(manager)),
            token.totalSupply(),
            "trading cannot create or destroy NAP"
        );
    }

    function test_handlerReachesClaimDebtWithdrawalAndFailsafe() public {
        // Deterministic reachability companion: random campaigns are not the only evidence
        // that the handler can execute claims and a successful deferred withdrawal.
        handler.buy(1 ether, 3, 2);
        handler.advanceAndCertify(2400, 4, 1); // work at 650, sleep 651..653
        handler.settle(1);
        assertEq(handler.naps(), 1);
        assertGt(hook.totalOwed(), 0);
        handler.receiverStatus(true);
        handler.withdraw(3);
        assertEq(handler.withdrawals(), 1);
        handler.buy(2 ether, 1, 2);
        handler.coreStatus(1);
        handler.takeFailsafeAfterSevenUnchangedDays();
        assertEq(handler.failsafes(), 1);
        handler.checkModel();
    }
}

/// @notice A separate campaign lets the ordinary one explore many timely naps, while this
/// campaign mixes prolonged outages and failsafes into the same accounting model.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNapHookRecoveryInvariantTest is HamsterNapHookInvariantTest {
    function _includeFailsafe() internal pure override returns (bool) {
        return true;
    }
}
