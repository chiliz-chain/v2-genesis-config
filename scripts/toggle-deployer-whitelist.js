const DeployerProxy = artifacts.require("DeployerProxy");
const Governance = artifacts.require('Governance');

const GOVERNANCE_ADDRESS = '0x0000000000000000000000000000000000007002';
const DEPLOYER_PROXY_ADDRESS = '0x0000000000000000000000000000000000007005';

const generate = async () => {
  const deployerProxy = await DeployerProxy.at(DEPLOYER_PROXY_ADDRESS);
  const governance = await Governance.at(GOVERNANCE_ADDRESS);
  const toggleValue = process.env.VALUE === "true";

  console.log(`building toggle deployer whitelist proposal...`);

  const targets = [DEPLOYER_PROXY_ADDRESS]
  const values = ['0x00']
  const calldatas = [deployerProxy.contract.methods.toggleDeployerWhitelist(toggleValue).encodeABI()]
  console.log(calldatas);
  const input = governance.contract.methods.proposeWithCustomVotingPeriod(targets, values, calldatas, `Toggle deployer whitelist feature ${toggleValue ? "on" : "off"}`, process.env.VOTING_DURATION || '50').encodeABI();
  console.log('input data for proposal:', input)
}

module.exports = async function(callback) {
  try {
    await generate();
  } catch (e) {
    console.error(e);
  } finally {
    callback();
  }
}