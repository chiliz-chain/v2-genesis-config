/** @var artifacts {Array} */
/** @var web3 {Web3} */
/** @function contract */
/** @function it */
/** @function before */
/** @var assert */

const {newMockContract, expectError} = require('./helper')
const BigNumber = require('bignumber.js');

contract.only("Tokenomics", async (accounts) => {
  const [owner, validator] = accounts;
  let Tokenomics;

  beforeEach(async () => {
    const {tokenomics} = await newMockContract(owner, {genesisValidators: [validator]});
    Tokenomics = tokenomics;
  })

  it("is initialized with correct values", async () => {
    const state = await Tokenomics.getState();
    assert.equal(state.shareStaking, '6500');
    assert.equal(state.shareSystem, '3500');
    assert.equal(state.totalSupply, '8888888888000000000000000000');
    assert.equal(state.totalIntroducedSupply, '0')
    assert.equal(state.introducedSupply, '0')
    assert.equal(state.inflationPct, '0')
  })

  it("shares are updated correctly and old state is available", async () => {
    // save current shares for later
    const stateBoforeUpdate = await Tokenomics.getState();
    assert.equal(stateBoforeUpdate.shareStaking, '6500');
    assert.equal(stateBoforeUpdate.shareSystem, '3500');

    // update shares, validate logs & state 
    const newStakingShare = 2400;
    const newSystemShare = 10000 - newStakingShare;
    const updateRes = await Tokenomics.updateShares(newStakingShare, newSystemShare);
    
    assert.equal(updateRes.receipt.status, true);
    assert.equal(updateRes.receipt.logs[0].event, "SharesUpdated");
    assert.equal(updateRes.receipt.logs[0].args.shareStaking, `${newStakingShare}`);
    assert.equal(updateRes.receipt.logs[0].args.shareSystem, `${newSystemShare}`);

    const stateAfterUpdate = await Tokenomics.getState();
    assert.equal(stateAfterUpdate.shareStaking, `${newStakingShare}`);
    assert.equal(stateAfterUpdate.shareSystem, `${newSystemShare}`);

    // make sure old state is still available
    const r = await web3.eth.call(await Tokenomics.getState.request(), updateRes.receipt.blockNumber - 1)
    const oldStateAfterUpdate = web3.eth.abi.decodeParameters([
      {type: "uint256", name: "totalSupply"},
      {type: "uint256", name: "totalIntroducedSupply"},
      {type: "uint256", name: "introducedSupply"},
      {type: "uint256", name: "inflationPct"},
      {type: "uint16", name: "shareStaking"},
      {type: "uint16", name: "shareSystem"}
    ],r);
    assert.equal(oldStateAfterUpdate.shareStaking, stateBoforeUpdate.shareStaking);
    assert.equal(oldStateAfterUpdate.shareSystem, stateBoforeUpdate.shareSystem);

    // share update should fail if shares don't add up to 100
    await expectError(Tokenomics.updateShares(newStakingShare + 1, newSystemShare), 'is');
    await expectError(Tokenomics.updateShares(newStakingShare - 1, newSystemShare), 'is');
  })

  it("deposit works and state is updated correctly", async () => {
    // save current state for later
    const stateBoforeDeposit = await Tokenomics.getState();
    assert.equal(stateBoforeDeposit.inflationPct, '0');
    assert.equal(stateBoforeDeposit.introducedSupply, '0');
    assert.equal(stateBoforeDeposit.totalIntroducedSupply, '0');
    assert.equal(stateBoforeDeposit.totalSupply, '8888888888000000000000000000');

    // deposit and check the values
    const initialTotalSupply = new BigNumber('8888888888000000000000000000');
    const inflationPct = new BigNumber('88000000000000000000');
    const introducedSupply = initialTotalSupply.multipliedBy(inflationPct).dividedBy(new BigNumber('1000000000000000000')).dividedBy(new BigNumber('100')).dividedBy(new BigNumber('10512000')).toFixed(0);
    const newTotalSupply = initialTotalSupply.plus(introducedSupply);

    const depositRes = await Tokenomics.deposit(validator, newTotalSupply, inflationPct, {value: introducedSupply});
    assert.equal(depositRes.receipt.status, true);
    assert.equal(depositRes.receipt.logs[0].event, "Deposit");
    assert.equal(depositRes.receipt.logs[0].args.introducedSupply, introducedSupply.toString());
    assert.equal(depositRes.receipt.logs[0].args.newTotalSupply, newTotalSupply.toFixed());
    assert.equal(depositRes.receipt.logs[0].args.inflationPct, inflationPct.toString());
    assert.equal(depositRes.receipt.logs[0].args.validator, validator.toString());
    assert.isNotNull(depositRes.receipt.logs[0].args.stakingAmount);
    assert.isNotNull(depositRes.receipt.logs[0].args.systemAmount);

    // check state
    const stateAfterDeposit = await Tokenomics.getState();
    assert.equal(stateAfterDeposit.inflationPct, inflationPct.toString());
    assert.equal(stateAfterDeposit.introducedSupply, introducedSupply.toString());
    assert.equal(stateAfterDeposit.totalIntroducedSupply, introducedSupply.toString());
    assert.equal(stateAfterDeposit.totalSupply, newTotalSupply.toFixed());

    // make sure old state is still available
    const r = await web3.eth.call(await Tokenomics.getState.request(), depositRes.receipt.blockNumber - 1)
    const oldStateAfterUpdate = web3.eth.abi.decodeParameters([
      {type: "uint256", name: "totalSupply"},
      {type: "uint256", name: "totalIntroducedSupply"},
      {type: "uint256", name: "introducedSupply"},
      {type: "uint256", name: "inflationPct"},
      {type: "uint16", name: "shareStaking"},
      {type: "uint16", name: "shareSystem"}
    ],r);
    assert.equal(oldStateAfterUpdate.inflationPct, stateBoforeDeposit.inflationPct);
    assert.equal(oldStateAfterUpdate.introducedSupply, stateBoforeDeposit.introducedSupply);
    assert.equal(oldStateAfterUpdate.totalIntroducedSupply, stateBoforeDeposit.totalIntroducedSupply);
    assert.equal(oldStateAfterUpdate.totalSupply, stateBoforeDeposit.totalSupply);

    // deposit should fail for 0 value
    await expectError(Tokenomics.deposit(validator, newTotalSupply, inflationPct, {value: 0}), 'diz');
  })
});