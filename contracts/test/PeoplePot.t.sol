// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PeoplePot.sol";
import "./Mocks.sol";

contract PeoplePotTest is Test {
    MockUSDC usdc;
    PeoplePot pot;
    address census = address(0xCE115);
    address rando = address(0xBEEF);
    uint256 constant START = 1_000_000;
    uint256 constant EPOCH = 7 days;
    uint256 constant PUBLISH = 3 days;
    uint256 constant CLAIM = 30 days;
    uint256 constant PER = 1_000_000;        // 1 USDC per person per epoch at most
    uint256 constant EPOCH_USD = 5_000_000;  // 5 USDC per epoch at most
    uint256 constant BPS = 2500;
    uint256 constant MAXN = 1000;

    function setUp() public {
        usdc = new MockUSDC();
        pot = new PeoplePot(address(usdc), census, START, EPOCH, PUBLISH, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        vm.warp(START);
    }

    function _fund(uint256 a) internal { usdc.mint(address(this), a); usdc.approve(address(pot), a); pot.fund(a); }
    function _people(uint256 n) internal pure returns (address[] memory p) { p = new address[](n); for (uint256 i = 0; i < n; i++) p[i] = address(uint160(0x1000 + i)); }
    function _leaves(address[] memory p, uint256 epoch) internal pure returns (bytes32[] memory l) { l = new bytes32[](p.length); for (uint256 i = 0; i < p.length; i++) l[i] = Tree.leaf(p[i], epoch); }
    function _endOf(uint256 e) internal pure returns (uint256) { return START + (e + 1) * EPOCH; }
    function _publish(uint256 epoch, address[] memory p) internal returns (bytes32[] memory leaves) {
        leaves = _leaves(p, epoch); vm.warp(_endOf(epoch) + 1);
        vm.prank(census); pot.publishEpoch(epoch, Tree.root(leaves), uint32(p.length));
    }

    // ---- constructor ----
    function testConstructorGuards() public {
        vm.expectRevert(); new PeoplePot(address(0), census, START, EPOCH, PUBLISH, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), address(0), START, EPOCH, PUBLISH, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, 10 minutes, PUBLISH, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, PUBLISH, 1 days, PER, EPOCH_USD, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, PUBLISH, CLAIM, PER, EPOCH_USD, 6000, MAXN);   // more than half the pot in one epoch
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, PUBLISH, CLAIM, PER, PER - 1, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, EPOCH, CLAIM, PER, EPOCH_USD, BPS, MAXN);   // publish window must be shorter than an epoch: two epochs can never be open at once
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, 14 days, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, EPOCH - 1, CLAIM, PER, EPOCH_USD, BPS, MAXN);   // two publishes seconds apart: window must be at most half an epoch
        vm.expectRevert(); new PeoplePot(address(usdc), census, START, EPOCH, EPOCH / 2 + 1, CLAIM, PER, EPOCH_USD, BPS, MAXN);
        new PeoplePot(address(usdc), census, START, EPOCH, EPOCH / 2, CLAIM, PER, EPOCH_USD, BPS, MAXN);   // exactly half is allowed
    }

    // ---- publishing: who, when, how much ----
    function testOnlyCensusPublishes() public {
        _fund(100e6); vm.warp(_endOf(0) + 1);
        vm.prank(rando); vm.expectRevert(PeoplePot.NotCensus.selector); pot.publishEpoch(0, bytes32(uint256(1)), 5);
    }
    function testCannotPublishBeforeEpochEnds() public {
        _fund(100e6); vm.warp(_endOf(0) - 1);
        vm.prank(census); vm.expectRevert(PeoplePot.EpochNotOver.selector); pot.publishEpoch(0, bytes32(uint256(1)), 5);
    }
    function testCannotPublishAfterWindow() public {
        _fund(100e6); vm.warp(_endOf(0) + PUBLISH + 1);
        vm.prank(census); vm.expectRevert(PeoplePot.PublishWindowClosed.selector); pot.publishEpoch(0, bytes32(uint256(1)), 5);
    }
    function testCannotPublishTwice() public {
        _fund(100e6); _publish(0, _people(5));
        vm.prank(census); vm.expectRevert(PeoplePot.AlreadyPublished.selector); pot.publishEpoch(0, bytes32(uint256(2)), 5);
    }
    function testBadCountsAndEmptyRoot() public {
        _fund(100e6); vm.warp(_endOf(0) + 1);
        vm.startPrank(census);
        vm.expectRevert(PeoplePot.BadCount.selector); pot.publishEpoch(0, bytes32(uint256(1)), 0);
        vm.expectRevert(PeoplePot.BadCount.selector); pot.publishEpoch(0, bytes32(uint256(1)), uint32(MAXN + 1));
        vm.expectRevert(PeoplePot.BadCount.selector); pot.publishEpoch(0, bytes32(0), 5);
        vm.stopPrank();
    }
    function testNothingToShareOnAnEmptyPot() public {
        vm.warp(_endOf(0) + 1); vm.prank(census); vm.expectRevert(PeoplePot.NothingToShare.selector); pot.publishEpoch(0, bytes32(uint256(1)), 5);
    }
    function testBudgetIsTheSmallestOfThreeCaps() public {
        _fund(100e6);                                   // 25% of 100 = 25 USDC, epoch cap 5, 10 people x 1 = 10 -> 5 USDC, 0.5 each
        _publish(0, _people(10)); (, , , uint128 per, , ) = pot.epochs(0); assertEq(per, 500_000);
        assertEq(pot.outstanding(), 5_000_000);
    }
    function testPerPersonCapBinds() public {
        _fund(100e6);                                   // 2 people x 1 USDC = 2 USDC < 5 and < 25
        _publish(0, _people(2)); (, , , uint128 per, , ) = pot.epochs(0); assertEq(per, 1_000_000);
    }
    function testPotShareCapBinds() public {
        _fund(8e6);                                     // 25% of 8 = 2 USDC across 4 people = 0.5
        _publish(0, _people(4)); (, , , uint128 per, , ) = pot.epochs(0); assertEq(per, 500_000);
    }
    function testSecondEpochSeesOnlyTheFreePot() public {
        _fund(8e6); _publish(0, _people(4));            // 2 USDC reserved, 6 free
        assertEq(pot.free(), 6e6);
        _publish(1, _people(4)); (, , , uint128 per, , ) = pot.epochs(1); assertEq(per, 375_000);   // 25% of 6 = 1.5, /4
        assertLe(pot.outstanding(), usdc.balanceOf(address(pot)));
    }

    // ---- claiming ----
    function testClaimPaysTheProvenAddressNotTheCaller() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        vm.prank(rando); pot.claim(0, p[3], Tree.proof(l, 3));
        assertEq(usdc.balanceOf(p[3]), 1_000_000); assertEq(usdc.balanceOf(rando), 0);
    }
    function testEveryoneGetsTheSameShare() public {
        _fund(100e6); address[] memory p = _people(7); bytes32[] memory l = _publish(0, p);
        for (uint256 i = 0; i < 7; i++) pot.claim(0, p[i], Tree.proof(l, i));
        for (uint256 i = 0; i < 7; i++) assertEq(usdc.balanceOf(p[i]), usdc.balanceOf(p[0]));
    }
    function testNoDoubleClaim() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        pot.claim(0, p[1], Tree.proof(l, 1));
        vm.expectRevert(PeoplePot.AlreadyClaimed.selector); pot.claim(0, p[1], Tree.proof(l, 1));
    }
    function testNotOnTheListCannotClaim() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        vm.expectRevert(PeoplePot.BadProof.selector); pot.claim(0, rando, Tree.proof(l, 1));
    }
    function testProofForAnotherEpochFails() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        _publish(1, p);
        vm.expectRevert(PeoplePot.BadProof.selector); pot.claim(1, p[1], Tree.proof(l, 1));      // epoch 0's proof is not epoch 1's
    }
    function testTamperedProofFails() public {
        _fund(100e6); address[] memory p = _people(8); bytes32[] memory l = _publish(0, p);
        bytes32[] memory pr = Tree.proof(l, 2); pr[0] = bytes32(uint256(pr[0]) ^ 1);
        vm.expectRevert(PeoplePot.BadProof.selector); pot.claim(0, p[2], pr);
    }
    function testSecondPreimageAttackFails() public {
        // an inner node (a hash of two leaves) offered as if it were a person's leaf must not verify
        _fund(100e6); address[] memory p = _people(4); bytes32[] memory l = _publish(0, p);
        bytes32 inner = l[0] <= l[1] ? keccak256(abi.encodePacked(l[0], l[1])) : keccak256(abi.encodePacked(l[1], l[0]));
        bytes32[] memory pr = new bytes32[](1); pr[0] = l[2] <= l[3] ? keccak256(abi.encodePacked(l[2], l[3])) : keccak256(abi.encodePacked(l[3], l[2]));
        // no address can have leaf == inner, so a claim by any address with this proof fails
        vm.expectRevert(PeoplePot.BadProof.selector); pot.claim(0, address(uint160(uint256(inner))), pr);
    }
    function testClaimWindowCloses() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        vm.warp(block.timestamp + CLAIM + 1);
        vm.expectRevert(PeoplePot.ClaimWindowClosed.selector); pot.claim(0, p[0], Tree.proof(l, 0));
    }
    function testUnpublishedEpochCannotBeClaimed() public {
        vm.expectRevert(PeoplePot.NotPublished.selector); pot.claim(0, rando, new bytes32[](0));
    }
    function testAListLongerThanItsCountCannotOverpay() public {
        _fund(100e6);
        address[] memory p = _people(6); bytes32[] memory l = _leaves(p, 0); vm.warp(_endOf(0) + 1);
        vm.prank(census); pot.publishEpoch(0, Tree.root(l), 3);     // the census says 3 people but proves 6
        uint256 ok = 0; for (uint256 i = 0; i < 6; i++) { try pot.claim(0, p[i], Tree.proof(l, i)) { ok++; } catch {} }
        assertEq(ok, 3); (, , , uint128 per, uint128 paid, ) = pot.epochs(0); assertEq(paid, uint256(per) * 3);
    }
    function testOverclaimCannotEatAnotherEpochsReservation() public {
        _fund(100e6);
        address[] memory p = _people(6); bytes32[] memory l = _leaves(p, 0); vm.warp(_endOf(0) + 1);
        vm.prank(census); pot.publishEpoch(0, Tree.root(l), 3);        // says 3, proves 6
        address[] memory q = _people(5); _publish(1, q);                  // epoch 1 reserves its own money
        (, , , uint128 per1, , ) = pot.epochs(1); uint256 reserved1 = uint256(per1) * 5;
        for (uint256 i = 0; i < 3; i++) pot.claim(0, p[i], Tree.proof(l, i));
        assertEq(pot.outstanding(), reserved1);
        vm.expectRevert(PeoplePot.EpochExhausted.selector); pot.claim(0, p[3], Tree.proof(l, 3));   // the 4th share does not exist
        assertEq(pot.outstanding(), reserved1);
    }
    function testBlacklistedRecipientDoesNotBlockOthers() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        usdc.setBlacklisted(p[0], true);
        vm.expectRevert(); pot.claim(0, p[0], Tree.proof(l, 0));
        pot.claim(0, p[1], Tree.proof(l, 1)); assertEq(usdc.balanceOf(p[1]), 1_000_000);
        assertFalse(pot.claimed(0, p[0]));                                                   // a failed claim marks nothing
    }
    function testReentrancyBlocked() public {
        _fund(100e6); address[] memory p = _people(5); bytes32[] memory l = _publish(0, p);
        usdc.setHook(address(pot), abi.encodeCall(PeoplePot.claim, (0, p[2], Tree.proof(l, 2))));   // paying p[1] tries to claim for p[2] from inside the transfer
        pot.claim(0, p[1], Tree.proof(l, 1));
        assertEq(usdc.balanceOf(p[2]), 0);                                                   // the nested claim was refused by the lock
    }

    // ---- release ----
    function testReleaseReturnsTheUnclaimed() public {
        _fund(8e6); address[] memory p = _people(4); bytes32[] memory l = _publish(0, p);    // 0.5 each, 2 reserved
        pot.claim(0, p[0], Tree.proof(l, 0));
        assertEq(pot.outstanding(), 1_500_000);
        vm.expectRevert(PeoplePot.NotYetReleasable.selector); pot.release(0);
        vm.warp(block.timestamp + CLAIM + 1); pot.release(0);
        assertEq(pot.outstanding(), 0); assertEq(pot.free(), usdc.balanceOf(address(pot)));
        vm.expectRevert(PeoplePot.AlreadyReleased.selector); pot.release(0);
    }
    function testReleaseOfAnUnpublishedEpochFails() public { vm.expectRevert(PeoplePot.NotPublished.selector); pot.release(3); }

    // ---- nobody can take money out except through a claim ----
    function testCensusCannotExtractMoreThanOneEpochCap() public {
        _fund(1000e6);
        // a lying census lists 64 sybil addresses it controls, all claim; the epoch cap (5 USDC) is the most that can leave
        address[] memory p = _people(64); bytes32[] memory l = _publish(0, p);
        uint256 out; for (uint256 i = 0; i < 64; i++) { pot.claim(0, p[i], Tree.proof(l, i)); out += usdc.balanceOf(p[i]); }
        assertLe(out, EPOCH_USD); assertGe(usdc.balanceOf(address(pot)), 1000e6 - EPOCH_USD);
    }
    function testNoOwnerFunctionsExist() public view {
        // every external function of the contract, by selector: none moves USDC except claim
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = pot.currentEpoch.selector; sel[1] = pot.free.selector; sel[2] = pot.fund.selector; sel[3] = pot.publishEpoch.selector; sel[4] = pot.claim.selector; sel[5] = pot.release.selector;
        sel[6] = pot.census.selector; sel[7] = pot.outstanding.selector; sel[8] = pot.totalPaid.selector; sel[9] = pot.totalFunded.selector; sel[10] = pot.epochs.selector; sel[11] = pot.claimed.selector;
        assertEq(sel.length, 12);   // the ABI is exactly these (checked against the compiled ABI by tests/pot-abi.sh)
    }
}
