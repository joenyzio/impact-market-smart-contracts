// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.4;

import "./IImpactLabsVestingV2.sol";

/**
 * @title Storage for ImpactLabsVesting
 */
abstract contract ImpactLabsVestingStorageV2 is IImpactLabsVestingV2 {
    address public override impactLabs;
    IERC20 public override PACT;
    IDonationMiner public override donationMiner;

    uint256 public override nextRewardPeriod;
    uint256 public override advancePayment;
}
