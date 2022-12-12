// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";

import "./Injector.sol";

contract Governance is InjectorContextHolder, GovernorCountingSimpleUpgradeable, GovernorSettingsUpgradeable, IGovernance {

    event ProposerAdded(address proposer);
    event ProposerRemoved(address proposer);

    uint256 internal _instantVotingPeriod;
    mapping(address => bool) internal _proposerRegistry;
    bool internal _registryActivated;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) {
    }

    function ctor(uint256 newVotingPeriod) external onlyInitializing {
        __Governor_init("Chiliz Governance");
        __GovernorSettings_init(0, 1, 0);
        _setVotingPeriod(newVotingPeriod);
    }

    function getVotingSupply() external view returns (uint256) {
        return _votingSupply(block.number);
    }

    function getVotingPower(address validator) external view returns (uint256) {
        return _validatorOwnerVotingPowerAt(validator, block.number);
    }

    function proposeWithCustomVotingPeriod(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        uint256 customVotingPeriod
    ) public virtual onlyProposer returns (uint256) {
        _instantVotingPeriod = customVotingPeriod;
        uint256 proposalId = propose(targets, values, calldatas, description);
        _instantVotingPeriod = 0;
        return proposalId;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override onlyProposer returns (uint256) {
        return GovernorUpgradeable.propose(targets, values, calldatas, description);
    }

    function addProposer(address proposer) external onlyFromGovernance {
        _addProposer(proposer);
    }

    function _addProposer(address proposer) internal {
        require(!isProposer(proposer), "Governance: proposer already exist");
        _proposerRegistry[proposer] = true;
        emit ProposerAdded(proposer);
    }

    function removeProposer(address proposer) external onlyFromGovernance {
        require(isProposer(proposer), "Governance: proposer not found");
        _proposerRegistry[proposer] = false;
        emit ProposerRemoved(proposer);
    }

    modifier onlyProposer() {
        if (!_registryActivated) {
            require(_stakingContract.isValidatorActive(_stakingContract.getValidatorByOwner(msg.sender)), "Governance: only validator owner");
        } else {
            require(isProposer(msg.sender), "Governance: only proposer");
        }
        _;
    }

    function activateProposerRegistry() external onlyFromGovernance {
        require(!_registryActivated, "Governance: registry already activated");
        address[] memory currentValidatorSet = _stakingContract.getValidators();
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            (address ownerAddress, uint8 status,,,,,,,) = _stakingContract.getValidatorStatus(currentValidatorSet[i]);
            if (status == uint8(1)) {
                _addProposer(ownerAddress);
            }
        }
        _registryActivated = true;
    }

    function isRegistryActivated() public view returns (bool) {
        return _registryActivated;
    }

    function isProposer(address account) public view returns (bool) {
        return _proposerRegistry[account];
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override onlyProposer returns (uint256) {
        return GovernorUpgradeable.execute(targets, values, calldatas, descriptionHash);
    }

    function votingPeriod() public view override(IGovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        // let use re-defined voting period for the proposals
        if (_instantVotingPeriod != 0) {
            return _instantVotingPeriod;
        }
        return GovernorSettingsUpgradeable.votingPeriod();
    }

    function _getVotes(address account, uint256 blockNumber, bytes memory /*params*/) internal view virtual override returns (uint256) {
        return _validatorOwnerVotingPowerAt(account, blockNumber);
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override(GovernorUpgradeable, GovernorCountingSimpleUpgradeable) {
        address validatorAddress = _stakingContract.getValidatorByOwner(account);
        return super._countVote(proposalId, validatorAddress, support, weight, params);
    }

    function _validatorOwnerVotingPowerAt(address validatorOwner, uint256 blockNumber) internal view returns (uint256) {
        address validator = _stakingContract.getValidatorByOwner(validatorOwner);
        return _validatorVotingPowerAt(validator, blockNumber);
    }

    function _validatorVotingPowerAt(address validator, uint256 blockNumber) internal view returns (uint256) {
        // only active validators power makes sense
        if (!_stakingContract.isValidatorActive(validator)) {
            return 0;
        }
        // find validator votes at block number
        uint64 epoch = uint64(blockNumber / _chainConfigContract.getEpochBlockInterval());
        (,,uint256 totalDelegated,,,,,,) = _stakingContract.getValidatorStatusAtEpoch(validator, epoch);
        // use total delegated amount is a voting power
        return totalDelegated;
    }

    function _votingSupply(uint256 blockNumber) internal view returns (uint256 votingSupply) {
        address[] memory validators = _stakingContract.getValidators();
        for (uint256 i = 0; i < validators.length; i++) {
            votingSupply += _validatorVotingPowerAt(validators[i], blockNumber);
        }
        return votingSupply;
    }

    function quorum(uint256 blockNumber) public view override returns (uint256) {
        uint256 votingSupply = _votingSupply(blockNumber);
        return votingSupply * 2 / 3;
    }

    function votingDelay() public view override(IGovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.votingDelay();
    }

    function proposalThreshold() public view virtual override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return GovernorSettingsUpgradeable.proposalThreshold();
    }

    function _hashTypedDataV4(bytes32 structHash) internal view override returns (bytes32) {
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes(name()));
        bytes32 versionHash = keccak256(bytes(version()));
        bytes32 domainSeparator = keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
        return ECDSAUpgradeable.toTypedDataHash(domainSeparator, structHash);
    }
}