// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.34;

/// @title DigilAppearance
/// @author gSOLO
/// @notice Bit packing helpers for Digil token appearance (uint120).
/// @dev Layout (little-endian bit indexing):
///      - styleId:     bits 0..7    (8 bits)
///      - cosmetics:   bits 8..27   (20 bits; 5 x 4-bit slots)
///      - mainRgb:     bits 28..51  (24 bits; RRGGBB background color)
///      - colorStart:  bits 52..83  (32 bits; RRGGBBAA gradient start)
///      - colorEnd:    bits 84..115 (32 bits; RRGGBBAA gradient end)
///      - reserved:    bits 116..119 (4 bits)
library DigilAppearance {
    // Shifts
    uint8 internal constant STYLE_SHIFT       = 0;
    uint8 internal constant COSMETICS_SHIFT   = 8;
    uint8 internal constant MAIN_RGB_SHIFT    = 28;
    uint8 internal constant COLOR_START_SHIFT = 52;
    uint8 internal constant COLOR_END_SHIFT   = 84;

    // Masks
    uint120 internal constant STYLE_MASK     = uint120(0xFF) << STYLE_SHIFT;         // 8 bits
    uint120 internal constant COSMETICS_MASK = uint120(0xFFFFF) << COSMETICS_SHIFT; // 20 bits

    uint120 internal constant RGB24_MASK  = uint120(0xFFFFFF);
    uint120 internal constant RGBA32_MASK = uint120(0xFFFFFFFF);

    uint120 internal constant MAIN_RGB_MASK    = RGB24_MASK  << MAIN_RGB_SHIFT;
    uint120 internal constant COLOR_START_MASK = RGBA32_MASK << COLOR_START_SHIFT;
    uint120 internal constant COLOR_END_MASK   = RGBA32_MASK << COLOR_END_SHIFT;

    // Convenience combined masks
    uint120 internal constant GRADIENT_MASK     = (COLOR_START_MASK | COLOR_END_MASK);
    uint120 internal constant COLOR_MASK        = (MAIN_RGB_MASK | GRADIENT_MASK);

    // reserved nibble used as themeId (0..15)
    uint8   internal constant THEME_SHIFT = 116;
    uint120 internal constant THEME_MASK  = uint120(0xF) << THEME_SHIFT;

    // ---- Core extractors ----

    function styleId(uint120 a) internal pure returns (uint8) {
        return uint8((a & STYLE_MASK) >> STYLE_SHIFT);
    }

    function cosmetics(uint120 a) internal pure returns (uint32) {
        return uint32((a & COSMETICS_MASK) >> COSMETICS_SHIFT);
    }

    function mainRgb(uint120 a) internal pure returns (uint24) {
        return uint24((a & MAIN_RGB_MASK) >> MAIN_RGB_SHIFT);
    }

    function colorStart(uint120 a) internal pure returns (uint32) {
        return uint32((a & COLOR_START_MASK) >> COLOR_START_SHIFT);
    }

    function colorEnd(uint120 a) internal pure returns (uint32) {
        return uint32((a & COLOR_END_MASK) >> COLOR_END_SHIFT);
    }

    function themeId(uint120 a) internal pure returns (uint8) {
        return uint8((a & THEME_MASK) >> THEME_SHIFT);
    }

    // ---- Cosmetics helpers (5 x 4-bit slots) ----

    /// @notice Reads a 4-bit cosmetic slot (idx 0..4).
    /// @dev Slot 0 is the least-significant nibble within the cosmetics field.
    function getCosmetic(uint120 a, uint8 idx) internal pure returns (uint8 value) {
        if (idx >= 5) return 0; // keep it soft; alternatively revert for stricter behavior
        uint8 shift = uint8(COSMETICS_SHIFT + (idx * 4));
        value = uint8((a >> shift) & 0xF);
    }

    /// @notice Sets a 4-bit cosmetic slot (idx 0..4) to `value` (low nibble used).
    function setCosmetic(uint120 a, uint8 idx, uint8 value) internal pure returns (uint120 out) {
        if (idx >= 5) return a; // keep it soft; alternatively revert
        uint8 shift = uint8(COSMETICS_SHIFT + (idx * 4));
        uint120 slotMask = uint120(0xF) << shift;

        out = (a & ~slotMask) | (uint120(value & 0xF) << shift);
    }

    // ---- Mutators ----

    /// @notice Sets the styleId field (0..255).
    function setStyleId(uint120 a, uint8 style) internal pure returns (uint120 out) {
        out = (a & ~STYLE_MASK) | (uint120(style) << STYLE_SHIFT);
    }

    /// @notice Sets the full 20-bit cosmetics field (5 x 4-bit slots).
    /// @dev Only the low 20 bits of `_cosmetics` are used; higher bits are ignored.
    function setCosmetics(uint120 a, uint32 _cosmetics) internal pure returns (uint120 out) {
        // keep only 20 bits (0xFFFFF), then place into the cosmetics field
        uint120 c = uint120(_cosmetics & 0xFFFFF);
        out = (a & ~COSMETICS_MASK) | (c << COSMETICS_SHIFT);
    }

    /// @notice Sets the main background RGB (RRGGBB) field.
    function setMainRgb(uint120 a, uint24 rgb) internal pure returns (uint120 out) {
        out = (a & ~MAIN_RGB_MASK) | (uint120(rgb) << MAIN_RGB_SHIFT);
    }

    /// @notice Sets both gradient endpoints (RRGGBBAA).
    function setGradient(uint120 a, uint32 start, uint32 end) internal pure returns (uint120 out) {
        // clear both, then set
        uint120 cleared = a & ~(COLOR_START_MASK | COLOR_END_MASK);
        out = cleared
            | (uint120(start) << COLOR_START_SHIFT)
            | (uint120(end)   << COLOR_END_SHIFT);
    }

    // (Optional) separate setters if you ever want them:
    function setColorStart(uint120 a, uint32 start) internal pure returns (uint120 out) {
        out = (a & ~COLOR_START_MASK) | (uint120(start) << COLOR_START_SHIFT);
    }

    function setColorEnd(uint120 a, uint32 end) internal pure returns (uint120 out) {
        out = (a & ~COLOR_END_MASK) | (uint120(end) << COLOR_END_SHIFT);
    }

    function setThemeId(uint120 a, uint8 theme) internal pure returns (uint120 out) {
        out = (a & ~THEME_MASK) | (uint120(theme & 0xF) << THEME_SHIFT);
    }

     // --- Predicates ---

    function hasStyle(uint120 a) internal pure returns (bool) {
        return styleId(a) != 0;
    }

    function hasCosmetics(uint120 a) internal pure returns (bool) {
        return cosmetics(a) != 0;
    }

    /// @dev True if mainRgb or either gradient endpoint is set.
    function hasColors(uint120 a) internal pure returns (bool) {
        return (a & COLOR_MASK) != 0;
    }

    function hasMainRgb(uint120 a) internal pure returns (bool) {
        return (a & MAIN_RGB_MASK) != 0;
    }

    function hasGradient(uint120 a) internal pure returns (bool) {
        return (a & GRADIENT_MASK) != 0;
    }

    /// @notice Unpacks a uint120 appearance into its component fields.
    /// @dev Returns raw packed channel values:
    ///      - mainRgb is RRGGBB (24-bit)
    ///      - colorStart/colorEnd are RRGGBBAA (32-bit)
    function unpack(uint120 a) internal pure returns (uint8 _styleId, uint32 _cosmetics, uint24 _mainRgb, uint32 _colorStart, uint32 _colorEnd, uint8  _themeId) {
        _styleId     = styleId(a);
        _cosmetics   = cosmetics(a);
        _mainRgb     = mainRgb(a);
        _colorStart  = colorStart(a);
        _colorEnd    = colorEnd(a);
        _themeId     = themeId(a);
    }

    /// @notice Packs components back into uint120 appearance.
    /// @dev Inputs are raw channel integers (mainRgb=RRGGBB, start/end=RRGGBBAA).
    function pack(uint8 _styleId, uint32 _cosmetics, uint24 _mainRgb, uint32 _colorStart, uint32 _colorEnd, uint8  _themeId) internal pure returns (uint120 a) {
        a = (uint120(_styleId) << STYLE_SHIFT) |
            (uint120(_cosmetics) << COSMETICS_SHIFT) |
            (uint120(_mainRgb) << MAIN_RGB_SHIFT) |
            (uint120(_colorStart) << COLOR_START_SHIFT) |
            (uint120(_colorEnd) << COLOR_END_SHIFT) |
            (uint120(_themeId & 0xF) << THEME_SHIFT);
    }

    /// @dev Convenience: true if any visual fields are non-zero.
    function any(uint120 a) internal pure returns (bool) {
        return a != 0;
    }
}
