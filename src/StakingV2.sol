// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title StakingV2
/// @author Absalom Benu | Bukit Digital Nusantara
/// @notice Single-asset staking with dynamic reward distribution
/// @dev Implements the MasterChef pattern (accRewardPerShare + rewardDebt)
///      used by SushiSwap, PancakeSwap, and most production DeFi protocols.
///
/// Key concepts:
///   accRewardPerShare — global accumulator, increases over time
///   rewardDebt        — per-user baseline, set on stake/claim/unstake
///   pendingReward     = stakedAmount × accRewardPerShare / PRECISION
///                       - rewardDebt
///
/// Advantages over Fixed APY:
///   - Predictable reward budget (rewardPerSecond × duration)
///   - Fair distribution (proportional to stake AND time)
///   - O(1) complexity regardless of staker count
///   - No risk of reward pool depleting unexpectedly
///
contract StakingV2 is Ownable, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;
    using Math for uint256;

        // _________ Struct _________

    /// @notice Per-staker information
    /// @dev Simpler than StakingV1 — no timestamp needed
    ///      Reward tracking done via rewardDebt + accRewardPerShare
    struct StakerInfo {
        /// @dev Amount of tokens currently staked
        uint256 stakedAmount;

        /// @dev Reward debt — the "baseline" for this user
        ///      Set to stakedAmount × accRewardPerShare on every
        ///      stake, unstake, claim, or compound operation
        ///      pendingReward = stakedAmount × accRewardPerShare / PRECISION
        ///                      - rewardDebt
        uint256 rewardDebt;

        /// @dev Total rewards claimed by this staker (analytics only)
        uint256 totalClaimed;
    }

        
        // __________ Constants __________

    /// @notice Minimum stake amount to prevent dust
    uint256 public constant MINIMUM_STAKE = 1e18;

    /// @notice Precision multiplier for accRewardPerShare
    /// @dev accRewardPerShare is stored × PRECISION to preserve
    ///      decimal places lost in integer division.
    ///      1e12 chosen as balance between precision and overflow safety:
    ///      max accRewardPerShare = type(uint256).max / maxStakedAmount
    ///      With 1e12 precision and 1e30 max staked: no overflow
    uint256 private constant PRECISION = 1e12;

        
        // __________ State Variables __________

    /// @notice Token used for both staking and rewards
    IERC20 public immutable stakingToken;

    /// @notice Reward tokens distributed per second to the entire pool
    /// @dev Can be updated by owner — always call _updatePool first
    uint256 public rewardPerSecond;

    /// @notice Whether new staking is currently active
    bool public stakingActive;

    // _____ Pool State _____

    /// @notice Accumulated reward per share (× PRECISION)
    /// @dev Global value — increases monotonically over time
    ///      Updated in _updatePool before every state change
    uint256 public accRewardPerShare;

    /// @notice Timestamp of last pool update
    uint256 public lastUpdateTime;

    /// @notice Timestamp when reward distribution ends
    /// @dev Calculated as: block.timestamp + totalFunded / rewardPerSecond
    ///      accRewardPerShare is never updated past this time
    uint256 public rewardEndTime;

    /// @notice Total tokens currently staked
    uint256 public totalStaked;

    /// @notice Total rewards distributed since deployment
    uint256 public totalRewardDistributed;

    /// @notice Total rewards funded by owner
    uint256 public totalRewardFunded;

    /// @notice Number of unique active stakers
    uint256 public stakerCount;

    /// @notice Per-address staker information
    mapping(address => StakerInfo) public stakerInfo;


        // __________ Events __________

    event Staked(
        address indexed staker,
        uint256 amount,
        uint256 totalStakedByUser
    );

    event Unstaked(
        address indexed staker,
        uint256 amount,
        uint256 rewardPaid
    );

    event RewardClaimed(
        address indexed staker,
        uint256 reward
    );

    /// @notice Emitted when reward is compounded (claimed + re-staked)
    event Compounded(
        address indexed staker,
        uint256 rewardCompounded,
        uint256 newTotalStaked
    );

    event RewardFunded(
        address indexed funder,
        uint256 amount,
        uint256 newRewardEndTime
    );

    event RewardRateUpdated(
        uint256 oldRate,
        uint256 newRate,
        uint256 newRewardEndTime
    );

    event EmergencyWithdraw(
        address indexed staker,
        uint256 amount
    );

    event StakingStatusUpdated(bool active);


        // __________ Errors __________

    error StakingNotActive();
    error AmountTooLow(uint256 provided, uint256 minimum);
    error InsufficientStaked(uint256 staked, uint256 requested);
    error NoRewardAvailable();
    error InsufficientRewardBalance(uint256 available, uint256 required);
    error NothingToWithdraw();
    error RewardRateCannotBeZero();


        // __________ Constructor __________

    /// @notice Deploy StakingV2
    /// @param _stakingToken Address of the ERC20 token to stake
    /// @param _rewardPerSecond Initial reward rate (tokens per second, in wei)
    ///        Example: 1e18 = 1 token per second = 86,400 tokens per day
    constructor(
        address _stakingToken,
        uint256 _rewardPerSecond
    )
        Ownable(msg.sender)
    {
        require(_stakingToken != address(0), "Invalid token address");
        require(_rewardPerSecond > 0, "Reward rate cannot be zero");

        stakingToken    = IERC20(_stakingToken);
        rewardPerSecond = _rewardPerSecond;
        stakingActive   = true;
        lastUpdateTime  = block.timestamp;

        // rewardEndTime starts as now — no reward until funded
        rewardEndTime   = block.timestamp;
    }


        // __________ Internal Functions __________

    /// @notice Update pool's accRewardPerShare based on time elapsed
    /// @dev MUST be called before every state-changing operation.
    ///      Failure to call this first results in incorrect reward calculation.
    ///
    /// Logic:
    ///   1. If nothing staked: update lastUpdateTime, return early
    ///   2. Cap current time at rewardEndTime (never distribute more than funded)
    ///   3. Calculate timeElapsed since last update
    ///   4. Calculate reward generated in this period
    ///   5. Update accRewardPerShare += reward × PRECISION / totalStaked
    ///   6. Update lastUpdateTime
    function _updatePool() internal {

        // _____ Early return: nothing staked _____
        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        // _____ Cap at rewardEndTime _____
        // Never distribute more reward than what's funded
        // This is the most critical safety mechanism in this contract
        uint256 currentTime = Math.min(block.timestamp, rewardEndTime);

        // _____ Calculate time elapsed _____
        uint256 timeElapsed = currentTime - lastUpdateTime;

        // Nothing to update if no time has passed
        if (timeElapsed == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        // _____ Calculate reward for this period _____
        uint256 reward = rewardPerSecond * timeElapsed;

        // _____ Update accRewardPerShare _____
        // Multiply by PRECISION before dividing to preserve decimals
        // reward × PRECISION / totalStaked can never overflow:
        // max reward per update ≈ rewardPerSecond × 1 second = small
        // PRECISION = 1e12, totalStaked >= MINIMUM_STAKE = 1e18
        // max ratio ≈ 1e18 × 1e12 / 1e18 = 1e12 — fits in uint256
        accRewardPerShare += reward * PRECISION / totalStaked;

        // _____ Update tracking variables _____
        lastUpdateTime          = block.timestamp;
        totalRewardDistributed += reward;
    }


        // __________ View Functions __________

    /// @notice Calculate pending reward for a staker
    /// @dev Simulates _updatePool without modifying state
    ///      This is what frontend calls to display claimable rewards
    /// @param staker Address to check
    /// @return Pending reward amount in wei
    function pendingReward(
        address staker
    ) public view returns (uint256) {
        StakerInfo memory info = stakerInfo[staker];

        if (info.stakedAmount == 0) return 0;

        // Simulate _updatePool calculation
        uint256 currentTime = Math.min(block.timestamp, rewardEndTime);
        uint256 _accRewardPerShare = accRewardPerShare;

        if (totalStaked > 0 && currentTime > lastUpdateTime) {
            uint256 timeElapsed = currentTime - lastUpdateTime;
            uint256 reward      = rewardPerSecond * timeElapsed;
            _accRewardPerShare += reward * PRECISION / totalStaked;
        }

        // pending = staked × accRewardPerShare / PRECISION - rewardDebt
        return (info.stakedAmount * _accRewardPerShare / PRECISION)
               - info.rewardDebt;
    }

    /// @notice How many seconds of reward distribution remain
    function rewardsDuration() public view returns (uint256) {
        if (block.timestamp >= rewardEndTime) return 0;
        return rewardEndTime - block.timestamp;
    }

    /// @notice Get comprehensive pool information
    function getPoolInfo() external view returns (
        uint256 _totalStaked,
        uint256 _rewardPerSecond,
        uint256 _accRewardPerShare,
        uint256 _rewardEndTime,
        uint256 _duration,
        uint256 _stakerCount,
        uint256 _totalDistributed,
        bool    _stakingActive
    ) {
        return (
            totalStaked,
            rewardPerSecond,
            accRewardPerShare,
            rewardEndTime,
            rewardsDuration(),
            stakerCount,
            totalRewardDistributed,
            stakingActive
        );
    }

    /// @notice Get staker information with pending reward
    function getStakerInfo(
        address staker
    ) external view returns (
        uint256 _stakedAmount,
        uint256 _pendingReward,
        uint256 _rewardDebt,
        uint256 _totalClaimed
    ) {
        StakerInfo memory info = stakerInfo[staker];
        return (
            info.stakedAmount,
            pendingReward(staker),
            info.rewardDebt,
            info.totalClaimed
        );
    }


        // __________ User Functions __________

    // _____ Stake _____
    /// @notice Stake tokens to earn rewards
    /// @dev Calls _updatePool first, then auto-claims pending rewards
    ///      before updating staked amount to prevent reward miscalculation
    /// @param amount Amount of tokens to stake (in wei)
    function stake(
        uint256 amount
    ) external whenNotPaused nonReentrant {

        // _____ Checks _____
        if (!stakingActive) revert StakingNotActive();
        if (amount < MINIMUM_STAKE) {
            revert AmountTooLow(amount, MINIMUM_STAKE);
        }

        // _____ Update pool FIRST _____
        _updatePool();

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Auto-claim pending reward _____
        // MUST happen before stakedAmount update
        if (info.stakedAmount > 0) {
            uint256 pending = (info.stakedAmount * accRewardPerShare / PRECISION)
                              - info.rewardDebt;

            if (pending > 0) {
                info.totalClaimed += pending;
                totalRewardDistributed; // already tracked in _updatePool
                stakingToken.safeTransfer(msg.sender, pending);
                emit RewardClaimed(msg.sender, pending);
            }
        } else {
            // First stake — increment staker count
            stakerCount++;
        }

        // _____ Effects _____
        info.stakedAmount += amount;
        totalStaked       += amount;

        // Update rewardDebt to current position
        // This "forgives" any reward that existed before this stake
        // For new stakers: rewardDebt = stakedAmount × current accRewardPerShare
        // This ensures they only get reward from this point forward
        info.rewardDebt = info.stakedAmount * accRewardPerShare / PRECISION;

        // _____ Interactions _____
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, info.stakedAmount);
    }

    //_____ Unstake _____
        /// @notice Unstake tokens and claim pending rewards
    /// @dev No lock period in V2. Partial unstake supported.
    /// @param amount Amount to unstake (in wei)
    function unstake(
        uint256 amount
    ) external nonReentrant {

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Checks _____
        if (info.stakedAmount < amount) {
            revert InsufficientStaked(info.stakedAmount, amount);
        }

        // _____ Update pool FIRST _____
        _updatePool();

        // _____ Calculate and transfer pending reward _____
        uint256 pending = (info.stakedAmount * accRewardPerShare / PRECISION)
                          - info.rewardDebt;

        // _____ Effects _____
        info.stakedAmount -= amount;
        totalStaked       -= amount;

        // Recalculate rewardDebt based on new staked amount
        info.rewardDebt = info.stakedAmount * accRewardPerShare / PRECISION;

        if (pending > 0) {
            info.totalClaimed += pending;
        }

        // Decrement staker count if fully unstaked
        if (info.stakedAmount == 0) {
            stakerCount--;
        }

        // _____ Interactions _____
        // Transfer staked tokens back
        stakingToken.safeTransfer(msg.sender, amount);

        // Transfer reward if any
        if (pending > 0) {
            stakingToken.safeTransfer(msg.sender, pending);
        }

        emit Unstaked(msg.sender, amount, pending);
    }

    //_____ Claim Reward _____
    /// @notice Claim pending rewards without unstaking
    function claimReward() external nonReentrant {

        // _____ Update pool FIRST _____
        _updatePool();

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Calculate pending _____
        uint256 pending = (info.stakedAmount * accRewardPerShare / PRECISION)
                          - info.rewardDebt;

        if (pending == 0) revert NoRewardAvailable();

        // _____ Effects _____
        // Update rewardDebt BEFORE transfer (CEI pattern)
        info.rewardDebt    = info.stakedAmount * accRewardPerShare / PRECISION;
        info.totalClaimed += pending;

        // _____ Interactions _____
        stakingToken.safeTransfer(msg.sender, pending);

        emit RewardClaimed(msg.sender, pending);
    }

    //_____ Compaund _____
    /// @notice Claim rewards and immediately re-stake them
    /// @dev Gas efficient — single transaction instead of claim + stake
    ///      Only works if staking is active
    function compound() external whenNotPaused nonReentrant {

        if (!stakingActive) revert StakingNotActive();

        // _____ Update pool FIRST _____
        _updatePool();

        StakerInfo storage info = stakerInfo[msg.sender];

        // _____ Calculate pending _____
        uint256 pending = (info.stakedAmount * accRewardPerShare / PRECISION)
                          - info.rewardDebt;

        if (pending == 0) revert NoRewardAvailable();

        // _____ Effects _____
        // Add pending reward directly to staked amount
        // No token transfer needed — tokens already in contract
        info.stakedAmount += pending;
        totalStaked       += pending;

        // Update rewardDebt with new staked amount
        info.rewardDebt = info.stakedAmount * accRewardPerShare / PRECISION;

        // Track as claimed for analytics
        info.totalClaimed += pending;

        emit Compounded(msg.sender, pending, info.stakedAmount);
    }

    //_____ Emergency Withdraw _____
    /// @notice Withdraw all staked tokens WITHOUT claiming rewards
    /// @dev Use only in case of contract emergency or bug
    ///      Intentionally does NOT call _updatePool
    ///      to prevent any state manipulation before emergency exit
    function emergencyWithdraw() external nonReentrant {

        StakerInfo storage info = stakerInfo[msg.sender];

        uint256 amount = info.stakedAmount;
        if (amount == 0) revert NothingToWithdraw();

        // _____ Effects _____
        // Reset all staker data — forfeits all pending rewards
        info.stakedAmount = 0;
        info.rewardDebt   = 0;
        totalStaked      -= amount;
        stakerCount--;

        // _____ Interactions _____
        stakingToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }


        // __________ Admin Functions __________

    /// @notice Fund the reward pool and extend reward period
    /// @dev Updates rewardEndTime based on funded amount
    /// @param amount Amount of tokens to add to reward pool
    function fundReward(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        // Update pool before changing end time
        _updatePool();

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        totalRewardFunded += amount;

        // Calculate remaining balance for reward
        // totalBalance = staked + reward pool
        uint256 rewardBalance = stakingToken.balanceOf(address(this))
                                - totalStaked;

        // Extend reward end time based on remaining balance
        rewardEndTime = block.timestamp + (rewardBalance / rewardPerSecond);

        emit RewardFunded(msg.sender, amount, rewardEndTime);
    }

    /// @notice Update reward rate per second
    /// @dev MUST call _updatePool first to settle pending rewards
    ///      at the old rate before switching to new rate
    /// @param newRate New reward rate in wei per second
    function setRewardPerSecond(uint256 newRate) external onlyOwner {
        if (newRate == 0) revert RewardRateCannotBeZero();

        // CRITICAL: update pool at old rate first
        // If we change rate before updating, pending rewards
        // from the elapsed time would be calculated at the wrong rate
        _updatePool();

        uint256 oldRate   = rewardPerSecond;
        rewardPerSecond   = newRate;

        // Recalculate end time with new rate
        uint256 rewardBalance = stakingToken.balanceOf(address(this))
                                - totalStaked;
        rewardEndTime = block.timestamp + (rewardBalance / newRate);

        emit RewardRateUpdated(oldRate, newRate, rewardEndTime);
    }

    /// @notice Enable or disable new staking
    function setStakingActive(bool active) external onlyOwner {
        stakingActive = active;
        emit StakingStatusUpdated(active);
    }

    /// @notice Pause all operations
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause all operations
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Emergency withdraw all tokens to owner
    /// @dev Only use in case of critical bug
    function emergencyAdminWithdraw() external onlyOwner {
        uint256 balance = stakingToken.balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();

        totalStaked = 0;
        stakingToken.safeTransfer(owner(), balance);

        emit EmergencyWithdraw(owner(), balance);
    }
}