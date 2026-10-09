import CryptoKit
import Foundation

/// A reviewer returns a decision about a frozen native request; it never gains
/// execution authority. The model owns one-shot consumption and target revalidation.
enum TerminalAIApprovalReview {
    static let maximumRequestBytes = 1_048_576
    static let maximumVerdictBytes = 16_384

    struct Target: Codable, Equatable, Sendable {
        let surfaceID: String?
        let host: String
        let directory: String
        let taskID: String?

        init(surfaceID: String? = nil, host: String, directory: String, taskID: String? = nil) {
            self.surfaceID = surfaceID
            self.host = host
            self.directory = directory
            self.taskID = taskID
        }
    }

    struct Context: Codable, Equatable, Sendable {
        /// Only original human messages captured by the native UI belong here.
        let userMessages: [String]
        let target: Target
    }

    struct Action: Encodable, Equatable, Sendable {
        enum Kind: String, Encodable, Sendable { case terminal, file }
        let kind: Kind
        let command: String?
        let reason: String?
        let timeoutSeconds: Int?
        let path: String?
        let diff: String?
        let contentSHA256: String?
        let originalSHA256: String?

        static func terminal(command: String, reason: String, timeoutSeconds: Int) -> Self {
            Self(kind: .terminal, command: command, reason: reason, timeoutSeconds: timeoutSeconds,
                 path: nil, diff: nil, contentSHA256: nil, originalSHA256: nil)
        }

        static func file(path: String, diff: String, contentSHA256: String, originalSHA256: String? = nil) -> Self {
            Self(kind: .file, command: nil, reason: nil, timeoutSeconds: nil,
                 path: path, diff: diff, contentSHA256: contentSHA256, originalSHA256: originalSHA256)
        }

        fileprivate var isComplete: Bool {
            switch kind {
            case .terminal:
                return command?.isEmpty == false && (command?.utf8.count ?? 0) <= 65_536 &&
                    (timeoutSeconds ?? 0) > 0
            case .file:
                return path?.hasPrefix("/") == true && diff != nil &&
                    contentSHA256.map(validSHA256) == true &&
                    (originalSHA256 == nil || originalSHA256.map(validSHA256) == true)
            }
        }
    }

    struct Request: Encodable, Equatable, Sendable {
        let version = 1
        let reviewId: String
        let nonce: String
        let actionDigest: String
        let generation: String
        let context: Context
        let action: Action
        let evidenceComplete: Bool
        /// Evidence from native scope checks, never the executor's explanation.
        let narrowScopeEvidence: String?

        init(context: Context, action: Action, generation: String, evidenceComplete: Bool = true,
             narrowScopeEvidence: String? = nil) throws {
            reviewId = UUID().uuidString
            nonce = UUID().uuidString
            self.generation = generation
            self.context = context
            self.action = action
            self.evidenceComplete = evidenceComplete
            self.narrowScopeEvidence = narrowScopeEvidence
            let payload = DigestPayload(generation: generation, context: context, action: action,
                                        evidenceComplete: evidenceComplete, narrowScopeEvidence: narrowScopeEvidence)
            actionDigest = sha256(try canonicalData(payload))
        }

        var canReview: Bool {
            evidenceComplete && action.isComplete && !generation.isEmpty &&
                !context.target.host.isEmpty && !context.target.directory.isEmpty
        }

        func base64Argument() throws -> String {
            guard canReview else { throw issue("The review evidence is incomplete. Use individual approval.") }
            let data = try canonicalData(self)
            guard data.count <= maximumRequestBytes else {
                throw issue("The complete action exceeds the review limit. Use individual approval.")
            }
            return data.base64EncodedString()
        }
    }

    enum Risk: String, Codable, Sendable { case low, medium, high, critical }
    enum Authorization: String, Codable, Sendable { case unknown, low, medium, high }
    enum Outcome: String, Codable, Sendable { case allow, deny }

    struct Assessment: Equatable, Sendable {
        let riskLevel: Risk
        let userAuthorization: Authorization
        let outcome: Outcome
        let rationale: String
    }

    enum Decision: Equatable, Sendable {
        case approve(Assessment)
        case deny(Assessment)
        case ask(String)
    }

    /// A late verdict must not consume a different pending review, even as a fallback.
    static func hasMatchingIdentity(_ json: String?, for request: Request) -> Bool {
        guard let json, json.utf8.count <= maximumVerdictBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
        return object["version"] as? Int == request.version && object["reviewId"] as? String == request.reviewId &&
            object["nonce"] as? String == request.nonce && object["actionDigest"] as? String == request.actionDigest &&
            object["generation"] as? String == request.generation
    }

