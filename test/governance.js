/** @var artifacts {Array} */
/** @var web3 {Web3} */
/** @function contract */
/** @function it */
/** @function before */
/** @var assert */

const {fromRpcSig} = require('ethereumjs-util');
const ethSigUtil = require('eth-sig-util');
const Wallet = require('ethereumjs-wallet').default;

const {newMockContract, waitForNextEpoch, expectError} = require('./helper')

const createTypedSignature = async (governance, voterBySig, message) => {
  const EIP712Domain = [
    {name: 'name', type: 'string'},
    {name: 'version', type: 'string'},
    {name: 'chainId', type: 'uint256'},
    {name: 'verifyingContract', type: 'address'},
  ];
  const chainId = await web3.eth.getChainId();
  return fromRpcSig(ethSigUtil.signTypedMessage(voterBySig.getPrivateKey(), {
    data: {
      types: {
        EIP712Domain,
        Ballot: [
          {name: 'proposalId', type: 'uint256'},
          {name: 'support', type: 'uint8'},
        ],
      },
      domain: {
        name: await governance.name(),
        version: await governance.version(),
        chainId: chainId,
        verifyingContract: governance.address
      },
      primaryType: 'Ballot',
      message,
    },
  }));
};

contract("Governance", async (accounts) => {
  const [owner, validator1, validator2, owner1, owner2, validator3, validator4, proposer] = accounts;
  it("voting power is well distributed for validators with different owners", async () => {
    const {parlia, governance} = await newMockContract(owner, {
      genesisValidators: [validator1, validator2],
    });
    await parlia.delegate(validator1, {value: '1000000000000000000', from: owner});
    await parlia.delegate(validator2, {value: '1000000000000000000', from: owner});
    await waitForNextEpoch(parlia);
    // let's check voting supply and voting powers for validators
    let votingSupply = await governance.getVotingSupply();
    assert.equal(votingSupply.toString(), '2000000000000000000');
    assert.equal((await governance.getVotingPower(validator1)).toString(), '1000000000000000000');
    assert.equal((await governance.getVotingPower(validator2)).toString(), '1000000000000000000');
    // now lets change validator owner
    await parlia.changeValidatorOwner(validator1, owner1, {from: validator1});
    await parlia.changeValidatorOwner(validator2, owner2, {from: validator2});
    // let's re-check voting supply and voting powers for validators, it should be the same
    votingSupply = await governance.getVotingSupply();
    assert.equal(votingSupply.toString(), '2000000000000000000');
    assert.equal((await governance.getVotingPower(owner1)).toString(), '1000000000000000000');
    assert.equal((await governance.getVotingPower(owner2)).toString(), '1000000000000000000');
  });
  it("its impossible to abuse voting processing using owner switching", async () => {
    const {parlia, governance} = await newMockContract(owner, {
      genesisValidators: [validator1, validator2], votingPeriod: '5',
    });
    await parlia.delegate(validator1, {value: '1000000000000000000', from: owner}); // 50%
    await parlia.delegate(validator2, {value: '2000000000000000000', from: owner}); // 50%
    await waitForNextEpoch(parlia);
    // an example of malicious proposal
    const res1 = await governance.propose([owner], ['0'], ['0x'], 'empty proposal', {from: validator1});
    assert.equal(res1.logs[0].event, 'ProposalCreated');
    const {proposalId} = res1.logs[0].args;
    // validator 1 votes for the proposal and proposal is still active
    await governance.castVote(proposalId, '1', {from: validator1});
    assert.equal(await governance.state(proposalId), '1')
    // now let change validator owner and vote again, state should be active
    await parlia.changeValidatorOwner(validator1, owner1, {from: validator1});
    await expectError(governance.castVote(proposalId, '1', {from: owner1}), 'GovernorVotingSimple: vote already cast')
    await waitForNextEpoch(parlia);
    // state must be defeated
    assert.equal(await governance.state(proposalId), '3')
  });
  it('vote with signature', async function () {
    // TODO: "this test fails on ganache due to chainid() problem"
    {
      const testChainNumber = await artifacts.require('TestChainNumber').new();
      const evmChainId = await testChainNumber.getChainId(),
        localChainId = await web3.eth.getChainId();
      if (evmChainId !== localChainId) {
        console.warn(`This unit test can't be run due to EVM chain id difference`)
        return;
      }
    }
    const {parlia, governance} = await newMockContract(owner, {
      genesisValidators: [
        validator1,
      ],
      votingPeriod: '5',
    });
    await parlia.delegate(validator1, {value: '1000000000000000000', from: owner});
    await waitForNextEpoch(parlia);
    const voterBySig = Wallet.fromPrivateKey(Buffer.from('0000000000000000000000000000000000000000000000000000000000000001', 'hex'));
    // an example of malicious proposal
    const res1 = await governance.propose([owner], ['0'], ['0x'], 'empty proposal', {from: validator1});
    const {proposalId} = res1.logs[0].args;
    // it's possible to vote using signature
    const sig = await createTypedSignature(governance, voterBySig, {
      proposalId, support: '1',
    });
    const res2 = await governance.castVoteBySig(proposalId, '1', sig.v, sig.r, sig.s);
    assert.equal(res2.logs[0].event, 'VoteCast');
    assert.equal(res2.logs[0].args.voter.toLowerCase(), voterBySig.getAddressString().toLowerCase());
  });
  it("anyone in proposer registry + active main validator owners can propose", async () => {
    const validators = [validator1, validator2, validator3, validator4];
    const {parlia, governance} = await newMockContract(owner, {
      genesisValidators: validators, votingPeriod: '5',
    });
    await governance.activateProposerRegistry();
    for (let i = 0; i < validators.length; i++) {
      await parlia.delegate(validators[i], {value: `${4-i}000000000000000000`, from: owner});
    }
    await governance.addProposer(proposer);
    await waitForNextEpoch(parlia);
    
    // all active main validators should be able to propose
    const mainValidators = validators.slice(0, 3);
    for (let i = 0; i < mainValidators.length; i++) {
      const res = await governance.propose([owner], ['0'], ['0x'], `test proposal ${i}`, {from: mainValidators[i]});
      assert.equal(res.logs[0].event, 'ProposalCreated');  
    }
    
    // candidate can't propose
    const candidateValidator = validators[validators.length-1];
    await expectError(governance.propose([owner], ['0'], ['0x'], 'test proposal 4', {from: candidateValidator}), "Governance: only proposer or active main validator owner");

    // proposer should be able to propose
    const res4 = await governance.propose([owner], ['0'], ['0x'], 'test proposal 5', {from: proposer});
    assert.equal(res4.logs[0].event, 'ProposalCreated');
    
    // an arbitrary account can't propose
    await expectError(governance.propose([owner], ['0'], ['0x'], 'test proposal 6', {from: owner}), "Governance: only proposer or active main validator owner");

    // active validator's new owner should be able to propose
    await parlia.changeValidatorOwner(validator1, owner1, {from: validator1});
    await parlia.changeValidatorOwner(validator1, owner2, {from: owner1}); // change twice because validator1 is already in registry
    const res5 = await governance.propose([owner], ['0'], ['0x'], 'test proposal 7', {from: owner2});
    assert.equal(res5.logs[0].event, 'ProposalCreated');
    // old owner of the same validator shouldn't be able to propose
    await expectError(governance.propose([owner], ['0'], ['0x'], 'test proposal 8', {from: owner1}), "Governance: only proposer or active main validator owner");
  });
});
