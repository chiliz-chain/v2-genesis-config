// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";

import "./Injector.sol";

contract Governance is InjectorContextHolder, GovernorCountingSimple, GovernorSettings, IGovernance {

    event ProposerAdded(address proposer);
    event ProposerRemoved(address proposer);

    uint256 internal _instantVotingPeriod;
    mapping(address => bool) internal _proposerRegistry;
    bool internal _registryActivated;

    constructor(bytes memory constructorParams) InjectorContextHolder(constructorParams) Governor("Chiliz Governance") GovernorSettings(0, 1, 0) {
    }

    function ctor(uint256 newVotingPeriod) external whenNotInitialized {
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
        return Governor.propose(targets, values, calldatas, description);
    }

    modifier onlyFromProposerOrGovernance() {
        require(_proposerRegistry[msg.sender] || msg.sender == address(_governanceContract), "Governance: only proposer or governance");
        _;
    }

    function addProposer(address proposer) external onlyFromProposerOrGovernance {
        _addProposer(proposer);
    }

    function _addProposer(address proposer) internal {
        require(!_proposerRegistry[proposer], "Governance: proposer already exist");
        _proposerRegistry[proposer] = true;
        emit ProposerAdded(proposer);
    }

    function removeProposer(address proposer) external onlyFromProposerOrGovernance {
        require(_proposerRegistry[proposer], "Governance: proposer not found");
        _proposerRegistry[proposer] = false;
        emit ProposerAdded(proposer);
    }

    modifier onlyProposer(address account) {
        if (!_registryActivated) {
            address validatorAddress = _stakingContract.getValidatorByOwner(account);
            require(_stakingContract.isValidatorActive(validatorAddress), "Governance: only validator owner");
        } else {
            require(_proposerRegistry[account], "Governance: only proposer");
        }
        _;
    }

    function activateProposerRegistry() external onlyFromGovernance {
        require(!_registryActivated, "Governance: registry already activated");
        address[] memory currentValidatorSet = _stakingContract.getValidators();
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            _addProposer(currentValidatorSet[i]);
        }
        _registryActivated = true;
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual override onlyProposer(msg.sender) returns (uint256) {
        return Governor.execute(targets, values, calldatas, descriptionHash);
    }

    function votingPeriod() public view override(IGovernor, GovernorSettings) returns (uint256) {
        // let use re-defined voting period for the proposals
        if (_instantVotingPeriod != 0) {
            return _instantVotingPeriod;
        }
        return GovernorSettings.votingPeriod();
    }

    function _getVotes(address account, uint256 blockNumber, bytes memory /*params*/) internal view virtual override returns (uint256) {
        return _validatorOwnerVotingPowerAt(account, blockNumber);
    }

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory params) internal virtual override(Governor, GovernorCountingSimple) {
        address validatorAddress = _stakingContract.getValidatorByOwner(account);
        return super._countVote(proposalId, validatorAddress, support, weight, params);
    }

    function _validatorOwnerVotingPowerAt(address validatorOwner, uint256 blockNumber) internal view returns (uint256) {
        address validator = _stakingContract.getValidatorByOwner(validatorOwner);
        // only active validators power makes sense
        if (!_stakingContract.isValidatorActive(validator)) {
            return 0;
        }
        return _validatorVotingPowerAt(validator, blockNumber);
    }

    function _validatorVotingPowerAt(address validator, uint256 blockNumber) internal view returns (uint256) {
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

    function votingDelay() public view override(IGovernor, GovernorSettings) returns (uint256) {
        return GovernorSettings.votingDelay();
    }

    function proposalThreshold() public view virtual override(Governor, GovernorSettings) returns (uint256) {
        return GovernorSettings.proposalThreshold();
    }

    function _hashTypedDataV4(bytes32 structHash) internal view override returns (bytes32) {
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 nameHash = keccak256(bytes(name()));
        bytes32 versionHash = keccak256(bytes(version()));
        bytes32 domainSeparator = keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
        return ECDSA.toTypedDataHash(domainSeparator, structHash);
    }
}