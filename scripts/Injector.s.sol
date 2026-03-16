// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import "../contracts/interfaces/IChainConfig.sol";
import "../contracts/interfaces/IGovernance.sol";
import "../contracts/interfaces/ISlashingIndicator.sol";
import "../contracts/interfaces/ISystemReward.sol";
import "../contracts/interfaces/IRuntimeUpgradeEvmHook.sol";
import "../contracts/interfaces/IValidatorSet.sol";
import "../contracts/interfaces/IStaking.sol";
import "../contracts/interfaces/IRuntimeUpgrade.sol";
import "../contracts/interfaces/IStakingPool.sol";
import "../contracts/interfaces/IInjector.sol";
import "../contracts/interfaces/IDeployerProxy.sol";
import "../contracts/interfaces/ITokenomics.sol";

import {InjectorContextHolder} from "../contracts/Injector.sol";
/**
forge script scripts/Injector.s.sol:InitManually -vvv \
  --fork-url https://ccv2-rpc-staging.chiliz.com \
  --priority-gas-price 1gwei \
  --with-gas-price 2501gwei \
  --broadcast 
 */
contract InitManually is Script {
    function run() public {
        InjectorContextHolder i = InjectorContextHolder(0x0000000000000000000000000000000000007006);
        vm.startBroadcast();
        i.initManually(
            IStaking(0x0000000000000000000000000000000000001000),
            ISlashingIndicator(0x0000000000000000000000000000000000001001),
            ISystemReward(0x0000000000000000000000000000000000001002),
            IStakingPool(0x0000000000000000000000000000000000007001),
            IGovernance(0x0000000000000000000000000000000000007002),
            IChainConfig(0x0000000000000000000000000000000000007003),
            IRuntimeUpgrade(0x0000000000000000000000000000000000007004),
            IDeployerProxy(0x0000000000000000000000000000000000007005),
            ITokenomics(0x0000000000000000000000000000000000007006)
        );
        vm.stopBroadcast();
    }
}
