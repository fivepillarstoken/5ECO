// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";

/// @title FounderPackages
/// @notice Sells founder packages in sequential phases: buyers pay USDT and receive vested `fiveECO`.
/// @dev Each phase defines package tiers, lock multipliers, and collateral pool caps. Referral fees are
///      paid in `USDT` and transferred to referrers across up to four upline levels.
contract FounderPackages is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Burnable;

    /// @notice Thrown when a required address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when an amount argument is zero or otherwise invalid.
    error ZeroAmount();
    /// @notice Thrown when vesting duration is outside the allowed 4–12 week range.
    error InvalidWithdrawDuration();
    /// @notice Thrown when the requested phase id does not exist.
    error InvalidPhaseId();
    /// @notice Thrown when phase start time is not in the future or overlaps an adjacent phase.
    error InvalidStartTime();
    /// @notice Thrown when phase duration is zero or overlaps the next phase.
    error InvalidDuration();
    /// @notice Thrown when phase price is zero.
    error InvalidPrice();
    /// @notice Thrown when a lock factor is below `PCT_BASE` (100%).
    error InvalidLockFactor();
    /// @notice Thrown when editing a phase that has already started or ended.
    error PhaseAlreadyActiveOrEnded();
    /// @notice Thrown when the package list is empty.
    error InvalidPackagesCount();
    /// @notice Thrown when a package quantity is zero.
    error InvalidPackageQuantity();
    /// @notice Thrown when a package price is less than the phase price.
    error InvalidPackagePrice();
    /// @notice Thrown when a package bonus exceeds `PCT_BASE`.
    error InvalidPackageBonus();
    /// @notice Thrown when a package pool cap is zero.
    error InvalidPackagePoolCap();
    /// @notice Thrown when the package type index is out of range for the active phase.
    error InvalidPackageType();
    /// @notice Thrown when the lock period index is out of range.
    error InvalidLockPeriod();
    /// @notice Thrown when a purchase would exceed the package pool cap.
    error PackagePoolCapExeeded();
    /// @notice Thrown when no phase has been created yet.
    error NoPhaseCreatedYet();
    /// @notice Thrown when no phase is currently active.
    error NoActivePhase();
    /// @notice Thrown when a buyer sets themselves as referrer.
    error InvalidReferrer();
    /// @notice Thrown when registering a referrer would create a referral loop.
    error ReferralCirculationDetected();
    /// @notice Thrown when the withdraw schedule index is out of range.
    error InvalidWithdrawIndex();
    /// @notice Thrown when withdrawing unsold collateral before the phase has ended.
    error PhaseNotEnded();
    /// @notice Thrown when all package collateral for a phase has been sold or withdrawn.
    error NoAvailableAmountInPackages();
    /// @notice Thrown when a withdraw schedule has no amount to burn.
    error NoAmountToBurn();
    /// @notice Thrown when a withdraw schedule has no amount to release.
    error NoAmountToRelease();

    /// @notice Basis points denominator (100% = 10_000).
    uint256 public constant PCT_BASE = 10000;
    /// @notice Decimal places used in the USDT price per package unit.
    uint256 public constant PRICE_DECIMALS = 9;
    /// @notice Number of referral levels used by the referral system.
    uint256 public constant REF_LEVEL_COUNT = 4;
    /// @notice Number of supported lock period options.
    uint256 private constant LOCK_PERIODS_COUNT = 3;

    /// @notice `fiveECO` token deposited as phase collateral and vested to buyers.
    IERC20Burnable public immutable fiveEco;
    /// @notice USDT token accepted as payment for package purchases.
    IERC20 public immutable usdt;

    /// @notice Id assigned to the next phase created via `createPhase`.
    uint256 public nextPhaseId;
    /// @notice Linear vesting duration after the lock period ends.
    uint256 public withdrawDuration;
    /// @notice Wallet that receives USDT payments from purchases.
    address public usdtReceiver;
    /// @notice Lock period options in seconds (1, 2, and 3 years).
    uint256[LOCK_PERIODS_COUNT] public LOCK_PERIODS = [360 days, 720 days, 1080 days];
    /// @notice Referral fee shares by level in basis points (level 1 through 4).
    uint256[REF_LEVEL_COUNT] public REF_SYSTEM_FEES = [800, 400, 200, 100];

    /// @dev Per-account vesting schedules created on purchase.
    mapping(address => WithdrawInfo[]) private _withdrawSchedules;
    /// @dev Referrer registered on a buyer's first purchase; immutable thereafter.
    mapping(address => address) private _accountToReferrer;
    /// @dev Phase configuration keyed by phase id.
    mapping(uint256 => PhaseInfo) private _phaseIdToPhaseInfo;
    /// @dev Package tiers configured for each phase.
    mapping(uint256 => PackageInfo[]) private _phaseIdToPackagesInfo;
    /// @dev Gross `fiveECO` sold per package type within a phase (before referral deduction).
    mapping(uint256 => mapping(uint256 => uint256)) private _phaseIdToPackageTypeToSoldAmount;

    /// @notice Vesting schedule for a single `fiveECO` allocation.
    struct WithdrawInfo {
        /// @notice Timestamp when linear release begins (after lock period).
        uint256 start;
        /// @notice Linear release duration in seconds.
        uint256 duration;
        /// @notice Amount already released to the beneficiary.
        uint256 released;
        /// @notice Amount already burned from this schedule.
        uint256 burned;
        /// @notice Total `fiveECO` allocated to this schedule.
        uint256 amount;
    }

    /// @notice Package tier configuration within a phase.
    struct PackageInfo {
        /// @notice Base `fiveECO` quantity per purchase (before lock factor and bonus).
        uint256 quantity;
        /// @notice Bonus percentage applied to `quantity`, in basis points.
        uint256 bonus;
        /// @notice Maximum gross `fiveECO` that can be sold for this package type.
        uint256 poolCap;
    }

    /// @notice Phase-level sale configuration.
    struct PhaseInfo {
        /// @notice USDT price per package unit, scaled by `PRICE_DECIMALS`.
        uint256 price;
        /// @notice Unix timestamp when the phase becomes purchasable.
        uint256 startTime;
        /// @notice Phase length in seconds.
        uint256 duration;
        /// @notice Lock multipliers per `LOCK_PERIODS` entry, in basis points.
        uint256[LOCK_PERIODS_COUNT] lockFactors;
    }

    /// @notice Emitted when the USDT receiver address is updated.
    /// @param usdtReceiver New receiver address.
    event UsdtReceiverSetted(address usdtReceiver);
    /// @notice Emitted when the post-lock vesting duration is updated.
    /// @param withdrawDuration New vesting duration in seconds.
    event WithdrawDurationSetted(uint256 withdrawDuration);
    /// @notice Emitted when a new sale phase is created.
    /// @param phaseId Id of the created phase.
    event PhaseCreated(uint256 phaseId);
    /// @notice Emitted when an existing phase is edited.
    /// @param phaseId Id of the edited phase.
    event PhaseEdited(uint256 phaseId);
    /// @notice Emitted when a package is purchased.
    /// @param account Buyer address.
    /// @param phaseId Active phase id at time of purchase.
    /// @param packageType Index of the purchased package tier.
    /// @param lockPeriod Index into `LOCK_PERIODS`.
    /// @param usdtAmount USDT paid by the buyer.
    /// @param fiveEcoAmount Net `fiveECO` allocated to the buyer's vesting schedule after referral fees.
    event Purchase(address indexed account, uint256 phaseId, uint256 packageType, uint256 lockPeriod, uint256 usdtAmount, uint256 fiveEcoAmount);
    /// @notice Emitted when a vesting schedule is created for a buyer.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Index of the new schedule in `_withdrawSchedules[account]`.
    /// @param amount Total `fiveECO` allocated to the schedule.
    /// @param startTimestamp Timestamp when linear release begins.
    /// @param lockPeriod Lock period in seconds before release starts.
    /// @param duration Linear release duration in seconds.
    event WithdrawScheduleCreated(address indexed account, uint256 withdrawIndex, uint256 amount, uint256 startTimestamp, uint256 lockPeriod, uint256 duration);
    /// @notice Emitted when vested `fiveECO` is released to a buyer.
    /// @param account Beneficiary address.
    /// @param amount Amount transferred in this release.
    event WithdrawReleased(address indexed account, uint256 amount);
    /// @notice Emitted when a referrer is registered on a buyer's first purchase.
    /// @param account Buyer address.
    /// @param referrer Referrer address (may be zero).
    event ReferrerRegistered(address indexed account, address indexed referrer);
    /// @notice Emitted when a referral fee is paid in `USDT`.
    /// @param account Buyer whose purchase generated the fee.
    /// @param referrer Referrer that received the fee.
    /// @param refFeeAmount Fee amount transferred.
    event RefFeePayed(address indexed account, address indexed referrer, uint256 refFeeAmount);
    /// @notice Emitted when unsold package collateral is withdrawn after a phase ends.
    /// @param phaseId Phase from which collateral was withdrawn.
    /// @param packageType Package tier index.
    /// @param amount Unsold `fiveECO` amount withdrawn for that tier.
    event PackageWithdrawn(uint256 indexed phaseId, uint256 indexed packageType, uint256 amount);
    /// @notice Emitted when a vesting schedule is burned.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Schedule index.
    /// @param burnedAmount Amount burned.
    event WithdrawScheduleBurned(address indexed account, uint256 withdrawIndex, uint256 burnedAmount);

    /// @notice Deploys FounderPackages.
    /// @param fiveEcoAddress Address of the `fiveECO` token used as phase collateral.
    /// @param usdtAddress Address of the USDT payment token.
    /// @param _usdtReceiver Wallet that receives USDT from purchases.
    /// @param _withdrawDuration Linear vesting duration after lock (4–12 weeks).
    constructor(
        address fiveEcoAddress,
        address usdtAddress,
        address _usdtReceiver,
        uint256 _withdrawDuration
    ) Ownable(msg.sender) {
        if (
            fiveEcoAddress == address(0) ||
            usdtAddress == address(0)
        ) revert ZeroAddress();

        fiveEco = IERC20Burnable(fiveEcoAddress);
        usdt = IERC20(usdtAddress);
        _setUsdtReceiver(_usdtReceiver);
        _setWithdrawDuration(_withdrawDuration);
    }

    /// @notice Returns the number of vesting schedules for an account.
    /// @param account Account to query.
    /// @return Number of withdraw schedules.
    function getWithdrawSchedulesCount(address account) external view returns (uint256) {
        return _withdrawSchedules[account].length;
    }

    /// @notice Returns a vesting schedule by index.
    /// @param account Account to query.
    /// @param withdrawIndex Schedule index.
    /// @return Schedule details.
    function getWithdrawSchedule(address account, uint256 withdrawIndex) external view returns (WithdrawInfo memory) {
        return _withdrawSchedules[account][withdrawIndex];
    }

    /// @notice Returns the referrer registered for an account.
    /// @param account Account to query.
    /// @return Referrer address, or zero if none was registered.
    function getAccountReferrer(address account) external view returns (address) {
        return _accountToReferrer[account];
    }

    /// @notice Returns configuration for a phase.
    /// @param phaseId Phase id to query.
    /// @return Phase configuration.
    function getPhaseInfo(uint256 phaseId) external view returns (PhaseInfo memory) {
        return _phaseIdToPhaseInfo[phaseId];
    }

    /// @notice Returns package tiers configured for a phase.
    /// @param phaseId Phase id to query.
    /// @return Package tier list for the phase.
    function getPackagesInfo(uint256 phaseId) external view returns (PackageInfo[] memory) {
        return _phaseIdToPackagesInfo[phaseId];
    }

    /// @notice Returns gross `fiveECO` sold for a package type within a phase.
    /// @dev Sold amount is tracked before referral fee deduction from the buyer allocation.
    /// @param phaseId Phase id to query.
    /// @param packageType Package tier index.
    /// @return Gross sold amount in `fiveECO`.
    function getPackageSoldAmount(uint256 phaseId, uint256 packageType) external view returns (uint256) {
        return _phaseIdToPackageTypeToSoldAmount[phaseId][packageType];
    }

    /// @notice Updates the USDT receiver address.
    /// @param _usdtReceiver New receiver address.
    function setUsdtReceiver(address _usdtReceiver) external onlyOwner {
        _setUsdtReceiver(_usdtReceiver);
    }

    /// @notice Updates the linear vesting duration applied to new purchases.
    /// @param _withdrawDuration New duration in seconds (4–12 weeks).
    function setWithdrawDuration(uint256 _withdrawDuration) external onlyOwner {
        _setWithdrawDuration(_withdrawDuration);
    }

    /// @notice Creates a new sale phase and pulls `fiveECO` collateral from the owner.
    /// @dev Total collateral equals the sum of all package `poolCap` values.
    /// @param phaseInfo Phase configuration.
    /// @param packageInfos Package tiers for the phase.
    function createPhase(
        PhaseInfo memory phaseInfo,
        PackageInfo[] memory packageInfos
    ) external onlyOwner nonReentrant {
        _checkPhaseInfo(phaseInfo, false, 0);
        uint256 totalCap = _checkPackageInfos(packageInfos, phaseInfo.price);

        uint256 phaseId = nextPhaseId;
        nextPhaseId++;

        fiveEco.safeTransferFrom(msg.sender, address(this), totalCap);

        _phaseIdToPhaseInfo[phaseId] = phaseInfo;
        for (uint256 i = 0; i < packageInfos.length; i++) {
            _phaseIdToPackagesInfo[phaseId].push(packageInfos[i]);
        }

        emit PhaseCreated(phaseId);
    }

    /// @notice Edits a phase that has not started yet and reconciles collateral with the owner.
    /// @dev Refunds excess `fiveECO` or pulls additional collateral when total pool caps change.
    /// @param phaseId Id of the phase to edit.
    /// @param phaseInfo Updated phase configuration.
    /// @param packageInfos Updated package tiers.
    function editPhase(
        uint256 phaseId,
        PhaseInfo memory phaseInfo,
        PackageInfo[] memory packageInfos
    ) external onlyOwner nonReentrant {
        if (phaseId >= nextPhaseId) revert InvalidPhaseId();

        _checkPhaseInfo(phaseInfo, true, phaseId);
        uint256 newTotalCap = _checkPackageInfos(packageInfos, phaseInfo.price);

        _phaseIdToPhaseInfo[phaseId] = phaseInfo;
        PackageInfo[] storage packages = _phaseIdToPackagesInfo[phaseId];
        uint256 oldTotalCap = 0;
        if (packageInfos.length < packages.length) {
            for (uint256 i = packages.length; i > 0; i--) {
                uint256 index = i - 1;
                oldTotalCap += packages[index].poolCap;
                if (index < packageInfos.length) {
                    packages[index] = packageInfos[index];
                } else {
                    packages.pop();
                }
            }
        } else {
            for (uint256 i = 0; i < packageInfos.length; i++) {
                if (i < packages.length) {
                    oldTotalCap += packages[i].poolCap;
                    packages[i] = packageInfos[i];
                } else {
                    packages.push(packageInfos[i]);
                }
            }
        }

        bool isCapReduced = oldTotalCap > newTotalCap;
        uint256 capDiff = isCapReduced ? oldTotalCap - newTotalCap : newTotalCap - oldTotalCap;
        if (capDiff > 0) {
            if (isCapReduced) {
                fiveEco.safeTransfer(msg.sender, capDiff);
            } else {
                fiveEco.safeTransferFrom(msg.sender, address(this), capDiff);
            }
        }

        emit PhaseEdited(phaseId);
    }

    /// @notice Withdraws unsold `fiveECO` collateral for all package tiers after a phase ends.
    /// @dev Marks each package tier as fully sold to prevent double withdrawal.
    /// @param phaseId Id of the ended phase.
    function withdrawFromPhase(
        uint256 phaseId
    ) external onlyOwner nonReentrant {
        if (phaseId >= nextPhaseId) revert InvalidPhaseId();
        PhaseInfo memory phase = _phaseIdToPhaseInfo[phaseId];
        if (phase.startTime + phase.duration > block.timestamp) revert PhaseNotEnded();
        uint256 totalAvailableAmount = 0;
        PackageInfo[] memory packages = _phaseIdToPackagesInfo[phaseId];
        for (uint256 i = 0; i < packages.length; i++) {
            uint256 availableAmount = packages[i].poolCap - _phaseIdToPackageTypeToSoldAmount[phaseId][i];
            totalAvailableAmount += availableAmount;
            _phaseIdToPackageTypeToSoldAmount[phaseId][i] = packages[i].poolCap;

            emit PackageWithdrawn(phaseId, i, availableAmount);
        }
        if (totalAvailableAmount == 0) revert NoAvailableAmountInPackages();
        fiveEco.safeTransfer(msg.sender, totalAvailableAmount);
    }

    /// @notice Purchases a founder package from the currently active phase.
    /// @dev Registers referrer on the buyer's first purchase. USDT is sent to `usdtReceiver`.
    ///      Referral fees are deducted from the buyer's USDT amount before sending to `usdtReceiver`.
    /// @param packageType Index of the package tier to buy.
    /// @param lockPeriod Index into `LOCK_PERIODS` selecting the lock multiplier.
    /// @param refferer Referrer address; only applied on the buyer's first purchase.
    function purchase(
        uint256 packageType,
        uint256 lockPeriod,
        address refferer
    ) external nonReentrant {
        uint256 activePhaseId = _getActivePhaseId();
        if (packageType >= _phaseIdToPackagesInfo[activePhaseId].length) revert InvalidPackageType();
        if (lockPeriod >= LOCK_PERIODS_COUNT) revert InvalidLockPeriod();
        PhaseInfo memory phase = _phaseIdToPhaseInfo[activePhaseId];
        PackageInfo memory package = _phaseIdToPackagesInfo[activePhaseId][packageType];

        if (_withdrawSchedules[msg.sender].length == 0) {
            _registerReferrer(msg.sender, refferer);
        }

        uint256 usdtAmount = phase.price * package.quantity / 10 ** PRICE_DECIMALS;
        if (_accountToReferrer[msg.sender] != address(0)) {
            uint256 refFee = _distributeReferralFee(usdtAmount);
            usdtAmount -= refFee;
        }
        usdt.safeTransferFrom(msg.sender, usdtReceiver, usdtAmount);

        uint256 fiveEcoAmount = package.quantity * phase.lockFactors[lockPeriod] / PCT_BASE + package.quantity * package.bonus / PCT_BASE;
        if (_phaseIdToPackageTypeToSoldAmount[activePhaseId][packageType] + fiveEcoAmount > package.poolCap) revert PackagePoolCapExeeded();
        _phaseIdToPackageTypeToSoldAmount[activePhaseId][packageType] += fiveEcoAmount;

        _createWithdrawSchedule(msg.sender, fiveEcoAmount, LOCK_PERIODS[lockPeriod], withdrawDuration);

        emit Purchase(msg.sender, activePhaseId, packageType, lockPeriod, usdtAmount, fiveEcoAmount);
    }

    /// @notice Returns the amount already released from a vesting schedule.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Schedule index.
    /// @return Released `fiveECO` amount.
    function released(address account, uint256 withdrawIndex) public view virtual returns (uint256) {
        return _withdrawSchedules[account][withdrawIndex].released;
    }

    /// @notice Returns the amount already burned from a vesting schedule.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Schedule index.
    /// @return Burned `fiveECO` amount.
    function burned(address account, uint256 withdrawIndex) public view virtual returns (uint256) {
        return _withdrawSchedules[account][withdrawIndex].burned;
    }

    /// @notice Returns the amount currently available to release from a vesting schedule.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Schedule index.
    /// @return Releasable `fiveECO` amount at the current block timestamp.
    function releasable(address account, uint256 withdrawIndex) public view virtual returns (uint256) {
        if (burned(account, withdrawIndex) > 0) return 0;
        return staggeredAmount(account, withdrawIndex, uint64(block.timestamp)) - released(account, withdrawIndex);
    }

    /// @notice Releases vested `fiveECO` to the caller for a schedule index.
    /// @param withdrawIndex Schedule index to release from.
    function release(uint256 withdrawIndex) public virtual nonReentrant {
        if (withdrawIndex >= _withdrawSchedules[msg.sender].length) revert InvalidWithdrawIndex();
        address account = msg.sender;
        uint256 amount = releasable(account, withdrawIndex);
        if (amount == 0) revert NoAmountToRelease();
        _withdrawSchedules[account][withdrawIndex].released += amount;
        emit WithdrawReleased(account, amount);
        fiveEco.safeTransfer(account, amount);
    }

    /// @notice Burns the `fiveECO` amount from a vesting schedule.
    /// @param withdrawIndex Schedule index to burn from.
    function burnWithdrawSchedule(uint256 withdrawIndex) public virtual nonReentrant {
        if (withdrawIndex >= _withdrawSchedules[msg.sender].length) revert InvalidWithdrawIndex();
        address account = msg.sender;
        uint256 amount = _withdrawSchedules[account][withdrawIndex].amount - released(account, withdrawIndex) - burned(account, withdrawIndex);
        if (amount == 0) revert NoAmountToBurn();
        _withdrawSchedules[account][withdrawIndex].burned += amount;
        emit WithdrawScheduleBurned(account, withdrawIndex, amount);
        fiveEco.burn(amount);
    }

    /// @notice Returns the total vested amount for a schedule at a given timestamp.
    /// @param account Beneficiary address.
    /// @param withdrawIndex Schedule index.
    /// @param timestamp Timestamp to evaluate vesting at.
    /// @return Vested `fiveECO` amount at `timestamp`.
    function staggeredAmount(address account, uint256 withdrawIndex, uint64 timestamp) public view virtual returns (uint256) {
        WithdrawInfo memory withdrawInfo = _withdrawSchedules[account][withdrawIndex];
        return _withdrawSchedule(
            withdrawInfo.amount,
            timestamp,
            withdrawInfo.start,
            withdrawInfo.start + withdrawInfo.duration
        );
    }

    /// @dev Sets `usdtReceiver` after validating the address.
    /// @param _usdtReceiver New receiver address.
    function _setUsdtReceiver(address _usdtReceiver) private {
        if (_usdtReceiver == address(0)) revert ZeroAddress();

        usdtReceiver = _usdtReceiver;

        emit UsdtReceiverSetted(_usdtReceiver);
    }

    /// @dev Sets `withdrawDuration` after validating the allowed range.
    /// @param _withdrawDuration New vesting duration in seconds.
    function _setWithdrawDuration(
        uint256 _withdrawDuration
    ) private {
        if (
            _withdrawDuration < 4 weeks ||
            _withdrawDuration > 12 weeks ||
            _withdrawDuration % 1 weeks != 0
        ) revert InvalidWithdrawDuration();

        withdrawDuration = _withdrawDuration;

        emit WithdrawDurationSetted(_withdrawDuration);
    }

    /// @dev Validates phase timing, price, and lock factors for create/edit flows.
    /// @param phaseInfo Phase configuration to validate.
    /// @param onEditPhase Whether validation runs in the `editPhase` context.
    /// @param phaseId Phase id being edited; ignored when `onEditPhase` is false.
    function _checkPhaseInfo(
        PhaseInfo memory phaseInfo,
        bool onEditPhase,
        uint256 phaseId
    ) private view {
        if (phaseInfo.startTime <= block.timestamp) revert InvalidStartTime();
        if (phaseInfo.duration == 0) revert InvalidDuration();
        if (phaseInfo.price == 0) revert InvalidPrice();
        if (
            phaseInfo.lockFactors[0] < PCT_BASE ||
            phaseInfo.lockFactors[1] < PCT_BASE ||
            phaseInfo.lockFactors[2] < PCT_BASE
        ) revert InvalidLockFactor();
        if (onEditPhase) {
            if (_phaseIdToPhaseInfo[phaseId].startTime <= block.timestamp) revert PhaseAlreadyActiveOrEnded();
            if (phaseId > 0) {
                PhaseInfo memory prevPhase = _phaseIdToPhaseInfo[phaseId - 1];
                if (prevPhase.startTime + prevPhase.duration > phaseInfo.startTime) revert InvalidStartTime();
            }
            if (phaseId + 1 != nextPhaseId) {
                PhaseInfo memory nextPhase = _phaseIdToPhaseInfo[phaseId + 1];
                if (phaseInfo.startTime + phaseInfo.duration > nextPhase.startTime) revert InvalidDuration();
            }
        } else {
            if (nextPhaseId > 0) {
                PhaseInfo memory prevPhase = _phaseIdToPhaseInfo[nextPhaseId - 1];
                if (prevPhase.startTime + prevPhase.duration > phaseInfo.startTime) revert InvalidStartTime();
            }
        }
    }

    /// @dev Validates package tiers and returns the total collateral cap.
    /// @param packageInfos Package tiers to validate.
    /// @param phasePrice Phase price.
    /// @return totalCap Sum of all package `poolCap` values.
    /// @dev The package price is the price of the package in USDT.
    function _checkPackageInfos(
        PackageInfo[] memory packageInfos,
        uint256 phasePrice
    ) private pure returns (uint256 totalCap) {
        if (packageInfos.length == 0) revert InvalidPackagesCount();

        for (uint256 i = 0; i < packageInfos.length; i++) {
            PackageInfo memory package = packageInfos[i];
            if (package.quantity == 0) revert InvalidPackageQuantity();
            if (package.quantity * phasePrice < 10 ** PRICE_DECIMALS) revert InvalidPackagePrice();
            if (package.bonus > PCT_BASE) revert InvalidPackageBonus();
            if (package.poolCap == 0) revert InvalidPackagePoolCap();
            totalCap += package.poolCap;
        }
    }

    /// @dev Returns the id of the phase that is active at the current block timestamp.
    /// @return phaseId Active phase id.
    function _getActivePhaseId() private view returns (uint256 phaseId) {
        if (nextPhaseId == 0) revert NoPhaseCreatedYet();
        phaseId = nextPhaseId;
        while (true) {
            phaseId--;
            PhaseInfo memory phase = _phaseIdToPhaseInfo[phaseId];
            if (phase.startTime <= block.timestamp && phase.startTime + phase.duration > block.timestamp) return phaseId;
            if (phase.startTime + phase.duration <= block.timestamp) revert NoActivePhase();
            if (phaseId == 0) revert NoActivePhase();
        }
    }

    /// @dev Appends a vesting schedule for `account`.
    /// @param account Beneficiary address.
    /// @param amount Total `fiveECO` to vest.
    /// @param lockPeriod Lock period in seconds before release starts.
    /// @param duration Linear release duration in seconds.
    function _createWithdrawSchedule(address account, uint256 amount, uint256 lockPeriod, uint256 duration) internal {
        uint256 withdrawIndex = _withdrawSchedules[account].length;
        if (amount == 0) revert ZeroAmount();
        if (account == address(0)) revert ZeroAddress();
        uint256 startTimestamp = block.timestamp + lockPeriod;
        _withdrawSchedules[account].push(WithdrawInfo({
            start: startTimestamp,
            duration: duration,
            released: 0,
            burned: 0,
            amount: amount
        }));

        emit WithdrawScheduleCreated(account, withdrawIndex, amount, startTimestamp, lockPeriod, duration);
    }

    /// @dev Computes vested amount using weekly step release between `startTimestamp` and `endTimestamp`.
    /// @param totalAllocation Total amount to vest.
    /// @param timestamp Timestamp to evaluate.
    /// @param startTimestamp Vesting start timestamp.
    /// @param endTimestamp Vesting end timestamp.
    /// @return Vested amount at `timestamp`.
    function _withdrawSchedule(
        uint256 totalAllocation,
        uint64 timestamp,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) internal view virtual returns (uint256) {
        if (timestamp < startTimestamp) {
            return 0;
        } else if (timestamp >= endTimestamp) {
            return totalAllocation;
        } else {
            uint256 weeksPassed = (timestamp - startTimestamp) / 1 weeks;
            uint256 totalWeeks = (endTimestamp - startTimestamp) / 1 weeks;
            return (totalAllocation * weeksPassed) / totalWeeks;
        }
    }

    /// @dev Registers `referrer` for `account` on first purchase and checks for referral loops.
    /// @param account Buyer address.
    /// @param referrer Referrer address proposed by the buyer.
    function _registerReferrer(address account, address referrer) private {
        if (referrer == account) revert InvalidReferrer();
        _accountToReferrer[account] = referrer;
        _checkRefererCirculation(referrer);
        if (referrer != address(0)) {
            emit ReferrerRegistered(account, referrer);
        }
    }

    /// @dev Reverts if `referer` participates in a referral loop within `REF_LEVEL_COUNT` hops.
    /// @param referer Referrer address to validate.
    function _checkRefererCirculation(address referer) internal view {
        address directReferer = referer;
        if (referer != address(0)) {
            for (uint i = 0; i < REF_LEVEL_COUNT; i++) {
                referer = _accountToReferrer[referer];
                if (referer == address(0)) break;
                if (referer == directReferer) revert ReferralCirculationDetected();
            }
        }
    }

    /// @dev Distributes referral fees in `usdt` along the buyer's upline.
    /// @param amount USDT amount used to compute fee amounts.
    /// @return totalRefFee Total referral fees paid in USDT.
    function _distributeReferralFee(uint256 amount) private returns (uint256 totalRefFee) {
        address referrer = _accountToReferrer[msg.sender];
        for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
            if (referrer == address(0)) break;
            uint256 refFee = amount * REF_SYSTEM_FEES[i] / PCT_BASE;
            totalRefFee += refFee;
            if (refFee > 0) {
                usdt.safeTransferFrom(msg.sender, referrer, refFee);
                emit RefFeePayed(msg.sender, referrer, refFee);
            }

            referrer = _accountToReferrer[referrer];
        }
    }
}
