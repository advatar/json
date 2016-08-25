import Core
import libc

// MARK: - JSON.Parser

extension JSON {

    public struct Parser {

        public struct Option: OptionSet {
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            public let rawValue: UInt8

            /// Do not remove null values from the resulting JSON value. Instead store `JSON.null`
            public static let skipNull        = Option(rawValue: 0b0001)

            /// Allows Parser to return top level objects that are not container types `{}` | `[]` as per RFC7159
            public static let allowFragments  = Option(rawValue: 0b0010)
        }

        let skipNull: Bool
        var pointer: UnsafePointer<UTF8.CodeUnit>
        var buffer: UnsafeBufferPointer<UTF8.CodeUnit>

        /// Used to reduce the number of alloc's for parsing subsequent strings
        var stringBuffer: [UTF8.CodeUnit] = []
    }
}


// MARK: - Initializers

extension JSON.Parser {

    // assumes data is null terminated.
    // and that the buffer will not be de-allocated before completion (handled by JSON.Parser.parse(_:,options:)
    internal init(bufferPointer: UnsafeBufferPointer<UTF8.CodeUnit>, options: Option) throws {

        self.buffer = bufferPointer

        guard let pointer = bufferPointer.baseAddress, buffer.endAddress != bufferPointer.baseAddress else { throw Error(byteOffset: 0, reason: .emptyStream) }

        // This can be unwrapped unsafely because
        self.pointer = pointer
        self.skipNull = options.contains(.skipNull)

        self.skipWhitespace()

        if !options.contains(.allowFragments) {
            guard let firstToken = peek(), firstToken == objectOpen || firstToken == arrayOpen else { throw Error.Reason.fragmentedJson }
        }
    }
}


// MARK: - Public API

extension JSON.Parser {

    public static func parse(_ data: Bytes, options: Option = []) throws -> Node {

        return try data.withUnsafeBufferPointer { bufferPointer in

            var parser = try self.init(bufferPointer: bufferPointer, options: options)

            do {

                parser.skipWhitespace()

                let rootValue = try parser.parseValue()

                // TODO (vkda): option to skip the trailing data check, useful for say streams see Jay's model

                parser.skipWhitespace()

                guard parser.pointer == parser.buffer.endAddress else { throw Error.Reason.invalidSyntax }

                return rootValue
            } catch let error as Error.Reason {

                guard let baseAddress = parser.buffer.baseAddress else { throw error }

                throw Error(byteOffset: baseAddress.distance(to: parser.pointer), reason: error)
            }
        }
    }

    public static func parse(_ string: String, options: Option = []) throws -> Node {

        let data = Array(string.utf8)

        return try JSON.Parser.parse(data, options: options)
    }

}


// MARK: - Internals

extension JSON.Parser {

    func peek(aheadBy n: Int = 0) -> UTF8.CodeUnit? {
        guard pointer.advanced(by: n) < buffer.endAddress else {
            return nil
        }
        return pointer.advanced(by: n).pointee
    }

    mutating func pop() throws -> UTF8.CodeUnit {
        guard pointer != buffer.endAddress else { throw Error.Reason.endOfStream }
        defer { pointer = pointer.advanced(by: 1) }
        return pointer.pointee
    }

    @discardableResult
    mutating func unsafePop() -> UTF8.CodeUnit {
        defer { pointer = pointer.advanced(by: 1) }
        return pointer.pointee
    }
}

extension JSON.Parser {

    mutating func skipWhitespace() {

        while pointer.pointee.isWhitespace && pointer != buffer.endAddress {

            unsafePop()
        }
    }
}

extension JSON.Parser {

    /**
     - precondition: `pointer` is at the beginning of a literal
     - postcondition: `pointer` will be in the next non-`whiteSpace` position
     */
    mutating func parseValue() throws -> Node {

        assert(!pointer.pointee.isWhitespace)

        defer { skipWhitespace() }
        switch peek() {
        case objectOpen?:

            let object = try parseObject()
            return object

        case arrayOpen?:

            let array = try parseArray()
            return array

        case quote?:

            let string = try parseString()
            return .string(string)

        case minus?, numbers?:

            let number = try parseNumber()
            return number

        case f?:

            unsafePop()
            try assertFollowedBy(alse)
            return .bool(false)

        case t?:

            unsafePop()
            try assertFollowedBy(rue)
            return .bool(true)

        case n?:

            unsafePop()
            try assertFollowedBy(ull)
            return .null

        case nil:
            throw Error.Reason.endOfStream

        default:
            throw Error.Reason.invalidSyntax
        }
    }

    mutating func assertFollowedBy(_ chars: [UTF8.CodeUnit]) throws {

        for scalar in chars {
            guard try scalar == pop() else { throw Error.Reason.invalidLiteral }
        }
    }

