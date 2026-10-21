// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockUSDC {
    string public name = "Mock USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;
    uint256 public totalSupply;
    address public hookTarget;      // a callback during transfer, to test re-entrancy (0 = off)
    bytes public hookData;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function setBlacklisted(address a, bool b) external { blacklisted[a] = b; }
    function setHook(address t, bytes calldata d) external { hookTarget = t; hookData = d; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "allowance"); allowance[f][msg.sender] = al - a; _move(f, to, a); return true;
    }
    function _move(address f, address to, uint256 a) internal {
        require(!blacklisted[f] && !blacklisted[to], "blacklisted");
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a; balanceOf[to] += a;
        if (hookTarget != address(0)) { address t = hookTarget; hookTarget = address(0); (bool ok, ) = t.call(hookData); ok; hookTarget = t; }
    }
}

/// Sorted-pair Merkle tree over leaves already hashed (OZ convention); proofs for each leaf.
library Tree {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 n = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](n);
            for (uint256 i = 0; i < n; i++) {
                if (2 * i + 1 < level.length) next[i] = _pair(level[2 * i], level[2 * i + 1]); else next[i] = level[2 * i];
            }
            level = next;
        }
        return level[0];
    }
    function proof(bytes32[] memory leaves, uint256 idx) internal pure returns (bytes32[] memory) {
        bytes32[] memory tmp = new bytes32[](32); uint256 k = 0;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < level.length) tmp[k++] = level[sib];
            uint256 n = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](n);
            for (uint256 i = 0; i < n; i++) {
                if (2 * i + 1 < level.length) next[i] = _pair(level[2 * i], level[2 * i + 1]); else next[i] = level[2 * i];
            }
            level = next; idx = idx / 2;
        }
        bytes32[] memory out = new bytes32[](k);
        for (uint256 i = 0; i < k; i++) out[i] = tmp[i];
        return out;
    }
    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
    function leaf(address person, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(person, epoch))));
    }
}
