/** @var web3 {Web3} */
const BigNumber = require("bignumber.js");
const {keccak256} = require('ethereumjs-util');
const AbiCoder = require('web3-eth-abi');

const ChainConfig = artifacts.require("ChainConfig");
const Staking = artifacts.require("Staking");
const SlashingIndicator = artifacts.require("SlashingIndicator");
const SystemReward = artifacts.require("SystemReward");
const Governance = artifacts.require("FakeGovernance");
const StakingPool = artifacts.require("StakingPool");
const RuntimeUpgrade = artifacts.require("RuntimeUpgrade");
const DeployerProxy = artifacts.require("DeployerProxy");
const Tokenomics = artifacts.require("Tokenomics");
const FakeStaking = artifacts.require("FakeStaking");
const FakeDeployerProxy = artifacts.require("FakeDeployerProxy");
const FakeRuntimeUpgrade = artifacts.require("FakeRuntimeUpgrade");
const FakeSystemReward = artifacts.require("FakeSystemReward");
const FakeTokenomics = artifacts.require("FakeTokenomics");

const DEFAULT_MOCK_PARAMS = {
  systemTreasury: '0x0000000000000000000000000000000000000000',
  activeValidatorsLength: '3',
  epochBlockInterval: '10',
  misdemeanorThreshold: '50',
  felonyThreshold: '150',
  validatorJailEpochLength: '7',
  undelegatePeriod: '0',
  minValidatorStakeAmount: '1000000000000000000',
  minStakingAmount: '1000000000000000000',
  genesisValidators: [],
  genesisDeployers: [],
  runtimeUpgradeEvmHook: '0x0000000000000000000000000000000000000001',
  votingPeriod: '2',
};

const DEFAULT_CONTRACT_TYPES = {
  ChainConfig: ChainConfig,
  Staking: Staking,
  SlashingIndicator: SlashingIndicator,
  SystemReward: SystemReward,
  Governance: Governance,
  StakingPool: StakingPool,
  RuntimeUpgrade: RuntimeUpgrade,
  DeployerProxy: DeployerProxy,
  Tokenomics: Tokenomics,
};

const createConstructorArgs = (types, args) => {
  const params = AbiCoder.encodeParameters(types, args)
  const sig = '0x' + keccak256(Buffer.from('ctor(' + types.join(',') + ')')).toString('hex').substring(0, 8)
  return sig + params.substring(2)
}

const newContractUsingTypes = async (owner, params, types = {}) => {
  const {
    ChainConfig,
    Staking,
    SlashingIndicator,
    SystemReward,
    Governance,
    StakingPool,
    RuntimeUpgrade,
    DeployerProxy,
    Tokenomics,
  } = Object.assign({}, DEFAULT_CONTRACT_TYPES, types)
  let {
    genesisDeployers,
    systemTreasury,
    activeValidatorsLength,
    epochBlockInterval,
    misdemeanorThreshold,
    felonyThreshold,
    validatorJailEpochLength,
    genesisValidators,
    undelegatePeriod,
    minValidatorStakeAmount,
    minStakingAmount,
    runtimeUpgradeEvmHook,
    votingPeriod,
  } = Object.assign({}, DEFAULT_MOCK_PARAMS, params)
  // factory contracts
  const staking = await Staking.new(createConstructorArgs(
    ['address[]', 'uint256[]', 'uint16'],
    [genesisValidators, genesisValidators.map(() => '0'), '0'])
  );
  const slashingIndicator = await SlashingIndicator.new(createConstructorArgs([], []));
  if (typeof systemTreasury === 'string') {
    systemTreasury = {[systemTreasury]: '10000'}
  }
  const systemReward = await SystemReward.new(createConstructorArgs(['address[]', 'uint16[]'], [Object.keys(systemTreasury), Object.values(systemTreasury)]));
  const governance = await Governance.new(createConstructorArgs(['uint256'], [votingPeriod]));
  const chainConfig = await ChainConfig.new(createConstructorArgs(
    ["uint32", "uint32", "uint32", "uint32", "uint32", "uint32", "uint256", "uint256"],
    [activeValidatorsLength, epochBlockInterval, misdemeanorThreshold, felonyThreshold, validatorJailEpochLength, undelegatePeriod, minValidatorStakeAmount, minStakingAmount])
  );
  const stakingPool = await StakingPool.new(createConstructorArgs([], []));
  const runtimeUpgrade = await RuntimeUpgrade.new(createConstructorArgs(['address'], [runtimeUpgradeEvmHook]));
  const deployerProxy = await DeployerProxy.new(createConstructorArgs(['address[]'], [genesisDeployers]));
  const tokenomics = await Tokenomics.new(createConstructorArgs(['uint16', 'uint16'], [6500, 3500]));
  // init them all
  for (const contract of [slashingIndicator, staking, systemReward, stakingPool, governance, chainConfig, runtimeUpgrade, deployerProxy, tokenomics]) {
    await contract.initManually(
      staking.address,
      slashingIndicator.address,
      systemReward.address,
      stakingPool.address,
      governance.address,
      chainConfig.address,
      runtimeUpgrade.address,
      deployerProxy.address,
      tokenomics.address,
    );
  }
  return {
    staking,
    parlia: staking,
    slashingIndicator,
    systemReward,
    stakingPool,
    governance,
    chainConfig,
    config: chainConfig,
    runtimeUpgrade,
    deployer: deployerProxy,
    deployerProxy,
    tokenomics,
  }
}

