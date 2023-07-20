/** @var artifacts {Array} */
/** @var web3 {Web3} */
/** @function contract */
/** @function it */
/** @function before */
const fs = require('fs');
const {setCode} = require("./helper");

/** @var assert */

/**
 * Run ganache:
 * ganache --f http://localhost:8545 -p 7545 --miner.blockGasLimit 300000000 --miner.callGasLimit 30000000 -b 1 -u 0xf299AfC34ec0B9dCAF868914288d735149d6306f 0xc9D6695BA2d3C3e674980f437EC4b0806d95C029 0x53AF95Aea0036F2555C7E04DC7d957660c73FA13 0x72676b2A2371Af4Fe23515e0E8bE9d44Bf41A6f4 0x8EB838bc93567a4D1102FEf4c7e03879e016a805 0x9a905C99D7753F01918E389C785b5862CF7A3945 0x4d466f3A688Cb1096497dbcB9Fd68E500e24f0B1 0xA5AaE23884D1890c7D2fe004694f8E0852bece39 0xa564D63BAb82931dC007193B4C987ba269333695 0x4cfA9d95E8A84B41677Eb8ae68AeF0b6B2e2B067 0xf299AfC34ec0B9dCAF868914288d735149d6306f 0x45c846a75a3958630bD5f9FD03Cb309262131E56 0x65a64463Bd571f3E18642ed613A4c503334B4Ef8 0x119C37D2Eab99aD9a1508289Cbf24aC9703cDDF3 0x39D1A8b9732d154876e9a466e00A0acD8ED6E106 0x98Dd87523296dDAbc24caAf5cf2E625D9b4F2292 0x4e4620FE9dF2751F55FA01D24413343290c22698 0xA2ec78Eb13C40c03F3F9283f7057B6C7E652F644 0xE548F293E2BA625eFB34c11e43217dD4330D6da8 0xb67D0e9394932d3cFa6102A55F636481FBcc7976 0x97ADd7226B3f1020fB3308cc67e74cb77757C211 0x8ee1c1f4b14c0A1698BdA02f58021968010523D2
 *
 * Run test:
 * npx truffle test test/fork-fix-epochs.js --network ganache
 */

const Staking = artifacts.require("Staking");
const StakingPool = artifacts.require("StakingPool");
const Governance = artifacts.require('Governance');
const RuntimeUpgrade = artifacts.require('RuntimeUpgrade');

const STAKING_ADDRESS = '0x0000000000000000000000000000000000001000';
const SLASHING_INDICATOR_ADDRESS = '0x0000000000000000000000000000000000001001';
const SYSTEM_REWARD_ADDRESS = '0x0000000000000000000000000000000000001002';
const STAKING_POOL_ADDRESS = '0x0000000000000000000000000000000000007001';
const GOVERNANCE_ADDRESS = '0x0000000000000000000000000000000000007002';
const CHAIN_CONFIG_ADDRESS = '0x0000000000000000000000000000000000007003';
const RUNTIME_UPGRADE_ADDRESS = '0x0000000000000000000000000000000000007004';
const DEPLOYER_PROXY_ADDRESS = '0x0000000000000000000000000000000000007005';

const PROPOSER_ADDRESS = '0xf299AfC34ec0B9dCAF868914288d735149d6306f';

const proposalStates = ['Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed'];

const sleepFor = async ms => {
  return new Promise(resolve => setTimeout(resolve, ms))
}

const readByteCodeForAddress = address => {
  const artifactPaths = {
    [STAKING_ADDRESS]: './build/contracts/Staking.json',
    [SLASHING_INDICATOR_ADDRESS]: './build/contracts/SlashingIndicator.json',
    [SYSTEM_REWARD_ADDRESS]: './build/contracts/SystemReward.json',
    [STAKING_POOL_ADDRESS]: './build/contracts/StakingPool.json',
    [GOVERNANCE_ADDRESS]: './build/contracts/Governance.json',
    [CHAIN_CONFIG_ADDRESS]: './build/contracts/ChainConfig.json',
    [RUNTIME_UPGRADE_ADDRESS]: './build/contracts/RuntimeUpgrade.json',
    [DEPLOYER_PROXY_ADDRESS]: './build/contracts/DeployerProxy.json',
  }
  const filePath = artifactPaths[address]
  if (!filePath) throw new Error(`There is no artifact for the address: ${address}`)
  const {deployedBytecode} = JSON.parse(fs.readFileSync(filePath, 'utf8'))
  return deployedBytecode
}

const upgradeContract = async (contractAddress) => {
  const byteCode = readByteCodeForAddress(contractAddress),
    existingByteCode = await web3.eth.getCode(contractAddress);
  if (byteCode === existingByteCode) {
    console.log(` ~ bytecode is the same, skipping ~ `)
    return;
  }
  await setCode(STAKING_ADDRESS, byteCode);
}

