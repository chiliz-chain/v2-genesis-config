/** @var artifacts {Array} */
/** @var web3 {Web3} */
/** @function contract */
/** @function it */
/** @function before */
/** @var assert */

const {newMockContract, waitForNextEpoch} = require("./helper");

contract("StakingPool", async (accounts) => {
  const [owner, staker1, staker2, validator1, validator2] = accounts
  it("empty delegator claim should work", async () => {
    const {parlia} = await newMockContract(owner, {epochBlockInterval: '50'})
    await parlia.addValidator(validator1);
    await parlia.claimDelegatorFee(validator1, {from: staker1});
  })
  it("staker can do simple delegation", async () => {
    const {parlia, stakingPool} = await newMockContract(owner, {epochBlockInterval: '50'})
    await parlia.addValidator(validator1);
    let res = await stakingPool.stake(validator1, {from: staker1, value: '1000000000000000000'}); // 1.0
    assert.equal(res.logs[0].args.validator, validator1);
    assert.equal(res.logs[0].args.staker, staker1);
    assert.equal(res.logs[0].args.amount.toString(), '1000000000000000000');
    res = await stakingPool.stake(validator1, {from: staker1, value: '1000000000000000000'}); // 1.0
    assert.equal(res.logs[0].args.validator, validator1);
    assert.equal(res.logs[0].args.staker, staker1);
    assert.equal(res.logs[0].args.amount.toString(), '1000000000000000000');
    res = await stakingPool.stake(validator1, {from: staker2, value: '1000000000000000000'});
    assert.equal(res.logs[0].args.validator, validator1);
    assert.equal(res.logs[0].args.staker, staker2);
    assert.equal(res.logs[0].args.amount.toString(), '1000000000000000000');
    assert.equal((await stakingPool.getStakedAmount(validator1, staker1)).toString(10), '2000000000000000000');
    assert.equal((await stakingPool.getStakedAmount(validator1, staker2)).toString(10), '1000000000000000000');
  })
  it("staker can claim his rewards", async () => {
    const {parlia, stakingPool} = await newMockContract(owner, {epochBlockInterval: '10'})
    await parlia.addValidator(validator1);
    await stakingPool.stake(validator1, {from: staker1, value: '50000000000000000000'}); // 50.0
    assert.equal((await stakingPool.getStakedAmount(validator1, staker1)).toString(), '50000000000000000000');
    await waitForNextEpoch(parlia);
    await parlia.deposit(validator1, {value: '1010000000000000000'}); // 10.1
    await waitForNextEpoch(parlia);
    // console.log(`Validator Pool: ${JSON.stringify(await stakingPool.getValidatorPool(validator1), null, 2)}`)
    // console.log(`Ratio: ${(await stakingPool.getRatio(validator1)).toString()}`)
    assert.equal((await stakingPool.getStakedAmount(validator1, staker1)).toString(), '51009999999999999964');
    let res = await stakingPool.unstake(validator1, '50000000000000000000', {from: staker1});
    assert.equal(res.logs[0].args.validator, validator1)
    assert.equal(res.logs[0].args.staker, staker1)
    assert.equal(res.logs[0].args.amount.toString(), '50000000000000000000')
    await stakingPool.getValidatorPool(validator1);
    await waitForNextEpoch(parlia);
    res = await stakingPool.claim(validator1, {from: staker1});
    assert.equal(res.logs[0].args.validator, validator1)
    assert.equal(res.logs[0].args.staker, staker1)
    assert.equal(res.logs[0].args.amount.toString(), '50000000000000000000')
    // console.log(`Validator Pool: ${JSON.stringify(await stakingPool.getValidatorPool(validator1), null, 2)}`)
    // console.log(`Ratio: ${(await stakingPool.getRatio(validator1)).toString()}`)
    // rest can't be claimed due to rounding problem (now can, because we increased the precision)
    assert.equal((await stakingPool.getStakedAmount(validator1, staker1)).toString(), '1009999999999999999');
  })
  // it("make sure gas race is not possible for different validators", async () => {
  //   const {parlia, stakingPool} = await newMockContract(owner, {epochBlockInterval: '10'})
  //   await parlia.addValidator(validator1);
  //   await parlia.addValidator(validator2);
  //   await stakingPool.stake(validator1, {from: staker1, value: '1000000000000000000'}); // 1.0
  //   await stakingPool.stake(validator2, {from: staker2, value: '1000000000000000000'}); // 1.0
  //   await waitForNextEpoch(parlia);
  //   await stakingPool.unstake(validator1, '1000000000000000000', {from: staker1, gas: 1_000_000}); // 1.0
  //   await stakingPool.unstake(validator2, '1000000000000000000', {from: staker2, gas: 292_000}); // 1.0
  //   await waitForNextEpoch(parlia);
  //   await stakingPool.claim(validator2, {from: staker2}); // staker2 claims before staker1
  //   await stakingPool.claim(validator1, {from: staker1});
  // })
  // it("its possible to do manually undelegate claim", async () => {
  //   const {parlia, stakingPool} = await newMockContract(owner, {epochBlockInterval: '10'})
  //   await parlia.addValidator(validator1);
  //   await parlia.addValidator(validator2);
  //   await stakingPool.stake(validator1, {from: staker1, value: '1000000000000000000'}); // 1.0
  //   await stakingPool.stake(validator2, {from: staker2, value: '1000000000000000000'}); // 1.0
  //   await waitForNextEpoch(parlia);
  //   await stakingPool.unstake(validator1, '1000000000000000000', {from: staker1, gas: 1_000_000}); // 1.0
  //   await stakingPool.unstake(validator2, '1000000000000000000', {from: staker2, gas: 292_000}); // 1.0
  //   await waitForNextEpoch(parlia);
  //   await stakingPool.manuallyClaimPendingUndelegates([validator1]);
  //   assert.equal('1000000000000000000', await web3.eth.getBalance(stakingPool.address));
  //   await stakingPool.manuallyClaimPendingUndelegates([validator2]);
  //   assert.equal('2000000000000000000', await web3.eth.getBalance(stakingPool.address));
  // })
});
