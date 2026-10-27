import Cocoa

struct WorkflowShortcut: Codable {
    var kind:String?
    var id: String?
    var label: String
    var detail: String?
    var path: String?
    var application: String?
    var bundleIdentifier: String?
    var url: String?
}
struct WorkflowMusic: Codable {
    var provider: String
    var url: String?
    var displayName: String {
        switch provider {case "spotify":return "Spotify";case "appleMusic":return "Apple Music";case "soundcloud":return "SoundCloud";default:return "Music link"}
    }
    var appBundleID: String? {provider == "spotify" ? "com.spotify.client" : provider == "appleMusic" ? "com.apple.Music" : nil}
    var appScriptName: String? {provider == "spotify" ? "Spotify" : provider == "appleMusic" ? "Music" : nil}
    var webURL: URL? {
        if let text=url,!text.isEmpty,let target=URL(string:text),["https","http","spotify","music"].contains(target.scheme?.lowercased() ?? "") {return target}
        if provider == "soundcloud" {return URL(string:"https://soundcloud.com/")}
        return nil
    }
}
struct WorkflowCard: Codable {
    var id:String
    var title:String
    var color:String?
    var shortcuts:[WorkflowShortcut]
}
struct WorkflowConfiguration: Codable {
    var customCards:[WorkflowCard]?
    var cardTitles:[String:String]?
    var cardColors:[String:String]?
    var desktopLabels:[String:String]?
    var desktopGroups:[String:String]?
    var allSections:[String:[WorkflowShortcut]] {var result=sections;for card in customCards ?? []{result[card.id]=card.shortcuts};return result}
    var schemaVersion: Int
    var workspaceName: String
    var music: WorkflowMusic
    var sections: [String:[WorkflowShortcut]]
    var folderGroups: [String:[String]]?
    static var starter: WorkflowConfiguration {
        WorkflowConfiguration(schemaVersion:1,workspaceName:"Your workspace",music:WorkflowMusic(provider:"spotify"),sections:[
            "projects":[WorkflowShortcut(id:"projects-folder",label:"Projects",detail:"Your project folders",path:"~/Documents"),WorkflowShortcut(id:"downloads-folder",label:"Downloads",path:"~/Downloads")],
            "ai":[WorkflowShortcut(id:"chatgpt",label:"ChatGPT",application:"ChatGPT",bundleIdentifier:"com.openai.codex"),WorkflowShortcut(id:"claude",label:"Claude",application:"Claude",bundleIdentifier:"com.anthropic.claudefordesktop"),WorkflowShortcut(id:"cursor",label:"Cursor",application:"Cursor")],
            "creative":[WorkflowShortcut(id:"safari",label:"Safari",bundleIdentifier:"com.apple.Safari"),WorkflowShortcut(id:"notes",label:"Notes",bundleIdentifier:"com.apple.Notes")],
            "systems":[],
            "links":[WorkflowShortcut(id:"web-github",label:"GitHub",url:"https://github.com/"),WorkflowShortcut(id:"web-google",label:"Google",url:"https://www.google.com/"),WorkflowShortcut(id:"web-youtube",label:"YouTube",url:"https://www.youtube.com/")]
        ],folderGroups:["Client work":["client","work"],"Brands & business":["brand","business"],"Apps & systems":["app","system","build","code"],"Creative & media":["film","design","photo","media","music","screenshot","recording"],"Personal & school":["personal","school","study"]])
    }
    func validate() throws {
        guard schemaVersion == 1 else {throw ConfigError.invalid("Use schemaVersion 1.")}
        guard !workspaceName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw ConfigError.invalid("Give your workspace a name.")}
        guard ["spotify","appleMusic","soundcloud","custom"].contains(music.provider) else {throw ConfigError.invalid("Unknown music provider.")}
        if music.provider == "custom",music.webURL == nil {throw ConfigError.invalid("A custom music service needs a valid link.")}
        var cardIDs=Set<String>()
        guard (customCards ?? []).count<=20 else{throw ConfigError.invalid("Use up to 20 custom cards.")}
        for card in customCards ?? [] {
            guard card.id.range(of:"^custom-[A-Za-z0-9_-]+$",options:.regularExpression) != nil,!cardIDs.contains(card.id),!card.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw ConfigError.invalid("Custom cards need a unique custom- id and a title.")}
            cardIDs.insert(card.id)
        }
        var ids=Set<String>()
        for group in allSections.keys {
            for (index,item) in (allSections[group] ?? []).enumerated() {
                let id=item.id ?? "\(group)-\(index)"
                guard !id.isEmpty,id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil,!["restore","connect","playpause","openConfig","importConfig","music-open","refreshFiles","openDesktop","addDesktopFiles"].contains(id),!ids.contains(id) else {throw ConfigError.invalid("Every shortcut must have a unique id: \(id)")}
                ids.insert(id)
                guard !item.label.isEmpty else {throw ConfigError.invalid("Every shortcut needs a label.")}
                guard item.path != nil || item.application != nil || item.bundleIdentifier != nil || item.url != nil else {throw ConfigError.invalid("\(item.label) needs a path, application or URL.")}
                if let text=item.url {guard let url=URL(string:text),["https","http","spotify","music","obsidian"].contains(url.scheme?.lowercased() ?? "") else {throw ConfigError.invalid("Unsupported link for \(item.label).")}}
                if let path=item.path,!path.hasPrefix("/") && !path.hasPrefix("~/") {throw ConfigError.invalid("Folder/app paths must start with / or ~/.")}
            }
        }
    }
}
enum ConfigError: LocalizedError {case invalid(String);var errorDescription:String? {if case let .invalid(text)=self{return text};return nil}}
final class ConfigurationStore {
    let url:URL
    init() {
        if let override=ProcessInfo.processInfo.environment["CYBERDESK_CONFIG"] {url=URL(fileURLWithPath:override)}
        else {url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cyberdesk/config.json")}
    }
    func load() throws -> WorkflowConfiguration {
        if !FileManager.default.fileExists(atPath:url.path) {
            if let resource=Bundle.main.url(forResource:"config.example",withExtension:"json"),let data=try? Data(contentsOf:resource),let config=try? JSONDecoder().decode(WorkflowConfiguration.self,from:data) {try save(config,backup:false)}
            else {try save(.starter,backup:false)}
        }
        let config=try JSONDecoder().decode(WorkflowConfiguration.self,from:Data(contentsOf:url));try config.validate();return config
    }
    func save(_ config:WorkflowConfiguration,backup:Bool=true) throws {
        try config.validate();try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if backup,FileManager.default.fileExists(atPath:url.path) {
            let dir=url.deletingLastPathComponent().appendingPathComponent("Backups",isDirectory:true);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let name="config-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try FileManager.default.copyItem(at:url,to:dir.appendingPathComponent(name))
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];try encoder.encode(config).write(to:url,options:.atomic)
    }
    var modified:Date? {(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate}
}
