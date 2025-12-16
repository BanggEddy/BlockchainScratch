// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Composite smart contracts implementing a simplified car insurance workflow.
 * Three main actors:
 * - claimprocessingDep: onboarding customers, validating policies, registering claims.
 * - ClaimsHandlingDep: evaluates claims, computes payouts/garage authorizations.
 * - Garage: receives repair requests and confirms completion.
 *
 * The code focuses on deterministic business logic, using fixed thresholds
 * described in the project brief. Payments use plain ether for simplicity;
 * in production this could be replaced with ERC20 transfers or treasury logic.
 */

enum PolicyType {
    None,
    ThirdParty,
    AllRisk
}

enum ClaimStatus {
    Submitted,
    InReview,
    Approved,
    Rejected,
    GarageAuthorized,
    PaidToGarage,
    PaidToThirdParty
}

interface IClaimsHandlingDep {
    function Third_party_assessment(uint256 claimId, uint256 percentage) external;
    function all_risk_assessment(uint256 claimId, uint256 damage) external;
}

interface IClaimProcessingDep {
    function decision(
        uint256 claimId,
        bool positive,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    ) external;
}

contract claimprocessingDep is IClaimProcessingDep {
    struct Customer {
        string name;
        PolicyType policy;
        bool valid;
    }

    struct Claim {
        uint256 id;
        address claimant;
        PolicyType policy;
        uint256 percentageOrDamage; // percentage for third-party, damage for all-risk
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
    event ClaimDecision(
        uint256 indexed claimId,
        bool positive,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not authorized");
        _;
    }

    constructor(address handlingDep) {
        admin = msg.sender;
        handlingDepartment = IClaimsHandlingDep(handlingDep);
    }

    function setHandlingDepartment(address handlingDep) external onlyAdmin {
        handlingDepartment = IClaimsHandlingDep(handlingDep);
    }

    function addcustomer(address customer, string calldata name, PolicyType policy) external onlyAdmin {
        customers[customer] = Customer({name: name, policy: policy, valid: true});
        emit CustomerAdded(customer, policy);
    }

    function check_claimant_rights(address claimant) public view returns (bool) {
        Customer memory c = customers[claimant];
        return c.valid && c.policy != PolicyType.None;
    }

    function submit_a_claim(PolicyType policy) internal returns (uint256 claimId) {
        require(check_claimant_rights(msg.sender), "Invalid or missing policy");
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

    // Third-party form: percent is the expert-assessed damage percentage.
    function Third_party_car_insurance_form(uint256 percentage) external {
        uint256 claimId = submit_a_claim(PolicyType.ThirdParty);
        claims[claimId].percentageOrDamage = percentage;
        claims[claimId].status = ClaimStatus.InReview;
        handlingDepartment.Third_party_assessment(claimId, percentage);
    }

    // All-risk form: damage is the declared damage percentage.
    function All_risk_car_insurance_form(uint256 damage) external {
        uint256 claimId = submit_a_claim(PolicyType.AllRisk);
        claims[claimId].percentageOrDamage = damage;
        claims[claimId].status = ClaimStatus.InReview;
        handlingDepartment.all_risk_assessment(claimId, damage);
    }

    // Called by ClaimsHandlingDep when an assessment is ready.
    function decision(
        uint256 claimId,
        bool positive,
        uint256 thirdPartyPayoutWei,
        uint256 garageCostWei
    ) external override {
        require(msg.sender == address(handlingDepartment), "Only handling dep");
        Claim storage claim = claims[claimId];
        require(claim.id != 0, "Unknown claim");

        claim.positive = positive;
        claim.thirdPartyPayoutWei = thirdPartyPayoutWei;
        claim.garageCostWei = garageCostWei;

        if (!positive) {
            claim.status = ClaimStatus.Rejected;
        } else if (claim.policy == PolicyType.ThirdParty) {
            claim.status = ClaimStatus.Approved;
        } else {
            claim.status = ClaimStatus.GarageAuthorized;
        }

        emit ClaimDecision(claimId, positive, thirdPartyPayoutWei, garageCostWei);
    }
}

contract ClaimsHandlingDep is IClaimsHandlingDep {
    claimprocessingDep public processingDep;
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
        processingDep = claimprocessingDep(dep);
    }

    receive() external payable {}

    function Third_party_assessment(uint256 claimId, uint256 percentage) external override onlyProcessingDep {
        (uint256 payout, bool positive) = _computeThirdPartyPayout(percentage);
        processingDep.decision(claimId, positive, payout, 0);
        emit ThirdPartyAssessed(claimId, positive, payout);
    }

    function all_risk_assessment(uint256 claimId, uint256 damage) external override onlyProcessingDep {
        uint256 cost = _computeGarageCost(damage);
        bool positive = cost > 0;
        processingDep.decision(claimId, positive, 0, cost);
        emit AllRiskAssessed(claimId, cost);
    }

    function pay_to_the_third(uint256 claimId, address payable thirdParty) external onlyAdmin {
        // Pull latest decision
        (, , , , , , uint256 payoutWei) = _getClaimSnapshot(claimId);
        require(payoutWei > 0, "No payout available");
        require(address(this).balance >= payoutWei, "Insufficient funds");
        thirdParty.transfer(payoutWei);
        emit PaidToThirdParty(claimId, thirdParty, payoutWei);
    }

    function pay_to_garage(uint256 claimId, address payable garageAddr) external onlyAdmin {
        (, , , , uint256 garageCostWei, , ) = _getClaimSnapshot(claimId);
        require(garageCostWei > 0, "No garage cost set");
        require(address(this).balance >= garageCostWei, "Insufficient funds");
        garageAddr.transfer(garageCostWei);
        emit PaidToGarage(claimId, garageAddr, garageCostWei);
    }

    // Internal helpers -----------------------------------------------------

    function _computeThirdPartyPayout(uint256 percentage) internal pure returns (uint256 payoutWei, bool positive) {
        if (percentage > 70) {
            return (0, false);
        }
        positive = true;
        if (percentage <= 30) {
            payoutWei = 7 ether;
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

    function _getClaimSnapshot(uint256 claimId)
        internal
        view
        returns (
            address claimant,
            PolicyType policy,
            uint256 percentageOrDamage,
            bool positive,
            uint256 garageCostWei,
            ClaimStatus status,
            uint256 thirdPartyPayoutWei
        )
    {
        claimprocessingDep.Claim memory c = processingDep.claims(claimId);
        return (
            c.claimant,
            c.policy,
            c.percentageOrDamage,
            c.positive,
            c.garageCostWei,
            c.status,
            c.thirdPartyPayoutWei
        );
    }
}

contract Garage {
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

    constructor(address handlingDep) {
        handlingDepartment = handlingDep;
    }

    function repairs_request(uint256 claimId, uint256 estimatedCostWei) external onlyHandling returns (uint256 orderId) {
        orderId = ++orderCounter;
        repairOrders[orderId] = RepairOrder({claimId: claimId, estimatedCostWei: estimatedCostWei, completed: false});
        emit RepairRequested(orderId, claimId, estimatedCostWei);
    }

    function repairs_response(uint256 orderId, bool completed) external onlyHandling {
        RepairOrder storage order = repairOrders[orderId];
        require(order.claimId != 0, "Unknown order");
        order.completed = completed;
        emit RepairCompleted(orderId, order.claimId);
    }
}

