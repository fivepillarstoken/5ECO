// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IInvestmentManager} from "./interfaces/IInvestmentManager.sol";

/// @title MiningEmission
/// @notice Distributes pre-allocated `fiveECO` rewards to users who burn `fivePT`.
/// @dev Rewards are streamed linearly for 20 years and split pro-rata by burned amount.
contract MiningEmission is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    
    /// @notice Thrown when a required address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when an amount argument is zero or otherwise invalid.
    error InvalidAmount();
    /// @notice Thrown when a user attempts to claim with no accrued rewards.
    error NoRewards();
    /// @notice Thrown when burn is attempted after emission period has ended.
    error MiningEmissionFinished();
    /// @notice Thrown when `fiveECO` is set more than once.
    error FiveECOAlreadySet();
    /// @notice Thrown when burn is attempted before `fiveECO` is configured.
    error FiveECONotSet();
    /// @notice Thrown when there is no queued amount to flush.
    error NoAmountWaitingToBurn();
    /// @notice Thrown when flush is called before investment manager deposit delay is over.
    error DepositDelayNotOver();
    /// @notice Thrown when there is insufficient reward balance.
    error InsufficientRewardBalance();
    /// @notice Thrown when mining emission is not finished.
    error MiningEmissionNotFinished();
    /// @notice Thrown when undistributed rewards have already been withdrawn.
    error UndistributedRewardsAlreadyWithdrawn();

    /// @notice Per-account reward and burn accounting.
    struct AccountInfo {
        /// @notice Total amount of `fivePT` burned by the account.
        uint256 totalBurned;
        /// @notice Snapshot of `rewardPerTokenStored` paid to account.
        uint256 rewardPerTokenPaid;
        /// @notice Pending unclaimed `fiveECO` rewards.
        uint256 rewards;
    }

    /// @notice Emission duration in seconds (7300 days = 20 years).
    uint256 public constant DURATION = 7300 days; // 20 years
    /// @notice Total `fiveECO` rewards distributed over `DURATION`.
    uint256 public constant TOTAL_REWARD = 17_000_000 * 10 ** 18;
    /// @notice Scalar used for fixed-point reward math.
    uint256 public constant PRECISION = 10 ** 18;

    /// @notice Token burned by users to earn rewards.
    IERC20 public immutable fivePT;
    /// @notice External investment manager where funds are being burned.
    IInvestmentManager public immutable investmentManager;

    /// @notice Per-account emission state.
    mapping(address => AccountInfo) public accountInfo;
    /// @notice Emission start timestamp.
    uint256 public startTimestamp;
    /// @notice Emission finish timestamp.
    uint256 public finishTimestamp;
    /// @notice Total burned `fivePT` across all participants.
    uint256 public totalBurned;
    /// @notice Total `fiveECO` rewards allocated to be distributed over `DURATION`.
    uint256 public totalRewardsAllocated;
    /// @notice Last timestamp when global reward state was updated.
    uint256 public updatedAt;
    /// @notice Accumulated reward per burned token.
    uint256 public rewardPerTokenStored;
    /// @notice Amount queued for deposit while investment manager delay is active.
    uint256 public amountWaitingToBurn;
    /// @notice Whether undistributed rewards have been withdrawn.
    bool public undistributedRewardsWithdrawn;

    /// @notice Reward token contract.
    IERC20 public fiveECO;

    /// @notice Emitted when reward token contract is configured.
    /// @param fiveECO Address of the configured `fiveECO` contract.
    event FiveECOSet(address indexed fiveECO);
    /// @notice Emitted when an account burns `fivePT`.
    /// @param account Burner address.
    /// @param amount Amount burned.
    event FivePTBurned(address indexed account, uint256 amount);
    /// @notice Emitted when an account claims rewards.
    /// @param account Claimer address.
    /// @param amount Amount of `fiveECO` minted.
    event RewardsClaimed(address indexed account, uint256 amount);
    /// @notice Emitted when queued amount is deposited into investment manager.
    /// @param amount Amount flushed from queue.
    event WaitingToBurnFlushed(uint256 amount);
    /// @notice Emitted when amount is queued due to active deposit delay.
    /// @param amount Amount added to queue.
    event AmountWaitingToBurnIncreased(uint256 amount);
    /// @notice Emitted when undistributed rewards are withdrawn.
    /// @param amount Amount withdrawn.
    event UndistributedRewardsWithdrawn(uint256 amount);

    /// @notice Updates global and account reward state before executing function body.
    /// @param account Account to update; pass zero address to skip account update.
    modifier updateReward(address account) {
        uint256 oldRewardPerTokenStored = rewardPerTokenStored;
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (rewardPerTokenStored > oldRewardPerTokenStored) {
            totalRewardsAllocated += ((rewardPerTokenStored - oldRewardPerTokenStored) * totalBurned) / PRECISION;
        }

        if (account != address(0)) {
            AccountInfo storage accountInfoItem = accountInfo[account];
            accountInfoItem.rewards = earned(account);
            accountInfoItem.rewardPerTokenPaid = rewardPerTokenStored;
        }

        _;
    }
    
    /// @notice Deploys MiningEmission.
    /// @param _fivePT Address of burnable `fivePT` token.
    /// @param _investmentManager Address of investment manager contract.
    constructor(
        IERC20 _fivePT,
        IInvestmentManager _investmentManager
    ) Ownable(msg.sender) {
        if (
            address(_fivePT) == address(0) ||
            address(_investmentManager) == address(0)
        ) revert ZeroAddress();

        fivePT = _fivePT;
        investmentManager = _investmentManager;
    }

    /// @notice Sets `fiveECO` token contract used for reward transfers.
    /// @dev Can only be called once by owner.
    /// @param _fiveECO Address of the reward token contract.
    function setFiveECO(IERC20 _fiveECO) external onlyOwner {
        if (address(_fiveECO) == address(0)) revert ZeroAddress();
        if (address(fiveECO) != address(0)) revert FiveECOAlreadySet();
        if (_fiveECO.balanceOf(address(this)) < TOTAL_REWARD) revert InsufficientRewardBalance();

        fiveECO = _fiveECO;
        startTimestamp = block.timestamp;
        updatedAt = block.timestamp;
        finishTimestamp = block.timestamp + DURATION;

        emit FiveECOSet(address(_fiveECO));
    }

    /// @notice Returns timestamp used for reward accrual upper bound.
    /// @return Timestamp clamped between `startTimestamp` and `finishTimestamp`.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < finishTimestamp ? block.timestamp : finishTimestamp;
    }

    /// @notice Returns current cumulative reward per burned token.
    /// @return Current `rewardPerToken` scaled by `PRECISION`.
    function rewardPerToken() public view returns (uint256) {
        if (totalBurned == 0) {
            return rewardPerTokenStored;
        }

        uint256 lastTime = lastTimeRewardApplicable();
        uint256 delta = lastTime - updatedAt;
        if (delta == 0) return rewardPerTokenStored;

        return rewardPerTokenStored
            + (TOTAL_REWARD * delta * PRECISION) / (DURATION * totalBurned);
    }

    /// @notice Returns total claimable rewards for an account.
    /// @param account Account to query.
    /// @return Claimable `fiveECO` amount.
    function earned(address account) public view returns (uint256) {
        AccountInfo memory accountInfoItem = accountInfo[account];
        return
            ((accountInfoItem.totalBurned *
                (rewardPerToken() - accountInfoItem.rewardPerTokenPaid)) / PRECISION) +
            accountInfoItem.rewards;
    }

    /// @notice Burns `fivePT` from caller and updates reward position.
    /// @dev Deposits into investment manager immediately when delay allows; otherwise queues amount.
    /// @param amount Amount of `fivePT` to burn.
    function burnFivePT(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (address(fiveECO) == address(0)) revert FiveECONotSet();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp >= finishTimestamp) revert MiningEmissionFinished();

        fivePT.safeTransferFrom(msg.sender, address(this), amount);
        accountInfo[msg.sender].totalBurned += amount;
        totalBurned += amount;
        
        emit FivePTBurned(msg.sender, amount);

        IInvestmentManager.InvestorInfo memory investorInfo = investmentManager.accountToInvestorInfo(address(this));
        if (
            investorInfo.lastDepositTimestamp + investmentManager.depositDelay() > block.timestamp ||
            investmentManager.isUpdateCriteriaActive() ||
            (investorInfo.totalDeposit == 0 && amount < 10 ** 18)
        ) {
            amountWaitingToBurn += amount;

            emit AmountWaitingToBurnIncreased(amount);
        } else {
            uint256 totalAmount = amount + amountWaitingToBurn;
            amountWaitingToBurn = 0;
            fivePT.approve(address(investmentManager), totalAmount);
            investmentManager.deposit(totalAmount, address(0));

            if (totalAmount > amount) {
                emit WaitingToBurnFlushed(totalAmount - amount);
            }
        }
    }

    /// @notice Deposits queued amount into investment manager once delay is over.
    function flushWaitingToBurn() external nonReentrant {
        if (amountWaitingToBurn == 0) revert NoAmountWaitingToBurn();

        IInvestmentManager.InvestorInfo memory investorInfo = investmentManager.accountToInvestorInfo(address(this));
        if (investorInfo.lastDepositTimestamp + investmentManager.depositDelay() > block.timestamp) {
            revert DepositDelayNotOver();
        }

        uint256 totalAmount = amountWaitingToBurn;
        amountWaitingToBurn = 0;
        fivePT.approve(address(investmentManager), totalAmount);
        investmentManager.deposit(totalAmount, address(0));

        emit WaitingToBurnFlushed(totalAmount);
    }

    /// @notice Claims caller's accrued rewards by transferring `fiveECO`.
    function claimRewards() external nonReentrant updateReward(msg.sender) {
        uint256 rewards = accountInfo[msg.sender].rewards;
        if (rewards == 0) revert NoRewards();

        accountInfo[msg.sender].rewards = 0;
        fiveECO.safeTransfer(msg.sender, rewards);
        
        emit RewardsClaimed(msg.sender, rewards);
    }

    /// @notice Withdraws undistributed rewards from the contract.
    /// @dev Can only be called by owner after mining emission is finished.
    function withdrawUndistributedRewards() external nonReentrant onlyOwner updateReward(address(0)) {
        if (address(fiveECO) == address(0)) revert FiveECONotSet();
        if (block.timestamp < finishTimestamp) revert MiningEmissionNotFinished();
        if (undistributedRewardsWithdrawn) revert UndistributedRewardsAlreadyWithdrawn();

        uint256 undistributedRewards = TOTAL_REWARD - totalRewardsAllocated;
        undistributedRewardsWithdrawn = true;

        fiveECO.safeTransfer(msg.sender, undistributedRewards);

        emit UndistributedRewardsWithdrawn(undistributedRewards);
    }
}
