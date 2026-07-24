/// Versioned-by-type wire contract shared by the phone and watch transports.
///
/// A single Codable message avoids maintaining one JSON payload for ticks and
/// an unrelated dictionary payload for control messages.
public enum SessionMessage: Equatable, Sendable, Codable {
    case output(EngineOutput)
    case stop
}
