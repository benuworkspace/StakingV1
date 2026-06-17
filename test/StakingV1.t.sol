// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StakingV1} from "../src/StakingV1.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// __________ Mock ERC20 Token untuk Testing __________

/// @dev Simple ERC20 token untuk dipakai di test
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        // Mint 10 juta token ke deployer
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    /// @dev Mint tambahan untuk test purposes
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// __________ Test Contract __________

contract StakingV1Test is Test {

    // _____ Contracts _____

    StakingV1 public staking;
    MockToken public token;

    // _____ Addresses _____

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    // _____ Constants _____

    uint256 public constant INITIAL_APY_BPS  = 12_000;  // 120%
    uint256 public constant REWARD_FUND      = 1_000_000 * 1e18;
    uint256 public constant STAKE_AMOUNT     = 1_000 * 1e18;
    uint256 public constant YEAR_IN_SECONDS  = 365 days;

    // _____ Events untuk expectEmit _____

    event Staked(address indexed staker, uint256 amount, uint256 totalStakedByUser);
    event Unstaked(address indexed staker, uint256 amount, uint256 rewardPaid);
    event RewardClaimed(address indexed staker, uint256 reward);
    event APYUpdated(uint256 indexed oldApyBps, uint256 indexed newApyBps);
    event RewardFunded(address indexed funder, uint256 amount);

    // _____ Setup _____

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy token
        token = new MockToken();

        // Deploy staking contract
        staking = new StakingV1(address(token), INITIAL_APY_BPS);

        // Fund reward pool
        token.approve(address(staking), REWARD_FUND);
        staking.fundReward(REWARD_FUND);

        // Distribusikan token ke users untuk testing
        token.transfer(user1, 100_000 * 1e18);
        token.transfer(user2, 100_000 * 1e18);
        token.transfer(user3, 100_000 * 1e18);

        // Approve staking contract dari masing-masing user
        vm.prank(user1);
        token.approve(address(staking), type(uint256).max);

        vm.prank(user2);
        token.approve(address(staking), type(uint256).max);

        vm.prank(user3);
        token.approve(address(staking), type(uint256).max);
    }

    // _____ Helper Functions _____

    /// @dev Stake token sebagai user
    function _stakeAs(address user, uint256 amount) internal {
        vm.prank(user);
        staking.stake(amount);
    }

    /// @dev Skip waktu ke depan
    function _skipTime(uint256 timeInSeconds) internal {
        vm.warp(block.timestamp + timeInSeconds);
    }

    /// @dev Hitung expected reward
    function _expectedReward(
        uint256 amount,
        uint256 apyBps,
        uint256 timeInSeconds
    ) internal pure returns (uint256) {
        return (amount * apyBps * timeInSeconds)
               / (10_000 * YEAR_IN_SECONDS);
    }

    // =============================================================
    //                    DEPLOYMENT TESTS
    // =============================================================

    function test_Deploy_Token() public view {
        assertEq(address(staking.stakingToken()), address(token));
    }

    function test_Deploy_APY() public view {
        assertEq(staking.apyBps(), INITIAL_APY_BPS);
    }

    function test_Deploy_StakingActive() public view {
        assertTrue(staking.stakingActive());
    }

    function test_Deploy_TotalStakedZero() public view {
        assertEq(staking.totalStaked(), 0);
    }

    function test_Deploy_StakerCountZero() public view {
        assertEq(staking.stakerCount(), 0);
    }

    function test_Deploy_RewardFunded() public view {
        assertEq(staking.availableRewardBalance(), REWARD_FUND);
    }

    function test_Deploy_RevertsIfZeroAddress() public {
        vm.expectRevert("Invalid token address");
        new StakingV1(address(0), INITIAL_APY_BPS);
    }

    function test_Deploy_RevertsIfAPYTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingV1.APYTooHigh.selector,
                60_000,
                50_000
            )
        );
        new StakingV1(address(token), 60_000);
    }

    // =============================================================
    //                      STAKE TESTS
    // =============================================================

    function test_Stake_Success() public {
        _stakeAs(user1, STAKE_AMOUNT);

        assertEq(staking.totalStaked(), STAKE_AMOUNT);
        assertEq(staking.stakerCount(), 1);

        (uint256 stakedAmount,,,,,,) = staking.getStakerInfo(user1);
        assertEq(stakedAmount, STAKE_AMOUNT);
    }

    function test_Stake_TransfersTokens() public {
        uint256 balanceBefore = token.balanceOf(user1);
        _stakeAs(user1, STAKE_AMOUNT);
        assertEq(token.balanceOf(user1), balanceBefore - STAKE_AMOUNT);
        assertEq(
            token.balanceOf(address(staking)),
            REWARD_FUND + STAKE_AMOUNT
        );
    }

    function test_Stake_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Staked(user1, STAKE_AMOUNT, STAKE_AMOUNT);
        _stakeAs(user1, STAKE_AMOUNT);
    }

    function test_Stake_MultipleUsers() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _stakeAs(user2, STAKE_AMOUNT * 2);

        assertEq(staking.totalStaked(), STAKE_AMOUNT * 3);
        assertEq(staking.stakerCount(), 2);
    }

    function test_Stake_AdditionalStake_AutoClaim() public {
        // User1 stake pertama
        _stakeAs(user1, STAKE_AMOUNT);

        // Skip 30 hari — ada pending reward
        _skipTime(30 days);

        uint256 pendingReward = staking.calculateReward(user1);
        assertGt(pendingReward, 0);

        uint256 balanceBefore = token.balanceOf(user1);

        // Stake tambahan — auto-claim seharusnya terjadi
        _stakeAs(user1, STAKE_AMOUNT);

        // User1 menerima pending reward
        assertGt(token.balanceOf(user1), balanceBefore - STAKE_AMOUNT);
        // (balanceBefore - STAKE_AMOUNT + pendingReward)
    }

    function test_Stake_AdditionalStake_IncreasesStakerCount_Once() public {
        // Stake pertama: count naik jadi 1
        _stakeAs(user1, STAKE_AMOUNT);
        assertEq(staking.stakerCount(), 1);

        // Stake kedua: count TIDAK naik lagi
        _stakeAs(user1, STAKE_AMOUNT);
        assertEq(staking.stakerCount(), 1);
    }

    function test_Stake_RevertsIfNotActive() public {
        staking.setStakingActive(false);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(StakingV1.StakingNotActive.selector)
        );
        staking.stake(STAKE_AMOUNT);
    }

    function test_Stake_RevertsIfBelowMinimum() public {
        uint256 dustAmount = 0.5e18; // 0.5 token < minimum 1 token

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingV1.AmountTooLow.selector,
                dustAmount,
                staking.MINIMUM_STAKE()
            )
        );
        staking.stake(dustAmount);
    }

    // =============================================================
    //                    REWARD CALCULATION TESTS
    // =============================================================

    function test_Reward_ZeroBeforeTimePass() public {
        _stakeAs(user1, STAKE_AMOUNT);
        // Langsung setelah stake — reward harus 0 atau sangat kecil
        assertEq(staking.calculateReward(user1), 0);
    }

    function test_Reward_After1Day() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(1 days);

        uint256 reward   = staking.calculateReward(user1);
        uint256 expected = _expectedReward(STAKE_AMOUNT, INITIAL_APY_BPS, 1 days);

        assertEq(reward, expected);
        // Dengan 120% APY, 1000 token selama 1 hari ≈ 3.287 token
        console.log("Reward after 1 day:", reward / 1e18, "tokens (approx)");
    }

    function test_Reward_After7Days() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        uint256 reward   = staking.calculateReward(user1);
        uint256 expected = _expectedReward(STAKE_AMOUNT, INITIAL_APY_BPS, 7 days);

        assertEq(reward, expected);
        console.log("Reward after 7 days:", reward / 1e18, "tokens (approx)");
    }

    function test_Reward_After30Days() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        uint256 reward   = staking.calculateReward(user1);
        uint256 expected = _expectedReward(STAKE_AMOUNT, INITIAL_APY_BPS, 30 days);

        assertEq(reward, expected);
        console.log("Reward after 30 days:", reward / 1e18, "tokens (approx)");
    }

    function test_Reward_After1Year() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(365 days);

        uint256 reward   = staking.calculateReward(user1);
        uint256 expected = _expectedReward(STAKE_AMOUNT, INITIAL_APY_BPS, 365 days);

        assertEq(reward, expected);

        // 120% APY: 1000 token selama 1 tahun = 1200 token reward
        assertApproxEqAbs(reward, 1_200 * 1e18, 1e15); // toleransi 0.001 token
        console.log("Reward after 1 year:", reward / 1e18, "tokens");
    }

    function test_Reward_ProportionalToAmount() public {
        // User1 stake 1000, user2 stake 2000
        _stakeAs(user1, STAKE_AMOUNT);
        _stakeAs(user2, STAKE_AMOUNT * 2);
        _skipTime(30 days);

        uint256 reward1 = staking.calculateReward(user1);
        uint256 reward2 = staking.calculateReward(user2);

        // Reward2 harus tepat 2x reward1
        assertApproxEqAbs(reward2, reward1 * 2, 1e15);
    }

    function test_Reward_AfterAPYChange() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        // Hitung reward dengan APY lama
        uint256 rewardOldAPY = staking.calculateReward(user1);

        // User claim dulu sebelum APY berubah
        vm.prank(user1);
        staking.claimReward();

        // Owner ubah APY ke 60%
        staking.setAPY(6_000);
        _skipTime(30 days);

        // Reward 30 hari berikutnya dengan APY baru
        uint256 rewardNewAPY = staking.calculateReward(user1);
        uint256 expected     = _expectedReward(STAKE_AMOUNT, 6_000, 30 days);

        assertEq(rewardNewAPY, expected);
        // APY baru (60%) harus menghasilkan reward lebih kecil
        assertLt(rewardNewAPY, rewardOldAPY);
    }

    function test_Reward_ZeroForNonStaker() public view {
        // Address yang tidak pernah stake
        assertEq(staking.calculateReward(user3), 0);
    }

    // =============================================================
    //                    UNSTAKE TESTS
    // =============================================================

    function test_Unstake_Success_AfterLockPeriod() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days); // lock period = 7 days

        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // User menerima stake + reward
        assertGt(token.balanceOf(user1), balanceBefore + STAKE_AMOUNT - 1);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.stakerCount(), 0);
    }

    function test_Unstake_EmitsEvent() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        uint256 expectedReward = staking.calculateReward(user1);

        vm.expectEmit(true, false, false, false);
        emit Unstaked(user1, STAKE_AMOUNT, expectedReward);

        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);
    }

    function test_Unstake_AutoClaimsReward() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        uint256 pendingReward = staking.calculateReward(user1);
        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        // User menerima stake + reward
        assertApproxEqAbs(
            token.balanceOf(user1),
            balanceBefore + STAKE_AMOUNT + pendingReward,
            1e15
        );
    }

    function test_Unstake_Partial() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        // Unstake setengah
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT / 2);

        // Setengah masih ter-stake
        (uint256 stakedAmount,,,,,,) = staking.getStakerInfo(user1);
        assertEq(stakedAmount, STAKE_AMOUNT / 2);
        assertEq(staking.totalStaked(), STAKE_AMOUNT / 2);
        // Staker count masih 1 (masih ada stake)
        assertEq(staking.stakerCount(), 1);
    }

    function test_Unstake_Full_DecrementsStakerCount() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _stakeAs(user2, STAKE_AMOUNT);
        _skipTime(7 days);

        assertEq(staking.stakerCount(), 2);

        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        assertEq(staking.stakerCount(), 1);
    }

    function test_Unstake_RevertsBeforeLockPeriod() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(3 days); // hanya 3 hari, butuh 7 hari

        // lock period not met: unlockTime = stakeTimestamp + LOCK_PERIOD
        // After staking and skipping 3 days, stakeTimestamp = block.timestamp - 3 days.
        uint256 stakeTimestamp = block.timestamp - 3 days;
        uint256 unlockTime = stakeTimestamp + staking.LOCK_PERIOD();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingV1.LockPeriodNotMet.selector,
                unlockTime,
                block.timestamp
            )
        );
        staking.unstake(STAKE_AMOUNT);

    }

    function test_Unstake_RevertsIfInsufficientStaked() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingV1.InsufficientStaked.selector,
                STAKE_AMOUNT,
                STAKE_AMOUNT + 1
            )
        );
        staking.unstake(STAKE_AMOUNT + 1);
    }

    function test_Unstake_CanUnstakeWhenStakingInactive() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        // Owner nonaktifkan staking
        staking.setStakingActive(false);

        // User masih bisa unstake
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        assertEq(staking.totalStaked(), 0);
    }

    // =============================================================
    //                    CLAIM REWARD TESTS
    // =============================================================

    function test_Claim_Success() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        uint256 expectedReward = staking.calculateReward(user1);
        uint256 balanceBefore  = token.balanceOf(user1);

        vm.prank(user1);
        staking.claimReward();

        assertEq(
            token.balanceOf(user1),
            balanceBefore + expectedReward
        );
    }

    function test_Claim_EmitsEvent() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        uint256 expectedReward = staking.calculateReward(user1);

        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(user1, expectedReward);

        vm.prank(user1);
        staking.claimReward();
    }

    function test_Claim_ResetsLastClaimTime() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        vm.prank(user1);
        staking.claimReward();

        // Setelah claim, reward harus 0 (lastClaimTime direset)
        assertEq(staking.calculateReward(user1), 0);
    }

    function test_Claim_DoesNotAffectStakedAmount() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        vm.prank(user1);
        staking.claimReward();

        (uint256 stakedAmount,,,,,,) = staking.getStakerInfo(user1);
        assertEq(stakedAmount, STAKE_AMOUNT);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);
    }

    function test_Claim_MultipleTimes_Accumulates() public {
        _stakeAs(user1, STAKE_AMOUNT);

        uint256 totalClaimed = 0;

        // Claim 3 kali masing-masing 10 hari
        for (uint256 i = 0; i < 3; i++) {
            _skipTime(10 days);
            uint256 reward = staking.calculateReward(user1);
            vm.prank(user1);
            staking.claimReward();
            totalClaimed += reward;
        }

        // Total claim 3x10 hari = 30 hari reward
        uint256 expected = _expectedReward(STAKE_AMOUNT, INITIAL_APY_BPS, 30 days);
        assertApproxEqAbs(totalClaimed, expected, 1e15);
    }

    function test_Claim_RevertsIfNoReward() public {
        _stakeAs(user1, STAKE_AMOUNT);
        // Tidak skip waktu — reward = 0

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(StakingV1.NoRewardAvailable.selector)
        );
        staking.claimReward();
    }

    function test_Claim_UpdatesTotalClaimed() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        uint256 reward = staking.calculateReward(user1);

        vm.prank(user1);
        staking.claimReward();

        (, , , uint256 lastClaimTime, uint256 totalClaimed,,) = staking.getStakerInfo(user1);
        assertEq(lastClaimTime, block.timestamp);
        assertEq(totalClaimed, reward);
        assertEq(staking.totalRewardPaid(), reward);

    }

    // =============================================================
    //                    ADMIN TESTS
    // =============================================================

    function test_SetAPY_Success() public {
        staking.setAPY(6_000);
        assertEq(staking.apyBps(), 6_000);
    }

    function test_SetAPY_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit APYUpdated(INITIAL_APY_BPS, 6_000);
        staking.setAPY(6_000);
    }

    function test_SetAPY_RevertsIfTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingV1.APYTooHigh.selector,
                60_000,
                50_000
            )
        );
        staking.setAPY(60_000);
    }

    function test_SetAPY_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.setAPY(6_000);
    }

    function test_FundReward_Success() public {
        uint256 additionalFund  = 500_000 * 1e18;
        uint256 balanceBefore   = staking.availableRewardBalance();

        token.approve(address(staking), additionalFund);
        staking.fundReward(additionalFund);

        assertEq(
            staking.availableRewardBalance(),
            balanceBefore + additionalFund
        );
    }

    function test_FundReward_EmitsEvent() public {
        uint256 amount = 100_000 * 1e18;
        token.approve(address(staking), amount);

        vm.expectEmit(true, false, false, true);
        emit RewardFunded(owner, amount);
        staking.fundReward(amount);
    }

    function test_FundReward_AnyoneCanFund() public {
        uint256 amount = 10_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), amount);
        staking.fundReward(amount);
        vm.stopPrank();

        assertGt(staking.availableRewardBalance(), REWARD_FUND);
    }

    function test_EmergencyWithdraw_Success() public {
        _stakeAs(user1, STAKE_AMOUNT);

        uint256 contractBalance = token.balanceOf(address(staking));
        uint256 ownerBefore     = token.balanceOf(owner);

        staking.emergencyWithdraw();

        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(token.balanceOf(owner), ownerBefore + contractBalance);
        assertEq(staking.totalStaked(), 0);
    }

    function test_EmergencyWithdraw_RevertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_RevertsIfEmpty() public {
        // Drain semua token dulu
        staking.emergencyWithdraw();

        vm.expectRevert(
            abi.encodeWithSelector(StakingV1.NothingToWithdraw.selector)
        );
        staking.emergencyWithdraw();
    }

    function test_SetStakingActive_False_BlocksNewStake() public {
        staking.setStakingActive(false);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(StakingV1.StakingNotActive.selector)
        );
        staking.stake(STAKE_AMOUNT);
    }

    // =============================================================
    //                    VIEW FUNCTION TESTS
    // =============================================================

    function test_GetStakerInfo() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        (
            uint256 stakedAmount,
            uint256 pendingReward,
            uint256 stakeTimestamp,
            uint256 lastClaimTime,
            uint256 totalClaimed,
            bool lockMet,
            uint256 unlockTime
        ) = staking.getStakerInfo(user1);

        assertEq(stakedAmount, STAKE_AMOUNT);
        assertGt(pendingReward, 0);
        assertGt(stakeTimestamp, 0);
        assertEq(lastClaimTime, stakeTimestamp);
        assertEq(totalClaimed, 0);
        assertTrue(lockMet);
    }

    function test_CanUnstake_AfterLockPeriod() public {
        _stakeAs(user1, STAKE_AMOUNT);

        (bool canUnstakeBefore,) = staking.canUnstake(user1);
        assertFalse(canUnstakeBefore);

        _skipTime(7 days);

        (bool canUnstakeAfter,) = staking.canUnstake(user1);
        assertTrue(canUnstakeAfter);
    }

    function test_GetPoolInfo() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _stakeAs(user2, STAKE_AMOUNT * 2);

        (
            uint256 _totalStaked,
            uint256 _totalRewardPaid,
            uint256 _stakerCount,
            uint256 _apyBps,
            uint256 _rewardBalance,
            bool _stakingActive
        ) = staking.getPoolInfo();

        assertEq(_totalStaked, STAKE_AMOUNT * 3);
        assertEq(_totalRewardPaid, 0);
        assertEq(_stakerCount, 2);
        assertEq(_apyBps, INITIAL_APY_BPS);
        assertGt(_rewardBalance, 0);
        assertTrue(_stakingActive);
    }

    function test_AvailableRewardBalance_ExcludesStaked() public {
        _stakeAs(user1, STAKE_AMOUNT);

        // Available reward = total balance - staked amount
        uint256 contractBalance  = token.balanceOf(address(staking));
        uint256 availableReward  = staking.availableRewardBalance();

        assertEq(availableReward, contractBalance - STAKE_AMOUNT);
        assertEq(availableReward, REWARD_FUND);
    }

    // =============================================================
    //                    EDGE CASE TESTS
    // =============================================================

    function test_Edge_StakeUnstakeStakeAgain() public {
        // Stake pertama
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        // Unstake semua
        vm.prank(user1);
        staking.unstake(STAKE_AMOUNT);

        assertEq(staking.stakerCount(), 0);

        // Stake lagi — harus seperti staker baru
        _stakeAs(user1, STAKE_AMOUNT);
        assertEq(staking.stakerCount(), 1);

        // Reward harus mulai dari 0 lagi
        assertEq(staking.calculateReward(user1), 0);
    }

    function test_Edge_MultipleStakersIndependent() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(15 days);

        _stakeAs(user2, STAKE_AMOUNT);
        _skipTime(15 days);

        // user1 sudah stake 30 hari
        // user2 baru stake 15 hari
        uint256 reward1 = staking.calculateReward(user1);
        uint256 reward2 = staking.calculateReward(user2);

        // Reward user1 harus lebih besar dari user2
        assertGt(reward1, reward2);

        // Reward user1 ≈ 2x reward user2 (karena 2x durasi)
        assertApproxEqAbs(reward1, reward2 * 2, 1e15);
    }

    function test_Edge_RewardNotAffectedByOtherStakers() public {
        // user1 stake sendirian 30 hari
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);
        uint256 reward1Alone = staking.calculateReward(user1);

        // Reset — user1 claim, user2 join
        vm.prank(user1);
        staking.claimReward();

        _stakeAs(user2, STAKE_AMOUNT * 10);
        _skipTime(30 days);

        uint256 reward1WithOthers = staking.calculateReward(user1);

        // Fixed APY tidak terpengaruh oleh staker lain
        assertApproxEqAbs(reward1Alone, reward1WithOthers, 1e15);
    }

    // =============================================================
    //                      FUZZ TESTS
    // =============================================================

    /// @notice Fuzz: reward selalu proporsional dengan jumlah dan waktu
    function test_Fuzz_RewardMath(uint256 amount, uint256 timeInSeconds) public {
        // Hindari vm.assume terlalu banyak input (limit fuzz)
        uint256 boundedAmount = bound(amount, 1e18, 10_000 * 1e18);
        uint256 boundedTime   = bound(timeInSeconds, 1 days, 30 days);

        // Fund extra reward untuk cover fuzz amounts
        token.approve(address(staking), type(uint256).max);
        staking.fundReward(boundedAmount * 2);

        token.transfer(user1, boundedAmount);
        vm.prank(user1);
        token.approve(address(staking), boundedAmount);
        _stakeAs(user1, boundedAmount);

        _skipTime(boundedTime);

        uint256 actualReward   = staking.calculateReward(user1);
        uint256 expectedReward = _expectedReward(boundedAmount, INITIAL_APY_BPS, boundedTime);

        assertEq(actualReward, expectedReward);
    }


    /// @notice Fuzz: total claim tidak melebihi reward yang di-fund
    function test_Fuzz_ClaimNeverExceedsRewardPool(uint256 amount) public {
        // Hindari vm.assume rejected too many inputs saat fuzz dijalankan sangat banyak
        uint256 boundedAmount = bound(amount, 1e18, 50_000 * 1e18);

        token.transfer(user1, boundedAmount);
        vm.prank(user1);
        token.approve(address(staking), boundedAmount);
        _stakeAs(user1, boundedAmount);

        _skipTime(365 days);

        uint256 rewardBefore = staking.availableRewardBalance();
        uint256 pendingReward = staking.calculateReward(user1);

        if (pendingReward <= rewardBefore) {
            vm.prank(user1);
            staking.claimReward();
            assertLe(staking.totalRewardPaid(), rewardBefore);
        }
    }

    // =============================================================
    //                      GAS REPORT
    // =============================================================

    function test_Gas_Stake() public {
        vm.prank(user1);
        uint256 before = gasleft();
        staking.stake(STAKE_AMOUNT);
        console.log("Gas stake():", before - gasleft());
    }

    function test_Gas_Unstake() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(7 days);

        vm.prank(user1);
        uint256 before = gasleft();
        staking.unstake(STAKE_AMOUNT);
        console.log("Gas unstake():", before - gasleft());
    }

    function test_Gas_ClaimReward() public {
        _stakeAs(user1, STAKE_AMOUNT);
        _skipTime(30 days);

        vm.prank(user1);
        uint256 before = gasleft();
        staking.claimReward();
        console.log("Gas claimReward():", before - gasleft());
    }
}