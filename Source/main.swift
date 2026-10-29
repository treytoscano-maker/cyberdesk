import Cocoa
import WebKit
import IOKit.ps
import Darwin
import UniformTypeIdentifiers

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class ClickableWebView: WKWebView, NSDraggingSource {
    var onDesktopDrop:((DesktopDrop,ClickableWebView)->Void)?
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    var fileDragMonitor:Any?
    var fileDragURL:URL?
    var fileDragDown:NSEvent?
    deinit {if let monitor=fileDragMonitor{NSEvent.removeMonitor(monitor)}}
    func installDropSupport(){
        registerForDraggedTypes([.fileURL,.png,.tiff])
        fileDragMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]){[weak self] event in
            guard let self=self,event.window === self.window else{return event}
            if event.type == .leftMouseDown {self.fileDragURL=nil;self.fileDragDown=event}
            if event.type == .leftMouseUp {self.fileDragURL=nil;self.fileDragDown=nil}
            if event.type == .leftMouseDragged,let url=self.fileDragURL,let down=self.fileDragDown {
                let a=event.locationInWindow,b=down.locationInWindow
                if hypot(a.x-b.x,a.y-b.y)>=5 {
                    self.fileDragURL=nil;self.fileDragDown=nil
                    self.evaluateJavaScript("window.fileDragDidStart && window.fileDragDidStart()",completionHandler:nil)
                    let item=NSDraggingItem(pasteboardWriter:url as NSURL)
                    let image=NSWorkspace.shared.icon(forFile:url.path);image.size=NSSize(width:64,height:64)
                    let point=self.convert(event.locationInWindow,from:nil)
                    item.setDraggingFrame(NSRect(x:point.x-32,y:point.y-32,width:64,height:64),contents:image)
                    let session=self.beginDraggingSession(with:[item],event:event,source:self)
                    session.animatesToStartingPositionsOnCancelOrFail=true
                    return nil
                }
            }
            return event
        }
    }
    func armFileDrag(_ url:URL){guard fileDragDown != nil,FileManager.default.fileExists(atPath:url.path)else{return};fileDragURL=url}
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation{.copy}
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation){fileDragURL=nil;fileDragDown=nil;evaluateJavaScript("window.fileDragDidEnd && window.fileDragDidEnd()",completionHandler:nil)}

    func droppedPayload(_ pasteboard:NSPasteboard)->DesktopDrop? {
        let urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        if !urls.isEmpty {return DesktopDrop(urls:urls)}
        if let png=pasteboard.data(forType:.png),png.count<100_000_000{return DesktopDrop(urls:[],pngData:png)}
        if let tiff=pasteboard.data(forType:.tiff),tiff.count<100_000_000,let image=NSBitmapImageRep(data:tiff),let png=image.representation(using:.png,properties:[:]){return DesktopDrop(urls:[],pngData:png)}
        return nil
    }
    func dropHighlight(_ active:Bool){evaluateJavaScript("window.setDropActive && window.setDropActive(\(active ? "true":"false"))",completionHandler:nil)}
    func acceptsDrop(_ sender:NSDraggingInfo)->Bool {
        if let source=sender.draggingSource as? NSView,source === self || source.isDescendant(of:self){return false}
        let pasteboard=sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) || pasteboard.availableType(from:[.png,.tiff]) != nil
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {if acceptsDrop(sender) {dropHighlight(true);return .copy};return super.draggingEntered(sender)}
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {if acceptsDrop(sender){return .copy};return super.draggingUpdated(sender)}
    override func draggingExited(_ sender:NSDraggingInfo?){dropHighlight(false);super.draggingExited(sender)}
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool {acceptsDrop(sender) || super.prepareForDragOperation(sender)}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {dropHighlight(false);guard acceptsDrop(sender) else{return super.performDragOperation(sender)};guard let payload=droppedPayload(sender.draggingPasteboard)else{return super.performDragOperation(sender)};onDesktopDrop?(payload,self);return true}
}
final class Desk: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var windows: [NSWindow] = []
    var views: [WKWebView] = []
    var status: NSStatusItem!
    var timer: Timer?
    let wallpaper=WallpaperController()
    var musicConnected = false
    var busy = false
    var lastCPU: [UInt32] = []
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var destinations: [String:String] = [:]
    var fileTargets: [String:URL] = [:]
    var folderData: [[String:Any]] = []
    let configStore=ConfigurationStore()
    var configuration=WorkflowConfiguration.starter
    var routeURLs:[String:URL]=[:]
    var configurationError:String?
    var configModified:Date?
    var desktopWatcher:DispatchSourceFileSystemObject?
    var desktopRefresh:DispatchWorkItem?
    let fileStore=DesktopFileStore()
    let importQueue=DispatchQueue(label:"local.cyberdesk.import",qos:.userInitiated)
    let thumbnailQueue=DispatchQueue(label:"local.cyberdesk.thumbnails",qos:.utility)
    let thumbnails=NSCache<NSString,NSString>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupDestinations()
        loadDesktopItems()
        watchDesktop()
        saveBaseline()
        do{try wallpaper.prepare()}catch{wallpaper.settings.matchNative=false;wallpaper.image=Bundle.main.url(forResource:"city",withExtension:"png").flatMap{NSImage(contentsOf:$0)};configurationError="Wallpaper backup/apply failed: \(error.localizedDescription)"}
        let notifications=NSWorkspace.shared.notificationCenter
        notifications.addObserver(forName:NSWorkspace.screensDidSleepNotification,object:nil,queue:.main){[weak self]_ in self?.wallpaper.sleeping=true;self?.wallpaper.update(cpu:0)}
        notifications.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self]_ in self?.wallpaper.sleeping=true;self?.wallpaper.update(cpu:0)}
        notifications.addObserver(forName:NSWorkspace.screensDidWakeNotification,object:nil,queue:.main){[weak self]_ in self?.wallpaper.sleeping=false;self?.wallpaper.update(cpu:0)}

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "⌘ D"
        status.button?.toolTip = "Desktop — desktop controls and restore"
        let menu = NSMenu()
        menu.addItem(withTitle: "Desktop · \(configuration.workspaceName)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Open workspace window", action: #selector(openWorkspaceWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Show desktop layer", action: #selector(showDesk), keyEquivalent: "")
        menu.addItem(withTitle: "Hide desktop layer", action: #selector(hideDesk), keyEquivalent: "")
        menu.addItem(withTitle: "Connect music controls", action: #selector(connectMusic), keyEquivalent: "")
        menu.addItem(withTitle: "Enable Desktop at sign-in", action: #selector(enableStartup), keyEquivalent: "")
        menu.addItem(withTitle: "Open setup & backup folder", action: #selector(openSetup), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Restore original desktop / Quit", action: #selector(restore), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        createWindows()
        if CommandLine.arguments.contains("--window") { openWorkspaceWindow() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }
    func setupDestinations() {
        do {let next=try configStore.load();let changed=next.music.provider != configuration.music.provider;configuration=next;configModified=configStore.modified;configurationError=nil
            if changed || !musicConnected {musicConnected=UserDefaults.standard.bool(forKey:"musicConnected-"+next.music.provider) || (next.music.provider == "spotify" && UserDefaults.standard.bool(forKey:"spotifyConnected"))}
        }catch{configurationError="Configuration: \(error.localizedDescription)";configModified=configStore.modified}
        destinations=[:];routeURLs=[:]
        for group in configuration.allSections.keys {
            for (index,item) in (configuration.allSections[group] ?? []).enumerated() {
                let id=item.id ?? "\(group)-\(index)"
                if let text=item.url,let url=URL(string:text){routeURLs[id]=url;continue}
                var app:URL?
                if let path=item.path {app=URL(fileURLWithPath:(path as NSString).expandingTildeInPath)}
                else if let bundleID=item.bundleIdentifier {app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID)}
                if app == nil,let name=item.application {
                    for base in ["/Applications",home+"/Applications","/System/Applications"] {let path=base+"/"+name+(name.hasSuffix(".app") ? "":".app");if FileManager.default.fileExists(atPath:path){app=URL(fileURLWithPath:path);break}}
                }
                if let app=app {destinations[id]=app.path}
            }
        }
    }
    func publishConfiguration() {
        var groups:[String:[[String:Any]]]=[:]
        for group in configuration.allSections.keys {
            groups[group]=(configuration.allSections[group] ?? []).enumerated().map { index,item in
                let id=item.id ?? "\(group)-\(index)"
                let available=routeURLs[id] != nil || destinations[id].map {FileManager.default.fileExists(atPath:$0)} == true
                return ["id":id,"label":item.label,"detail":item.detail ?? "","available":available]
            }
        }
        let editorConfig=(try? JSONEncoder().encode(configuration)).flatMap{try? JSONSerialization.jsonObject(with:$0)} ?? [:]
        let custom=(configuration.customCards ?? []).map{["id":$0.id,"title":$0.title,"color":$0.color ?? "cyan"]}
        send("updateConfiguration",["editorConfig":editorConfig,"desktopLabels":configuration.desktopLabels ?? [:],"desktopGroups":configuration.desktopGroups ?? [:],"customCards":custom,"cardTitles":configuration.cardTitles ?? [:],"cardColors":configuration.cardColors ?? [:],"workspaceName":configuration.workspaceName,"sections":groups,"music":["provider":configuration.music.provider,"name":configuration.music.displayName,"url":configuration.music.url ?? "","nativeControls":configuration.music.appBundleID != nil],"folderGroups":Array((configuration.folderGroups ?? [:]).keys).sorted()])
        if let error=configurationError{send("showFeedback",["text":error,"error":true])}
    }
    func openMusicService() {
        if let url=configuration.music.webURL {NSWorkspace.shared.open(url);return}
        if let bundle=configuration.music.appBundleID,let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle){openTarget(url)}
    }
    func wireDrop(_ web:ClickableWebView){web.installDropSupport();web.onDesktopDrop={[weak self] payload,view in self?.importDesktopDrop(payload,view:view)}}
    func importDesktopDrop(_ payload:DesktopDrop,view:ClickableWebView){
        importQueue.async {[weak self,weak view] in guard let self=self else{return};var names:[String]=[],errors:[String]=[]
            for url in payload.urls {do {names.append(try self.fileStore.addFile(url).lastPathComponent)}catch{errors.append(error.localizedDescription)}}
            if let data=payload.pngData {do{names.append(try self.fileStore.addPNG(data).lastPathComponent)}catch{errors.append(error.localizedDescription)}}
            DispatchQueue.main.async {self.loadDesktopItems();self.publishFiles();if !names.isEmpty{view?.evaluateJavaScript("window.openLooseDesktop && window.openLooseDesktop()",completionHandler:nil)}
                self.send("showFeedback",["text":errors.isEmpty ? "Added \(names.count) item\(names.count == 1 ? "":"s") to Desktop. Originals kept in place." : "\(names.count) added. \(errors.joined(separator:" "))","error": !errors.isEmpty])}
        }
    }
    func watchDesktop(){let fd=open((home+"/Desktop"),O_EVTONLY);guard fd>=0 else{return};let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib],queue:.main);source.setEventHandler{[weak self]in guard let self=self else{return};self.desktopRefresh?.cancel();let work=DispatchWorkItem{[weak self]in self?.loadDesktopItems();self?.publishFiles()};self.desktopRefresh=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)};source.setCancelHandler{close(fd)};desktopWatcher=source;source.resume()}
    func requestThumbnail(_ id:String){guard let url=fileTargets[id]else{return};let modified=(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0;let key=(id+String(modified)) as NSString;if let cached=thumbnails.object(forKey:key){send("updateThumbnail",["id":id,"src":cached as String]);return};thumbnailQueue.async{[weak self]in guard let self=self,let src=self.fileStore.thumbnail(url)else{return};self.thumbnails.setObject(src as NSString,forKey:key);DispatchQueue.main.async{self.send("updateThumbnail",["id":id,"src":src])}}}
    func importConfiguration(){let picker=NSOpenPanel();picker.allowedContentTypes=[.json];picker.allowsMultipleSelection=false;picker.canChooseDirectories=false;picker.message="Choose a Desktop workflow configuration";NSApp.activate(ignoringOtherApps:true);if picker.runModal() == .OK,let url=picker.url {do{let next=try JSONDecoder().decode(WorkflowConfiguration.self,from:Data(contentsOf:url));try configStore.save(next);setupDestinations();loadDesktopItems();publishConfiguration();publishFiles()}catch{send("showFeedback",["text":"Could not import: \(error.localizedDescription)","error":true])}}}
    func saveBaseline() {
        let dir = home+"/Documents/Cyberdesk/Original Desktop Backup"
        try? FileManager.default.createDirectory(atPath:dir,withIntermediateDirectories:true)
        let path = dir+"/wallpapers.json"
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let rows = NSScreen.screens.enumerated().map { i, screen -> [String:Any] in
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            if let url = url { try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath:dir+"/original-wallpaper-\(i)."+url.pathExtension)) }
            return ["screen": i, "wallpaper":url?.path ?? "", "frame":NSStringFromRect(screen.frame)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: URL(fileURLWithPath:path)) }
    }
    func desktopScreens()->[NSScreen] {
        if Bundle.main.url(forResource:"room-mode",withExtension:"flag") != nil {
            return NSScreen.main.map { [$0] } ?? Array(NSScreen.screens.prefix(1))
        }
        return NSScreen.screens
    }
    func createWindows() {
        guard let resource = Bundle.main.resourceURL else { return }
        for screen in desktopScreens() {
            let win = DesktopWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen:screen)
            // NSWindow screen initialization uses screen-relative coordinates; apply the global frame explicitly.
            win.setFrame(screen.frame, display:false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            win.title = "Desktop"
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.isOpaque = true; win.backgroundColor = .black; win.hasShadow = false; win.isReleasedWhenClosed = false
            let conf = WKWebViewConfiguration()
            let displayNumber=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let displayID=String(displayNumber)
            let uuid=CGDisplayCreateUUIDFromDisplayID(displayNumber)?.takeRetainedValue()
            let stableID=uuid.map { CFUUIDCreateString(nil,$0) as String } ?? displayID
            let context:[String:Any]=["cyberdeskDisplayID":"display-"+stableID,"cyberdeskLegacyDisplayID":"display-"+displayID,"cyberdeskMonitorName":screen.localizedName,"cyberdeskMonitorCount":desktopScreens().count]
            if let data=try? JSONSerialization.data(withJSONObject:context),let json=String(data:data,encoding:.utf8) {
                conf.userContentController.addUserScript(WKUserScript(source:"Object.assign(window,\(json));",injectionTime:.atDocumentStart,forMainFrameOnly:true))
            }
            conf.userContentController.add(self, name: "desk")
            let web = ClickableWebView(frame:NSRect(origin:.zero,size:screen.frame.size),configuration:conf)
            wireDrop(web)
            web.navigationDelegate = self
            web.autoresizingMask = [.width,.height]
            web.setValue(false, forKey: "drawsBackground")
            let host=WallpaperSurface(frame:web.frame);host.addSubview(web);win.contentView=host;wallpaper.surfaces.append(host)
            web.loadFileURL(resource.appendingPathComponent("desktop.html"),allowingReadAccessTo:resource)
            win.orderFrontRegardless()
            windows.append(win); views.append(web)
        }
    }

    @objc func openWorkspaceWindow() {
        if let existing=windows.first(where: { $0.level == .normal }) { existing.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return }
        guard let screen=NSScreen.main,let resource=Bundle.main.resourceURL else{return}
        let win=NSWindow(contentRect:screen.visibleFrame.insetBy(dx:35,dy:30),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        win.title="Desktop — Interactive Workspace"
        win.minSize=NSSize(width:1000,height:760)
        win.isReleasedWhenClosed=false
        let conf=WKWebViewConfiguration();conf.userContentController.addUserScript(WKUserScript(source:"window.cyberdeskDisplayID='workspace-window';window.cyberdeskMonitorName='Workspace window';window.cyberdeskMonitorCount=0;",injectionTime:.atDocumentStart,forMainFrameOnly:true));conf.userContentController.add(self,name:"desk")
        let web=ClickableWebView(frame:NSRect(origin:.zero,size:win.frame.size),configuration:conf)
        wireDrop(web)
        web.navigationDelegate=self;web.autoresizingMask=[.width,.height]
        let host=WallpaperSurface(frame:web.frame);host.addSubview(web);win.contentView=host;wallpaper.surfaces.append(host)
        web.loadFileURL(resource.appendingPathComponent("desktop.html"),allowingReadAccessTo:resource)
        windows.append(win);views.append(web)
        win.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }

    @objc func screensChanged() { for win in windows { win.close() }; windows=[]; views=[];wallpaper.surfaces=[];createWindows();if wallpaper.settings.matchNative{try? wallpaper.matchNative()} }
    @objc func showDesk() { for win in windows { win.orderFrontRegardless() } }
    @objc func hideDesk() { for win in windows { win.orderOut(nil) } }
    @objc func openSetup() { NSWorkspace.shared.open(URL(fileURLWithPath:home+"/Documents/Cyberdesk")) }
    @objc func restore() {
        if wallpaper.settings.matchNative {do{try wallpaper.restoreNative();wallpaper.settings.matchNative=false;try wallpaper.save()}catch{send("showFeedback",["text":"Could not restore wallpaper: \(error.localizedDescription)","error":true]);return}}
        setStartupEnabled(false)
        NSApp.terminate(nil)
    }
    @discardableResult func launchControl(_ args:[String])->Bool {
        let task=Process();task.executableURL=URL(fileURLWithPath:"/bin/launchctl");task.arguments=args
        task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        do {try task.run();task.waitUntilExit();return task.terminationStatus == 0} catch {return false}
    }
    @objc func enableStartup() { setStartupEnabled(true) }
    func setStartupEnabled(_ enabled:Bool) {
        let label="local.cyberdesk.autostart"
        let service="gui/\(getuid())/"+label
        let file=URL(fileURLWithPath:home+"/Library/LaunchAgents/"+label+".plist")
        if !enabled {
            _=launchControl(["disable",service])
            _=launchControl(["bootout",service])
            if let data=try? Data(contentsOf:file),var config=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any] {
                config["Disabled"]=true
                if let result=try? PropertyListSerialization.data(fromPropertyList:config,format:.xml,options:0){try? result.write(to:file,options:.atomic)}
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            let config:[String:Any]=["Label":label,"ProgramArguments":["/usr/bin/open","-g",Bundle.main.bundleURL.path],"RunAtLoad":true,"KeepAlive":false,"Disabled":false,"LimitLoadToSessionType":"Aqua"]
            let data=try PropertyListSerialization.data(fromPropertyList:config,format:.xml,options:0);try data.write(to:file,options:.atomic)
            let ok=launchControl(["enable",service])
            _=launchControl(["bootstrap","gui/\(getuid())",file.path])
            send("showFeedback",["text":ok ? "Desktop will open on your monitors when you sign in." : "Could not enable Desktop at sign-in.","error": !ok])
        }catch{send("showFeedback",["text":"Could not save sign-in settings: \(error.localizedDescription)","error":true])}
    }
    @objc func connectMusic() {guard configuration.music.appBundleID != nil else{openMusicService();return};musicConnected=true;UserDefaults.standard.set(true,forKey:"musicConnected-"+configuration.music.provider);tick()}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let state = UserDefaults.standard.string(forKey: "desktopLayoutV2") ?? "{}"
        send("loadDeskState", ["value":state])
        publishConfiguration()
        publishFiles()
        wallpaper.lastSignature="";tick()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let key = message.body as? String else { return }
        if key.hasPrefix("diagnostic:") {
            let line=String(key.dropFirst(11))+"\n"
            let url=URL(fileURLWithPath:home+"/Documents/Cyberdesk/interface-errors.log")
            if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil)}
            if let handle=try? FileHandle(forWritingTo:url){handle.seekToEndOfFile();handle.write(Data(line.utf8));try? handle.close()}
            return
        }
        if key == "restore" { restore(); return }
        if key.hasPrefix("state:") {
            let value = String(key.dropFirst(6))
            if value.utf8.count < 200_000, let data=value.data(using:.utf8), (try? JSONSerialization.jsonObject(with:data)) is [String:Any] {
                UserDefaults.standard.set(value, forKey:"desktopLayoutV2")
                send("loadDeskState", ["value":value])
            }
            return
        }
        if key.hasPrefix("wallpaper:"){let action=String(key.dropFirst(10));do{switch action {
            case "photo":let picker=NSOpenPanel();picker.allowedContentTypes=[.image];picker.canChooseDirectories=false;picker.message="Add a still wallpaper · your original stays in place";NSApp.activate(ignoringOtherApps:true);if picker.runModal() == .OK,let url=picker.url{try wallpaper.importPhoto(url)}
            case let action where action.hasPrefix("select:"):try wallpaper.select(String(action.dropFirst(7)))
            case "choose":let picker=NSOpenPanel();picker.allowedContentTypes=[.movie];picker.canChooseDirectories=false;picker.message="Choose a local video · optimized to a silent 720p, 24 fps loop up to 30 seconds";NSApp.activate(ignoringOtherApps:true);if picker.runModal() == .OK,let url=picker.url{send("showFeedback",["text":"Optimizing wallpaper once. Your original video stays in place."]);wallpaper.importVideo(url){[weak self]error in self?.send("showFeedback",["text":error?.localizedDescription ?? "Video ready. Motion pauses on battery and during heavy work.","error":error != nil]);self?.tick()}}
            case "undo":try wallpaper.undo()
            case "match":wallpaper.settings.matchNative=true;try wallpaper.matchNative();try wallpaper.save()
            case "still","subtle","video":if action == "video" && wallpaper.settings.videoPath == nil{throw ConfigError.invalid("Choose a video first.")};wallpaper.settings.mode=action;try wallpaper.save()
            default:break};tick()}catch{send("showFeedback",["text":error.localizedDescription,"error":true])};return}
        if key.hasPrefix("pickShortcut:"),let data=String(key.dropFirst(13)).data(using:.utf8),let request=try? JSONSerialization.jsonObject(with:data)as?[String:String],let token=request["token"],let kind=request["kind"]{let picker=NSOpenPanel();picker.canChooseDirectories=kind == "folder";picker.canChooseFiles=kind != "folder";picker.allowsMultipleSelection=false;if kind == "app"{picker.allowedContentTypes=[.application]};picker.message="Choose a \(kind) for this shortcut";NSApp.activate(ignoringOtherApps:true);if picker.runModal() == .OK,let url=picker.url{send("shortcutPicked",["token":token,"path":url.path,"name":url.deletingPathExtension().lastPathComponent])};return}
        if key == "addDesktopFiles" {let picker=NSOpenPanel();picker.allowsMultipleSelection=true;picker.canChooseDirectories=false;picker.message="Copy files to Desktop / Loose Files · originals stay in place";NSApp.activate(ignoringOtherApps:true);if picker.runModal() == .OK,let view=message.webView as? ClickableWebView{importDesktopDrop(DesktopDrop(urls:picker.urls),view:view)};return}
        if key.hasPrefix("fileOrganization:") {do{guard let data=String(key.dropFirst(17)).data(using:.utf8),let values=try JSONSerialization.jsonObject(with:data) as? [String:String],let id=values["id"],let url=fileTargets[id]else{return};var next=configuration;next.desktopLabels=next.desktopLabels ?? [:];next.desktopGroups=next.desktopGroups ?? [:];let name=url.lastPathComponent;if let label=values["label"],!label.isEmpty{next.desktopLabels?[name]=label}else{next.desktopLabels?.removeValue(forKey:name)};if let group=values["group"],!group.isEmpty{next.desktopGroups?[name]=group}else{next.desktopGroups?.removeValue(forKey:name)};try configStore.save(next);setupDestinations();publishConfiguration();publishFiles();send("showFeedback",["text":"Desktop labels saved. Original filenames and locations unchanged.","error":false])}catch{send("showFeedback",["text":error.localizedDescription,"error":true])};return}
        if key.hasPrefix("workflowConfig:") {do{guard let data=String(key.dropFirst(15)).data(using:.utf8),data.count<300_000 else{return};let next=try JSONDecoder().decode(WorkflowConfiguration.self,from:data);try configStore.save(next);setupDestinations();publishConfiguration();loadDesktopItems();publishFiles();send("showFeedback",["text":"Cards saved. Use CARDS to show custom cards on each monitor.","error":false])}catch{send("showFeedback",["text":error.localizedDescription,"error":true])};return}
        if key == "openConfig" {NSWorkspace.shared.open(configStore.url);return}
        if key == "importConfig" {importConfiguration();return}
        if key == "music-open" {openMusicService();return}
        if key.hasPrefix("armFileDrag:"),let view=message.webView as? ClickableWebView {if let url=fileTargets[String(key.dropFirst(12))]{view.armFileDrag(url)};return}
        if key.hasPrefix("preview:") {let id=String(key.dropFirst(8));guard let url=fileTargets[id]else{return};thumbnailQueue.async{[weak self]in guard let self=self else{return};let src=self.fileStore.thumbnail(url,maxPixels:2400);DispatchQueue.main.async{self.send("updateImagePreview",["id":id,"src":src ?? "","name":url.lastPathComponent])}};return}
        if key.hasPrefix("thumb:") {requestThumbnail(String(key.dropFirst(6)));return}
        if key.hasPrefix("settings:") {do{guard let data=String(key.dropFirst(9)).data(using:.utf8),let fields=try JSONSerialization.jsonObject(with:data) as? [String:String]else{return};var next=configuration;if let name=fields["workspaceName"]{next.workspaceName=name};if let provider=fields["provider"]{next.music.provider=provider};next.music.url=fields["url"];try configStore.save(next);setupDestinations();publishConfiguration();tick();send("showFeedback",["text":"Workflow settings saved.","error":false])}catch{send("showFeedback",["text":error.localizedDescription,"error":true])};return}
        if key == "refreshFiles" { loadDesktopItems(); publishFiles(); return }
        if key == "openDesktop" { NSWorkspace.shared.open(URL(fileURLWithPath:home+"/Desktop")); return }
        if key.hasPrefix("file:") {
            let id = String(key.dropFirst(5))
            guard let url=fileTargets[id] else { return }
            openTarget(url)
            return
        }
        if key.hasPrefix("reveal:") {
            if let url=fileTargets[String(key.dropFirst(7))] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if key == "connect" {connectMusic();return}
        if ["playpause","previous track","next track"].contains(key) {
            guard let scriptApp=configuration.music.appScriptName else{openMusicService();return}
            guard musicConnected else{connectMusic();return}
            DispatchQueue.global(qos:.utility).async{[weak self]in guard let self=self else{return};let _=self.appleScript("tell application \"\(scriptApp)\" to \(key)");DispatchQueue.main.async{self.tick()}};return
        }
        if let url=routeURLs[key]{NSWorkspace.shared.open(url);return}
        guard let path = destinations[key] else { return }
        openTarget(URL(fileURLWithPath:path))
    }

    func openTarget(_ url:URL) {
        guard FileManager.default.fileExists(atPath:url.path) else {
            send("showFeedback", ["text":"This item is unavailable: " + url.lastPathComponent, "error":true]); return
        }
        if url.pathExtension.lowercased() == "app" {
            let config=NSWorkspace.OpenConfiguration()
            config.activates=true
            NSWorkspace.shared.openApplication(at:url,configuration:config) { _,error in
                DispatchQueue.main.async {
                    self.send("showFeedback", ["text":error == nil ? "Opened " + url.deletingPathExtension().lastPathComponent : error!.localizedDescription,"error":error != nil])
                }
            }
        } else {
            let ok=NSWorkspace.shared.open(url)
            send("showFeedback", ["text":ok ? "Opened " + url.lastPathComponent : "Could not open " + url.lastPathComponent,"error": !ok])
        }
    }
    func loadDesktopItems() {
        let desktop=URL(fileURLWithPath:home+"/Desktop",isDirectory:true)
        do {
            let urls=try FileManager.default.contentsOfDirectory(at:desktop,includingPropertiesForKeys:[.isDirectoryKey,.isPackageKey],options:[.skipsHiddenFiles])
            fileTargets=[:]
            folderData=urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { url in
                let id=Data(url.lastPathComponent.utf8).base64EncodedString()
                fileTargets[id]=url
                let values=try? url.resourceValues(forKeys:[.isDirectoryKey,.isPackageKey])
                let directory=values?.isDirectory == true && values?.isPackage != true
                let image=UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true
                return ["id":id,"name":url.lastPathComponent,"folder":directory,"app":url.pathExtension.lowercased() == "app","image":image,"group":groupFor(url.lastPathComponent,directory:directory)]
            }
        } catch {
            send("showFeedback",["text":"Desktop access is unavailable. Allow Desktop folder access in macOS Privacy settings if requested.","error":true])
        }
    }
    func groupFor(_ name:String,directory:Bool)->String {
        let n=name.lowercased()
        for group in (configuration.folderGroups ?? [:]).keys.sorted(){if configuration.folderGroups?[group]?.contains(where:{n.contains($0.lowercased())}) == true{return group}}
        return "Other items"
    }
    func publishFiles() {
        send("updateFiles",["items":folderData,"desktop":home+"/Desktop"])
    }

    func appleScript(_ source: String) -> (String, Bool) {
        var error: NSDictionary?
        let value = NSAppleScript(source:source)?.executeAndReturnError(&error)
        return (value?.stringValue ?? "", error == nil)
    }
    func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to:&info) { ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,$0,&count) } }
        guard result == KERN_SUCCESS else { return 0 }
        let now = [info.cpu_ticks.0,info.cpu_ticks.1,info.cpu_ticks.2,info.cpu_ticks.3]
        defer {lastCPU=now}
        guard lastCPU.count == 4 else {return 0}
        let diffs = zip(now,lastCPU).map { Double($0 &- $1) }
        let total = diffs.reduce(0,+)
        return total > 0 ? (total-diffs[2])/total*100 : 0
    }
    func memory() -> Double {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to:&info) { ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count) } }
        guard result == KERN_SUCCESS else {return 0}
        let used = Double(info.active_count)+Double(info.wire_count)+Double(info.compressor_page_count)
        return min(100, used * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
    }
    func battery() -> String {
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources=IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {return "AC"}
        for source in sources {
            if let d=IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any], let current=d[kIOPSCurrentCapacityKey] as? Int, let max=d[kIOPSMaxCapacityKey] as? Int, max>0 {return "\(current*100/max)%"}
        }; return "AC"
    }
    func tick() {
        if configStore.modified != configModified {let old=configModified;setupDestinations();if configModified != old{loadDesktopItems();publishConfiguration();publishFiles();if let error=configurationError{send("showFeedback",["text":error,"error":true])}}}
        let measuredCPU=cpu();wallpaper.update(cpu:measuredCPU)
        let wallpaperSignature="\(wallpaper.settings.mode)|\(wallpaper.status)|\(wallpaper.settings.matchNative)|\(wallpaper.settings.selectedID ?? "city")|\(wallpaper.galleryRows.count)|\(wallpaper.palette)|\(wallpaper.image != nil)"
        if wallpaper.lastSignature != wallpaperSignature{wallpaper.lastSignature=wallpaperSignature
        send("updateWallpaper",["native":wallpaper.image != nil,"mode":wallpaper.settings.mode,"status":wallpaper.status,"matched":wallpaper.settings.matchNative,"hasVideo":wallpaper.settings.videoPath != nil,"gallery":wallpaper.galleryRows,"selectedID":wallpaper.settings.selectedID ?? "city","palette":wallpaper.palette])
        }
        let running=Set(NSWorkspace.shared.runningApplications.compactMap{$0.bundleURL?.path})
        send("updateSystem",["cpu":Int(measuredCPU.rounded()),"memory":Int(memory().rounded()),"battery":battery(),"running":destinations.filter{running.contains($0.value)}.map{$0.key}])
        let music=configuration.music
        guard let appID=music.appBundleID,let appName=music.appScriptName else {send("updateMusic",["state":"web","title":music.displayName,"artist":"Open your music service in the browser","position":0,"duration":0]);return}
        guard musicConnected else{send("updateMusic",["state":"connect","title":music.displayName,"artist":"Connect to see your current track","position":0,"duration":0]);return};guard !busy else{return}
        guard NSWorkspace.shared.runningApplications.contains(where:{$0.bundleIdentifier==appID})else{send("updateMusic",["state":"closed","title":"\(music.displayName) is closed","artist":"Open it to listen","position":0,"duration":0]);return}
        busy=true
        DispatchQueue.global(qos:.utility).async{[weak self]in guard let self=self else{return}
            let script="""
            tell application "\(appName)"
                if player state is stopped then return {"stopped", "Nothing playing", "Choose a track in your music app", 0, 0, ""}
                try
                    return {(player state as text), name of current track, artist of current track, player position, duration of current track, album of current track}
                on error
                    return {"stopped", "Nothing playing", "Choose a track in your music app", 0, 0, ""}
                end try
            end tell
            """
            var error:NSDictionary?;let result=NSAppleScript(source:script)?.executeAndReturnError(&error);let code=error?[NSAppleScript.errorNumber]as?Int
            var info:[String:Any]=[:]
            if let result=result,error==nil,result.numberOfItems>=6 {let duration=music.provider=="spotify" ? Double(result.atIndex(5)?.int32Value ?? 0)/1000 : result.atIndex(5)?.doubleValue ?? 0;info=["state":result.atIndex(1)?.stringValue ?? "stopped","title":result.atIndex(2)?.stringValue ?? "Nothing playing","artist":result.atIndex(3)?.stringValue ?? "","position":max(0,result.atIndex(4)?.doubleValue ?? 0),"duration":max(0,duration),"album":result.atIndex(6)?.stringValue ?? ""]}
            else{info=["state":code == -1743 ? "connect":"error","title":code == -1743 ? "Connect \(music.displayName)":"Music status unavailable","artist":code == -1743 ? "Allow music-app control in macOS":"Waiting for the player to respond","position":0,"duration":0]}
            DispatchQueue.main.async{self.busy=false;guard self.configuration.music.provider==music.provider else{return};if code == -1743{self.musicConnected=false};self.send("updateMusic",info)}
        }
    }
    func send(_ fn:String,_ data:[String:Any]) {
        guard let bytes=try? JSONSerialization.data(withJSONObject:data),let json=String(data:bytes,encoding:.utf8) else {return}
        for view in views {view.evaluateJavaScript("window.\(fn) && window.\(fn)(\(json))",completionHandler:nil)}
    }
}
let app=NSApplication.shared
if CommandLine.arguments.contains("--wallpaper-report"){let controller=WallpaperController();let rows=NSScreen.screens.map{["display":controller.displayID($0),"wallpaper":NSWorkspace.shared.desktopImageURL(for:$0)?.path ?? ""]};if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),let value=String(data:data,encoding:.utf8){print(value)};exit(0)}
if CommandLine.arguments.contains("--restore-wallpaper"){let controller=WallpaperController();if let data=try? Data(contentsOf:controller.settingsURL),let settings=try? JSONDecoder().decode(WallpaperSettings.self,from:data){controller.settings=settings};do{try controller.restoreNative();controller.settings.mode="still";controller.settings.matchNative=false;try controller.save();print("Original wallpapers restored")}catch{fputs("Wallpaper restore failed: \(error.localizedDescription)\n",stderr);exit(1)};exit(0)}
let delegate=Desk()
app.delegate=delegate
app.run()
