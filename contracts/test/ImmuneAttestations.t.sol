// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ImmuneAttestations.sol";

contract ImmuneAttestationsTest is Test {
    ImmuneAttestations a;
    address att = address(0xA77E57);
    address token = address(0x7040E);
    address rando = address(0xBAD);
    event Attested(address indexed token, uint8 grade, bytes32 evidenceHash, uint64 blockNumber);

    function setUp() public { a = new ImmuneAttestations(att); vm.roll(1234); vm.warp(1_700_000_000); }

    function testOnlyTheAttestorAttests() public {
        vm.prank(rando); vm.expectRevert(ImmuneAttestations.NotAttestor.selector); a.attest(token, 0, bytes32(uint256(1)));
        vm.prank(rando); vm.expectRevert(ImmuneAttestations.NotAttestor.selector); a.attestBatch(new address[](1), new uint8[](1), new bytes32[](1));
    }
    function testAttestationIsStoredAndEmitted() public {
        vm.expectEmit(true, false, false, true); emit Attested(token, 4, bytes32(uint256(0xabc)), 1234);
        vm.prank(att); a.attest(token, 4, bytes32(uint256(0xabc)));
        (uint8 g, uint64 b, uint64 t, bytes32 h) = a.latest(token);
        assertEq(g, 4); assertEq(b, 1234); assertEq(t, 1_700_000_000); assertEq(h, bytes32(uint256(0xabc))); assertEq(a.attestations(), 1);
    }
    function testNeverAttestedReadsBlockZero() public view { (, uint64 b, , ) = a.latest(token); assertEq(b, 0); }
    function testLatestOverwrites() public {
        vm.startPrank(att); a.attest(token, 0, bytes32(uint256(1))); vm.roll(1300); a.attest(token, 4, bytes32(uint256(2))); vm.stopPrank();
        (uint8 g, uint64 b, , bytes32 h) = a.latest(token); assertEq(g, 4); assertEq(b, 1300); assertEq(h, bytes32(uint256(2)));
    }
    function testGradeRange() public {
        vm.startPrank(att);
        a.attest(token, 5, bytes32(uint256(1)));
        vm.expectRevert(ImmuneAttestations.BadGrade.selector); a.attest(token, 6, bytes32(uint256(1)));
        vm.stopPrank();
    }
    function testEmptyEvidenceRefused() public { vm.prank(att); vm.expectRevert(ImmuneAttestations.EmptyEvidence.selector); a.attest(token, 1, bytes32(0)); }
    function testZeroTokenRefused() public { vm.prank(att); vm.expectRevert(ImmuneAttestations.ZeroToken.selector); a.attest(address(0), 1, bytes32(uint256(1))); }
    function testBatchWritesEach() public {
        address[] memory t = new address[](3); uint8[] memory g = new uint8[](3); bytes32[] memory h = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) { t[i] = address(uint160(0x100 + i)); g[i] = uint8(i); h[i] = bytes32(uint256(i + 1)); }
        vm.prank(att); a.attestBatch(t, g, h);
        for (uint256 i = 0; i < 3; i++) { (uint8 gg, uint64 b, , bytes32 hh) = a.latest(t[i]); assertEq(gg, i); assertEq(b, 1234); assertEq(hh, h[i]); }
        assertEq(a.attestations(), 3);
    }
    function testBatchBoundsAndShape() public {
        address[] memory t = new address[](51); uint8[] memory g = new uint8[](51); bytes32[] memory h = new bytes32[](51);
        for (uint256 i = 0; i < 51; i++) { t[i] = address(uint160(0x500 + i)); g[i] = 1; h[i] = bytes32(uint256(i + 1)); }   // all individually valid
        vm.startPrank(att);
        vm.expectRevert(bytes("batch")); a.attestBatch(t, g, h);                                                          // refused only because it is too long
        vm.expectRevert(bytes("batch")); a.attestBatch(new address[](2), new uint8[](1), new bytes32[](2));                // mismatched lengths
        vm.stopPrank();
    }
    function testBatchIsAllOrNothing() public {
        address[] memory t = new address[](2); uint8[] memory g = new uint8[](2); bytes32[] memory h = new bytes32[](2);
        t[0] = token; t[1] = address(0x2); g[0] = 1; g[1] = 9; h[0] = bytes32(uint256(1)); h[1] = bytes32(uint256(1));
        vm.prank(att); vm.expectRevert(); a.attestBatch(t, g, h);
        (, uint64 b, , ) = a.latest(token); assertEq(b, 0);
    }
    function testAttestorChangeIsTwoStep() public {
        vm.prank(att); a.proposeAttestor(rando);
        assertEq(a.attestor(), att);                                              // nothing changes until accepted
        vm.prank(address(0x9)); vm.expectRevert(ImmuneAttestations.NotPending.selector); a.acceptAttestor();
        vm.prank(rando); a.acceptAttestor(); assertEq(a.attestor(), rando); assertEq(a.pendingAttestor(), address(0));
        vm.prank(att); vm.expectRevert(ImmuneAttestations.NotAttestor.selector); a.attest(token, 0, bytes32(uint256(1)));   // the old key is out
    }
    function testOnlyTheAttestorProposes() public { vm.prank(rando); vm.expectRevert(ImmuneAttestations.NotAttestor.selector); a.proposeAttestor(rando); }
    function testZeroPendingCannotAcceptByDefault() public { vm.prank(address(0)); vm.expectRevert(ImmuneAttestations.NotPending.selector); a.acceptAttestor(); }
    function testConstructorRefusesZero() public { vm.expectRevert(); new ImmuneAttestations(address(0)); }
    function testFuzzGradeAndHash(uint8 g, bytes32 h, address t) public {
        vm.assume(t != address(0)); vm.prank(att);
        if (g > 5 || h == bytes32(0)) { vm.expectRevert(); a.attest(t, g, h); } else { a.attest(t, g, h); (uint8 gg, , , bytes32 hh) = a.latest(t); assertEq(gg, g); assertEq(hh, h); }
    }
}
