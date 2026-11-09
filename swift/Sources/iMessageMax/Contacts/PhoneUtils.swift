import Foundation

enum PhoneUtils {
    /// The Mac's region (an ISO 3166 code such as "GB"), read once. A number
    /// written without a country code is read the way someone dialling in
    /// this region would read it.
    static let currentRegion: String? = Locale.current.region?.identifier

    /// How a region writes numbers without a country code.
    struct DialingPlan: Equatable {
        /// The country calling code, without "+".
        let callingCode: String
        /// Dialled before an area or mobile code inside the country ("0" in
        /// most of Europe, "8" in Russia). Empty when the region has none and
        /// every national number is dialled as it is written.
        let trunkPrefixes: [String]
        /// Dialled before a country code to call abroad. Empty when the
        /// prefix carries a carrier choice, so the country code that follows
        /// cannot be read reliably.
        let internationalPrefixes: [String]
        /// Lengths of a national number that people also write without the
        /// trunk prefix, such as a 10-digit mobile in India. A number of any
        /// other length without the trunk prefix is not guessed at.
        let bareLengths: Set<Int>

        var isNANP: Bool { callingCode == "1" }
    }

    static func dialingPlan(for region: String?) -> DialingPlan? {
        guard let region else { return nil }
        return dialingPlans[region.uppercased()]
    }

    /// Returns the E.164 form of `input` ("+447911123456"), or nil when the
    /// number cannot be read without guessing. A number written with "+" or
    /// an international prefix keeps its own country code. Any other number is
    /// read in `region`: +1 is assumed only in a North American Numbering Plan
    /// region, and elsewhere the trunk prefix is dropped and the region's
    /// calling code added. An unknown region reads only "+" and "00" numbers.
    static func normalizeToE164(_ input: String, region: String? = currentRegion) -> String? {
        let main = stripExtension(input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !main.contains(where: \.isLetter) else { return nil }

        // "(0)" marks a trunk digit that is dialled only inside the country.
        let international = asciiDigits(main.replacingOccurrences(of: "(0)", with: ""))
        let national = asciiDigits(main)
        guard !national.isEmpty else { return nil }

        if main.hasPrefix("+") || main.hasPrefix("＋") {
            return e164(international)
        }

        let plan = dialingPlan(for: region)
        let internationalPrefixes = plan?.internationalPrefixes ?? ["00"]
        for prefix in internationalPrefixes.sorted(by: { $0.count > $1.count })
        where international.hasPrefix(prefix) {
            return e164(String(international.dropFirst(prefix.count)))
        }

        guard let plan else { return nil }

        if plan.isNANP {
            if national.count == 10 { return "+1\(national)" }
            if national.count == 11 && national.hasPrefix("1") { return "+\(national)" }
            if national.count > 11 { return e164(national) }
            return nil
        }

        for trunk in plan.trunkPrefixes where national.hasPrefix(trunk) {
            var significant = String(national.dropFirst(trunk.count))
            // Brazil: a long-distance call puts a two-digit carrier code
            // between the trunk 0 and the area code ("0 21 11 98765-4321").
            // A Brazilian national number has 10 or 11 digits.
            if plan.callingCode == "55" && (12...13).contains(significant.count) {
                significant = String(significant.dropFirst(2))
            }
            return withCallingCode(plan.callingCode, significant)
        }

        if plan.trunkPrefixes.isEmpty || plan.bareLengths.contains(national.count) {
            return withCallingCode(plan.callingCode, national)
        }
        return nil
    }

    static func formatDisplay(_ phone: String) -> String {
        guard let normalized = normalizeToE164(phone) else {
            return phone
        }

        if normalized.hasPrefix("+1") && normalized.count == 12 {
            let digits = String(normalized.dropFirst(2))
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let subscriber = digits.suffix(4)
            return "+1 (\(area)) \(exchange)-\(subscriber)"
        }

        return normalized
    }

    static func isPhoneNumber(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter { $0.isNumber }
        let nonDigitsAllowed = trimmed.allSatisfy { $0.isNumber || " -()+.".contains($0) }
        guard nonDigitsAllowed else { return false }
        if digits.count >= 10 && digits.count <= 15 { return true }
        return !trimmed.hasPrefix("+") && digits.count >= 5 && digits.count <= 8
    }

    static func isEmail(_ input: String) -> Bool {
        input.contains("@") && input.contains(".")
    }

    // MARK: - Parsing

    private static func e164(_ digits: String) -> String? {
        guard !digits.isEmpty, digits.count <= 15 else { return nil }
        return "+\(digits)"
    }

    /// A national number shorter than 6 digits is a short code, which has
    /// no E.164 form.
    private static func withCallingCode(_ code: String, _ significant: String) -> String? {
        guard significant.count >= 6, code.count + significant.count <= 15 else { return nil }
        return "+\(code)\(significant)"
    }

    /// Digits in any script ("٠١٢", full-width) become ASCII digits.
    private static func asciiDigits(_ text: String) -> String {
        String(text.compactMap { character -> Character? in
            guard character.isNumber, let value = character.wholeNumberValue, (0...9).contains(value) else {
                return nil
            }
            return Character(String(value))
        })
    }

    /// Drops an extension or dial-string suffix: "x12", "ext. 12",
    /// "extension 12", ",12", ";12", "#12".
    static func stripExtension(_ input: String) -> String {
        var sawDigit = false
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if character.isNumber {
                sawDigit = true
            } else if sawDigit && ",;#".contains(character) {
                return String(input[..<index])
            } else if sawDigit && character.isLetter {
                let word = input[index...].prefix(while: \.isLetter).lowercased()
                if ["x", "ext", "extn", "extension"].contains(word) {
                    return String(input[..<index])
                }
                index = input.index(index, offsetBy: word.count)
                continue
            }
            index = input.index(after: index)
        }
        return input
    }

