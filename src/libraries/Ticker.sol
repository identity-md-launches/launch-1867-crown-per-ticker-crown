// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Ticker
/// @notice A ticker is keccak256 of the ASCII-uppercased symbol string: keccak256("CRWN") for "CRWN" or "crwn".
library Ticker {
    /// @dev Gas allowed for a token's symbol() call, so a hostile token cannot burn the caller's gas.
    uint256 internal constant SYMBOL_GAS = 60_000;

    function fromSymbol(string memory symbol) internal pure returns (bytes32) {
        bytes memory s = bytes(symbol);
        bytes memory upper = new bytes(s.length);
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c >= 0x61 && c <= 0x7a) c = bytes1(uint8(c) - 32);
            upper[i] = c;
        }
        return keccak256(upper);
    }

    /// @notice The ticker of `token`, or zero when it has no code or no readable, non-empty symbol().
    function ofToken(address token) internal view returns (bytes32) {
        if (token.code.length == 0) return bytes32(0);
        (bool ok, bytes memory data) = token.staticcall{gas: SYMBOL_GAS}(abi.encodeWithSignature("symbol()"));
        if (!ok || data.length < 64) return bytes32(0);
        uint256 offset;
        uint256 len;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
        }
        if (offset != 0x20) return bytes32(0);
        assembly ("memory-safe") {
            len := mload(add(data, 0x40))
        }
        if (len == 0 || len > 64 || data.length < 64 + len) return bytes32(0);
        string memory symbol = new string(len);
        assembly ("memory-safe") {
            mcopy(add(symbol, 0x20), add(data, 0x60), len)
        }
        return fromSymbol(symbol);
    }
}
