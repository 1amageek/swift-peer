import Foundation
import GRPCCore

// MARK: - Generic Message Serializer

/// Serializes Codable messages to JSON bytes for gRPC transport.
struct MessageSerializer<Message: Codable & Sendable>: GRPCCore.MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
        let data = try JSONEncoder().encode(message)
        return Bytes(data)
    }
}

// MARK: - Generic Message Deserializer

/// Deserializes JSON bytes to Codable messages from gRPC transport.
struct MessageDeserializer<Message: Codable & Sendable>: GRPCCore.MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> Message {
        let data = serializedMessageBytes.withUnsafeBytes { Data($0) }
        return try JSONDecoder().decode(Message.self, from: data)
    }
}
