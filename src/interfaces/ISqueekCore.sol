// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The read-only surface of SqueekChain's SqueekCore (implementation version 3) that the
/// Hamster Nap game depends on. Taken from the published ABI at docs.squeekchain.com
/// (assets/abi/SqueekCore.json, a copy is in docs/abi/SqueekCore.json).
/// @dev Round numbering, confirmed against the live Sepolia proxy on 2026-10-31: round 1 starts at
/// `genesisTimestamp`, every round lasts `roundDuration` seconds, and round 0 is the launch position.
/// At timestamp `t >= genesisTimestamp` the round is `(t - genesisTimestamp) / roundDuration + 1`.
/// `settledThroughRound` is the certified frontier: rounds after it are unknown, not zero.
interface ISqueekCore {
    struct CoreState {
        uint64 settledThroughRound;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint64 blockHeight;
        uint96 blockProgress;
        uint32 workPerThousandBlocks;
        uint256 authorizationNonce;
        bool paused;
    }

    struct CoreConfiguration {
        bytes32 streamId;
        uint64 genesisTimestamp;
        uint64 roundDuration;
        uint64 maxWorkPerRound;
        uint16 maxRoundsPerBatch;
        address guardian;
        address reporter;
        uint32 initialWorkPerThousandBlocks;
        uint64 targetBlocksPerActiveRound;
        uint64 difficultySmoothingRounds;
        uint96 blockUnitsPerBlock;
    }

    struct LedgerPosition {
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
    }

    struct RoundCheckpoint {
        uint64 roundId;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
        bytes32 dataHash;
    }

    struct RoundPage {
        uint64 certifiedThroughRound;
        LedgerPosition start;
        LedgerPosition end;
        RoundCheckpoint[] rounds;
    }

    /// @dev Reverts for a reversed range, an end past the frontier, or more than 16 records.
    error InvalidRoundPageBounds();

    function state() external view returns (CoreState memory result);

    function configuration() external view returns (CoreConfiguration memory result);

    /// @notice The rounds in (afterRound, throughRound] that had work, at most `maxRecords` of them
    /// (0 to 16). A settled round missing from the page had zero work. The page may end before
    /// `throughRound` when the record cap is hit; `certifiedThroughRound` says where it ends.
    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory result);
}
