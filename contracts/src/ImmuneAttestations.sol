// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ImmuneAttestations
/// @notice Public, on-chain record of the immune grades apexfaucet.xyz gives Arc tokens: (token, grade, evidenceHash, block).
///         It holds no value and has no say over any token. A grade is a claim by the attestor, backed by an evidence hash
///         anyone who bought the deep check can recompute (sha256 of the canonical JSON of the evidence).
///         Grades: 0 A healthy, 1 B fair, 2 C watch, 3 D sick, 4 F infected, 5 ? unproven.
contract ImmuneAttestations {
    struct Attestation {
        uint8 grade;
        uint64 blockNumber;
        uint64 timestamp;
        bytes32 evidenceHash;
    }

    address public attestor;
    address public pendingAttestor;
    mapping(address => Attestation) private _latest;
    uint256 public attestations;

    event Attested(address indexed token, uint8 grade, bytes32 evidenceHash, uint64 blockNumber);
    event AttestorProposed(address indexed current, address indexed proposed);
    event AttestorChanged(address indexed previous, address indexed current);

    error NotAttestor();
    error BadGrade();
    error EmptyEvidence();
    error ZeroToken();
    error NotPending();

    constructor(address attestor_) {
        require(attestor_ != address(0), "attestor");
        attestor = attestor_;
        emit AttestorChanged(address(0), attestor_);
    }

    modifier onlyAttestor() {
        if (msg.sender != attestor) revert NotAttestor();
        _;
    }

    function attest(address token, uint8 grade, bytes32 evidenceHash) external onlyAttestor {
        _attest(token, grade, evidenceHash);
    }

    function attestBatch(address[] calldata tokens, uint8[] calldata grades, bytes32[] calldata hashes) external onlyAttestor {
        require(tokens.length == grades.length && tokens.length == hashes.length && tokens.length <= 50, "batch");
        for (uint256 i = 0; i < tokens.length; i++) _attest(tokens[i], grades[i], hashes[i]);
    }

    function _attest(address token, uint8 grade, bytes32 evidenceHash) internal {
        if (token == address(0)) revert ZeroToken();
        if (grade > 5) revert BadGrade();
        if (evidenceHash == bytes32(0)) revert EmptyEvidence();
        _latest[token] = Attestation(grade, uint64(block.number), uint64(block.timestamp), evidenceHash);
        attestations++;
        emit Attested(token, grade, evidenceHash, uint64(block.number));
    }

    /// @return grade the last grade (meaningful only when blockNumber != 0), blockNumber 0 = never attested
    function latest(address token) external view returns (uint8 grade, uint64 blockNumber, uint64 timestamp, bytes32 evidenceHash) {
        Attestation memory a = _latest[token];
        return (a.grade, a.blockNumber, a.timestamp, a.evidenceHash);
    }

    /// Two steps, so a typo cannot hand the key to nobody.
    function proposeAttestor(address next) external onlyAttestor {
        require(next != address(0), "attestor");
        pendingAttestor = next;
        emit AttestorProposed(msg.sender, next);
    }

    function acceptAttestor() external {
        if (pendingAttestor == address(0) || msg.sender != pendingAttestor) revert NotPending();
        emit AttestorChanged(attestor, msg.sender);
        attestor = msg.sender;
        pendingAttestor = address(0);
    }
}
