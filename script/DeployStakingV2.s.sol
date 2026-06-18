// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StakingV2} from "../src/StakingV2.sol";


contract DeployStakingV2 is Script {
    // Token used for both staking and rewards in StakingV2
    address constant STAKE_TOKEN = address(0x8054091C2248b938782ff3eC4772065ab90B6314);

    // Initial reward rate: 0.01 token per second (adjust as needed)
    uint256 constant INITIAL_REWARD_RATE = 0.01 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying StakingV2...");
        console.log("Deployer:", deployer);
        console.log("Stake Token:", STAKE_TOKEN);

        console.log("Initial Reward Rate:", INITIAL_REWARD_RATE);

        vm.startBroadcast(deployerPrivateKey);

        StakingV2 staking = new StakingV2(
            STAKE_TOKEN,
            INITIAL_REWARD_RATE
        );


        console.log("StakingV2 deployed at:", address(staking));

        vm.stopBroadcast();
    }
}