const {getLogsOrCache, switchNetwork, getEpochDuration, parseLog, format, sumLogs} = require("./utils");
const { Web3 } = require("web3");
const BigNumber = require("bignumber.js");

/**
 * Envs:
 * RPC - rpc for block fetch using latest web3 version
 * VOTING_DURATION - duration of voting
 */

const BLOCK_LIMIT = 30_000_000;
const DETAILED = true;

const Staking = artifacts.require("Staking");
const StakingPool = artifacts.require("StakingPool");
const Governance = artifacts.require('Governance');

const StakingAddress = '0x0000000000000000000000000000000000001000';

const web3Secondary = new Web3(process.env.RPC || web3._provider.host);

const getBrokenEpochs = async () => {
  const staking = await Staking.at(StakingAddress);

  const validatorAddedLogs = await getLogsOrCache(web3, staking, 'ValidatorAdded', 0, BLOCK_LIMIT);
  const validatorSet = new Map();
  validatorAddedLogs.forEach((v) => {
    validatorSet.set(v.returnValues.validator.toLowerCase(), {})
  })
  console.log(`${validatorAddedLogs.length} validators presented`, );
  // states by epoch
  const LATEST_BLOCK = Number(await web3.eth.getBlockNumber());
  const CURRENT_EPOCH = Math.floor(LATEST_BLOCK / getEpochDuration());
  console.log('current epoch', CURRENT_EPOCH);

  // fill data
  for (let epoch = 0; epoch <= CURRENT_EPOCH + 1; epoch++) {
    for (const [_, v] of validatorSet.entries()) {
      v[epoch] = { status: null, delegations: [], undelegations: [], claims: [] }
    }
  }

  // add initial delegation
  for (const validatorAdded of validatorAddedLogs) {
    let tx;

    tx = await web3.eth.getTransaction(validatorAdded.transactionHash);
    if (!tx) {
      console.warn(`tx ${validatorAdded.transactionHash} not found, but exist in block ${validatorAdded.blockNumber}; fetching tx directly from block...`);
      const block = await web3Secondary.eth.getBlock(validatorAdded.blockNumber, true);
      tx = block.transactions.find(tx => tx.hash === validatorAdded.transactionHash);
    }

    if (!tx) throw new Error(`there is no tx: ${validatorAdded.transactionHash}`);

    const validator = validatorAdded.returnValues.validator.toLowerCase();
    const data = validatorSet.get(validator);
    if (!data) continue;

    const sig = tx.input.substring(0, 10);
    if (sig === '0xe1c7392a') {
      // console.log(` # - genesis amount=10000000 txHash=${validatorAdded.transactionHash}`);
      // mock delegation
      data[0].delegations.push(
        {
          "address": "0x0000000000000000000000000000000000001000",
          "data": tx.input,
          "blockNumber": tx.blockNumber,
          "transactionHash": tx.hash,
          "transactionIndex": tx.transactionIndex,
          "blockHash": tx.blockHash,
          "returnValues": {
            "validator": validator,
            "amount": '10000000000000000000000000',
          },
          "event": "Mock",
        });
    } else if (sig === '0x61cadbf4') {
      // console.log(` # - register-validator amount=${tx.value} txHash=${validatorAdded.transactionHash}`);
      const epoch = Math.floor(Number(tx.blockNumber) / getEpochDuration());
      data[epoch + 1].delegations.push(
        {
          "address": "0x0000000000000000000000000000000000001000",
          "data": tx.input,
          "blockNumber": tx.blockNumber,
          "transactionHash": tx.hash,
          "transactionIndex": tx.transactionIndex,
          "blockHash": tx.blockHash,
          "returnValues": {
            "validator": validator,
            "amount": tx.value,
          },
          "event": "Mock",
        });
    } else if (sig === '0x4d238c8e') {
      // console.log(` # - add-validator amount=${tx.value} validator=${validator} txHash=${validatorAdded.transactionHash}`);
    } else {
      throw new Error(`unknown sig: ${sig}`)
    }
  }

  const stakingDelegates = await getLogsOrCache(web3, staking, 'Delegated', 0, BLOCK_LIMIT);

  for (const delegation of stakingDelegates) {
    const { epoch, validator } = parseLog(delegation);
    const v = validatorSet.get(validator);
    if (!v) continue;
    v[epoch + 1].delegations.push(delegation);
  }

  const stakingUndelegates = await getLogsOrCache(web3, staking, 'Undelegated', 0, BLOCK_LIMIT);
  for (const undelegation of stakingUndelegates) {
    const { epoch, validator } = parseLog(undelegation);
    const v = validatorSet.get(validator);
    if (!v) continue;
    v[epoch + 1].undelegations.push(undelegation);
  }

  const stakingClaims = (await getLogsOrCache(web3, staking, 'Claimed', 0, BLOCK_LIMIT))
  for (const claim of stakingClaims) {
    const { epoch, validator } = parseLog(claim);
    const v = validatorSet.get(validator);
    if (!v) continue;
    v[epoch].claims.push(claim);
  }

  // get changed epochs
  for (const [vldr, v] of validatorSet.entries()) {
    for (const [epoch, data] of Object.entries(v)) {
      if (data.delegations.length > 0 || data.undelegations.length > 0) {
        data.status = await staking.getValidatorStatusAtEpoch(vldr, epoch);
      }
    }
  }

  const result = [];

  console.log(`analyzing...`)
  for (const [vldr, v] of validatorSet.entries()) {
    let totalDelegated = new BigNumber('0');
    let totalUndelegated = new BigNumber('0');

    for (const [epoch, data] of Object.entries(v)) {

      const delegated = sumLogs(data.delegations);
      const undelegated = sumLogs(data.undelegations);
      const claimed = sumLogs(data.claims);

      // do not log if no un/delegations
      if (delegated.eq('0') && undelegated.eq('0')) continue;

      totalDelegated = totalDelegated.plus(delegated);
      totalUndelegated = totalUndelegated.plus(undelegated);
      const expectedTotalDelegated = totalDelegated.minus(totalUndelegated);


      if (new BigNumber(data.status.totalDelegated).eq(expectedTotalDelegated)) {
        continue;
      } else {
        DETAILED && console.log('\ntotal delegated from status not eq to (delegated-undelegated) ↓↓↓')
      }

      result.push({
        data: staking.contract.methods.fixValidatorEpoch(vldr, expectedTotalDelegated.dividedBy(10**10).toFixed(0), epoch).encodeABI(),
        validatorAddress: vldr,
        totalDelegated: expectedTotalDelegated.toString(10),
        epoch: epoch,
      })

      if (DETAILED) {
        console.log(`* validator: ${vldr}, epoch: ${epoch}`);
        console.log(`\t~ total delegated from status ${format(data.status.totalDelegated)}`)
        // console.log(JSON.stringify(data.status, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));
        console.log('');
        console.log(`\t- delegated sum ${format(totalDelegated)}`);
        console.log(`\t- undelegated sum ${format(totalUndelegated)}`);
        console.log(`\t- EXPECTED TOTAL DELEGATED: ${format(expectedTotalDelegated)}`);
        console.log('');
        console.log(`\t= delegated in epoch: ${format(delegated)}`);
        console.log(`\t= undelegated in epoch: ${format(undelegated)}`);
        console.log(`\t= claimed in epoch: ${format(claimed)}`);
        console.log('')
      }


      // if (DETAILED) {
      //   console.log('\t# DELEGATIONS:')
      //   data.delegations.forEach((v) => {
      //     console.log(`\t\t## staker=${v.returnValues.staker} amount=${format(v.returnValues.amount)} epoch=${v.returnValues.epoch} validator=${v.returnValues.validator}`);
      //   })
      //   console.log(`\t# UNDELEGATIONS:`)
      //   data.undelegations.forEach((v) => {
      //     console.log(`\t\t## staker=${v.returnValues.staker} amount=${format(v.returnValues.amount)} epoch=${v.returnValues.epoch} validator=${v.returnValues.validator}`);
      //   })
      // }
      // console.log('')
    }
  }
  return result;
}

const proposeFixies = async (fixies) => {
  const governance = await Governance.at('0x0000000000000000000000000000000000007002');

  console.log(`to fix ${fixies.length} epochs`);
  if (fixies.length === 0) {
    throw Error('no epochs to fix');
  }

  const targets = new Array(fixies.length).fill(StakingAddress);
  const values = new Array(fixies.length).fill('0x00');
  const calldatas = fixies.map((v) => v.data);

  // console.log('calldata', calldatas);


  const input = governance.contract.methods.proposeWithCustomVotingPeriod(targets, values, calldatas, 'Fix validators epochs', process.env.VOTING_DURATION || '500').encodeABI();

  console.log('input data for proposal:', input)
}

module.exports = async function(callback) {
  try {
    await switchNetwork(web3);
    const epochs = await getBrokenEpochs();
    await proposeFixies(epochs);
  } catch (e) {
    console.error(e);
  } finally {
    callback();
  }
}