import Cocoa
import AVFoundation
import QuartzCore
import IOKit.ps
import ImageIO

final class WallpaperSurface:NSView {
    let picture=CALayer()
    let glow=CAGradientLayer()
    var player:AVQueuePlayer?
    var looper:AVPlayerLooper?
    var movieLayer:AVPlayerLayer?
    var sourcePath:String?
    var currentImage:NSImage?
    var lastRenderSignature=""
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=true;picture.frame=bounds;picture.contentsGravity = .resizeAspectFill;layer?.addSublayer(picture);glow.colors=[NSColor.clear.cgColor,NSColor.systemTeal.withAlphaComponent(0.09).cgColor,NSColor.systemRed.withAlphaComponent(0.06).cgColor];glow.startPoint=CGPoint(x:0,y:0);glow.endPoint=CGPoint(x:1,y:1);layer?.addSublayer(glow)}
    required init?(coder:NSCoder){fatalError()}
    override func layout(){super.layout();picture.frame=bounds;CATransaction.begin();CATransaction.setDisableActions(true);movieLayer?.frame=bounds;glow.frame=bounds;CATransaction.commit()}
    func update(image:NSImage?,mode:String,path:String?,moving:Bool,palette:String="city"){let signature=palette+mode+"|"+(path ?? "")+"|"+String(moving);if signature==lastRenderSignature && currentImage === image{return};lastRenderSignature=signature;let accents:[String:(NSColor,NSColor)]=["sage":(NSColor(deviceRed:0.66,green:0.77,blue:0.53,alpha:1),NSColor(deviceRed:0.80,green:0.73,blue:0.51,alpha:1)),"solar":(NSColor(deviceRed:0.97,green:0.68,blue:0.36,alpha:1),NSColor(deviceRed:0.40,green:0.72,blue:0.66,alpha:1)),"waterfront":(NSColor(deviceRed:0.55,green:0.75,blue:0.77,alpha:1),NSColor(deviceRed:0.80,green:0.74,blue:0.54,alpha:1))];let colors=accents[palette] ?? (.systemTeal,.systemRed);glow.colors=[NSColor.clear.cgColor,colors.0.withAlphaComponent(0.09).cgColor,colors.1.withAlphaComponent(0.06).cgColor];if currentImage !== image{currentImage=image;picture.contents=image?.cgImage(forProposedRect:nil,context:nil,hints:nil)}
        if mode == "video",let path=path {
            if sourcePath != path {player?.pause();movieLayer?.removeFromSuperlayer();let queue=AVQueuePlayer();queue.isMuted=true;queue.preventsDisplaySleepDuringVideoPlayback=false;looper=AVPlayerLooper(player:queue,templateItem:AVPlayerItem(url:URL(fileURLWithPath:path)));let view=AVPlayerLayer(player:queue);view.videoGravity = .resizeAspectFill;layer?.insertSublayer(view,below:glow);player=queue;movieLayer=view;sourcePath=path;needsLayout=true}
            movieLayer?.isHidden=false;moving ? player?.play() : player?.pause()
        }else{player?.pause();player=nil;looper=nil;movieLayer?.removeFromSuperlayer();movieLayer=nil;sourcePath=nil}
        if mode == "subtle" && moving {if glow.animation(forKey:"ambient") == nil {let animation=CABasicAnimation(keyPath:"opacity");animation.fromValue=0.15;animation.toValue=0.8;animation.duration=9;animation.autoreverses=true;animation.repeatCount = .infinity;glow.add(animation,forKey:"ambient")}}else{glow.removeAnimation(forKey:"ambient");glow.opacity=0}
    }
}
struct WallpaperChoice:Codable {var id:String;var name:String;var path:String;var palette:String}
struct WallpaperSettings:Codable {var selectedID:String?;var mode="subtle";var videoPath:String?;var posterPath:String?;var matchNative=true}
final class WallpaperController {
    let directory:URL
    init(directory:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cyberdesk/Wallpaper",isDirectory:true)){self.directory=directory}
    var settings=WallpaperSettings()
    var choices:[WallpaperChoice]=[]
    var galleryRows:[[String:Any]]=[]
    var surfaces:[WallpaperSurface]=[]
    var sleeping=false
    var busyUntil=Date.distantPast
    var status="Still background"
    var lastSignature=""
    var image:NSImage?
    var savingVideo=false
    var lastCoverageCheck=Date.distantPast
    var coveredScreens=Set<UInt32>()
    var settingsURL:URL{directory.appendingPathComponent("settings.json")}
    var backupURL:URL{directory.appendingPathComponent("Before Live Wallpaper.plist")}
    func displayID(_ screen:NSScreen)->String{let number=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]as?NSNumber)?.uint32Value ?? 0;return CGDisplayCreateUUIDFromDisplayID(number).map{CFUUIDCreateString(nil,$0.takeRetainedValue())as String} ?? String(number)}
    func prepare() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:settingsURL),let value=try? JSONDecoder().decode(WallpaperSettings.self,from:data){settings=value}
        try backupCurrentScreens()
        if let source=Bundle.main.url(forResource:"city",withExtension:"png") {let target=directory.appendingPathComponent("Cyberdesk City.png");if !FileManager.default.fileExists(atPath:target.path){try FileManager.default.copyItem(at:source,to:target)}}
        loadGallery();reloadImage();if settings.matchNative{try matchNative()};try save()
    }
    func backupCurrentScreens()throws{
        var records:[[String:Any]]=[]
        if FileManager.default.fileExists(atPath:backupURL.path){records=try PropertyListSerialization.propertyList(from:Data(contentsOf:backupURL),format:nil)as?[[String:Any]] ?? []}
            for screen in NSScreen.screens where !records.contains(where:{$0["display"]as?String==displayID(screen)}) {guard let url=NSWorkspace.shared.desktopImageURL(for:screen)else{throw ConfigError.invalid("Could not back up this screen's wallpaper.")};let copy=directory.appendingPathComponent("Original-\(displayID(screen))."+url.pathExtension);try Data(contentsOf:url).write(to:copy,options:.atomic);let options=NSWorkspace.shared.desktopImageOptions(for:screen) ?? [:];var saved:[String:Any]=[:];for key in [NSWorkspace.DesktopImageOptionKey.imageScaling,.allowClipping]{if let value=options[key]{saved[key.rawValue]=value}};if let color=options[.fillColor]as?NSColor,let rgb=color.usingColorSpace(.deviceRGB){saved["fillRGBA"]=[rgb.redComponent,rgb.greenComponent,rgb.blueComponent,rgb.alphaComponent]};records.append(["display":displayID(screen),"original":url.path,"copy":copy.path,"options":saved])}
        try PropertyListSerialization.data(fromPropertyList:records,format:.xml,options:0).write(to:backupURL,options:.atomic)
    }
    var selectedChoice:WallpaperChoice?{choices.first{$0.id==(settings.selectedID ?? "city")}}
    var palette:String{selectedChoice?.palette ?? "city"}
    var libraryURL:URL{directory.appendingPathComponent("library.json")}
    func loadGallery(){choices=[WallpaperChoice(id:"city",name:"Cyber City",path:directory.appendingPathComponent("Cyberdesk City.png").path,palette:"city")];if let data=try? Data(contentsOf:libraryURL),let imported=try? JSONDecoder().decode([WallpaperChoice].self,from:data){var ids=Set(["city"]);for item in imported where !ids.contains(item.id) && FileManager.default.fileExists(atPath:item.path){choices.append(item);ids.insert(item.id)}};galleryRows=choices.map{choice in var row:[String:Any]=["id":choice.id,"name":choice.name,"palette":choice.palette];if let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:choice.path)as CFURL,nil),let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:360]as CFDictionary){let rep=NSBitmapImageRep(cgImage:thumb);if let data=rep.representation(using:.jpeg,properties:[.compressionFactor:0.75]){row["thumbnail"]="data:image/jpeg;base64,"+data.base64EncodedString()}};return row}}
    func select(_ id:String)throws{guard choices.contains(where:{$0.id==id})else{throw ConfigError.invalid("Wallpaper not found.")};settings.selectedID=id;settings.mode="still";settings.matchNative=true;reloadImage();try matchNative();try save()}
    func importPhoto(_ url:URL)throws{guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(source)>0 else{throw ConfigError.invalid("Choose a readable image.")};let folder=directory.appendingPathComponent("Gallery",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let id="photo-"+UUID().uuidString;let target=folder.appendingPathComponent(id+"."+url.pathExtension);try FileManager.default.copyItem(at:url,to:target);var imported=choices.filter{$0.id != "city"};imported.append(WallpaperChoice(id:id,name:url.deletingPathExtension().lastPathComponent,path:target.path,palette:"waterfront"));try JSONEncoder().encode(imported).write(to:libraryURL,options:.atomic);loadGallery();try select(id)}
    var posterURL:URL {if settings.mode != "video",let choice=selectedChoice{return URL(fileURLWithPath:choice.path)};if let path=settings.posterPath,FileManager.default.fileExists(atPath:path){return URL(fileURLWithPath:path)};return directory.appendingPathComponent("Cyberdesk City.png")}
    func reloadImage(){image=NSImage(contentsOf:posterURL)}
    func save()throws{try JSONEncoder().encode(settings).write(to:settingsURL,options:.atomic)}
    func matchNative()throws {try backupCurrentScreens();guard FileManager.default.fileExists(atPath:backupURL.path)else{throw ConfigError.invalid("Wallpaper backup is required before changing it.")};for screen in NSScreen.screens {try NSWorkspace.shared.setDesktopImageURL(posterURL,for:screen,options:[.imageScaling:NSImageScaling.scaleProportionallyUpOrDown.rawValue,.allowClipping:true])}}
    func restoreNative()throws {
        let records=try PropertyListSerialization.propertyList(from:Data(contentsOf:backupURL),format:nil)as?[[String:Any]] ?? []
        for screen in NSScreen.screens {guard let row=records.first(where:{$0["display"]as?String==displayID(screen)}),let copy=row["copy"]as?String else{continue};let original=row["original"]as?String ?? copy;let path=FileManager.default.fileExists(atPath:original) ? original:copy;var options:[NSWorkspace.DesktopImageOptionKey:Any]=[:];if let saved=row["options"]as?[String:Any]{for key in [NSWorkspace.DesktopImageOptionKey.imageScaling,.allowClipping]{options[key]=saved[key.rawValue]};if let rgba=saved["fillRGBA"]as?[Double],rgba.count==4{options[.fillColor]=NSColor(deviceRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3])}};try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath:path),for:screen,options:options)}
    }
    func undo()throws{try restoreNative();let old=[settings.videoPath,settings.posterPath].compactMap{$0};settings.mode="still";settings.matchNative=false;settings.selectedID=nil;settings.videoPath=nil;settings.posterPath=nil;try save();reloadImage();for path in old where path.hasPrefix(directory.path+"/"){try? FileManager.default.removeItem(atPath:path)}}
    func update(cpu:Double){if cpu>55{busyUntil=Date().addingTimeInterval(12)}
        let thermal=ProcessInfo.processInfo.thermalState
        let battery:Bool={guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue()else{return false};return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()as String? == kIOPSBatteryPowerValue}()
        let reason=sleeping ? "Paused · display asleep":ProcessInfo.processInfo.isLowPowerModeEnabled ? "Paused · Low Power Mode":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Paused · Reduce Motion":battery ? "Paused · on battery":thermal == .serious || thermal == .critical ? "Paused · Mac is warm":Date()<busyUntil ? "Paused · Mac is busy":""
        if settings.mode != "still" && reason.isEmpty && Date().timeIntervalSince(lastCoverageCheck)>5 {lastCoverageCheck=Date();coveredScreens=[];let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID)as?[[String:Any]] ?? [];let rectangles=windows.compactMap{row->CGRect? in guard (row[kCGWindowLayer as String]as?Int)==0,(row[kCGWindowAlpha as String]as?Double ?? 1)>0.95,let dict=row[kCGWindowBounds as String]as?[String:Any] else{return nil};return CGRect(dictionaryRepresentation:dict as CFDictionary)};for screen in NSScreen.screens {let display=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]as?NSNumber)?.uint32Value ?? 0;let frame=CGDisplayBounds(display);var covered=0;for x in 0..<8{for y in 0..<8{let point=CGPoint(x:frame.minX+(Double(x)+0.5)*frame.width/8,y:frame.minY+(Double(y)+0.5)*frame.height/8);if rectangles.contains(where:{$0.contains(point)}){covered+=1}}};if covered>=58{coveredScreens.insert(display)}}}
        status=settings.mode == "still" ? "Still · lowest power":reason.isEmpty ? settings.mode == "video" ? "Local video · main screen only":"Subtle glow · no video decoding":reason
        for surface in surfaces {let screen=surface.window?.screen;let main=screen==NSScreen.screens.first;let display=(screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]as?NSNumber)?.uint32Value ?? 0;let visible=surface.window?.isVisible == true && !coveredScreens.contains(display);let mode=settings.mode == "video" && !main ? "still":settings.mode;surface.update(image:image,mode:mode,path:settings.videoPath,moving:reason.isEmpty && visible,palette:palette)}
    }
    func importVideo(_ url:URL,completion:@escaping(Error?)->Void){guard !savingVideo else{return};savingVideo=true
        DispatchQueue.global(qos:.utility).async {do {
            let asset=AVURLAsset(url:url);guard let track=asset.tracks(withMediaType:.video).first else{throw ConfigError.invalid("Choose a video file.")}
            let duration=min(CMTimeGetSeconds(asset.duration),30);guard duration.isFinite,duration>0 else{throw ConfigError.invalid("This video has no readable duration.")}
            let composition=AVMutableComposition();let video=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!;try video.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:duration,preferredTimescale:600)),of:track,at:.zero);video.preferredTransform=track.preferredTransform
            guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPreset1280x720)else{throw ConfigError.invalid("Could not optimize this video.")}
            let target=self.directory.appendingPathComponent("loop-\(UUID().uuidString).mp4");exporter.outputURL=target;exporter.outputFileType = .mp4;exporter.shouldOptimizeForNetworkUse=false
            let timing=AVMutableVideoComposition(propertiesOf:composition);timing.sourceTrackIDForFrameTiming=kCMPersistentTrackID_Invalid;timing.frameDuration=CMTime(value:1,timescale:24);exporter.videoComposition=timing
            exporter.exportAsynchronously {DispatchQueue.main.async {self.savingVideo=false;guard exporter.status == .completed else{try? FileManager.default.removeItem(at:target);completion(exporter.error ?? ConfigError.invalid("Video conversion failed."));return};do{let generator=AVAssetImageGenerator(asset:AVURLAsset(url:target));generator.appliesPreferredTrackTransform=true;let frame=try generator.copyCGImage(at:.zero,actualTime:nil);let rep=NSBitmapImageRep(cgImage:frame);let poster=self.directory.appendingPathComponent("poster-\(UUID().uuidString).png");try rep.representation(using:.png,properties:[:])!.write(to:poster);let oldVideo=self.settings.videoPath,oldPoster=self.settings.posterPath;self.settings.videoPath=target.path;self.settings.posterPath=poster.path;self.settings.mode="video";self.reloadImage();try self.save();if self.settings.matchNative{try self.matchNative()};for old in [oldVideo,oldPoster].compactMap({$0}) where old.hasPrefix(self.directory.path+"/"){try? FileManager.default.removeItem(atPath:old)};completion(nil)}catch{completion(error)}}}
        }catch{DispatchQueue.main.async{self.savingVideo=false;completion(error)}}}
    }
}
