// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @title Digil Flags
/// @author gSOLO
/// @notice Bitmask constants used for Digil buffs / tier-tags.
library DigilFlags {
    // Buff Bitmasks
    uint16 internal constant STABILIZED       = uint16(1) << 0;  // Anti-Bleed - Prevents one bleed event; consumed on deactivation/recall bleed
    uint16 internal constant ANCHORED         = uint16(1) << 1;  // Retain Charge - On discharge, retain a fraction of activeCharge if buff still activ
    uint16 internal constant PRIMED           = uint16(1) << 2;  // Half Activation - Next activation threshold is halved once; consumed on successful activation
    uint16 internal constant REVERBERATED     = uint16(1) << 3;  // Reflect Propogated Charge - While buff is active, reflect a fraction of *propagated* link charge back as activeCharge

    // Tier / tag flags
    uint16 internal constant ELEMENTAL        = uint16(1) << 4;  // Tier 1 tag
    uint16 internal constant PARAELEMENTAL    = uint16(1) << 5;  // Tier 2 tag
    uint16 internal constant VOIDIC           = uint16(1) << 6;  // Tier 3 tag
    uint16 internal constant KARMIC           = uint16(1) << 7;  // Tier 4 tag (variant A)
    uint16 internal constant KAOTIC           = uint16(1) << 8;  // Tier 4 tag (variant B)
    uint16 internal constant AETHERIAL        = uint16(1) << 9;  // Tier 5 tag
    uint16 internal constant CELESTIAL        = uint16(1) << 10; // Tier 6 tag

    // Users may NOT set STABILIZED/PRIMED, but can set everything else (tiers, anchored, etc.)
    uint16 internal constant USER_FLAGS_MASK =
        uint16(type(uint16).max) & ~(STABILIZED | PRIMED);

    // Optional helper masks (handy + still inlined)
    uint16 internal constant INTERNAL_ONLY_MASK = (STABILIZED | PRIMED);

    // Inlined helpers
    function has(uint16 flags, uint16 mask) internal pure returns (bool) {
        return (flags & mask) != 0;
    }

    function set(uint16 flags, uint16 mask) internal pure returns (uint16) {
        return flags | mask;
    }

    function clear(uint16 flags, uint16 mask) internal pure returns (uint16) {
        return flags & ~mask;
    }
}
