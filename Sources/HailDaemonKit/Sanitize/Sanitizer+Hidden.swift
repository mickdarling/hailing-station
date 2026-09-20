/// The hidden-character rule of `Sanitizer` (#44 item 2): what is refused and the emoji exceptions.
extension Sanitizer {
    /// Refuses by Unicode property rather than by list: every format character (Cf: bidi embeddings,
    /// overrides, isolates and marks, zero-width set, soft hyphen, invisible operators, tags, ...), every
    /// other default-ignorable code point (Mongolian and Khmer selectors, Hangul fillers, ...), and the
    /// combining grapheme joiner; also the braille blank, which is a visible-nothing that reads back as a
    /// space, and every noncharacter. The emoji mechanisms are the narrow exceptions: a zero-width joiner
    /// between two emoji, the two emoji variation selectors after an emoji-capable scalar (`❤️`; after an
    /// ASCII keycap base only with the keycap, `1️⃣`),
    /// and the three standardised subdivision flags (England, Scotland, Wales) as exact tag runs.
    /// Returned as the class name for the spoken reason.
    static func firstHiddenCharacterClass(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
                return "bidirectional control"
            case 0x200D where joinsEmoji(scalars, at: index):
                break
            case 0x200B...0x200D, 0x2060, 0xFEFF:
                return "zero-width character"
            case 0xFE0E, 0xFE0F:
                guard selectsEmoji(scalars, at: index) else { return "invisible format character" }
            case 0x1F3F4 where flagTagRunLength(scalars, after: index) != nil:
                index += flagTagRunLength(scalars, after: index) ?? 0
            default:
                if let other = otherHiddenClass(scalar) { return other }
            }
            index += 1
        }
        return nil
    }

    /// The classes with no emoji exception: noncharacters, the braille blank, the combining grapheme joiner,
    /// and every remaining default-ignorable or format character.
    static func otherHiddenClass(_ scalar: Unicode.Scalar) -> String? {
        if scalar.properties.isNoncharacterCodePoint { return "noncharacter" }
        if scalar.value == 0x2800 { return "blank lookalike character" }
        if scalar.value == 0x034F || scalar.properties.isDefaultIgnorableCodePoint
            || scalar.properties.generalCategory == .format {
            return "invisible format character"
        }
        return nil
    }

    /// An emoji variation selector may follow an emoji-capable scalar; after an ASCII keycap base (digits,
    /// `#`, `*`) only when the keycap U+20E3 follows, so `7\u{FE0F}77` and `*\u{FE0F}` cannot hide a selector.
    static func selectsEmoji(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0, scalars[index - 1].properties.isEmoji else { return false }
        guard scalars[index - 1].value < 0x80 else { return true }
        return index + 1 < scalars.count && scalars[index + 1].value == 0x20E3
    }

    /// Left: an emoji-presentation scalar, a skin-tone modifier, or the emoji variation selector. Right: an
    /// emoji-presentation scalar, a modifier base, or a scalar followed by the emoji variation selector.
    static func joinsEmoji(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0, index + 1 < scalars.count else { return false }
        let before = scalars[index - 1]
        let after = scalars[index + 1]
        let beforeIsEmoji = before.properties.isEmojiPresentation || before.properties.isEmojiModifier
            || before.value == 0xFE0F
        let afterIsEmoji = after.properties.isEmojiPresentation || after.properties.isEmojiModifierBase
            || (index + 2 < scalars.count && scalars[index + 2].value == 0xFE0F && after.properties.isEmoji)
        return beforeIsEmoji && afterIsEmoji
    }

    /// The only subdivision flags with recommended-for-interchange status: England, Scotland, Wales. Any
    /// other tag run after the black flag renders as a bare flag and would be an invisible text channel.
    static let subdivisionFlags: [[UInt32]] = ["gbeng", "gbsct", "gbwls"].map { code in
        code.unicodeScalars.map { 0xE0000 + $0.value } + [0xE007F]
    }

    /// Number of tag scalars forming one of `subdivisionFlags` directly after the black flag at `index`;
    /// `nil` for anything else.
    static func flagTagRunLength(_ scalars: [Unicode.Scalar], after index: Int) -> Int? {
        for flag in subdivisionFlags where index + flag.count < scalars.count {
            let run = scalars[(index + 1)...(index + flag.count)].map(\.value)
            if run == flag { return flag.count }
        }
        return nil
    }
}