const voteProposal = async (proposalId, validators, staking, governance) => {
  for (const validatorAddress of validators) {
    const { ownerAddress } = await staking.getValidatorStatus(validatorAddress);
    console.log(` ~ validator owner ${ownerAddress} is voting`)
    // feed validators
    await web3.eth.sendTransaction({ from: PROPOSER_ADDRESS, value: '1000000000000000000', to: ownerAddress });
    try {
      await governance.castVote(proposalId, '1', { from: ownerAddress });
    } catch (e) {
      console.error(e);
    }
  }
}

const executeProposal = async (proposalId, targets, calldatas, desc, governance) => {
  while (true) {
    const currentBlock = await web3.eth.getBlockNumber()
    const state = await governance.state(proposalId),
      status = proposalStates[Number(state)];
    const deadline = await governance.proposalDeadline(proposalId);
    console.log(`Current proposal status is: ${status}, current block is: ${currentBlock} deadline is: ${deadline}, elapsed: ${deadline - currentBlock}`)
    switch (status) {
      case 'Pending':
      case 'Active': {
        break;
      }
      case 'Succeeded': {
        const { tx } = await governance.execute(targets, new Array(targets.length).fill('0x00'), calldatas, web3.utils.keccak256(desc), { from: PROPOSER_ADDRESS });
        console.log(`Executing proposal: ${tx}`);
        break;
      }
      case 'Executed': {
        console.log(`Proposal was successfully executed`);
        return;
      }
      default: {
        console.error(`Incorrect proposal status, upgrade failed: ${status}, exiting`)
        return;
      }
    }
    await sleepFor(12_000)
  }
}

const proposePause = async (staking, governance) => {
  const validators = await staking.getValidators();
  const desc = 'Pause delegations and undelegations';
  const pauseCall = '0xc4ae3168';

  // const pauseCall = staking.contract.methods.togglePause().encodeABI();
  // const governanceTx = await governance.proposeWithCustomVotingPeriod([STAKING_ADDRESS], ['0x00'], [pauseCall], desc, validators.length + 20, { from: PROPOSER_ADDRESS });
  // const proposalId = governanceTx.receipt.logs[0].args.proposalId

  const tx = await web3.eth.sendTransaction({
    from: PROPOSER_ADDRESS,
    to: GOVERNANCE_ADDRESS,
    data: '0x0eb448fa00000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004c4ae316800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002350617573652064656c65676174696f6e7320616e6420756e64656c65676174696f6e730000000000000000000000000000000000000000000000000000000000',
    gasLimit: 1_000_000,
  })
  const proposalId = tx.logs[0].data.substring(0, 66);

  await voteProposal(proposalId, validators, staking, governance);
  // now we can execute the proposal
  await executeProposal(proposalId, [STAKING_ADDRESS], [pauseCall], desc, governance);
}

