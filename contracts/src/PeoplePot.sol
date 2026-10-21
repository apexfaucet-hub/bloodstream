// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title PeoplePot
/// @notice An immutable pot of USDC split EQUALLY, once per epoch, among the people on that epoch's published list.
///         - No owner, no upgrade, no pause, no withdrawal. USDC leaves only to an address proven to be on a published epoch
///           list, at most `perPerson` once per epoch, and the list can never be changed after it is published.
///         - Anyone can fund it (USDC transfer or fund()). Nobody can take funds out except through a claim.
///         - The ONE trusted role is `census`: it publishes the Merkle root of the epoch's list (who counts as a person). It cannot
///           touch funds, cannot change a published epoch, and its damage if it lies is bounded per epoch by `maxEpochBps` of the pot,
///           `maxEpochUsdc` and `maxPerPerson` (immutable). The list itself is published off-chain so anyone can recompute the root.
///           Trustless identity is the Lifeline of a later stage; this contract says plainly that it is not that.
///         - Unclaimed shares return to the pot after `claimWindow` (release()).
contract PeoplePot {
    IERC20 public immutable usdc;
    address public immutable census;
    uint256 public immutable start;
    uint256 public immutable epochLength;
    uint256 public immutable publishWindow;   // seconds after an epoch ends in which its list may still be published
    uint256 public immutable claimWindow;     // seconds after publishing in which people may claim
    uint256 public immutable maxPerPerson;    // USDC (6 decimals) one person can receive in one epoch
    uint256 public immutable maxEpochUsdc;    // USDC one epoch may budget in total
    uint256 public immutable maxEpochBps;     // share (of 10,000) of the free pot one epoch may budget
    uint256 public immutable maxCount;        // people on one list

    struct Epoch {
        bytes32 root;
        uint64 publishedAt;
        uint32 count;
        uint128 perPerson;
        uint128 paid;
        bool released;
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;
    /// USDC reserved for published, unreleased epochs and not yet paid out: always <= the pot's balance.
    uint256 public outstanding;
    uint256 public totalPaid;
    uint256 public totalFunded;   // funded through fund(); plain transfers raise the balance without being counted here

    event Funded(address indexed from, uint256 amount);
    event EpochPublished(uint256 indexed epoch, bytes32 root, uint32 count, uint128 perPerson);
    event Claimed(uint256 indexed epoch, address indexed person, uint128 amount);
    event Released(uint256 indexed epoch, uint256 returned);

    error NotCensus();
    error EpochNotOver();
    error PublishWindowClosed();
    error AlreadyPublished();
    error BadCount();
    error NothingToShare();
    error NotPublished();
    error ClaimWindowClosed();
    error AlreadyClaimed();
    error EpochExhausted();
    error BadProof();
    error NotYetReleasable();
    error AlreadyReleased();
    error TransferFailed();

    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "reentrant");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address usdc_, address census_, uint256 start_, uint256 epochLength_, uint256 publishWindow_, uint256 claimWindow_,
        uint256 maxPerPerson_, uint256 maxEpochUsdc_, uint256 maxEpochBps_, uint256 maxCount_
    ) {
        require(usdc_ != address(0) && census_ != address(0), "zero");
        require(epochLength_ >= 1 hours && publishWindow_ > 0 && publishWindow_ <= epochLength_ / 2 && claimWindow_ >= 7 days, "windows");
        require(maxPerPerson_ > 0 && maxEpochUsdc_ >= maxPerPerson_ && maxEpochUsdc_ <= type(uint128).max && maxEpochBps_ > 0 && maxEpochBps_ <= 5000 && maxCount_ > 0 && maxCount_ <= 100000, "caps");
        usdc = IERC20(usdc_);
        census = census_;
        start = start_;
        epochLength = epochLength_;
        publishWindow = publishWindow_;
        claimWindow = claimWindow_;
        maxPerPerson = maxPerPerson_;
        maxEpochUsdc = maxEpochUsdc_;
        maxEpochBps = maxEpochBps_;
        maxCount = maxCount_;
    }

    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < start) return 0;
        return (block.timestamp - start) / epochLength;
    }

    function fund(uint256 amount) external nonReentrant {
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    /// The free pot: what is held and not already promised to a published epoch.
    function free() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > outstanding ? bal - outstanding : 0;
    }

    function publishEpoch(uint256 epoch, bytes32 root, uint32 count) external nonReentrant {
        if (msg.sender != census) revert NotCensus();
        uint256 endsAt = start + (epoch + 1) * epochLength;
        if (block.timestamp < endsAt) revert EpochNotOver();
        if (block.timestamp > endsAt + publishWindow) revert PublishWindowClosed();
        if (epochs[epoch].publishedAt != 0) revert AlreadyPublished();
        if (count == 0 || count > maxCount || root == bytes32(0)) revert BadCount();
        uint256 f = free();
        uint256 budget = f * maxEpochBps / 10000;
        if (budget > maxEpochUsdc) budget = maxEpochUsdc;
        if (budget > uint256(count) * maxPerPerson) budget = uint256(count) * maxPerPerson;
        uint256 per = budget / count;
        if (per == 0) revert NothingToShare();
        epochs[epoch] = Epoch(root, uint64(block.timestamp), count, uint128(per), 0, false);
        outstanding += per * count;
        emit EpochPublished(epoch, root, count, uint128(per));
    }

    function claim(uint256 epoch, address person, bytes32[] calldata proof) external nonReentrant {
        Epoch storage e = epochs[epoch];
        if (e.publishedAt == 0) revert NotPublished();
        if (block.timestamp > e.publishedAt + claimWindow) revert ClaimWindowClosed();
        if (claimed[epoch][person]) revert AlreadyClaimed();
        // A list longer than its stated count can never pay more than count shares (it would eat another epoch's reservation).
        if (uint256(e.paid) + e.perPerson > uint256(e.perPerson) * e.count) revert EpochExhausted();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(person, epoch))));
        if (!_verify(proof, e.root, leaf)) revert BadProof();
        claimed[epoch][person] = true;
        e.paid += e.perPerson;
        outstanding -= e.perPerson;
        totalPaid += e.perPerson;
        if (!usdc.transfer(person, e.perPerson)) revert TransferFailed();
        emit Claimed(epoch, person, e.perPerson);
    }

    /// After the claim window, what nobody claimed stops being reserved and rejoins the free pot. Anyone may call it, once per epoch.
    function release(uint256 epoch) external nonReentrant {
        Epoch storage e = epochs[epoch];
        if (e.publishedAt == 0) revert NotPublished();
        if (block.timestamp <= e.publishedAt + claimWindow) revert NotYetReleasable();
        if (e.released) revert AlreadyReleased();
        e.released = true;
        uint256 left = uint256(e.perPerson) * e.count - e.paid;
        outstanding -= left;
        emit Released(epoch, left);
    }

    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h <= p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }
}