    // MARK: - Dialing plans

    /// One line per region: region, calling code, trunk prefixes, international
    /// prefixes and bare lengths ("|" separated, "-" for none). A region left
    /// out reads only numbers written with "+" or "00". Leave a region out
    /// rather than guess its prefixes: a wrong guess can match a stranger.
    private static let dialingPlanTable = """
        US 1 1 011|00 -
        CA 1 1 011|00 -
        PR 1 1 011|00 -
        VI 1 1 011|00 -
        GU 1 1 011|00 -
        AS 1 1 011|00 -
        MP 1 1 011|00 -
        UM 1 1 011|00 -
        AG 1 1 011|00 -
        AI 1 1 011|00 -
        BB 1 1 011|00 -
        BM 1 1 011|00 -
        BS 1 1 011|00 -
        DM 1 1 011|00 -
        DO 1 1 011|00 -
        GD 1 1 011|00 -
        JM 1 1 011|00 -
        KN 1 1 011|00 -
        KY 1 1 011|00 -
        LC 1 1 011|00 -
        MS 1 1 011|00 -
        SX 1 1 011|00 -
        TC 1 1 011|00 -
        TT 1 1 011|00 -
        VC 1 1 011|00 -
        VG 1 1 011|00 -
        GB 44 0 00 -
        IE 353 0 00 -
        DE 49 0 00 -
        FR 33 0 00 -
        NL 31 0 00 -
        BE 32 0 00 -
        CH 41 0 00 -
        AT 43 0 00 -
        SE 46 0 00 -
        FI 358 0 00 -
        RO 40 0 00 -
        BG 359 0 00 -
        HR 385 0 00 -
        SI 386 0 00 -
        SK 421 0 00 -
        RS 381 0 00 -
        BA 387 0 00 -
        ME 382 0 00 -
        MK 389 0 00 -
        AL 355 0 00 -
        UA 380 0 00 -
        HU 36 06 00 -
        RU 7 8 810 10
        KZ 7 8 810 10
        BY 375 8 810 -
        TR 90 0 00 10
        IL 972 0 00 -
        SA 966 0 00 -
        AE 971 0 00 -
        JO 962 0 00 -
        LB 961 0 00 -
        EG 20 0 00 -
        MA 212 0 00 -
        ZA 27 0 00 -
        NG 234 0 009 -
        KE 254 0 000 -
        GH 233 0 00 -
        IN 91 0 00 10
        PK 92 0 00 -
        BD 880 0 00 -
        LK 94 0 00 -
        CN 86 0 00 11
        TW 886 0 002 -
        JP 81 0 010 -
        KR 82 0 - -
        TH 66 0 001 -
        VN 84 0 00 -
        PH 63 0 00 -
        MY 60 0 00 -
        ID 62 0 - -
        AU 61 0 0011 -
        NZ 64 0 00 -
        BR 55 0 - 10|11
        AR 54 0 00 -
        PE 51 0 00 9
        VE 58 0 00 -
        IT 39 - 00 -
        SM 378 - 00 -
        ES 34 - 00 -
        PT 351 - 00 -
        NO 47 - 00 -
        DK 45 - 00 -
        GR 30 - 00 -
        LU 352 - 00 -
        MT 356 - 00 -
        CY 357 - 00 -
        PL 48 - 00 -
        CZ 420 - 00 -
        EE 372 - 00 -
        LV 371 - 00 -
        IS 354 - 00 -
        MC 377 - 00 -
        AD 376 - 00 -
        LI 423 - 00 -
        FO 298 - 00 -
        GL 299 - 00 -
        MX 52 - 00 -
        HK 852 - 001 -
        SG 65 - 001|008 -
        QA 974 - 00 -
        KW 965 - 00 -
        BH 973 - 00 -
        OM 968 - 00 -
        """

    private static let dialingPlans: [String: DialingPlan] = {
        func list(_ field: Substring) -> [String] {
            field == "-" ? [] : field.split(separator: "|").map(String.init)
        }
        var plans: [String: DialingPlan] = [:]
        for line in dialingPlanTable.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 5 else { continue }
            plans[String(fields[0])] = DialingPlan(
                callingCode: String(fields[1]),
                trunkPrefixes: list(fields[2]),
                internationalPrefixes: list(fields[3]),
                bareLengths: Set(list(fields[4]).compactMap { Int($0) })
            )
        }
        return plans
    }()
}
