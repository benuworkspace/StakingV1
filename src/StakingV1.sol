// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingV1
/// @author Absalom Benu | Bukit Digital Nusantara
/// @notice Single-asset staking contract with fixed APY
/// @dev Users stake tokens and earn rewards at a fixed APY rate.
///      Rewards are paid in the same token as the staked token.
///      Lock period enforced before unstaking.
///
/// Reward Formula:
///   reward = stakedAmount × apyBps × timeElapsed
///            ÷ (BPS_DENOMINATOR × YEAR_IN_SECONDS)
///
/// Example: 1000 tokens staked at 120% APY for 1 day
///   = 1000e18 × 12000 × 86400 ÷ (10000 × 31536000)
///   ≈ 3.287 tokens reward
///
contract StakingV1 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

        // __________ Struct __________

    /// @notice Information stored per staker
    struct StakerInfo {
        /// @dev Amount of tokens currently staked
        uint256 stakedAmount;

        /// @dev Timestamp when user first staked or last fully restaked
        ///      Used to enforce lock period
        uint256 stakeTimestamp;

        /// @dev Timestamp of last reward claim
        ///      Used to calculate pending rewards
        ///      Updated on every claim and stake operation
        uint256 lastClaimTime;

        /// @dev Total rewards claimed by this staker across all time
        ///      For analytics and transparency only
        uint256 totalClaimed;
    }


        // __________ Constants __________

    /// @notice Lock period before unstaking is allowed
    uint256 public constant LOCK_PERIOD = 7 days;

    /// @notice Minimum amount required to stake
    uint256 public constant MINIMUM_STAKE = 1e18;

    /// @notice Maximum APY in basis points (500%)
    /// @dev Prevents owner from setting unsustainable APY
    uint256 public constant MAX_APY_BPS = 50_000;

    /// @notice Seconds in a year for APY calculation
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10_000;


        // ___________ State Variables ___________

    /// @notice The token used for staking and rewards
    /// @dev immutable — cannot be changed after deployment
    IERC20 public immutable stakingToken;

    /// @notice Current APY rate in basis points
    /// @dev Default 12000 = 120% APY
    uint256 public apyBps;

    /// @notice Whether new staking is currently active
    /// @dev Unstake and claim remain available even when inactive
    bool public stakingActive;

    /// @notice Total tokens currently staked across all users
    uint256 public totalStaked;

    /// @notice Total rewards paid out since deployment
    uint256 public totalRewardPaid;

    /// @notice Number of unique active stakers
    uint256 public stakerCount;

    /// @notice Staker information per address
    mapping(address => StakerInfo) public stakerInfo;


        // __________ Events __________

    /// @notice Emitted when tokens are staked
    event Staked(
        address indexed staker,
        uint256 amount,
        uint256 totalStakedByUser
    );

    /// @notice Emitted when tokens are unstaked
    event Unstaked(
        address indexed staker,
        uint256 amount,
        uint256 rewardPaid
    );

    /// @notice Emitted when reward is claimed without unstaking
    event RewardClaimed(
        address indexed staker,
        uint256 reward
    );

    /// @notice Emitted when APY is updated
    event APYUpdated(
        uint256 indexed oldApyBps,
        uint256 indexed newApyBps
    );

    /// @notice Emitted when reward pool is funded
    event RewardFunded(
        address indexed funder,
        uint256 amount
    );

    /// @notice Emitted on emergency withdrawal by owner
    event EmergencyWithdraw(
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when staking active status changes
    event StakingStatusUpdated(bool active);


        // __________ Errors __________

    /// @notice Staking is not currently active
    error StakingNotActive();

    /// @notice Stake amount below minimum
    error AmountTooLow(uint256 provided, uint256 minimum);

    /// @notice Insufficient staked balance for unstake
    error InsufficientStaked(uint256 staked, uint256 requested);

    /// @notice Lock period has not been met
    /// @param unlockTime Timestamp when unstaking becomes available
    /// @param currentTime Current block timestamp
    error LockPeriodNotMet(uint256 unlockTime, uint256 currentTime);

    /// @notice No reward available to claim
    error NoRewardAvailable();

    /// @notice Contract does not have enough tokens for reward
    error InsufficientRewardBalance(uint256 available, uint256 required);

    /// @notice APY exceeds maximum allowed
    error APYTooHigh(uint256 requested, uint256 maximum);

    /// @notice Nothing to withdraw in emergency
    error NothingToWithdraw();


        // __________ Constructor __________

    /// @notice Deploy StakingV1
    /// @param _stakingToken Address of the ERC20 token to stake
    /// @param _initialApyBps Initial APY in basis points (12000 = 120%)
    constructor(
        address _stakingToken,
        uint256 _initialApyBps
    )
        Ownable(msg.sender)
    {
        require(_stakingToken != address(0), "Invalid token address");

        if (_initialApyBps > MAX_APY_BPS) {
            revert APYTooHigh(_initialApyBps, MAX_APY_BPS);
        }

        stakingToken  = IERC20(_stakingToken);
        apyBps        = _initialApyBps;
        stakingActive = true;
    }


        // __________ View Functions __________

    /// @notice Calculate pending reward for a staker
    /// @dev Pure time-based calculation using fixed APY
    ///      reward = stakedAmount × apyBps × timeElapsed
    ///               ÷ (BPS_DENOMINATOR × YEAR_IN_SECONDS)
    /// @param staker Address to calculate reward for
    /// @return Pending reward amount in wei
    function calculateReward(
        address staker
    ) public view returns (uint256) {
        StakerInfo memory info = stakerInfo[staker];

        // No reward if nothing staked
        if (info.stakedAmount == 0) return 0;

        uint256 timeElapsed = block.timestamp - info.lastClaimTime;

        // Multiply first, then divide — prevents precision loss
        return (info.stakedAmount * apyBps * timeElapsed)
               / (BPS_DENOMINATOR * YEAR_IN_SECONDS);
    }

    /// @notice Check if a staker can unstake
    /// @param staker Address to check
    /// @return canUnstake True if lock period has passed
    /// @return unlockTime Timestamp when unstaking becomes available
    function canUnstake(
        address staker
    ) public view returns (bool, uint256) {
        StakerInfo memory info = stakerInfo[staker];
        uint256 unlockTime = info.stakeTimestamp + LOCK_PERIOD;
        return (block.timestamp >= unlockTime, unlockTime);
    }

    /// @notice Get staker information
    function getStakerInfo(
        address staker
    ) external view returns (
        uint256 stakedAmount,
        uint256 pendingReward,
        uint256 stakeTimestamp,
        uint256 lastClaimTime,
        uint256 totalClaimed,
        bool lockMet,
        uint256 unlockTime
    ) {
        StakerInfo memory info = stakerInfo[staker];
        (bool _lockMet, uint256 _unlockTime) = canUnstake(staker);

        return (
            info.stakedAmount,
            calculateReward(staker),
            info.stakeTimestamp,
            info.lastClaimTime,
            info.totalClaimed,
            _lockMet,
            _unlockTime
        );
    }

    /// @notice Get global pool information
    function getPoolInfo() external view returns (
        uint256 _totalStaked,
        uint256 _totalRewardPaid,
        uint256 _stakerCount,
        uint256 _apyBps,
        uint256 _rewardBalance,
        bool _stakingActive
    ) {
        return (
            totalStaked,
            totalRewardPaid,
            stakerCount,
            apyBps,
            availableRewardBalance(),
            stakingActive
        );
    }

    /// @notice Available reward tokens in contract
    /// @dev Total balance minus staked tokens
    ///      This prevents double-counting staked tokens as rewards
    function availableRewardBalance() public view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));

        // Kalau contract balance kurang dari totalStaked
        // (seharusnya tidak terjadi, tapi defensive check)
        if (contractBalance <= totalStaked) return 0;

        return contractBalance - totalStaked;
    }


        // __________ User Functions __________

    //_____ Stake _____
    /// @notice Stake tokens to earn rewards
    /// @dev If user already has a stake, pending rewards are
    ///      auto-claimed before updating the staked amount.
    ///      This prevents reward loss when adding to existing stake.
    /// @param amount Amount of tokens to stake (in wei)
    function stake(
        uint256 amount
    ) external whenNotPaused nonReentrant {

        // _____ Checks _____
        if (!stakingActive) revert StakingNotActive();
        if (amount < MINIMUM_STAKE) {
            revert AmountTooLow(amount, MINIMUM_STAKE);
        }

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Auto-claim if already staking _____
        // CRITICAL: Must claim before updating stakedAmount
        // If we update amount first, old rewards would be calculated
        // with the new (higher) amount — user gets too much reward
        if (info.stakedAmount > 0) {
            uint256 pendingReward = calculateReward(msg.sender);

            if (pendingReward > 0) {
                uint256 available = availableRewardBalance();

                // Only claim if enough reward available
                // If not enough, skip auto-claim — don't block stake
                if (available >= pendingReward) {
                    info.totalClaimed += pendingReward;
                    totalRewardPaid   += pendingReward;

                    // Transfer reward before updating stake
                    // (reward calculation based on OLD staked amount)
                    stakingToken.safeTransfer(msg.sender, pendingReward);

                    emit RewardClaimed(msg.sender, pendingReward);
                }
            }
        } else {
            // First time staking — increment staker count
            stakerCount++;
        }

        // _____ Effects _____
        info.stakedAmount    += amount;
        info.stakeTimestamp   = block.timestamp;
        info.lastClaimTime    = block.timestamp;
        totalStaked          += amount;

        // _____ Interactions _____
        // Transfer tokens from user to contract
        // User must have approved this contract first
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, info.stakedAmount);
    }


    //_____ Unstake _____
    /// @notice Unstake tokens and claim pending rewards
    /// @dev Partial unstake is supported.
    ///      Lock period is enforced based on stakeTimestamp.
    ///      Rewards auto-claimed for full staked amount on unstake.
    /// @param amount Amount of tokens to unstake (in wei)
    function unstake(
        uint256 amount
    ) external nonReentrant {

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Checks _____
        if (info.stakedAmount < amount) {
            revert InsufficientStaked(info.stakedAmount, amount);
        }

        // Enforce lock period
        uint256 unlockTime = info.stakeTimestamp + LOCK_PERIOD;
        if (block.timestamp < unlockTime) {
            revert LockPeriodNotMet(unlockTime, block.timestamp);
        }

        // _____ Calculate reward _____
        // Reward calculated on FULL staked amount, not just unstake amount
        // This ensures user gets all pending rewards
        uint256 reward = calculateReward(msg.sender);

        // Check if contract can pay reward
        // If not enough, still allow unstake but skip reward
        uint256 available    = availableRewardBalance();
        bool canPayReward    = available >= reward && reward > 0;
        uint256 rewardToPay  = canPayReward ? reward : 0;

        // _____ Effects _____
        info.stakedAmount   -= amount;
        info.lastClaimTime   = block.timestamp;
        totalStaked         -= amount;

        if (rewardToPay > 0) {
            info.totalClaimed  += rewardToPay;
            totalRewardPaid    += rewardToPay;
        }

        // Decrement staker count if fully unstaked
        if (info.stakedAmount == 0) {
            stakerCount--;
        }

        // _____ Interactions _____
        // Transfer staked tokens back
        stakingToken.safeTransfer(msg.sender, amount);

        // Transfer reward if available
        if (rewardToPay > 0) {
            stakingToken.safeTransfer(msg.sender, rewardToPay);
        }

        emit Unstaked(msg.sender, amount, rewardToPay);
    }


    //_____ Claim Reward _____
        /// @notice Claim pending rewards without unstaking
    /// @dev Resets lastClaimTime to prevent double-claiming
    function claimReward() external nonReentrant {

        // _____ Checks _____
        uint256 reward = calculateReward(msg.sender);
        if (reward == 0) revert NoRewardAvailable();

        uint256 available = availableRewardBalance();
        if (available < reward) {
            revert InsufficientRewardBalance(available, reward);
        }

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Effects _____
        info.lastClaimTime  = block.timestamp;
        info.totalClaimed  += reward;
        totalRewardPaid    += reward;

        // _____ Interactions _____
        stakingToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }


        // __________ Admin Functions __________

    /// @notice Update APY rate
    /// @param newApyBps New APY in basis points
    function setAPY(uint256 newApyBps) external onlyOwner {
        if (newApyBps > MAX_APY_BPS) {
            revert APYTooHigh(newApyBps, MAX_APY_BPS);
        }

        uint256 oldApy = apyBps;
        apyBps         = newApyBps;

        emit APYUpdated(oldApy, newApyBps);
    }

    /// @notice Fund the reward pool
    /// @dev Anyone can fund — enables community-funded rewards
    /// @param amount Amount of tokens to add to reward pool
    function fundReward(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardFunded(msg.sender, amount);
    }

    /// @notice Enable or disable new staking
    /// @dev Unstake and claim remain available when inactive
    function setStakingActive(bool active) external onlyOwner {
        stakingActive = active;
        emit StakingStatusUpdated(active);
    }

    /// @notice Pause all operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdraw all tokens
    /// @dev Only use in case of critical bug or security issue
    ///      All staker funds will be withdrawn to owner
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();

        // Reset global state
        totalStaked = 0;

        stakingToken.safeTransfer(owner(), balance);

        emit EmergencyWithdraw(owner(), balance);
    }
}