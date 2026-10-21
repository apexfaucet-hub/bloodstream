// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Lumenox
/// @notice A soulbound creature, one per address, minted to an address once and never movable. It holds no value and grants no rights; what it
///         looks like is drawn off chain from public facts about the address (tokenURI). The token id IS the address, so no id is ever guessable-new.
contract Lumenox {
    string public constant name = "Lumenox";
    string public constant symbol = "LUMX";
    address public minter;
    address public pendingMinter;
    mapping(uint256 => address) private _owner;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Locked(uint256 tokenId);
    event MinterProposed(address indexed proposed);
    event MinterChanged(address indexed previous, address indexed current);

    error NotMinter();
    error AlreadyBorn();
    error ZeroAddress();
    error Soulbound();
    error NoSuchToken();
    error NotPending();

    constructor(address minter_) { require(minter_ != address(0), "minter"); minter = minter_; emit MinterChanged(address(0), minter_); }

    function mint(address to) external {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        uint256 id = uint256(uint160(to));
        if (_owner[id] != address(0)) revert AlreadyBorn();
        _owner[id] = to; totalSupply++;
        emit Transfer(address(0), to, id); emit Locked(id);
    }
    function ownerOf(uint256 id) public view returns (address o) { o = _owner[id]; if (o == address(0)) revert NoSuchToken(); }
    function balanceOf(address a) external view returns (uint256) { if (a == address(0)) revert ZeroAddress(); return _owner[uint256(uint160(a))] == a ? 1 : 0; }
    function locked(uint256 id) external view returns (bool) { ownerOf(id); return true; }
    function tokenURI(uint256 id) external view returns (string memory) {
        address o = ownerOf(id);
        bytes memory h = "0123456789abcdef"; bytes memory s = new bytes(42); s[0] = "0"; s[1] = "x";
        uint160 v = uint160(o); for (uint256 i = 41; i > 1; i--) { s[i] = h[v & 0xf]; v >>= 4; }
        return string.concat("https://apexfaucet.xyz/api/lumenox/meta/", string(s));
    }
    // Every way to move or approve it reverts.
    function transferFrom(address, address, uint256) external pure { revert Soulbound(); }
    function safeTransferFrom(address, address, uint256) external pure { revert Soulbound(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert Soulbound(); }
    function approve(address, uint256) external pure { revert Soulbound(); }
    function setApprovalForAll(address, bool) external pure { revert Soulbound(); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
    function supportsInterface(bytes4 i) external pure returns (bool) { return i == 0x01ffc9a7 || i == 0x80ac58cd || i == 0x5b5e139f || i == 0xb45a3c0e; }

    function proposeMinter(address next) external { if (msg.sender != minter) revert NotMinter(); require(next != address(0), "minter"); pendingMinter = next; emit MinterProposed(next); }
    function acceptMinter() external { if (pendingMinter == address(0) || msg.sender != pendingMinter) revert NotPending(); emit MinterChanged(minter, msg.sender); minter = msg.sender; pendingMinter = address(0); }
}
