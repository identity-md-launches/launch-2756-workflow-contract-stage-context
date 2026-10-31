// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {ISqueekCore} from "./interfaces/ISqueekCore.sol";
import {ISworn} from "./interfaces/ISworn.sol";

/// @title Hamster Nap: a last-buyer-before-bedtime game on SqueekChain's hamster
/// @notice One Uniswap v4 hook on the NAP / ETH pool. Every buy of NAP pays 2% of its ETH into a pot
/// the hook holds and, if it spends at least 0.001 ETH, makes the buyer's wallet the latest buyer.
/// When SqueekCore certifies a nap (three consecutive settled rounds with zero work), the last
/// qualifying buyer whose buy happened before the nap's first round started takes the pot collected
/// up to that round. Sells pay no game fee and never read the core. Nobody has owner powers: no
/// pause, no upgrade, no signer, no keeper, no withdrawal by anyone but winners.
/// @dev The pot is the hook's own ETH (plus ERC-6909 ETH claims on the PoolManager when the manager
/// could not pay the fee out in ETH at swap time, redeemed before any payout). `pot()` is the
/// authoritative figure: fees in minus payouts, and the hook's ETH plus claims always cover it plus
/// what deferred winners are owed.
contract HamsterNapHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------- game constants

    /// @notice The live SqueekCore proxy on Sepolia that the SqueekChain API and livestream follow.
    ISqueekCore public constant CORE = ISqueekCore(0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44);
    /// @notice SqueekCore `configuration().genesisTimestamp`: round 1 starts here.
    uint64 public constant GENESIS_TIMESTAMP = 1793022600;
    /// @notice SqueekCore `configuration().roundDuration` in seconds.
    uint64 public constant ROUND_DURATION = 600;
    /// @notice Consecutive settled zero-work rounds that make a nap (30 minutes).
    uint64 public constant NAP_ROUNDS = 3;
    /// @notice The most records one `roundPage` call returns, so the most rounds scanned per page.
    uint64 public constant PAGE_ROUNDS = 16;
    /// @notice Buy fee in basis points of the ETH a buy spends: 2%.
    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS = 10_000;
    /// @notice The smallest buy (ETH spent, fee included) that makes the buyer the latest buyer.
    uint256 public constant MIN_QUALIFYING_BUY = 0.001 ether;
    /// @notice How long the core's frontier may stand still before the failsafe opens.
    uint256 public constant FAILSAFE_DELAY = 7 days;
    /// @notice The Sworn card registry on Ethereum mainnet, read live during the first game there.
    ISworn public constant SWORN = ISworn(0x0da2679000Ea5380d1361cc3Cca7D4e8c881F766);
    /// @notice The only chain on which the Sworn card check runs.
    uint256 public constant SWORN_CHAIN_ID = 1;

    // ---------------------------------------------------------------- launch wiring

    /// @notice The launch factory: the only sender allowed to open this hook's pool.
    address public immutable factory;

    /// @notice The pool this hook serves, bound in `beforeInitialize`.
    PoolId public poolId;
    /// @notice The launch token, read from the PoolKey when the pool is opened.
    Currency public token;
    bool public poolBound;

    // ---------------------------------------------------------------- game state

    /// @dev The state right after a buy, appended per buy in round order. Binary-searched at claim
    /// time for the last buy before a nap's first round.
    struct BuyRecord {
        uint64 round;
        uint128 cumulativeFees;
        address latestBuyer;
    }

    BuyRecord[] private _buys;

    /// @notice The last qualifying buyer so far (the wallet whose buy spent at least 0.001 ETH).
    address public latestBuyer;
    /// @notice All fees ever collected, in wei.
    uint256 public cumulativeFees;
    /// @notice All fees ever paid out (or credited to a winner that could not receive ETH), in wei.
    uint256 public cumulativePaid;
    /// @notice ETH credited to winners whose payout transfer failed; they pull it with `withdrawOwed`.
    mapping(address winner => uint256 amount) public owed;
    /// @notice The sum of `owed`.
    uint256 public totalOwed;
    /// @notice ERC-6909 ETH claims on the PoolManager the hook holds instead of ETH.
    uint256 public claimsHeld;

    /// @notice The next round the nap scan examines; 0 until the pool's first swap starts the game.
    uint64 public scanRound;
    /// @notice Consecutive zero-work rounds seen ending at `scanRound - 1`.
    uint64 public zeroRun;
    /// @notice The first round of the current zero-work run.
    uint64 public zeroRunStart;
    /// @notice The highest `settledThroughRound` the hook has read from the core.
    uint64 public lastSeenFrontier;
    /// @notice Naps settled (paid or found without a winner) so far.
    uint256 public napsSettled;
    /// @notice True once the first nap is settled: the end of the first game.
    bool public firstNapSettled;

    bool private _locked;

    // ---------------------------------------------------------------- events

    event PoolBound(PoolId indexed poolId, Currency token);
    event GameStarted(uint64 round);
    event Buy(address indexed buyer, uint256 ethSpent, uint256 fee, uint64 round, bool qualifying);
    event NapSettled(uint64 indexed napStart, address indexed winner, uint256 amount);
    event FailsafeTaken(address indexed winner, uint256 amount, uint64 frontier);
    event PayoutDeferred(address indexed winner, uint256 amount);
    event OwedWithdrawn(address indexed winner, uint256 amount);
    event ClaimsRedeemed(uint256 amount);
    event FrontierSeen(uint64 frontier);

    // ---------------------------------------------------------------- errors

    error NotFactory();
    error AlreadyBound();
    error PairMustBeNativeEth();
    error UnknownPool();
    error NotSworn(address buyer);
    error GameNotStarted();
    error CoreNotStale(uint256 staleAt);
    error NoQualifyingBuyer();
    error NothingToPay();
    error NothingOwed();
    error TransferFailed();
    error NotFromPoolManager();
    error Reentrancy();
    error ZeroPages();

    constructor(IPoolManager poolManager_, address factory_) BaseHook(poolManager_) {
        factory = factory_;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @dev ETH arrives only from the PoolManager (fee takes and claim redemptions).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotFromPoolManager();
    }

    // ---------------------------------------------------------------- hook permissions

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- callbacks

    /// @notice Only the launch factory opens the pool, once, and only paired with native ETH.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (poolBound) revert AlreadyBound();
        if (!key.currency0.isAddressZero()) revert PairMustBeNativeEth();
        poolBound = true;
        poolId = key.toId();
        token = key.currency1;
        emit PoolBound(poolId, key.currency1);
        return this.beforeInitialize.selector;
    }

    /// @notice On a buy, runs the mainnet-only Sworn check and, for an exact-input buy, carves the
    /// 2% fee out of the ETH input. Sells pass through untouched.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool();
        // ETH is currency0 (address zero sorts first), so a buy of the token is zeroForOne.
        if (!params.zeroForOne) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _checkSworn();

        if (params.amountSpecified < 0) {
            // Exact input: the specified currency is ETH. The hook takes the fee from it here so the
            // pool swaps the remaining 98%; the ETH itself is collected in afterSwap.
            uint256 fee = _feeOnGross(uint256(-params.amountSpecified));
            return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Collects the fee in ETH, records the buy and the latest buyer. Starts the game on the
    /// pool's first swap of either direction.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool();
        _startGameIfNeeded();
        if (!params.zeroForOne) return (this.afterSwap.selector, 0);

        uint256 fee;
        uint256 gross;
        int128 hookDeltaUnspecified;
        if (params.amountSpecified < 0) {
            gross = uint256(-params.amountSpecified);
            fee = _feeOnGross(gross);
        } else {
            // Exact output: the pool's ETH input is the unspecified side; the hook adds the fee to it.
            uint256 poolEth = uint256(uint128(-delta.amount0()));
            fee = _feeOnPoolEth(poolEth);
            gross = poolEth + fee;
            hookDeltaUnspecified = fee.toInt128();
        }

        if (fee > 0) {
            _collectFee(fee);
            cumulativeFees += fee;
        }

        address buyer = tx.origin;
        bool qualifying = gross >= MIN_QUALIFYING_BUY;
        if (qualifying) latestBuyer = buyer;
        uint64 round = currentRound();
        if (fee > 0 || qualifying) {
            _buys.push(BuyRecord({round: round, cumulativeFees: cumulativeFees.toUint128(), latestBuyer: latestBuyer}));
        }
        emit Buy(buyer, gross, fee, round, qualifying);
        _observeFrontier();
        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    // ---------------------------------------------------------------- claims

    /// @notice Scans up to `maxPages` pages of settled rounds (16 rounds each) past the last scanned
    /// round and pays every nap found, in order. Anyone may call it; progress is kept between calls.
    /// Reverts when the core cannot be read.
    /// @return settled The number of naps settled in this call.
    function settleNaps(uint256 maxPages) external nonReentrant returns (uint256 settled) {
        if (maxPages == 0) revert ZeroPages();
        if (scanRound == 0) revert GameNotStarted();
        uint64 frontier = CORE.state().settledThroughRound;
        _noteFrontier(frontier);

        uint64 from = scanRound;
        for (uint256 page = 0; page < maxPages && from <= frontier; page++) {
            uint64 through = from + PAGE_ROUNDS - 1;
            if (through > frontier) through = frontier;
            ISqueekCore.RoundPage memory result = CORE.roundPage(from - 1, through, PAGE_ROUNDS);
            uint64 certified = result.certifiedThroughRound;
            if (certified > through) certified = through;
            if (certified < from) break;

            uint256 index;
            for (uint64 round = from; round <= certified; round++) {
                bool hadWork = index < result.rounds.length && result.rounds[index].roundId == round;
                if (hadWork) {
                    index++;
                    zeroRun = 0;
                } else {
                    if (zeroRun == 0) zeroRunStart = round;
                    zeroRun++;
                    if (zeroRun == NAP_ROUNDS) {
                        _settleNap(zeroRunStart);
                        settled++;
                    }
                }
            }
            from = certified + 1;
        }
        scanRound = from;
    }

    /// @notice If the core's settled frontier has stood still for 7 days, the pot goes to the last
    /// qualifying buyer. Anyone may trigger it; only that buyer is paid. Works when the core reverts,
    /// from the last frontier the hook saw.
    function failsafe() external nonReentrant {
        if (scanRound == 0) revert GameNotStarted();
        (bool ok, uint64 frontier) = _readFrontier();
        if (ok) _noteFrontier(frontier);
        frontier = lastSeenFrontier;
        uint256 staleAt = roundEnd(frontier) + FAILSAFE_DELAY;
        if (block.timestamp < staleAt) revert CoreNotStale(staleAt);
        address winner = latestBuyer;
        if (winner == address(0)) revert NoQualifyingBuyer();
        uint256 amount = pot();
        if (amount == 0) revert NothingToPay();
        cumulativePaid += amount;
        emit FailsafeTaken(winner, amount, frontier);
        _pay(winner, amount);
    }

    /// @notice A winner whose payout could not be delivered pulls it here.
    function withdrawOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        totalOwed -= amount;
        _ensureEth(amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit OwedWithdrawn(msg.sender, amount);
    }

    /// @notice Turns the hook's ERC-6909 ETH claims on the PoolManager into ETH. Anyone may call it.
    function redeemClaims() external nonReentrant {
        _redeemClaims();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotFromPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    // ---------------------------------------------------------------- views

    /// @notice Fees collected and not yet paid out: what the next nap's winner stands to take at most.
    function pot() public view returns (uint256) {
        return cumulativeFees - cumulativePaid;
    }

    /// @notice The SqueekCore round at `timestamp` (0 before genesis).
    function roundAt(uint256 timestamp) public pure returns (uint64) {
        if (timestamp < GENESIS_TIMESTAMP) return 0;
        return uint64((timestamp - GENESIS_TIMESTAMP) / ROUND_DURATION + 1);
    }

    /// @notice The round the current block falls in.
    function currentRound() public view returns (uint64) {
        return roundAt(block.timestamp);
    }

    /// @notice The first second of `round`.
    function roundStart(uint64 round) public pure returns (uint256) {
        if (round == 0) return GENESIS_TIMESTAMP;
        return GENESIS_TIMESTAMP + uint256(round - 1) * ROUND_DURATION;
    }

    /// @notice The first second after `round`.
    function roundEnd(uint64 round) public pure returns (uint256) {
        return GENESIS_TIMESTAMP + uint256(round) * ROUND_DURATION;
    }

    /// @notice Whether the game is in its first game (before the first settled nap), when the Sworn
    /// card check applies on mainnet.
    function firstGame() public view returns (bool) {
        return !firstNapSettled;
    }

    /// @notice Whether a buy by `buyer` would pass the Sworn card check on this chain right now.
    function mayBuy(address buyer) public view returns (bool) {
        if (block.chainid != SWORN_CHAIN_ID || firstNapSettled) return true;
        return SWORN.balanceOf(buyer) >= 1;
    }

    /// @notice The number of recorded buys.
    function buyCount() external view returns (uint256) {
        return _buys.length;
    }

    /// @notice A recorded buy: the round, the fees collected through it and the latest buyer then.
    function buyAt(uint256 index) external view returns (BuyRecord memory) {
        return _buys[index];
    }

    /// @notice Who would win a nap that begins at `napStart`, and how much, from the records so far.
    function winnerBefore(uint64 napStart) external view returns (address winner, uint256 amount) {
        uint256 cumulative;
        (winner, cumulative) = _stateBefore(napStart);
        if (winner == address(0) || cumulative <= cumulativePaid) return (winner, 0);
        amount = cumulative - cumulativePaid;
    }

    /// @notice The earliest timestamp at which the failsafe opens, given the last frontier seen.
    function failsafeOpensAt() external view returns (uint256) {
        return roundEnd(lastSeenFrontier) + FAILSAFE_DELAY;
    }

    // ---------------------------------------------------------------- internals

    function _feeOnGross(uint256 gross) private pure returns (uint256) {
        return gross * FEE_BPS / BPS;
    }

    /// @dev For an exact-output buy the pool receives the ETH net of the fee; the fee is 2% of the
    /// gross, so fee = net * 200 / 9800.
    function _feeOnPoolEth(uint256 poolEth) private pure returns (uint256) {
        return poolEth * FEE_BPS / (BPS - FEE_BPS);
    }

    function _checkSworn() private view {
        if (block.chainid != SWORN_CHAIN_ID || firstNapSettled) return;
        address buyer = tx.origin;
        if (SWORN.balanceOf(buyer) < 1) revert NotSworn(buyer);
    }

    function _startGameIfNeeded() private {
        if (scanRound != 0) return;
        uint64 round = currentRound();
        if (round == 0) round = 1;
        scanRound = round;
        emit GameStarted(round);
    }

    /// @dev The hook is owed `fee` of ETH by the PoolManager at the end of this swap. Take it as ETH
    /// when the manager already holds enough; otherwise mint an ERC-6909 claim, redeemed later.
    function _collectFee(uint256 fee) private {
        if (address(poolManager).balance >= fee) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        } else {
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
            claimsHeld += fee;
        }
    }

    /// @dev Reads the core's frontier without letting a reverting or dead core break a buy.
    function _observeFrontier() private {
        (bool ok, uint64 frontier) = _readFrontier();
        if (ok) _noteFrontier(frontier);
    }

    function _readFrontier() private view returns (bool ok, uint64 frontier) {
        (bool success, bytes memory ret) = address(CORE).staticcall(abi.encodeCall(ISqueekCore.state, ()));
        // CoreState is eight static words; the first is settledThroughRound.
        if (!success || ret.length != 256) return (false, 0);
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint64).max) return (false, 0);
        return (true, uint64(word));
    }

    function _noteFrontier(uint64 frontier) private {
        if (frontier > lastSeenFrontier) {
            lastSeenFrontier = frontier;
            emit FrontierSeen(frontier);
        }
    }

    /// @dev The state after the last buy before round `napStart` started.
    function _stateBefore(uint64 napStart) private view returns (address winner, uint256 cumulative) {
        uint256 length = _buys.length;
        if (length == 0 || _buys[0].round >= napStart) return (address(0), 0);
        // Largest index whose round < napStart. _buys[lo].round < napStart holds throughout.
        uint256 lo = 0;
        uint256 hi = length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_buys[mid].round < napStart) lo = mid;
            else hi = mid - 1;
        }
        BuyRecord storage record = _buys[lo];
        return (record.latestBuyer, record.cumulativeFees);
    }

    function _settleNap(uint64 napStart) private {
        napsSettled++;
        firstNapSettled = true;
        (address winner, uint256 cumulative) = _stateBefore(napStart);
        uint256 amount;
        if (winner != address(0) && cumulative > cumulativePaid) {
            amount = cumulative - cumulativePaid;
            cumulativePaid = cumulative;
        }
        emit NapSettled(napStart, winner, amount);
        if (amount > 0) _pay(winner, amount);
    }

    /// @dev Pays a winner; a winner that cannot receive ETH is credited instead and never blocks.
    function _pay(address winner, uint256 amount) private {
        _ensureEth(amount);
        (bool ok,) = winner.call{value: amount}("");
        if (!ok) {
            owed[winner] += amount;
            totalOwed += amount;
            emit PayoutDeferred(winner, amount);
        }
    }

    function _ensureEth(uint256 amount) private {
        if (address(this).balance < amount && claimsHeld > 0) _redeemClaims();
    }

    function _redeemClaims() private {
        uint256 amount = claimsHeld;
        if (amount == 0) return;
        claimsHeld = 0;
        poolManager.unlock(abi.encode(amount));
        emit ClaimsRedeemed(amount);
    }
}
