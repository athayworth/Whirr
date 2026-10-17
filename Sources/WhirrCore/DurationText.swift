import Foundation

/// The one way Whirr writes a duration for people: "45 s", "17 min",
/// "1 h 10 min" — never "999 seconds".
public enum DurationText {
    public static func words(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = s % 3600 / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
