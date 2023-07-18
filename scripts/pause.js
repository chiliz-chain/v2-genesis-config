const Staking = artifacts.require("Staking");
const Governance = artifacts.require('Governance');

const StakingAddress = '0x0000000000000000000000000000000000001000';

const proposePause = async () => {
  const staking = await Staking.at(StakingAddress);
  const governance = await Governance.at('0x0000000000000000000000000000000000007002');

  console.log(`building pause proposal...`);

  const targets = [StakingAddress]
  const values = ['0x00']
  const calldatas = [staking.contract.methods.togglePause().encodeABI()]

  const input = governance.contract.methods.propose(targets, values, calldatas, 'Pause delegations and undelegations').encodeABI();

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