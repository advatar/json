/**
 The MIT License (MIT)

 Copyright (c) 2016 Ethan Jackwitz

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

import Core
import libc
import Node

extension JSON {
    public init(
        serialized: Bytes,
        allowComments: Bool = true,
        omitNulls: Bool = true,
        allowFragments: Bool = true
    ) throws {
        var options: Parser.Option = []

        if omitNulls {
            options.insert(.omitNulls)
        }

        if allowFragments {
            options.insert(.allowFragments)
        }

        if allowComments {
            options.insert(.allowComments)
        }

        let node = try JSON.Parser.parse(serialized, options: options)
        self = node
    }
}

// MARK https://raw.githubusercontent.com/vdka/JSON/master/Sources/JSONCore/JSONParser.swift 0.10.0

// MARK: - JSON.Parser

extension JSON {

    public struct Parser {

        public struct Option: OptionSet {
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            public let rawValue: UInt8

            /// Omit null values from `JSON.object`s & `JSON.array`s
            public static let omitNulls       = Option(rawValue: 0b0001)

            /// Allows Parser to return top level objects that are not container types `{}` | `[]` as per RFC7159
            public static let allowFragments  = Option(rawValue: 0b0010)

            /// Allow the Parser to remove comments
            public static let allowComments   = Option(rawValue: 0b0100)
        }

        let omitNulls: Bool
        let allowComments: Bool

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

        self.omitNulls = options.contains(.omitNulls)
        self.allowComments = options.contains(.allowComments)
    }
}


// MARK: - Public API

extension JSON.Parser {

    public static func parse(_ data: Bytes, options: Option = []) throws -> JSON {

        return try data.withUnsafeBufferPointer { bufferPointer in

            var parser = try JSON.Parser(bufferPointer: bufferPointer, options: options)

            parser.skipWhitespace()
            if options.contains(.allowComments) {
                _ = try? parser.skipComments()
            }
            parser.skipWhitespace()

            do {

                if !options.contains(.allowFragments) {
                    // if we don't allow fragments then ensure the first token is opening an Array or an Object
                    guard let firstToken = parser.peek(), firstToken == objectOpen || firstToken == arrayOpen else {
                        throw Error.Reason.fragmentedJson
                    }
                }

                let rootValue = try parser.parseValue()

                // TODO (vkda): option to skip the trailing data check, useful for say streams see Jay's model

                parser.skipWhitespace()
                if options.contains(.allowComments) {
                    _ = try? parser.skipComments()
                }
                parser.skipWhitespace()

                guard parser.pointer == parser.buffer.endAddress else { throw Error.Reason.invalidSyntax }

                return rootValue
            } catch let error as Error.Reason {

                // We unwrap here because on we do this check prior to the do { } catch { } block.
                throw Error(byteOffset: parser.buffer.baseAddress!.distance(to: parser.pointer), reason: error)
            }
        }
    }

    public static func parse(_ string: String, options: Option = []) throws -> JSON {

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

    /// - Precondition: pointer != buffer.endAddress. It is assumed before calling pop that you have
    @discardableResult
    mutating func pop() -> UTF8.CodeUnit {
        assert(pointer != buffer.endAddress)
        defer { pointer = pointer.advanced(by: 1) }
        // print("Pop: \(Bytes([pointer.pointee]).string)")
        return pointer.pointee
    }
}

extension JSON.Parser {

    mutating func skipWhitespace() {

        while pointer.pointee.isWhitespace && pointer != buffer.endAddress {

            pop()
        }
    }

    /// - Precondition: peek() == slash
    /// - Postcondition: Both comments and whitespace will be skipped and peek() *will* be at the next meaningfull token
    mutating func skipComments() throws {
        // Pop off the first slash
        guard let char = peek(), char == slash else { throw Error.Reason.invalidSyntax }
        pop()

        // ensure we have a second character
        guard let next = peek() else { throw Error.Reason.invalidSyntax }

        if next == slash {
            while let next = peek() {
                pop()
                if next == newline {
                    break
                }
            }
            skipWhitespace()
            return
        }
        if next == star {
            while let next = peek() {
                pop()

                if next == star && peek() == slash {
                    pop()
                    break
                }
            }
            skipWhitespace()
            return
        }

        throw Error.Reason.invalidSyntax
    }
}

extension JSON.Parser {

    /**
     - precondition: `pointer` is at the beginning of a literal
     - postcondition: `pointer` will be in the next non-`whiteSpace` position
     */
    mutating func parseValue() throws -> JSON {

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
            return JSON(.string(string))

        case minus?, numbers?:

            let number = try parseNumber()
            return number

        case f?:

            pop()
            try assertFollowedBy(alse)
            return JSON(.bool(false))

        case t?:

            pop()
            try assertFollowedBy(rue)
            return JSON(.bool(true))

        case n?:

            pop()
            try assertFollowedBy(ull)
            return JSON(.null)

        case slash? where allowComments:
            try skipComments()
            return try parseValue()

        default:
            throw Error.Reason.invalidSyntax
        }
    }

    mutating func assertFollowedBy(_ chars: [UTF8.CodeUnit]) throws {

        for scalar in chars {
            guard scalar == pop() else { throw Error.Reason.invalidLiteral }
        }
    }

    mutating func parseObject() throws -> JSON {

        assert(peek() == objectOpen)
        pop()

        skipWhitespace()

        guard peek() != objectClose else {
            pop()
            return JSON(.object([:]))
        }

        var tempDict: [String: Node] = Dictionary(minimumCapacity: 6)
        var wasComma = false

        repeat {

            switch peek() {
            case cma?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                wasComma = true
                pop()
                skipWhitespace()

            case quote?:

                if tempDict.count > 0 && !wasComma {
                    throw Error.Reason.expectedComma
                }

                let key = try parseString()
                skipWhitespace()
                guard pop() == colon else { throw Error.Reason.expectedColon }
                skipWhitespace()
                let value = try parseValue()
                wasComma = false

                switch value.node {
                case .null where omitNulls:
                    break

                default:
                    tempDict[key] = value.node
                }

            case objectClose?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                pop()
                return JSON(.object(tempDict))

            default:
                throw Error.Reason.invalidSyntax
            }
        } while true
    }

    mutating func parseArray() throws -> JSON {

        assert(peek() == arrayOpen)
        pop()

        skipWhitespace()

        // Saves the allocation of the tempArray
        guard peek() != arrayClose else {
            pop()
            return JSON(.array([]))
        }

        var tempArray: [Node] = []
        tempArray.reserveCapacity(6)

        var wasComma = false

        repeat {

            switch peek() {
            case cma?:

                guard !wasComma else { throw Error.Reason.invalidSyntax }
                guard tempArray.count > 0 else { throw Error.Reason.invalidSyntax }

                wasComma = true
                try skipComma()

            case arrayClose?:

                guard !wasComma else { throw Error.Reason.trailingComma }

                _ = pop()
                return JSON(.array(tempArray))

            case nil:
                throw Error.Reason.endOfStream

            default:

                if tempArray.count > 0 && !wasComma {
                    throw Error.Reason.expectedComma
                }

                let value = try parseValue()
                skipWhitespace()
                wasComma = false

                switch value.node {
                case .null where omitNulls:
                    if peek() == cma {
                        try skipComma()
                        wasComma = true
                    }

                default:
                    tempArray.append(value.node)
                }
            }
        } while true
    }

    mutating func parseNumber() throws -> JSON {

        assert(numbers ~= peek()! || minus == peek()!)

        var seenExponent = false
        var seenDecimal = false

        let negative: Bool = {
            guard minus == peek() else { return false }
            pop()
            return true
        }()

        guard let next = peek(), numbers ~= next else { throw Error.Reason.invalidNumber }
        // Checks for leading zero's on numbers that are not '0' or '0.x'
        if next == zero {
            guard let following = peek(aheadBy: 1) else {
                pop()
                return JSON(.number(.int(0)))
            }
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

                (significand, didOverflow) = UInt64.addWithOverflow(significand, UInt64(pop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case numbers? where seenDecimal && !seenExponent:

                divisor *= 10

                (mantisa, didOverflow) = UInt64.multiplyWithOverflow(mantisa, 10)
                guard !didOverflow else { throw Error.Reason.numberOverflow }

                (mantisa, didOverflow) = UInt64.addWithOverflow(mantisa, UInt64(pop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case numbers? where seenExponent:

                (exponent, didOverflow) = UInt64.multiplyWithOverflow(exponent, 10)
                guard !didOverflow else { throw Error.Reason.numberOverflow }

                (exponent, didOverflow) = UInt64.addWithOverflow(exponent, UInt64(pop() - zero))
                guard !didOverflow else { throw Error.Reason.numberOverflow }

            case decimal? where !seenExponent && !seenDecimal:

                pop()
                seenDecimal = true
                guard let next = peek(), numbers ~= next else { throw Error.Reason.invalidNumber }

            case E? where !seenExponent,
                 e? where !seenExponent:

                pop()
                seenExponent = true

                if peek() == minus {

                    negativeExponent = true
                    pop()
                } else if peek() == plus {

                    pop()
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

    func constructNumber(significand: UInt64, mantisa: UInt64?, exponent: UInt64?, divisor: Double, negative: Bool, negativeExponent: Bool) throws -> JSON {

        if mantisa != nil || exponent != nil {
            var divisor = divisor

            divisor /= 10

            let number = Double(negative ? -1 : 1) * (Double(significand) + Double(mantisa ?? 0) / divisor)

            guard let exponent = exponent else { return JSON(.number(.double(number))) }
            return JSON(.number(.double(Double(number) * pow(10, negativeExponent ? -Double(exponent) : Double(exponent)))))
        } else {

            switch significand {
            case validUnsigned64BitInteger where !negative:
                return JSON(.number(.int(Int(significand))))

            case UInt64(Int64.max) + 1 where negative:
                return JSON(.number(.int(Int.min)))

            case validUnsigned64BitInteger where negative:
                return JSON(.number(.int(-Int(significand))))

            default:
                throw Error.Reason.numberOverflow
            }
        }
    }

    // TODO (vdka): refactor
    // TODO (vdka): option to _repair_ Unicode
    // NOTE(vdka): Not sure I ever will get to refactoring this, I just don't find Swift's String _comfortable_ to work with at a byte level.
    mutating func parseString() throws -> String {

        assert(peek() == quote)
        pop()

        var escaped = false
        stringBuffer.removeAll(keepingCapacity: true)

        repeat {

            let codeUnit = pop()
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
                    
                case f:
                    stringBuffer.append(formfeed)
                    
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
            let c = pop()
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
            
            guard pop() == backslash && pop() == u else { throw Error.Reason.endOfStream }
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
    
    /// - Precondition: pointer will be on a comma character.
    mutating func skipComma() throws {
        assert(peek() == cma)
        pop()
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
        if self == spc || self == tab || self == cr || self == newline || self == formfeed {
            return true
        }
        
        return false
    }
    
    var isTerminator: Bool {
        if self.isWhitespace || self == cma || self == objectClose || self == arrayClose {
            return true
        }
        
        return false
    }
}
