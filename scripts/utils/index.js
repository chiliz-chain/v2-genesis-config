const fs = require('fs');
const BigNumber = require("bignumber.js");

let chainId;

const switchNetwork = async (web3) => {
  chainId = await web3.eth.getChainId();
  console.log(`current chain id is ${chainId}`)
}

const getLogsOrCache = async (web3, contract, eventName, fromBlock = 0, blocksPerRequest = 0) => {
  let currentBlock = Number(fromBlock);
  let resultLogs = [];
  try {
    if (!fs.existsSync('./cache')) fs.mkdirSync('./cache');
  } catch (e) {
    console.error('failed to create cache folder', e);
  }
  const cacheKey = `./cache/${contract.address}_${eventName}_${chainId}_${fromBlock}.json`;
  try {
    const cache = fs.readFileSync(cacheKey, 'utf8')
    if (cache.length > 0) {
      resultLogs = JSON.parse(cache);
      for (const item of resultLogs) {
        if (item && item.blockNumber > currentBlock) {
          // gap 1 block to not re-download latest block
          currentBlock = item.blockNumber + 1;
        }
      }
    }
  } catch (e) {
    console.warn(`failed to read cache: ${e}`);
    console.log(`downloading logs...`)
  }
  const latestKnownBlock = Number(await web3.eth.getBlockNumber()),
    totalDownload = latestKnownBlock - fromBlock;
  do {
    let toBlock = latestKnownBlock;
    if (blocksPerRequest > 0) {
      toBlock = currentBlock + blocksPerRequest;
      if (toBlock >= latestKnownBlock) {
        toBlock = latestKnownBlock;
      }
    }
    const logs = await contract.getPastEvents(eventName, {
      fromBlock: currentBlock,
      toBlock: toBlock,
    });
    resultLogs.push(...logs);
    if (currentBlock >= latestKnownBlock) {
      break;
    }
    currentBlock = toBlock + 1;
    const pc = `${(100 * (currentBlock - fromBlock) / totalDownload).toFixed(0)}%`;
    process.stdout.write(`${pc}${'\b'.repeat(pc.length)}`);
  } while (true);
  fs.writeFileSync(cacheKey, JSON.stringify(resultLogs, null, 2))
  return resultLogs;
};

const parseLog = (log) => {
  const epoch = Math.floor(Number(log.blockNumber) / getEpochDuration());
  const validator = log.returnValues.validator.toLowerCase();

  return {
    epoch,
    validator
  }
}


const getEpochDuration = () => {
  if (chainId === 88880) { // if testnet
    return 1200;
  } else {
    return 28800;
  }
}

const sumLogs = (logs) => {
  return logs.reduce((sum, v) => sum.plus(v.returnValues.amount), new BigNumber(0));
}

const format = (big) => new BigNumber(big).dividedBy(10**18).toString(10);

module.exports = {
  getLogsOrCache,
  format,
  sumLogs,
  parseLog,
  switchNetwork,
  getEpochDuration,
}