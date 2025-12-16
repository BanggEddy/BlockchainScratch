// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- 1. Interfaces & Shared Data ---

interface IShared {
    enum PolicyType { None, ThirdParty, AllRisk }
    enum ClaimStatus { Submitted, InReview, Approved, Rejected, GarageAuthorized, PaidToGarage, PaidToThirdParty }
}

interface IGarage {
    function repairs_request(uint256 claimId, uint256 estimatedCostWei) external returns (uint256 orderId);
}

interface IClaimProcessingDep {
    function decision(uint256 claimId, bool positive, uint256 thirdPartyPayoutWei, uint256 garageCostWei) external;
    function setClaimStatusPaid(uint256 claimId, bool toGarage) external;
    // Getter explicite pour retourner les infos nécessaires
    function getClaimPayoutInfo(uint256 claimId) external view returns (
        address payable claimant,
        IShared.ClaimStatus status,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    );
}

interface IClaimsHandlingDep {
    function thirdPartyAssessment(uint256 claimId, uint256 percentage) external;
    function allRiskAssessment(uint256 claimId, uint256 damage) external;
}

// --- 2. Processing Department ---

contract ClaimProcessingDep is IClaimProcessingDep, IShared {
    struct Customer {
        string name;
        PolicyType policy;
        bool valid;
    }

    struct Claim {
        uint256 id;
        address claimant;
        PolicyType policy;
        uint256 percentageOrDamage;
        ClaimStatus status;
        bool positive;
        uint256 thirdPartyPayoutWei;
        uint256 garageCostWei;
    }

    address public admin;
    IClaimsHandlingDep public handlingDepartment;

    mapping(address => Customer) public customers;
    mapping(uint256 => Claim) public claims;
    uint256 public claimCounter;

    event CustomerAdded(address indexed customer, PolicyType policy);
    event ClaimSubmitted(uint256 indexed claimId, address indexed customer, PolicyType policy);
    event ClaimDecision(uint256 indexed claimId, bool positive, ClaimStatus newStatus);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not authorized");
        _;
    }

    modifier onlyHandlingDep() {
        require(address(handlingDepartment) != address(0), "Handling dep not set");
        require(msg.sender == address(handlingDepartment), "Only handling dep");
        _;
    }

    constructor() {
        admin = msg.sender;
        // On ne demande plus l'adresse ici pour éviter la dépendance circulaire
    }

    function setHandlingDepartment(address handlingDep) external onlyAdmin {
        handlingDepartment = IClaimsHandlingDep(handlingDep);
    }

    function addCustomer(address customer, string calldata name, PolicyType policy) external onlyAdmin {
        customers[customer] = Customer({name: name, policy: policy, valid: true});
        emit CustomerAdded(customer, policy);
    }

    function checkClaimantRights(address claimant) public view returns (bool) {
        Customer memory c = customers[claimant];
        return c.valid && c.policy != PolicyType.None;
    }

    function submitClaim(PolicyType policy) internal returns (uint256 claimId) {
        require(checkClaimantRights(msg.sender), "Invalid or missing policy");
        require(customers[msg.sender].policy == policy, "Policy mismatch");

        claimId = ++claimCounter;
        claims[claimId] = Claim({
            id: claimId,
            claimant: msg.sender,
            policy: policy,
            percentageOrDamage: 0,
            status: ClaimStatus.Submitted,
            positive: false,
            thirdPartyPayoutWei: 0,
            garageCostWei: 0
        });
        emit ClaimSubmitted(claimId, msg.sender, policy);
    }

    function submitThirdPartyForm(uint256 percentage) external {
        uint256 claimId = submitClaim(PolicyType.ThirdParty);
        claims[claimId].percentageOrDamage = percentage;
        claims[claimId].status = ClaimStatus.InReview;
        handlingDepartment.thirdPartyAssessment(claimId, percentage);
    }

    function submitAllRiskForm(uint256 damage) external {
        uint256 claimId = submitClaim(PolicyType.AllRisk);
        claims[claimId].percentageOrDamage = damage;
        claims[claimId].status = ClaimStatus.InReview;
        handlingDepartment.allRiskAssessment(claimId, damage);
    }

    function decision(
        uint256 claimId,
        bool positive,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    ) external override onlyHandlingDep {
        Claim storage claim = claims[claimId];
        require(claim.id != 0, "Unknown claim");

        claim.positive = positive;
        claim.thirdPartyPayoutWei = thirdPartyPayoutWei;
        claim.garageCostWei = garageCostWei;

        if (!positive) {
            claim.status = ClaimStatus.Rejected;
        } else if (claim.policy == PolicyType.ThirdParty) {
            claim.status = ClaimStatus.Approved; // Prêt à être payé au tiers
        } else {
            claim.status = ClaimStatus.GarageAuthorized; // Prêt pour réparation
        }

        emit ClaimDecision(claimId, positive, claim.status);
    }

    // CORRECTION CRITIQUE: Permet de marquer comme payé pour éviter la double dépense
    function setClaimStatusPaid(uint256 claimId, bool toGarage) external override onlyHandlingDep {
        Claim storage claim = claims[claimId];
        require(claim.status == ClaimStatus.Approved || claim.status == ClaimStatus.GarageAuthorized, "Wrong status for payment");
        
        if (toGarage) {
            claim.status = ClaimStatus.PaidToGarage;
        } else {
            claim.status = ClaimStatus.PaidToThirdParty;
        }
    }

    // Helper pour ClaimsHandlingDep pour lire les données sans erreur de tuple
    function getClaimPayoutInfo(uint256 claimId) external view override returns (
        address payable claimant,
        ClaimStatus status,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    ) {
        Claim memory c = claims[claimId];
        return (payable(c.claimant), c.status, c.thirdPartyPayoutWei, c.garageCostWei);
    }
}

