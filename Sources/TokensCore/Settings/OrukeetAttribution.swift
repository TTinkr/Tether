import Foundation

/*
Orukeet's weights are licensed CC BY-SA 4.0, so every place Tokens names or lists the model
credits Oruk with the license and a link to the model page. One source for the wording keeps
Settings, About and any later notice in agreement; tests hold the exact strings.
*/
public enum OrukeetAttribution {
    public static let line = "Orukeet by Oruk, CC BY-SA 4.0"
    public static let license = "CC BY-SA 4.0"
    public static let modelPage = URL(string: "https://huggingface.co/oruk/orukeet")!
    public static let licensePage = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    /// The Settings engine row's help text.
    public static let engineCaption = "\(line). Runs as a local model on this Mac. The choice applies to your next talk."
}