    mutating func parseObject() throws -> Node {

        assert(peek() == objectOpen)
        unsafePop()

        skipWhitespace()

        guard peek() != objectClose else {
            unsafePop()
            return .object([:])
        }

        var tempDict: [String: Node] = Dictionary(minimumCapacity: 6)
        var wasComma = false

        repeat {

            switch peek() {
            case comma_?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                wasComma = true
                unsafePop()
                skipWhitespace()

            case quote?:

                if tempDict.count > 0 && !wasComma {
                    throw Error.Reason.expectedComma
                }

                let key = try parseString()
                try skipColon()
                let value = try parseValue()
                wasComma = false

                switch value {
                case .null where skipNull:
                    break

                default:
                    tempDict[key] = value
                }

            case objectClose?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                unsafePop()
                return .object(tempDict)

            case nil:
                throw Error.Reason.endOfStream

            default:
                throw Error.Reason.invalidSyntax
            }
        } while true
    }

    mutating func parseArray() throws -> Node {

        assert(peek() == arrayOpen)
        unsafePop()

        skipWhitespace()

        // Saves the allocation of the tempArray
        guard peek() != arrayClose else {
            unsafePop()
            return .array([])
        }

        var tempArray: [Node] = []
        tempArray.reserveCapacity(6)

        var wasComma = false

        repeat {

            switch peek() {
            case comma_?:

                guard !wasComma else { throw Error.Reason.invalidSyntax }
                guard tempArray.count > 0 else { throw Error.Reason.invalidSyntax }

                wasComma = true
                try skipComma()

            case arrayClose?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                _ = try pop()
                return .array(tempArray)

            case nil:
                throw Error.Reason.endOfStream

            default:

                if tempArray.count > 0 && !wasComma {
                    throw Error.Reason.expectedComma
                }

                let value = try parseValue()
                skipWhitespace()
                wasComma = false

                switch value {
                case .null where skipNull:
                    if peek() == comma_ {
                        try skipComma()
                    }

                default:
                    tempArray.append(value)
                }
            }
        } while true
    }


