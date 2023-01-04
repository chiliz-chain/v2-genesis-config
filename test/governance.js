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
  const [owner, validator1, validator2, owner1, owner2] = accounts;
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
    await parlia.delegate(validator2, {value: '1000000000000000000', from: owner}); // 50%
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
});