const proposeFix = async (staking, governance) => {
  const validators = await staking.getValidators();
  const desc = 'Fix validators epochs';
  const calldatas = [
    '0x20543d34000000000000000000000000e548f293e2ba625efb34c11e43217dd4330d6da800000000000000000000000000000000000000000000000000000019de1377000000000000000000000000000000000000000000000000000000000000000097',
    '0x20543d34000000000000000000000000a2ec78eb13c40c03f3f9283f7057b6c7e652f64400000000000000000000000000000000000000000000000000000019de1377000000000000000000000000000000000000000000000000000000000000000097',
    '0x20543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e324a865674000000000000000000000000000000000000000000000000000000000000005d',
    '0x20543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e354b96a48c0000000000000000000000000000000000000000000000000000000000000070',
    '0x20543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e32f78ac08c0000000000000000000000000000000000000000000000000000000000000097',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec6200000000000000000000000000000000000000000000000000038ece4ad4d000000000000000000000000000000000000000000000000000000000000000005c',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003903bd3a470b0000000000000000000000000000000000000000000000000000000000000005d',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec6200000000000000000000000000000000000000000000000000039013506f24b0000000000000000000000000000000000000000000000000000000000000005e',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003905ca7e5b2b0000000000000000000000000000000000000000000000000000000000000005f',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000391457c8ac2b00000000000000000000000000000000000000000000000000000000000000062',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003913c2ccf51800000000000000000000000000000000000000000000000000000000000000065',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003913c2ce381660000000000000000000000000000000000000000000000000000000000000066',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000391733c0e4788000000000000000000000000000000000000000000000000000000000000007b',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390c119a1f9d4000000000000000000000000000000000000000000000000000000000000007d',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac2536f5d4000000000000000000000000000000000000000000000000000000000000007f',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac28000b900000000000000000000000000000000000000000000000000000000000000085',
    '0x20543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac46a41f0c0000000000000000000000000000000000000000000000000000000000000090',
    '0x20543d3400000000000000000000000031db81188a5cc391857624f668dda57ba7f2b07400000000000000000000000000000000000000000000000000039da49f1ff1000000000000000000000000000000000000000000000000000000000000000094'
  ];
  const targets = new Array(18).fill(STAKING_ADDRESS);

  // const pauseCall = staking.contract.methods.togglePause().encodeABI();
  // const governanceTx = await governance.proposeWithCustomVotingPeriod([STAKING_ADDRESS], ['0x00'], [pauseCall], desc, validators.length + 20, { from: PROPOSER_ADDRESS });
  // const proposalId = governanceTx.receipt.logs[0].args.proposalId

  const tx = await web3.eth.sendTransaction({
    from: PROPOSER_ADDRESS,
    to: GOVERNANCE_ADDRESS,
    data: '0x0eb448fa00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000056000000000000000000000000000000000000000000000000000000000000013000000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000380000000000000000000000000000000000000000000000000000000000000042000000000000000000000000000000000000000000000000000000000000004c00000000000000000000000000000000000000000000000000000000000000560000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000006a0000000000000000000000000000000000000000000000000000000000000074000000000000000000000000000000000000000000000000000000000000007e00000000000000000000000000000000000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000092000000000000000000000000000000000000000000000000000000000000009c00000000000000000000000000000000000000000000000000000000000000a600000000000000000000000000000000000000000000000000000000000000b000000000000000000000000000000000000000000000000000000000000000ba00000000000000000000000000000000000000000000000000000000000000c400000000000000000000000000000000000000000000000000000000000000ce0000000000000000000000000000000000000000000000000000000000000006420543d34000000000000000000000000e548f293e2ba625efb34c11e43217dd4330d6da800000000000000000000000000000000000000000000000000000019de137700000000000000000000000000000000000000000000000000000000000000009700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d34000000000000000000000000a2ec78eb13c40c03f3f9283f7057b6c7e652f64400000000000000000000000000000000000000000000000000000019de137700000000000000000000000000000000000000000000000000000000000000009700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e324a865674000000000000000000000000000000000000000000000000000000000000005d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e354b96a48c000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d34000000000000000000000000e5cff8f16da0b3067bc7432ba2b4ae7199eaae5300000000000000000000000000000000000000000000000000038e32f78ac08c000000000000000000000000000000000000000000000000000000000000009700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec6200000000000000000000000000000000000000000000000000038ece4ad4d000000000000000000000000000000000000000000000000000000000000000005c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003903bd3a470b0000000000000000000000000000000000000000000000000000000000000005d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec6200000000000000000000000000000000000000000000000000039013506f24b0000000000000000000000000000000000000000000000000000000000000005e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003905ca7e5b2b0000000000000000000000000000000000000000000000000000000000000005f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000391457c8ac2b0000000000000000000000000000000000000000000000000000000000000006200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003913c2ccf5180000000000000000000000000000000000000000000000000000000000000006500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec620000000000000000000000000000000000000000000000000003913c2ce38166000000000000000000000000000000000000000000000000000000000000006600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000391733c0e4788000000000000000000000000000000000000000000000000000000000000007b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390c119a1f9d4000000000000000000000000000000000000000000000000000000000000007d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac2536f5d4000000000000000000000000000000000000000000000000000000000000007f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac28000b90000000000000000000000000000000000000000000000000000000000000008500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000052527e4b47ad69cd69021fbb6da2a4f210feec62000000000000000000000000000000000000000000000000000390ac46a41f0c000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006420543d3400000000000000000000000031db81188a5cc391857624f668dda57ba7f2b07400000000000000000000000000000000000000000000000000039da49f1ff10000000000000000000000000000000000000000000000000000000000000000940000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000154669782076616c696461746f72732065706f6368730000000000000000000000',
    gasLimit: 10_000_000,
  })
  const proposalId = tx.logs[0].data.substring(0, 66);

  await voteProposal(proposalId, validators, staking, governance);
  // now we can execute the proposal
  console.log(targets);
  console.log(calldatas)
  await executeProposal(proposalId, targets, calldatas, desc, governance);
}

contract("fork fix", async (accounts) => {
  let staking, runtimeUpgrade, governance, activeValidatorSet;
  let notSupported = false;
  before(async () => {
    try {
      staking = await Staking.at(STAKING_ADDRESS);
      runtimeUpgrade = await RuntimeUpgrade.at(RUNTIME_UPGRADE_ADDRESS);
      governance = await Governance.at(GOVERNANCE_ADDRESS);
      activeValidatorSet = await staking.getValidators();
    } catch (e) {
      if (e.message.includes('no code at address')) {
        notSupported = true;
        console.error(`Can't run fork test because test env is not a fork of mainnet`)
      }
    }
  })
  it("test proposal migration", async () => {
    if (!notSupported) {
      await upgradeContract(STAKING_ADDRESS);
      await proposePause(staking, governance);
      await proposeFix(staking, governance);
    }
  }).timeout(2_000_000)
});