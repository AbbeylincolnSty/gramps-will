// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GrampsWill {
    enum Status {
        Active,
        DeathReported,
        Challenged,
        Executable,
        Executed,
        Revoked
    }

    enum AllocationType {
        FixedAmount,
        SpecificAsset
    }

    enum AssetType {
        ETH
    }

    enum VerifierMode {
        Oracle,
        Multisig
    }

    struct Beneficiary {
        address payable beneficiaryAddress;
        bytes32 identifierHash;
        AllocationType allocationType;
        uint256 allocationValue; // Wei for ETH fixed allocation
        bool exists;
    }

    struct Asset {
        AssetType assetType;
        address tokenAddress; // address(0) for ETH
        uint256 amount;
        uint256 distributionRuleId;
    }

    address payable public owner;
    uint256 public lastUpdatedAt;
    Status public status;
    VerifierMode public verifierMode;
    uint256 public totalWillAmountWei;
    bool public paused;

    Asset[] public assets;
    address[] private beneficiaryIndex;

    mapping(address => Beneficiary) public beneficiaries;
    mapping(address => bool) public authorizedVerifiers;
    mapping(address => bool) public activeChallenges;

    uint256 public challengeCount;

    event BeneficiaryAdded(address indexed beneficiary, bytes32 indexed identifierHash, uint256 allocationValue);
    event BeneficiaryChanged(address indexed beneficiary, bytes32 indexed identifierHash, uint256 allocationValue);
    event AssetDeposited(address indexed from, uint256 amount, uint256 indexed distributionRuleId);
    event DeathReported(address indexed reporter);
    event ChallengeRaised(address indexed challenger, string reason);
    event ChallengeCleared(address indexed resolver, address indexed challenger);
    event ExecutionStarted(uint256 timestamp);
    event DistributionCompleted(uint256 totalDistributed);
    event ContractPaused(address indexed by);
    event ContractRevoked(address indexed by);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier notRevoked() {
        require(status != Status.Revoked, "Contract revoked");
        _;
    }

    constructor(
        uint256 _totalWillAmountWei,
        VerifierMode _verifierMode,
        address[] memory _verifiers
    ) payable {
        owner = payable(msg.sender);
        totalWillAmountWei = _totalWillAmountWei;
        verifierMode = _verifierMode;
        status = Status.Active;
        lastUpdatedAt = block.timestamp;

        for (uint256 i = 0; i < _verifiers.length; i++) {
            authorizedVerifiers[_verifiers[i]] = true;
        }

        if (msg.value > 0) {
            _recordEthDeposit(msg.value);
        }
    }

    function addBeneficiary(
        address payable _beneficiaryAddress,
        bytes32 _identifierHash,
        AllocationType _allocationType,
        uint256 _allocationValue
    ) external onlyOwner whenNotPaused notRevoked {
        require(status == Status.Active, "Can only edit in Active state");
        require(_beneficiaryAddress != address(0), "Invalid beneficiary");
        require(!beneficiaries[_beneficiaryAddress].exists, "Beneficiary exists");

        beneficiaries[_beneficiaryAddress] = Beneficiary({
            beneficiaryAddress: _beneficiaryAddress,
            identifierHash: _identifierHash,
            allocationType: _allocationType,
            allocationValue: _allocationValue,
            exists: true
        });
        beneficiaryIndex.push(_beneficiaryAddress);

        _validateTotalFixedAllocations();
        _touch();

        emit BeneficiaryAdded(_beneficiaryAddress, _identifierHash, _allocationValue);
    }

    function updateBeneficiary(
        address payable _beneficiaryAddress,
        bytes32 _identifierHash,
        AllocationType _allocationType,
        uint256 _allocationValue
    ) external onlyOwner whenNotPaused notRevoked {
        require(status == Status.Active, "Can only edit in Active state");
        require(beneficiaries[_beneficiaryAddress].exists, "Unknown beneficiary");

        Beneficiary storage b = beneficiaries[_beneficiaryAddress];
        b.identifierHash = _identifierHash;
        b.allocationType = _allocationType;
        b.allocationValue = _allocationValue;

        _validateTotalFixedAllocations();
        _touch();

        emit BeneficiaryChanged(_beneficiaryAddress, _identifierHash, _allocationValue);
    }

    function depositETH(uint256 distributionRuleId) external payable onlyOwner whenNotPaused notRevoked {
        require(msg.value > 0, "No ETH sent");
        _recordEthDeposit(msg.value);
        _touch();
        emit AssetDeposited(msg.sender, msg.value, distributionRuleId);
    }

    function reportDeath() external whenNotPaused notRevoked {
        require(status == Status.Active, "Invalid state");
        require(_isVerifier(msg.sender), "Not authorized verifier");
        status = Status.DeathReported;
        _touch();
        emit DeathReported(msg.sender);
    }

    function raiseChallenge(string calldata reason) external whenNotPaused notRevoked {
        require(status == Status.DeathReported || status == Status.Executable, "No report to challenge");
        require(!activeChallenges[msg.sender], "Challenge already active");

        activeChallenges[msg.sender] = true;
        challengeCount += 1;
        status = Status.Challenged;
        _touch();

        emit ChallengeRaised(msg.sender, reason);
    }

    function clearChallenge(address challenger) external onlyOwner whenNotPaused notRevoked {
        require(activeChallenges[challenger], "No active challenge");
        activeChallenges[challenger] = false;
        challengeCount -= 1;

        if (challengeCount == 0) {
            status = Status.DeathReported;
        }
        _touch();

        emit ChallengeCleared(msg.sender, challenger);
    }

    function markExecutable() external onlyOwner whenNotPaused notRevoked {
        require(status == Status.DeathReported, "Must be death reported");
        require(challengeCount == 0, "Challenges still active");
        status = Status.Executable;
        _touch();
    }

    function executeDistribution() external onlyOwner whenNotPaused notRevoked {
        require(status == Status.Executable, "Not executable");
        require(address(this).balance > 0, "No ETH to distribute");

        status = Status.Executed;
        _touch();
        emit ExecutionStarted(block.timestamp);

        uint256 totalDistributed;

        for (uint256 i = 0; i < beneficiaryIndex.length; i++) {
            Beneficiary memory b = beneficiaries[beneficiaryIndex[i]];
            if (b.allocationType == AllocationType.FixedAmount && b.allocationValue > 0) {
                require(address(this).balance >= b.allocationValue, "Insufficient balance");
                b.beneficiaryAddress.transfer(b.allocationValue);
                totalDistributed += b.allocationValue;
            }
        }

        emit DistributionCompleted(totalDistributed);
    }

    function pauseContract() external onlyOwner notRevoked {
        paused = true;
        _touch();
        emit ContractPaused(msg.sender);
    }

    function unpauseContract() external onlyOwner notRevoked {
        paused = false;
        _touch();
    }

    function revokeContract() external onlyOwner notRevoked {
        status = Status.Revoked;
        _touch();
        emit ContractRevoked(msg.sender);
    }

    function addVerifier(address verifier) external onlyOwner notRevoked {
        authorizedVerifiers[verifier] = true;
        _touch();
    }

    function removeVerifier(address verifier) external onlyOwner notRevoked {
        authorizedVerifiers[verifier] = false;
        _touch();
    }

    function getBeneficiaries() external view returns (address[] memory) {
        return beneficiaryIndex;
    }

    function _validateTotalFixedAllocations() internal view {
        uint256 totalFixed;
        for (uint256 i = 0; i < beneficiaryIndex.length; i++) {
            Beneficiary memory b = beneficiaries[beneficiaryIndex[i]];
            if (b.allocationType == AllocationType.FixedAmount) {
                totalFixed += b.allocationValue;
            }
        }
        require(totalFixed <= totalWillAmountWei, "Allocations exceed total will amount");
    }

    function _recordEthDeposit(uint256 amount) internal {
        assets.push(
            Asset({
                assetType: AssetType.ETH,
                tokenAddress: address(0),
                amount: amount,
                distributionRuleId: 0
            })
        );
    }

    function _isVerifier(address sender) internal view returns (bool) {
        if (sender == owner) {
            return true;
        }
        if (verifierMode == VerifierMode.Oracle || verifierMode == VerifierMode.Multisig) {
            return authorizedVerifiers[sender];
        }
        return false;
    }

    function _touch() internal {
        lastUpdatedAt = block.timestamp;
    }
}
