// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/Lumenox.sol";
contract LumenoxTest is Test {
    Lumenox l; address m = address(0xA1); address a = address(0xB0B); address r = address(0xBAD);
    function setUp() public { l = new Lumenox(m); }
    function testOnlyMinterMints() public { vm.prank(r); vm.expectRevert(Lumenox.NotMinter.selector); l.mint(a); }
    function testMintIsOneToOne() public { vm.startPrank(m); l.mint(a); assertEq(l.ownerOf(uint256(uint160(a))), a); assertEq(l.balanceOf(a), 1); assertEq(l.totalSupply(), 1);
        vm.expectRevert(Lumenox.AlreadyBorn.selector); l.mint(a); vm.stopPrank(); }
    function testZeroAddressRefused() public { vm.prank(m); vm.expectRevert(Lumenox.ZeroAddress.selector); l.mint(address(0)); }
    function testNothingMoves() public {
        vm.prank(m); l.mint(a); uint256 id = uint256(uint160(a));
        vm.startPrank(a);
        vm.expectRevert(Lumenox.Soulbound.selector); l.transferFrom(a, r, id);
        vm.expectRevert(Lumenox.Soulbound.selector); l.safeTransferFrom(a, r, id);
        vm.expectRevert(Lumenox.Soulbound.selector); l.safeTransferFrom(a, r, id, "");
        vm.expectRevert(Lumenox.Soulbound.selector); l.approve(r, id);
        vm.expectRevert(Lumenox.Soulbound.selector); l.setApprovalForAll(r, true);
        vm.stopPrank(); assertEq(l.ownerOf(id), a);
    }
    function testTokenUriNamesTheAddress() public { vm.prank(m); l.mint(a); assertEq(l.tokenURI(uint256(uint160(a))), "https://apexfaucet.xyz/api/lumenox/meta/0x0000000000000000000000000000000000000b0b"); }
    function testUnbornReverts() public { vm.expectRevert(Lumenox.NoSuchToken.selector); l.ownerOf(5); vm.expectRevert(Lumenox.NoSuchToken.selector); l.tokenURI(5); }
    function testMinterChangeIsTwoStep() public {
        vm.prank(m); l.proposeMinter(r); assertEq(l.minter(), m);
        vm.prank(a); vm.expectRevert(Lumenox.NotPending.selector); l.acceptMinter();
        vm.prank(r); l.acceptMinter(); assertEq(l.minter(), r);
        vm.prank(m); vm.expectRevert(Lumenox.NotMinter.selector); l.mint(a);
        vm.prank(address(0)); vm.expectRevert(Lumenox.NotPending.selector); l.acceptMinter();
    }
    function testInterfaces() public view { assertTrue(l.supportsInterface(0x80ac58cd)); assertTrue(l.supportsInterface(0x5b5e139f)); assertFalse(l.supportsInterface(0xdeadbeef)); }
    function testFuzzMint(address to) public { vm.assume(to != address(0)); vm.prank(m); l.mint(to); assertEq(l.balanceOf(to), 1); assertEq(l.ownerOf(uint256(uint160(to))), to); }
}
