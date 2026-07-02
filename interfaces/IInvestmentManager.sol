// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal interface for the BSC InvestmentManager used by MiningEmission.
interface IInvestmentManager {
    struct InvestorInfo {
        uint256 totalDeposit;
        uint128 directRefsCount;
        uint128 downlineRefsCount;
        uint256 directRefsDeposit;
        uint256 downlineRefsDeposit;
        address referer;
        uint256 lastDailyReward;
        uint256 lastRefReward;
        uint256 accumulatedReward;
        uint32 lastClaimTimestamp;
        uint32 lastDepositTimestamp;
        uint32 updateRefRewardTimestamp;
    }

    function startTimestamp() external view returns (uint256);
    function depositDelay() external view returns (uint256);
    function accountToInvestorInfo(address account) external view returns (InvestorInfo memory);
    function deposit(uint256 amount, address referer) external;
}
