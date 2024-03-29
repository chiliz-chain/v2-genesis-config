/** @var artifacts {Array} */
/** @var web3 {Web3} */
/** @function contract */
/** @function it */
/** @function before */
/** @var assert */

const {newMockContract, expectError} = require('./helper')

contract("DeployerProxy", async (accounts) => {
  const [owner] = accounts;
  it("add remove deployer", async () => {
    const {deployer} = await newMockContract(owner);
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), false)
    // add deployer
    const r1 = await deployer.addDeployer('0x0000000000000000000000000000000000000001')
    assert.equal(r1.logs[0].event, 'DeployerAdded')
    assert.equal(r1.logs[0].args.account, '0x0000000000000000000000000000000000000001')
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
    // remove deployer
    const r2 = await deployer.removeDeployer('0x0000000000000000000000000000000000000001')
    assert.equal(r2.logs[0].event, 'DeployerRemoved')
    assert.equal(r2.logs[0].args.account, '0x0000000000000000000000000000000000000001')
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), false)
  });
  it("disable/enable smart contract", async () => {
    const from = '0x0000000000000000000000000000000000000001';
    const {deployer} = await newMockContract(from, {
      genesisDeployers: [from],
    });
    const r1 = await deployer.registerDeployedContract(from, '0x0000000000000000000000000000000000000222');
    assert.equal(r1.logs[0].event, 'ContractDeployed');
    let contract = await deployer.getContractState('0x0000000000000000000000000000000000000222');
    assert.equal(contract.state, '1');
    //disable contract

    const r2 = await deployer.disableContract('0x0000000000000000000000000000000000000222');
    assert.equal(r2.logs[0].event, 'ContractDisabled');
    contract = await deployer.getContractState('0x0000000000000000000000000000000000000222');
    assert.equal(contract.state, '2');

    //enable contract
    const r3 = await deployer.enableContract('0x0000000000000000000000000000000000000222');
    assert.equal(r3.logs[0].event, 'ContractEnabled');
    contract = await deployer.getContractState('0x0000000000000000000000000000000000000222');
    assert.equal(contract.state, '1');
  });
  it("contract deployment is not possible w/o whitelist (WHITELIST ENABLED)", async () => {
    const {deployer} = await newMockContract(owner);
    // try to register w/o whitelist
    await expectError(deployer.registerDeployedContract(owner, '0x0000000000000000000000000000000000000123'), 'Deployer: deployer is not allowed');
    // let owner be a deployer
    await deployer.addDeployer(owner)
    const r1 = await deployer.registerDeployedContract(owner, '0x0000000000000000000000000000000000000123');
    assert.equal(r1.logs[0].event, 'ContractDeployed')
    const contractDeployer = await deployer.getContractState('0x0000000000000000000000000000000000000123');
    assert.equal(contractDeployer.state, '1')
    assert.equal(contractDeployer.impl, '0x0000000000000000000000000000000000000123')
    assert.equal(contractDeployer.deployer, owner)
  })
  it("contract deployment is possible w/o whitelist (WHITELIST DISABLED)", async () => {
    const {deployer} = await newMockContract(owner);
    // sanity check
    assert.equal(await deployer.isDeployer(owner), false);
    assert.equal(await deployer.isDeployerWhitelistEnabled(), true);

    // disable whitelist & try to register
    await deployer.toggleDeployerWhitelist(false);
    assert.equal(await deployer.isDeployerWhitelistEnabled(), false);
    const r1 = await deployer.registerDeployedContract(owner, '0x0000000000000000000000000000000000000123');
    assert.equal(r1.logs[0].event, 'ContractDeployed')
    const contractDeployer = await deployer.getContractState('0x0000000000000000000000000000000000000123');
    assert.equal(contractDeployer.state, '1')
    assert.equal(contractDeployer.impl, '0x0000000000000000000000000000000000000123')
    assert.equal(contractDeployer.deployer, owner)
  })
  it("deployer constructor works", async () => {
    const {deployer} = await newMockContract(owner, {
      genesisDeployers: [
        '0x0000000000000000000000000000000000000001',
        '0x0000000000000000000000000000000000000002',
        '0x0000000000000000000000000000000000000003',
      ],
    });
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000000'), false)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000002'), true)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000003'), true)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000004'), false)
  })
  it("deployer can be banned and unbanned", async () => {
    const test = async (whitelistOff) => {
      const {deployer} = await newMockContract(owner);
      if (whitelistOff) {
        await deployer.toggleDeployerWhitelist(false);
        assert.equal(await deployer.isDeployerWhitelistEnabled(), false);
      }
      await deployer.addDeployer('0x0000000000000000000000000000000000000001');
      assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
      assert.equal(await deployer.isBanned('0x0000000000000000000000000000000000000001'), false)
      await deployer.banDeployer('0x0000000000000000000000000000000000000001');
      assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
      assert.equal(await deployer.isBanned('0x0000000000000000000000000000000000000001'), true)
      await deployer.unbanDeployer('0x0000000000000000000000000000000000000001');
      assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
      assert.equal(await deployer.isBanned('0x0000000000000000000000000000000000000001'), false)
    }

    // test with whitelist on and off
    await test(false);
    await test(true);
  })
  it("deployer can deploy factory and its whitelisted", async () => {
    const TestDeployerFactory = artifacts.require('TestDeployerFactory');
    const {deployer} = await newMockContract(owner);
    await deployer.addDeployer(owner);
    const deployerFactory = await TestDeployerFactory.new();
    await deployer.registerDeployedContract(owner, deployerFactory.address);
    assert.equal(await deployer.isDeployer(owner), true);
    assert.equal(await deployer.isDeployer(deployerFactory.address), true);

    // This should still be true if the whitelist is off
    await deployer.toggleDeployerWhitelist(false);
    assert.equal(await deployer.isDeployerWhitelistEnabled(), false);
    assert.equal(await deployer.isDeployer(owner), true);
    assert.equal(await deployer.isDeployer(deployerFactory.address), true);
  });
  it("enable disable deployer whitelist", async () => {
    const {deployer} = await newMockContract(owner);
    assert.equal(await deployer.isDeployerWhitelistEnabled(), true)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), false)
    // disable whitelist
    const r1 = await deployer.toggleDeployerWhitelist(false)
    assert.equal(r1.logs[0].event, 'DeployerWhitelistEnabled')
    assert.equal(r1.logs[0].args.state, false)
    assert.equal(await deployer.isDeployerWhitelistEnabled(), false)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), true)
    // enable whitelist
    const r2 = await deployer.toggleDeployerWhitelist(true)
    assert.equal(r2.logs[0].event, 'DeployerWhitelistEnabled')
    assert.equal(r2.logs[0].args.state, true)
    assert.equal(await deployer.isDeployerWhitelistEnabled(), true)
    assert.equal(await deployer.isDeployer('0x0000000000000000000000000000000000000001'), false)
  });
});
