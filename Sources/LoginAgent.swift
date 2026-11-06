import Foundation

// Preserve the existing label so upgrades do not create a second login item.
func writeLoginAgent(to url: URL, executable: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = ["Label": "com.xiaopomao.LGLidSwitch", "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
}

func refreshLoginAgentExecutable(at url: URL, executable: String) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let data = try Data(contentsOf: url)
    guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          plist["Label"] as? String == "com.xiaopomao.LGLidSwitch",
          var arguments = plist["ProgramArguments"] as? [String] else { return }
    let legacy = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("LGLidSwitch").path
    guard arguments.first == legacy else { return }
    arguments[0] = executable
    plist["ProgramArguments"] = arguments
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
}
