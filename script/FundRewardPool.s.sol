// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FundRewardPool is Script {
    address constant STAKING_V2 = 0x6F08E2CaA1F91ebcE7203F0360185e7cb4bF89FC; // hasil deploy DeployStakingV2
    address constant REWARD_TOKEN = 0x8054091C2248b938782ff3eC4772065ab90B6314; // token yang sama dengan STAKE_TOKEN


    // Fund 1000 reward tokens
    uint256 constant FUND_AMOUNT = 1000 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        IERC20(REWARD_TOKEN).transfer(STAKING_V2, FUND_AMOUNT);
        console.log("Reward pool funded with:", FUND_AMOUNT);

        vm.stopBroadcast();
    }
}