    /// Accepts only the private response envelope and Codex's assessment fields.
    /// A nil result is a timeout/cancellation, never implied approval.
    static func verify(_ json: String?, for request: Request) -> Decision {
        guard request.canReview, (try? request.base64Argument()) != nil else {
            return .ask("The complete action and target must be available before automatic review.")
        }
        guard let json, !json.isEmpty, json.utf8.count <= maximumVerdictBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              stringTokenCount(json) == expectedStringTokenCount(object) else {
            return .ask("The automatic approval review returned no valid result.")
        }
        let envelopeKeys: Set<String> = ["version", "reviewId", "nonce", "actionDigest", "generation"]
        let keys = Set(object.keys)
        guard keys == envelopeKeys.union(["assessment"]) || keys == envelopeKeys.union(["error"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
              envelope.version == request.version, envelope.reviewId == request.reviewId,
              envelope.nonce == request.nonce, envelope.actionDigest == request.actionDigest,
              envelope.generation == request.generation else {
            return .ask("The review result does not match the pending action.")
        }
        if let error = envelope.error {
            guard !error.isEmpty, error.utf8.count <= 4_096 else {
                return .ask("The automatic approval review failed.")
            }
            return .ask(error)
        }
        guard let fields = object["assessment"] as? [String: Any],
              Set(fields.keys).isSubset(of: ["risk_level", "user_authorization", "outcome", "rationale"]),
              fields.values.allSatisfy({ $0 is String }), let payload = envelope.assessment,
              (payload.rationale?.utf8.count ?? 0) <= 4_096 else {
            return .ask("The automatic approval assessment is invalid.")
        }
        let risk = payload.riskLevel ?? (payload.outcome == .allow ? .low : .high)
        let authorization = payload.userAuthorization ?? .unknown
        let rationale = payload.rationale.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (payload.outcome == .allow ? "Auto-review allowed the action." : "Auto-review denied the action.")
        let assessment = Assessment(riskLevel: risk, userAuthorization: authorization,
                                    outcome: payload.outcome, rationale: rationale)
        if risk == .critical {
            return .deny(Assessment(riskLevel: risk, userAuthorization: authorization, outcome: .deny,
                                    rationale: "The review classified this action as critical risk."))
        }
        guard payload.outcome == .allow else { return .deny(assessment) }
        if risk == .high {
            guard authorization == .medium || authorization == .high,
                  request.context.userMessages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  request.narrowScopeEvidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return .ask("This high-risk action needs individual approval or verified narrow scope.")
            }
        }
        return .approve(assessment)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct DigestPayload: Encodable {
        let generation: String
        let context: Context
        let action: Action
        let evidenceComplete: Bool
        let narrowScopeEvidence: String?
    }

    private struct Envelope: Decodable {
        let version: Int
        let reviewId: String
        let nonce: String
        let actionDigest: String
        let generation: String
        let assessment: AssessmentPayload?
        let error: String?
    }

    private struct AssessmentPayload: Decodable {
        let riskLevel: Risk?
        let userAuthorization: Authorization?
        let outcome: Outcome
        let rationale: String?

        enum CodingKeys: String, CodingKey {
            case riskLevel = "risk_level", userAuthorization = "user_authorization", outcome, rationale
        }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Foundation accepts trailing commas and discards duplicate object keys.
    /// Count tokens against the decoded tree to reject discarded/escaped keys.
    private static func stringTokenCount(_ json: String) -> Int {
        var count = 0
        var inString = false
        var escaped = false
        var previous: UInt8?
        for byte in json.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
            } else if byte == 34 {
                count += 1
                inString = true
                previous = byte
            } else if ![9, 10, 13, 32].contains(byte) {
                if (byte == 125 || byte == 93) && previous == 44 { return -1 }
                previous = byte
            }
        }
        return count
    }

    private static func expectedStringTokenCount(_ value: Any) -> Int {
        if let object = value as? [String: Any] {
            return object.count + object.values.reduce(0) { $0 + expectedStringTokenCount($1) }
        }
        if let array = value as? [Any] { return array.reduce(0) { $0 + expectedStringTokenCount($1) } }
        return value is String ? 1 : 0
    }

    private static func issue(_ message: String) -> NSError {
        NSError(domain: "GhosttyAIApprovalReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