    // TODO(vdka): No leading 0's it's against the spec.
    mutating func parseNumber() throws -> Node {

        assert(numbers ~= peek()! || minus == peek()!)

        var seenExponent = false
        var seenDecimal = false

        let negative: Bool = {
            guard minus == peek() else { return false }
            unsafePop()
            return true
        }()

        guard let next = peek(), numbers ~= next else { throw Error.Reason.invalidNumber }
        // Checks for leading zero's on numbers that are not '0' or '0.x'
        if next == zero {
            guard let following = peek(aheadBy: 1) else { return Node.number(.int(0)) }
            guard following == decimal || following.isTerminator else { throw Error.Reason.invalidNumber }
        }

        var significand: UInt64 = 0
        var mantisa: UInt64 = 0
        var divisor: Double = 10
        var exponent: UInt64 = 0
        var negativeExponent = false
        var didOverflow: Bool

        repeat {

            switch peek() {
            case numbers? where !seenDecimal && !seenExponent:

                (significand, didOverflow) = UInt64.multiplyWithOverflow(significand, 10)
                guard !didOverflow else { throw Error.Reason.numberOverflow }

                (significand, didOverflow) = UInt64.addWithOverflow(significand, UInt64(unsafePop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case numbers? where seenDecimal && !seenExponent:

                divisor *= 10

                (mantisa, didOverflow) = UInt64.multiplyWithOverflow(mantisa, 10)
                guard !didOverflow else { throw Error.Reason.numberOverflow }

                (mantisa, didOverflow) = UInt64.addWithOverflow(mantisa, UInt64(unsafePop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case numbers? where seenExponent:

                (exponent, didOverflow) = UInt64.multiplyWithOverflow(exponent, 10)
                guard !didOverflow else { throw Error.Reason.numberOverflow }

                (exponent, didOverflow) = UInt64.addWithOverflow(exponent, UInt64(unsafePop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case decimal? where !seenExponent && !seenDecimal:

                unsafePop()
                seenDecimal = true
                guard let next = peek(), numbers ~= next else { throw Error.Reason.invalidNumber }

            case E? where !seenExponent,
                     e? where !seenExponent:

                unsafePop()
                seenExponent = true

                if peek() == minus {

                    negativeExponent = true
                    unsafePop()
                } else if peek() == plus {

                    unsafePop()
                }

                guard let next = peek(), numbers ~= next else { throw Error.Reason.invalidNumber }

            case let value? where value.isTerminator:
                fallthrough

            case nil:

                return try constructNumber(
                    significand: significand,
                    mantisa: seenDecimal ? mantisa : nil,
                    exponent: seenExponent ? exponent : nil,
                    divisor: divisor,
                    negative: negative,
                    negativeExponent: negativeExponent
                )

            default:
                throw Error.Reason.invalidNumber
            }
        } while true
    }

    func constructNumber(significand: UInt64, mantisa: UInt64?, exponent: UInt64?, divisor: Double, negative: Bool, negativeExponent: Bool) throws -> Node {

        if mantisa != nil || exponent != nil {
            var divisor = divisor

            divisor /= 10

            let number = Double(negative ? -1 : 1) * (Double(significand) + Double(mantisa ?? 0) / divisor)

            if let exponent = exponent {
                return .number(.double(Double(number) * pow(10, negativeExponent ? -Double(exponent) : Double(exponent))))
            } else {
                return .number(.double(number))
            }

        } else {

            switch significand {
            case validUnsigned64BitInteger where !negative:
                return .number(.int(Int(significand)))

            case UInt64(Int64.max) + 1 where negative:
                return .number(.int(Int.min))

            case validUnsigned64BitInteger where negative:
                return .number(.int(-Int(significand)))

            default:
                throw Error.Reason.invalidNumber
            }
        }
    }

    // TODO (vdka): refactor
    // TODO (vdka): option to _repair_ Unicode
    mutating func parseString() throws -> String {

        assert(peek() == quote)
        unsafePop()

        var escaped = false
        stringBuffer.removeAll(keepingCapacity: true)

        repeat {

            let codeUnit = try pop()
            if codeUnit == backslash && !escaped {

                escaped = true
            } else if codeUnit == quote && !escaped {

                stringBuffer.append(0)
                let string = stringBuffer.withUnsafeBufferPointer { bufferPointer in
                    return String(cString: unsafeBitCast(bufferPointer.baseAddress, to: UnsafePointer<CChar>.self))
                }

                return string
            } else if escaped {

                switch codeUnit {
                case r:
                    stringBuffer.append(cr)

                case t:
                    stringBuffer.append(tab)

                case n:
                    stringBuffer.append(newline)

                case b:
                    stringBuffer.append(backspace)

                case quote:
                    stringBuffer.append(quote)

                case slash:
                    stringBuffer.append(slash)

                case backslash:
                    stringBuffer.append(backslash)

                case u:
                    let scalar = try parseUnicodeScalar()
                    var bytes: [UTF8.CodeUnit] = []
                    UTF8.encode(scalar, into: { bytes.append($0) })
                    stringBuffer.append(contentsOf: bytes)

                default:
                    throw Error.Reason.invalidEscape
                }

                escaped = false

            } else {

                stringBuffer.append(codeUnit)
            }
        } while true
    }
}

extension JSON.Parser {

    mutating func parseUnicodeEscape() throws -> UTF16.CodeUnit {

        var codeUnit: UInt16 = 0
        for _ in 0..<4 {
            let c = try pop()
            codeUnit <<= 4
            switch c {
            case numbers:
                codeUnit += UInt16(c - 48)
            case alphaNumericLower:
                codeUnit += UInt16(c - 87)
            case alphaNumericUpper:
                codeUnit += UInt16(c - 55)
            default:
                throw Error.Reason.invalidEscape
            }
        }

        return codeUnit
    }

    mutating func parseUnicodeScalar() throws -> UnicodeScalar {

        // For multi scalar Unicodes eg. flags
        var buffer: [UInt16] = []

        let codeUnit = try parseUnicodeEscape()
        buffer.append(codeUnit)

        if UTF16.isLeadSurrogate(codeUnit) {

            guard try pop() == backslash && pop() == u else { throw Error.Reason.invalidUnicode }
            let trailingSurrogate = try parseUnicodeEscape()
            buffer.append(trailingSurrogate)
        }

        var gen = buffer.makeIterator()

        var utf = UTF16()

        switch utf.decode(&gen) {
        case .scalarValue(let scalar):
            return scalar

        case .emptyInput, .error:
            throw Error.Reason.invalidUnicode
        }
    }

    mutating func skipColon() throws {
        skipWhitespace()
        guard case colon = try pop() else { throw Error.Reason.expectedColon }
        skipWhitespace()
    }

    mutating func skipComma() throws {
        skipWhitespace()
        guard case comma_ = try pop() else { throw Error.Reason.expectedComma }
        skipWhitespace()
    }
}

extension JSON.Parser {

    public struct Error: Swift.Error, Equatable {

        public var byteOffset: Int

        public var reason: Reason

        public enum Reason: Swift.Error {

            case endOfStream
            case emptyStream
            case trailingComma
            case expectedComma
            case expectedColon
            case invalidEscape
            case invalidSyntax
            case invalidNumber
            case numberOverflow
            case invalidLiteral
            case invalidUnicode
            case fragmentedJson
        }

        public static func == (lhs: JSON.Parser.Error, rhs: JSON.Parser.Error) -> Bool {
            return lhs.byteOffset == rhs.byteOffset && lhs.reason == rhs.reason
        }
    }
}

// MARK: - Stdlib extensions

extension UnsafeBufferPointer {

    var endAddress: UnsafePointer<Element> {

        return baseAddress!.advanced(by: endIndex)
    }
}

extension UTF8.CodeUnit {

    var isWhitespace: Bool {
        if self == space_ || self == tab || self == cr || self == newline || self == formfeed {
            return true
        }

        return false
    }

    var isTerminator: Bool {
        if self.isWhitespace || self == comma_ || self == objectClose || self == arrayClose {
            return true
        }

        return false
    }
}



