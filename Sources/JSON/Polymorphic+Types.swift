import Mapper


extension Polymorphic {
    public var float: Float? {
        guard let double = self.double else {
            return nil
        }

        return Float(double)
    }

    public func assertFloat() throws -> Float {
        guard let float = self.float else {
            throw PolymorphicError.unableToConvert(self, to: Float.self)
        }

        return float
    }

    public var int8: Int8? {
        guard let int = self.int else {
            return nil
        }

        guard int <= Int8.max else {
            return nil
        }

        return Int8(int)
    }

    public func assertInt8() throws -> Int8 {
        guard let int8 = self.int8 else {
            throw PolymorphicError.unableToConvert(self, to: Int8.self)
        }

        return int8
    }

    public var int16: Int16? {
        guard let int = self.int else {
            return nil
        }

        guard int <= Int16.max else {
            return nil
        }

        return Int16(int)
    }

    public func assertInt16() throws -> Int16 {
        guard let int16 = self.int16 else {
            throw PolymorphicError.unableToConvert(self, to: Int16.self)
        }

        return int16
    }

    public var int32: Int32? {
        guard let int = self.int else {
            return nil
        }

        guard int <= Int32.max else {
            return nil
        }

        return Int32(int)
    }

    public func assertInt32() throws -> Int32 {
        guard let int32 = self.int32 else {
            throw PolymorphicError.unableToConvert(self, to: Int32.self)
        }

        return int32
    }

    public var int64: Int64? {
        guard let int = self.int else {
            return nil
        }

        guard int <= Int64.max else {
            return nil
        }

        return Int64(int)
    }

    public func assertInt64() throws -> Int64 {
        guard let int64 = self.int64 else {
            throw PolymorphicError.unableToConvert(self, to: Int64.self)
        }

        return int64
    }

    public var uint: UInt? {
        guard let int = self.int else {
            return nil
        }

        guard int >= 0 else {
            return nil
        }

        return UInt(int)
    }

    public func assertUInt() throws -> UInt {
        guard let uint = self.uint else {
            throw PolymorphicError.unableToConvert(self, to: UInt.self)
        }

        return uint
    }

    public var uint8: UInt8? {
        guard let uint = self.uint else {
            return nil
        }

        guard uint <= UInt8.max else {
            return nil
        }

        return UInt8(uint)
    }

    public func assertUInt8() throws -> UInt8 {
        guard let uint8 = self.uint8 else {
            throw PolymorphicError.unableToConvert(self, to: UInt8.self)
        }

        return uint8
    }

    public var uint16: UInt16? {
        guard let uint = self.uint else {
            return nil
        }

        guard uint <= UInt16.max else {
            return nil
        }

        return UInt16(uint)
    }

    public func assertUInt16() throws -> UInt16 {
        guard let uint16 = self.uint16 else {
            throw PolymorphicError.unableToConvert(self, to: UInt16.self)
        }

        return uint16
    }

    public var uint32: UInt32? {
        guard let uint = self.uint else {
            return nil
        }

        guard uint <= UInt32.max else {
            return nil
        }

        return UInt32(uint)
    }

    public func assertUInt32() throws -> UInt32 {
        guard let uint32 = self.uint32 else {
            throw PolymorphicError.unableToConvert(self, to: UInt32.self)
        }

        return uint32
    }

    public var uint64: UInt64? {
        guard let uint = self.uint else {
            return nil
        }

        guard uint <= UInt64.max else {
            return nil
        }

        return UInt64(uint)
    }

    public func assertUInt64() throws -> UInt64 {
        guard let uint64 = self.uint64 else {
            throw PolymorphicError.unableToConvert(self, to: UInt64.self)
        }

        return uint64
    }
}

