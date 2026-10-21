// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PeoplePot.sol";
import "./Mocks.sol";

/// Random funding, donations, publishing, claiming (valid and forged), releasing and time travel.
contract PotHandler is Test {
    MockUSDC public usdc; PeoplePot public pot; address public census;
    uint256 public ghostIn;                    // every USDC ever put into the pot
    uint256 public nextEpoch;                  // lowest epoch not yet published
    uint256[] public published;
    mapping(uint256 => address[]) internal _people;
    mapping(uint256 => bytes32[]) internal _leaves;
    address[] public outsiders;
    mapping(address => bool) public everListed;
    uint256 START;

    constructor(MockUSDC u, PeoplePot p, address c, uint256 start_) {
        usdc = u; pot = p; census = c; START = start_;
        for (uint256 i = 0; i < 4; i++) outsiders.push(address(uint160(0xdead00 + i)));
    }
    function publishedCount() external view returns (uint256) { return published.length; }

    function fund(uint256 amt) external { amt = bound(amt, 1, 60e6); usdc.mint(address(this), amt); usdc.approve(address(pot), amt); pot.fund(amt); ghostIn += amt; }
    function donate(uint256 amt) external { amt = bound(amt, 1, 30e6); usdc.mint(address(pot), amt); ghostIn += amt; }
    function publish(uint256 n, uint256 salt) external {
        n = bound(n, 1, 12);
        uint256 e = nextEpoch; uint256 endsAt = START + (e + 1) * pot.epochLength();
        if (block.timestamp < endsAt + 1) vm.warp(endsAt + 1);
        address[] memory p = new address[](n); bytes32[] memory l = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) { p[i] = address(uint160(uint256(keccak256(abi.encode(salt, e, i))) | 1)); l[i] = Tree.leaf(p[i], e); }
        vm.prank(census);
        try pot.publishEpoch(e, Tree.root(l), uint32(n)) {
            published.push(e); _people[e] = p; _leaves[e] = l; nextEpoch = e + 1;
            for (uint256 i = 0; i < n; i++) everListed[p[i]] = true;
        } catch { nextEpoch = e + 1; }   // an empty pot cannot publish; the epoch is skipped
    }
    function claim(uint256 pick, uint256 who) external {
        if (published.length == 0) return;
        uint256 e = published[pick % published.length]; address[] storage p = _people[e]; uint256 i = who % p.length;
        try pot.claim(e, p[i], Tree.proof(_leaves[e], i)) {} catch {}
    }
    function forgedClaim(uint256 pick, uint256 whoSeed, uint256 as_) external {
        if (published.length == 0) return;
        uint256 e = published[pick % published.length]; address[] storage p = _people[e];
        address outsider = outsiders[whoSeed % outsiders.length];
        // an outsider replays a real proof, or a real person's proof under their own address
        try pot.claim(e, outsider, Tree.proof(_leaves[e], as_ % p.length)) {} catch {}
    }
    function release(uint256 pick) external {
        if (published.length == 0) return;
        uint256 e = published[pick % published.length]; vm.warp(block.timestamp + pot.claimWindow() + 1);
        try pot.release(e) {} catch {}
    }
    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 1, 20 days)); }
    function allPeople(uint256 e) external view returns (address[] memory) { return _people[e]; }
}

contract PeoplePotInvariantTest is Test {
    MockUSDC usdc; PeoplePot pot; PotHandler h;
    uint256 constant START = 1_000_000;

    function setUp() public {
        usdc = new MockUSDC();
        pot = new PeoplePot(address(usdc), address(0xCE115), START, 7 days, 3 days, 30 days, 1_000_000, 5_000_000, 2500, 1000);
        vm.warp(START);
        h = new PotHandler(usdc, pot, address(0xCE115), START);
        targetContract(address(h));
    }
    function invariant_balanceCoversWhatIsPromised() public view { assertGe(usdc.balanceOf(address(pot)), pot.outstanding()); }
    function invariant_everyUsdcIsAccountedFor() public view { assertEq(h.ghostIn(), usdc.balanceOf(address(pot)) + pot.totalPaid()); }
    function invariant_epochsStayInsideTheirCaps() public view {
        uint256 sumPaid; uint256 sumOut;
        for (uint256 i = 0; i < h.publishedCount(); i++) {
            uint256 e = h.published(i);
            (, , uint32 count, uint128 per, uint128 paid, bool released) = pot.epochs(e);
            assertLe(per, 1_000_000); assertLe(uint256(per) * count, 5_000_000); assertLe(paid, uint256(per) * count);
            sumPaid += paid; if (!released) sumOut += uint256(per) * count - paid;
        }
        assertEq(pot.totalPaid(), sumPaid); assertEq(pot.outstanding(), sumOut);
    }
    function invariant_onlyListedPeopleEverGetPaid() public view {
        for (uint256 i = 0; i < 4; i++) assertEq(usdc.balanceOf(h.outsiders(i)), 0);
    }
    function invariant_paidEqualsClaimsTimesShare() public view {
        for (uint256 i = 0; i < h.publishedCount(); i++) {
            uint256 e = h.published(i); (, , , uint128 per, uint128 paid, ) = pot.epochs(e);
            address[] memory p = h.allPeople(e); uint256 n;
            for (uint256 j = 0; j < p.length; j++) if (pot.claimed(e, p[j])) n++;
            assertEq(paid, uint256(per) * n);
        }
    }
}
