import Foundation

/// The Anthropic HTTP surface: the requests this module builds, and the shapes
/// it reads back (§7.1's "no vendor type escapes").
///
/// Everything in this file is `internal`. `AnthropicProvider` is the only
/// reader, no signature on it mentions one of these types, and §14 keeps
/// `AIProvider` for exactly this reason.
///
/// **The response types are top-level rather than nested inside this enum**,
/// only because each needs its own `CodingKeys` and SwiftLint caps nesting at
/// one level (`nesting`). The `Anthropic` prefix does the namespacing the
/// nesting would have.
///
/// **There is no type here for the API's error envelope, and that is a §8
/// decision rather than an omission.** `error.message` can quote the request
/// that provoked it — which, on the draft path, is the user's event log. The
/// status code and `retry-after` are everything `AnthropicErrors` needs, so the
/// body of a failed response is never decoded, never stored, and therefore
/// cannot reach a log line.
enum AnthropicWire {
    /// `anthropic-version`, the only value this module has ever sent.
    static let apiVersion = "2023-06-01"

    /// `stop_reason` values this module acts on (D-144).
    enum StopReason {
        static let refusal = "refusal"
        static let maxTokens = "max_tokens"
    }

    // MARK: - Requests

    /// `GET /v1/models`, one page (D-141).
    static func modelsRequest(baseURL: URL, apiKey: String, after cursor: String?) -> HTTPRequest {
        let endpoint = baseURL.appendingPathComponent("v1/models")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "limit", value: "1000")]
        if let cursor {
            query.append(URLQueryItem(name: "after_id", value: cursor))
        }
        components?.queryItems = query

        return HTTPRequest(
            method: .get,
            url: components?.url ?? endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
            ]
        )
    }

    /// `POST /v1/messages` (D-142).
    static func messagesRequest(baseURL: URL, apiKey: String, body: Data) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: baseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
                "content-type": "application/json",
            ],
            body: body
        )
    }

    /// §7.3's request body, and nothing else (D-142).
    ///
    /// Five keys: `model`, `max_tokens`, `system`, `messages`,
    /// `output_config`. No `thinking`, no `effort`, no sampling parameters, no
    /// `anthropic-beta` — the model id comes from a runtime list, so a
    /// parameter that is fine on one model and a 400 on another would make that
    /// model unusable from a picker that offers it, with an error the user
    /// cannot act on.
    ///
    /// **The schema is transmitted as the JSON value M3-03 authored.** It is
    /// parsed once — which is also how a schema that is not a JSON object is
    /// caught here, before a network call — and re-serialized as part of the
    /// body. Keys are sorted so that two calls with equal inputs produce equal
    /// bytes; `JSONSerialization`'s unsorted order is hash order, which differs
    /// between processes and would make a body assertion flake.
    static func messagesBody(for request: StandupRequest) throws -> Data {
        let parsed = try? JSONSerialization.jsonObject(with: request.outputSchema.json)
        guard let schema = parsed as? [String: Any] else {
            throw AIError.invalidRequest
        }

        let envelope: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.maxOutputTokens,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]

        guard
            let body = try? JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys])
        else {
            throw AIError.invalidRequest
        }
        return body
    }

    // MARK: - Helpers

    /// Parse an API timestamp, tolerating the presence or absence of fractional
    /// seconds.
    ///
    /// Two formatters rather than one: `ISO8601DateFormatter` fails outright on
    /// fractional seconds unless `.withFractionalSeconds` is set, and fails
    /// outright on their *absence* when it is. Returning `nil` rather than
    /// throwing is the point — a model whose timestamp will not parse still
    /// belongs in the picker, it just ranks by id within its family.
    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

// MARK: - Responses

/// One page of `GET /v1/models`.
///
/// The Models endpoint uses the `after_id`/`before_id` cursor scheme and
/// reports `has_more`/`first_id`/`last_id`. Both paging fields are optional
/// here: a response that omits them ends the loop, which is the behaviour this
/// module wants from a shape it does not recognise.
struct AnthropicModelsPage: Decodable {
    let data: [AnthropicModel]
    let hasMore: Bool?
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// One model, reduced to the three things D-141 ranks on.
///
/// **Decoded defensively, field by field.** A vendor response that grows a
/// field, renames one inside `capabilities`, or returns a timestamp in a shape
/// `ISO8601DateFormatter` does not accept must cost at most the ranking quality
/// of one model — never the user's whole picker. Only `id` is required.
struct AnthropicModel: Decodable, Equatable, Sendable {
    let id: String
    let displayName: String
    let createdAt: Date?

    /// `nil` when the response said nothing about it. D-141 filters on an
    /// explicit `false` only, so an unrecognised `capabilities` shape drops
    /// nothing.
    let supportsStructuredOutputs: Bool?

    init(
        id: String,
        displayName: String,
        createdAt: Date? = nil,
        supportsStructuredOutputs: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.supportsStructuredOutputs = supportsStructuredOutputs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName =
            (try? container.decodeIfPresent(String.self, forKey: .displayName)).flatMap { $0 } ?? id
        createdAt = AnthropicWire.timestamp(
            (try? container.decodeIfPresent(String.self, forKey: .createdAt)).flatMap { $0 })
        let capabilities =
            (try? container.decodeIfPresent(AnthropicCapabilities.self, forKey: .capabilities))
            .flatMap { $0 }
        supportsStructuredOutputs = capabilities?.structuredOutputs?.supported
    }
}

/// The subtree of `capabilities` D-141 reads, and no more.
struct AnthropicCapabilities: Decodable {
    let structuredOutputs: AnthropicCapabilityFlag?

    private enum CodingKeys: String, CodingKey {
        case structuredOutputs = "structured_outputs"
    }
}

/// One `{"supported": Bool}` leaf. Optional, so a leaf that grows a different
/// shape reads as "said nothing" rather than failing the page.
struct AnthropicCapabilityFlag: Decodable {
    let supported: Bool?
}

/// `POST /v1/messages`, reduced to what §7.3 and §8 read.
struct AnthropicMessagesResponse: Decodable {
    let content: [AnthropicContentBlock]
    let stopReason: String?
    let usage: AnthropicUsage?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }
}

/// One block of a response's `content` array.
struct AnthropicContentBlock: Decodable {
    let type: String
    let text: String?
}

/// §8's "token counts".
///
/// Both optional: a response that reported no usage and one that reported zero
/// are different facts (D-137).
struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
