// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract FindPrivateKeysTest is Test {
    function test_FindPrivateKeys() external {
        address targetA = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906);
        address targetB = address(0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65);
        address targetC = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);

        console2.log("Targets:");
        console2.log("  A:", uint256(uint160(targetA)));
        console2.log("  B:", uint256(uint160(targetB)));
        console2.log("  C:", uint256(uint160(targetC)));

        uint256[] memory candidates = new uint256[](7);
        candidates[0] = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478caba5e658e12e3804e3a3f00;
        candidates[1] = 0x59c6995e998f97a5a0044966f0945389dc9e86dae82c7f8412c2f953c3d4b5f;
        candidates[2] = 0xde9be85777e070a3c5a97db30e29b1d85d4f1a9d8e1cf1c6d9a6ef11b67b4e;
        candidates[3] = 0x7c87602173a284daa77c025f72c3f1203745e68f2d293c4c99a6ea33140d55c9;
        candidates[4] = 0x1b89c295df4524e1da8c041a03e7fd5e07057be8ea05e04eb16f95f2c8e9e2c0;
        candidates[5] = 0x5de8ab5e6155a3bc9b7a84b2e4a89f3a6a95b8eb5a4c7e7c2b3d4e5f6a7b8c;
        candidates[6] = 0x4d5db51027c23896d2d0d01c9dd1b0001b3e6a8c7f3e2d1c0b9a8f7e6d5c4b;

        for (uint256 i = 0; i < candidates.length; i++) {
            address derived = vm.addr(candidates[i]);
            if (derived == targetA) console2.log("FOUND A! PK:", candidates[i]);
            if (derived == targetB) console2.log("FOUND B! PK:", candidates[i]);
            if (derived == targetC) console2.log("FOUND C! PK:", candidates[i]);
        }

        // Try offsets from base
        uint256 basePK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae82c7f8412c2f953c3d4b5f;
        for (uint256 i = 0; i < 30; i++) {
            uint256 pk = basePK + i;
            address derived = vm.addr(pk);
            console2.log("Offset", i, "->", derived);
            if (derived == targetA) console2.log("  MATCHES A! PK:", pk);
            if (derived == targetB) console2.log("  MATCHES B! PK:", pk);
            if (derived == targetC) console2.log("  MATCHES C! PK:", pk);
        }

        assertTrue(false, "Check output above for correct PKs");
    }
}
