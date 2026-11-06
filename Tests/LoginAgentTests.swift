import Foundation

@main struct LoginAgentTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agent.plist")
        let executable = "/Applications/Mac合盖和显示器联动助手.app/Contents/MacOS/MacDisplaySwitch"
        let legacy = "/Applications/Mac合盖和显示器联动助手.app/Contents/MacOS/LGLidSwitch"
        func write(_ plist: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }
        try refreshLoginAgentExecutable(at: url, executable: executable)
        precondition(!FileManager.default.fileExists(atPath: url.path), "upgrade must not enable a disabled login item")
        let old: [String: Any] = ["Label": "com.xiaopomao.LGLidSwitch", "ProgramArguments": [legacy, "--settings"], "RunAtLoad": true, "CustomSetting": "preserved"]
        try write(old)
        try refreshLoginAgentExecutable(at: url, executable: executable)
        let migrated = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
        precondition(migrated["ProgramArguments"] as? [String] == [executable, "--settings"])
        precondition(migrated["CustomSetting"] as? String == "preserved" && migrated["RunAtLoad"] as? Bool == true)
        let migratedData = try Data(contentsOf: url)
        try refreshLoginAgentExecutable(at: url, executable: executable)
        let repeatedData = try Data(contentsOf: url)
        precondition(repeatedData == migratedData, "already migrated item must remain byte-identical")
        for (label, arguments) in [("another.app", [legacy]), ("com.xiaopomao.LGLidSwitch", ["/another/location/LGLidSwitch"]), ("com.xiaopomao.LGLidSwitch", [])] {
            try write(["Label": label, "ProgramArguments": arguments])
            let original = try Data(contentsOf: url)
            try refreshLoginAgentExecutable(at: url, executable: executable)
            let unchanged = try Data(contentsOf: url)
            precondition(unchanged == original, "unrelated or malformed entry must remain unchanged")
        }
        try writeLoginAgent(to: url, executable: executable)
        let created = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
        precondition(created["ProgramArguments"] as? [String] == [executable])
        precondition(created["Label"] as? String == "com.xiaopomao.LGLidSwitch")
        print("Login startup upgrade checks passed")
    }
}
