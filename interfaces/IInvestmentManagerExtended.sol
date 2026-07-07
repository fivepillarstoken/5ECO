// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal interface for the BSC InvestmentManager used by MiningEmission.
interface IInvestmentManagerExtended {
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

    struct PoolCriteria {
        uint128 personalInvestRequired;
        uint128 totalDirectInvestRequired;
        uint8 directRefsRequired;
    }

    struct PoolInfo {
        bool isActive;
        uint256 curReward;
        uint256 lastReward;
        uint256 participantsCount;
        uint256 rewardPerInvestorStored;
        uint128 personalInvestRequired;
        uint128 totalDirectInvestRequired;
        uint8 directRefsRequired;
        uint16 share;
    }

    function startTimestamp() external view returns (uint256);
    function depositDelay() external view returns (uint256);
    function accountToInvestorInfo(address account) external view returns (InvestorInfo memory);
    function deposit(uint256 amount, address referer) external;
    function isUpdateCriteriaActive() external view returns (bool);
    function setPoolCriteria(
        uint8[] calldata poolIds,
        PoolCriteria[] calldata criteriaOfPools,
        uint256 checkCountLimit
    ) external;
    function pools(uint256 poolId) external view returns (PoolInfo memory);
    function owner() external view returns (address);
}