// --- 3. Claims Handling Department ---

contract ClaimsHandlingDep is IClaimsHandlingDep, IShared {
    IClaimProcessingDep public processingDep;
    IGarage public garageContract;
    address public admin;

    event ThirdPartyAssessed(uint256 indexed claimId, bool positive, uint256 payoutWei);
    event AllRiskAssessed(uint256 indexed claimId, uint256 garageCostWei);
    event PaidToThirdParty(uint256 indexed claimId, address indexed recipient, uint256 amountWei);
    event PaidToGarage(uint256 indexed claimId, address indexed garage, uint256 amountWei);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not authorized");
        _;
    }

    modifier onlyProcessingDep() {
        require(msg.sender == address(processingDep), "Only processing dep");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function setProcessingDep(address dep) external onlyAdmin {
        processingDep = IClaimProcessingDep(dep);
    }

    function setGarage(address garageAddr) external onlyAdmin {
        garageContract = IGarage(garageAddr);
    }

    receive() external payable {}

    function thirdPartyAssessment(uint256 claimId, uint256 percentage) external override onlyProcessingDep {
        (uint256 payout, bool positive) = _computeThirdPartyPayout(percentage);
        processingDep.decision(claimId, positive, payout, 0);
        emit ThirdPartyAssessed(claimId, positive, payout);
    }

    function allRiskAssessment(uint256 claimId, uint256 damage) external override onlyProcessingDep {
        uint256 cost = _computeGarageCost(damage);
        bool positive = cost > 0;
        
        processingDep.decision(claimId, positive, 0, cost);
        
        // CORRECTION: Notifier le garage si approuvé
        if (positive && address(garageContract) != address(0)) {
            garageContract.repairs_request(claimId, cost);
        }
        
        emit AllRiskAssessed(claimId, cost);
    }

    // Fonction sécurisée contre la double dépense
    function payToTheThird(uint256 claimId) external onlyAdmin {
        (address payable claimant, ClaimStatus status, uint256 payoutWei, ) = processingDep.getClaimPayoutInfo(claimId);
        
        require(status == ClaimStatus.Approved, "Claim not approved or already paid");
        require(payoutWei > 0, "No payout amount");
        require(address(this).balance >= payoutWei, "Insufficient funds");

        // 1. Update State (Effect)
        processingDep.setClaimStatusPaid(claimId, false);

        // 2. Interaction
        (bool sent, ) = claimant.call{value: payoutWei}("");
        require(sent, "Ether transfer failed");

        emit PaidToThirdParty(claimId, claimant, payoutWei);
    }

    function payToGarage(uint256 claimId, address payable garageAddr) external onlyAdmin {
        (, ClaimStatus status, , uint256 garageCostWei) = processingDep.getClaimPayoutInfo(claimId);
        
        require(status == ClaimStatus.GarageAuthorized, "Claim not authorized or already paid");
        require(garageCostWei > 0, "No cost set");
        require(address(this).balance >= garageCostWei, "Insufficient funds");

        // 1. Update State
        processingDep.setClaimStatusPaid(claimId, true);

        // 2. Interaction
        (bool sent, ) = garageAddr.call{value: garageCostWei}("");
        require(sent, "Ether transfer failed");

        emit PaidToGarage(claimId, garageAddr, garageCostWei);
    }

    // --- Helpers ---

    function _computeThirdPartyPayout(uint256 percentage) internal pure returns (uint256 payoutWei, bool positive) {
        if (percentage > 70) {
            return (0, false);
        }
        positive = true;
        if (percentage <= 30) {
            payoutWei = 7 ether; // Warning: 7 ETH is huge for testing, ensure testnet funds
        } else {
            payoutWei = 3 ether;
        }
    }

    function _computeGarageCost(uint256 damage) internal pure returns (uint256 garageCostWei) {
        if (damage <= 30) return 3 ether;
        if (damage <= 60) return 6 ether;
        if (damage <= 80) return 8 ether;
        if (damage <= 100) return 10 ether;
        return 0;
    }
}

// --- 4. Garage ---

contract Garage is IGarage, IShared {
    address public handlingDepartment;

    struct RepairOrder {
        uint256 claimId;
        uint256 estimatedCostWei;
        bool completed;
    }

    mapping(uint256 => RepairOrder) public repairOrders;
    uint256 public orderCounter;

    event RepairRequested(uint256 indexed orderId, uint256 indexed claimId, uint256 estimatedCostWei);
    event RepairCompleted(uint256 indexed orderId, uint256 indexed claimId);

    modifier onlyHandling() {
        require(msg.sender == handlingDepartment, "Only handling dep");
        _;
    }

    constructor(address _handlingDep) {
        handlingDepartment = _handlingDep;
    }

    function repairs_request(uint256 claimId, uint256 estimatedCostWei) external override onlyHandling returns (uint256 orderId) {
        orderId = ++orderCounter;
        repairOrders[orderId] = RepairOrder({claimId: claimId, estimatedCostWei: estimatedCostWei, completed: false});
        emit RepairRequested(orderId, claimId, estimatedCostWei);
    }

    function completeRepair(uint256 orderId) external {
        // En prod: restreindre cette fonction au mécanicien
        RepairOrder storage order = repairOrders[orderId];
        require(order.claimId != 0, "Unknown order");
        order.completed = true;
        emit RepairCompleted(orderId, order.claimId);
    }
}