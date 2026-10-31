// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockSqueekCore} from "../mocks/MockSqueekCore.sol";

/// @notice Real round pages captured from the live SqueekCore proxy
/// 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44 on Sepolia at block 12030371 (2026-10-31, timestamp
/// 1793407932), when `state().settledThroughRound` was 642 and `cumulativeWork` 55392.
/// `roundPage(482, 498, 16)` through `roundPage(626, 642, 16)` were read with cast; the rounds with
/// work and their cumulative work are reproduced below. Every settled round missing from them had
/// zero work. In this window Squeektoshi slept:
///   - rounds 503..514 (12 rounds, a nap beginning at 503),
///   - rounds 519..538 (20 rounds, a nap beginning at 519),
///   - rounds 540..621 (82 rounds, a nap beginning at 540),
/// and had single zero-work rounds at 498 and 640, which are not naps.
library SepoliaRounds {
    uint64 internal constant FRONTIER = 642;
    uint64 internal constant CUMULATIVE_WORK_AT_482 = 33645;
    uint64 internal constant CUMULATIVE_WORK_AT_642 = 55392;

    function load(MockSqueekCore core) internal {
        // The ledger position at round 482 (start of the first captured page), as one block of work.
        core.setWork(1, CUMULATIVE_WORK_AT_482);
        uint64[2][48] memory records = [
            [uint64(483), 34227],
            [uint64(484), 34851],
            [uint64(485), 35432],
            [uint64(486), 35868],
            [uint64(487), 36499],
            [uint64(488), 36993],
            [uint64(489), 37632],
            [uint64(490), 38127],
            [uint64(491), 38589],
            [uint64(492), 39214],
            [uint64(493), 39770],
            [uint64(494), 40147],
            [uint64(495), 40769],
            [uint64(496), 41366],
            [uint64(497), 41845],
            [uint64(499), 42460],
            [uint64(500), 43008],
            [uint64(501), 43562],
            [uint64(502), 43898],
            [uint64(515), 44365],
            [uint64(516), 44956],
            [uint64(517), 45292],
            [uint64(518), 45758],
            [uint64(539), 45957],
            [uint64(622), 46537],
            [uint64(623), 47194],
            [uint64(624), 47681],
            [uint64(625), 47801],
            [uint64(626), 48276],
            [uint64(627), 48704],
            [uint64(628), 49301],
            [uint64(629), 49835],
            [uint64(630), 50369],
            [uint64(631), 50994],
            [uint64(632), 51467],
            [uint64(633), 51972],
            [uint64(634), 52205],
            [uint64(635), 52843],
            [uint64(636), 53404],
            [uint64(637), 53563],
            [uint64(638), 54076],
            [uint64(639), 54547],
            [uint64(641), 55170],
            [uint64(642), 55392],
            [uint64(0), 0],
            [uint64(0), 0],
            [uint64(0), 0],
            [uint64(0), 0]
        ];
        uint64 previous = CUMULATIVE_WORK_AT_482;
        for (uint256 i = 0; i < records.length; i++) {
            if (records[i][0] == 0) break;
            core.setWork(records[i][0], records[i][1] - previous);
            previous = records[i][1];
        }
        core.setFrontier(FRONTIER);
    }
}
