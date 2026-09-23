import Foundation

/// §7.3's two output schemas, selected by `project.reportCadence` (D17).
///
/// **They are not cosmetic variants of each other** — §7.3's words. The
/// sections differ, and so does the cardinality of the task reference:
/// `daily` carries `task_id`, `periodic` carries `task_ids`, and that plural
/// is what licenses a themed bullet to span several tasks while the app can
/// still link it back to every one of them.
///
/// **`task_id` is a plain string, not an `enum` of the ids the app sent**
/// (D-149). Constraining it would make a hallucinated id impossible to express
/// — but a model that has invented a sentence still emits that sentence, now
/// attached to a real task, and the user reads a fabricated claim aloud under a
/// correct attribution. §7.3 wants the opposite: "a hallucinated ID is the
/// clearest possible signal the model invented a fact, and it should fail
/// loudly into the §7.4 fallback rather than render."
///
/// **`format: "uuid"` is set, which is a different question from D-149.** The
/// Anthropic structured-output subset supports the `uuid` string format, and
/// constraining the *shape* of an id costs nothing and keeps a malformed UUID
/// out of `StandupDraft.decode`, where it would arrive as a schema violation
/// with no way to tell it from an invented section. Constraining *which* ids
/// are allowed is the thing D-149 rejects, and nothing here does that.
///
/// **Written as literals rather than assembled through `JSONSerialization`.**
/// The assembled version has to be `try`-ed at a call site where it cannot
/// fail, and its key order is an argument about options rather than something
/// a reader can see. A literal is greppable, diffable, byte-stable by
/// construction, and is checked by `StandupSchemaTests` parsing it back.
public enum StandupSchema {
    /// The schema this cadence's response is constrained to.
    public static func schema(for cadence: ReportCadence) -> AIOutputSchema {
        switch cadence {
        case .daily:
            AIOutputSchema(name: "standup_daily", json: Data(daily.utf8))
        case .periodic:
            AIOutputSchema(name: "standup_periodic", json: Data(periodic.utf8))
        }
    }

    /// §7.3's `daily` schema: one bullet per task, three DSU sections.
    ///
    /// `additionalProperties: false` throughout, and every section required:
    /// a response missing `blockers` is a schema violation rather than an empty
    /// section, because "no blockers" is a thing the model must say rather than
    /// omit.
    static let daily = """
        {
          "additionalProperties": false,
          "properties": {
            "blockers": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "since_last_standup": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "today": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" }
          },
          "required": ["since_last_standup", "today", "blockers"],
          "type": "object",
          "$defs": {
            "bullet": {
              "additionalProperties": false,
              "properties": {
                "task_id": { "format": "uuid", "type": "string" },
                "text": { "type": "string" }
              },
              "required": ["task_id", "text"],
              "type": "object"
            }
          }
        }
        """

    /// §7.3's `periodic` schema: themed bullets that may each span several
    /// tasks, hence `task_ids`.
    static let periodic = """
        {
          "additionalProperties": false,
          "properties": {
            "blockers_and_risks": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "completed": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "in_flight": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" }
          },
          "required": ["completed", "in_flight", "blockers_and_risks"],
          "type": "object",
          "$defs": {
            "bullet": {
              "additionalProperties": false,
              "properties": {
                "task_ids": { "items": {"format": "uuid", "type": "string"}, "type": "array" },
                "text": { "type": "string" }
              },
              "required": ["task_ids", "text"],
              "type": "object"
            }
          }
        }
        """
}
