const Staking = artifacts.require("Staking");
const Governance = artifacts.require('Governance');

const STAKING_ADDRESS = '0x0000000000000000000000000000000000001000';
const SLASHING_INDICATOR_ADDRESS = '0x0000000000000000000000000000000000001001';
const SYSTEM_REWARD_ADDRESS = '0x0000000000000000000000000000000000001002';
const STAKING_POOL_ADDRESS = '0x0000000000000000000000000000000000007001';
const GOVERNANCE_ADDRESS = '0x0000000000000000000000000000000000007002';
const CHAIN_CONFIG_ADDRESS = '0x0000000000000000000000000000000000007003';
const RUNTIME_UPGRADE_ADDRESS = '0x0000000000000000000000000000000000007004';
const DEPLOYER_PROXY_ADDRESS = '0x0000000000000000000000000000000000007005';

const proposePause = async () => {
  const staking = await Staking.at(STAKING_ADDRESS);
  const governance = await Governance.at(GOVERNANCE_ADDRESS);

  console.log(`building pause proposal...`);

  const targets = [STAKING_ADDRESS]
  const values = ['0x00']
  const calldatas = [staking.contract.methods.togglePause().encodeABI()]
  console.log(calldatas);
  const input = governance.contract.methods.proposeWithCustomVotingPeriod(targets, values, calldatas, 'Pause delegations and undelegations', process.env.VOTING_DURATION || '50').encodeABI();
  console.log('input data for proposal:', input)
}

module.exports = async function(callback) {
  try {
    await proposePause();
  } catch (e) {
    console.error(e);
  } finally {
    callback();
  }
}