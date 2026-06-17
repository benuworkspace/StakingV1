// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StakingV1} from "../src/StakingV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployStakingV1
/// @notice Script untuk deploy dan setup StakingV1
/// @dev Melakukan tiga langkah sekaligus:
///      1. Deploy StakingV1
///      2. Approve staking contract
///      3. Fund reward pool
///
/// Required env vars:
///   PRIVATE_KEY        — deployer private key
///   STAKING_TOKEN      — address ERC20 token (MyToken dari Hari 4)
///   REWARD_AMOUNT      — jumlah token untuk reward pool (dalam wei)
///   INITIAL_APY_BPS    — APY awal dalam basis points
///
contract DeployStakingV1 is Script {

    function run() public returns (StakingV1 staking) {

        // ── Load env ──────────────────────────────────────────────
        uint256 deployerPrivateKey  = vm.envUint("PRIVATE_KEY");
        address deployer            = vm.addr(deployerPrivateKey);
        address stakingTokenAddress = vm.envAddress("STAKING_TOKEN");
        uint256 rewardAmount        = vm.envUint("REWARD_AMOUNT");
        uint256 initialApyBps       = vm.envUint("INITIAL_APY_BPS");

        IERC20 stakingToken = IERC20(stakingTokenAddress);

        // ── Pre-deploy validation ─────────────────────────────────
        uint256 deployerBalance = stakingToken.balanceOf(deployer);

        // ── Pre-deploy logging ────────────────────────────────────
        console.log("====================================================================================");
        console.log("                              Deploying StakingV1                                   ");
        console.log("====================================================================================");
        console.log("Deployer         :", deployer);
        console.log("Staking Token    :", stakingTokenAddress);
        console.log("Deployer Balance :", deployerBalance / 1e18, "tokens");
        console.log("Reward Amount    :", rewardAmount / 1e18, "tokens");
        console.log("Initial APY      :", initialApyBps / 100, "%");
        console.log("Lock Period      : 7 days");
        console.log("Min Stake        : 1 token");
        console.log("Network Chain ID :", block.chainid);
        console.log("====================================================================================");

        require(
            deployerBalance >= rewardAmount,
            "Insufficient token balance for reward funding"
        );

        // ── Deploy + Setup ────────────────────────────────────────
        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy StakingV1
        staking = new StakingV1(stakingTokenAddress, initialApyBps);
        console.log("StakingV1 deployed at:", address(staking));

        // Step 2: Approve staking contract untuk ambil reward token
        stakingToken.approve(address(staking), rewardAmount);
        console.log("Approved:", rewardAmount / 1e18, "tokens");

        // Step 3: Fund reward pool
        staking.fundReward(rewardAmount);
        console.log("Reward pool funded!");

        vm.stopBroadcast();

        // ── Post-deploy logging ───────────────────────────────────
        console.log("====================================================================================");
        console.log("                           Deploy + Setup Successful!                               ");
        console.log("====================================================================================");
        console.log("Contract Address   :", address(staking));
        console.log("Staking Token      :", address(staking.stakingToken()));
        console.log("APY                :", staking.apyBps() / 100, "%");
        console.log("Reward Balance     :", staking.availableRewardBalance() / 1e18, "tokens");
        console.log("Staking Active     :", staking.stakingActive());
        console.log("====================================================================================");
        console.log("Etherscan:");
        console.log(
            string(abi.encodePacked(
                "https://sepolia.etherscan.io/address/",
                vm.toString(address(staking))
            ))
        );
        console.log("====================================================================================");
        console.log("Next steps:");
        console.log("1. Verify contract on Etherscan");
        console.log("2. Approve token from your wallet");
        console.log("3. Test stake via Etherscan Write Contract");
        console.log("====================================================================================");

        return staking;
    }
}