const newMockContract = async (owner, params = {}) => {
  return newContractUsingTypes(owner, params, {
    Staking: FakeStaking,
    RuntimeUpgrade: FakeRuntimeUpgrade,
    DeployerProxy: FakeDeployerProxy,
    SystemReward: FakeSystemReward,
    Tokenomics: FakeTokenomics,
  });
}

const setCode = (address, code) => {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send({
      jsonrpc: "2.0",
      method: "evm_setAccountCode",
      id: new Date().getTime(),
      params: [address, code],
    }, (err, result) => {
      if (err) {
        return reject(err);
      }
      const newBlockHash = web3.eth.getBlock("latest").hash;

      return resolve(newBlockHash);
    })
  })
}

const advanceBlock = () => {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send({
      jsonrpc: "2.0",
      method: "evm_mine",
      id: new Date().getTime()
    }, (err, result) => {
      if (err) {
        return reject(err);
      }
      const newBlockHash = web3.eth.getBlock("latest").hash;

      return resolve(newBlockHash);
    });
  });
};

const advanceBlocks = async (count) => {
  for (let i = 0; i < count; i++) {
    await advanceBlock();
  }
}

const expectError = async (promise, text) => {
  try {
    await promise;
  } catch (e) {
    if (e.message.includes(text)) {
      return;
    }
    console.error(new Error(`Unexpected error: ${e.message}`))
  }
  console.error(new Error(`Expected error: ${text}`))
  assert.fail();
}

const extractTxCost = async (executionResult) => {
  let {receipt: {gasUsed, effectiveGasPrice}} = executionResult;
  if (typeof effectiveGasPrice === 'string') {
    effectiveGasPrice = new BigNumber(effectiveGasPrice.substring(2), 16)
  } else {
    effectiveGasPrice = new BigNumber(await web3.eth.getGasPrice(), 10)
  }
  executionResult.txCost = new BigNumber(gasUsed).multipliedBy(effectiveGasPrice);
  return executionResult;
}

const waitForNextEpoch = async (parlia, blockStep = 1) => {
  const currentEpoch = await parlia.currentEpoch()
  while (true) {
    await advanceBlocks(blockStep)
    const nextEpoch = await parlia.currentEpoch()
    if (`${currentEpoch}` === `${nextEpoch}`) continue;
    break;
  }
}

module.exports = {
  newMockContract,
  expectError,
  extractTxCost,
  waitForNextEpoch,
  advanceBlock,
  createConstructorArgs,
  advanceBlocks,
  setCode,
}