import Foundation
import SwiftData

@testable import StenoKit

/// An in-memory store for tests that need a live context.
///
/// A thin alias for the shipped factory, kept because three files call it. The
/// model list that used to live here is gone: M0-04 shipped
/// `StenoStore.models()`, and a second list here would be a second declaration
/// of the schema that the application's container could silently disagree with.
func inMemoryContainer() throws -> ModelContainer {
    try StenoStore.inMemory()
}
