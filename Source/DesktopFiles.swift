import Cocoa
import ImageIO

struct DesktopDrop {
    var urls:[URL]
    var pngData:Data?
}
final class DesktopFileStore {
    let desktop:URL
    init(desktop:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop",isDirectory:true)){self.desktop=desktop}
    func uniqueTarget(_ name:String,attempt:Int)->URL {
        let original=URL(fileURLWithPath:name),stem=original.deletingPathExtension().lastPathComponent,ext=original.pathExtension
        let candidate=attempt==0 ? name : stem+" (\(attempt+1))"+(ext.isEmpty ? "":"."+ext)
        return desktop.appendingPathComponent(candidate)
    }
    func addFile(_ source:URL) throws -> URL {
        var isDir:ObjCBool=false
        guard source.isFileURL,FileManager.default.fileExists(atPath:source.path,isDirectory:&isDir),!isDir.boolValue else {throw ConfigError.invalid("Drop image files or screenshots, rather than folders.")}
        if source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == desktop.resolvingSymlinksInPath().standardizedFileURL {return source}
        for n in 0..<1000 {
            let target=uniqueTarget(source.lastPathComponent,attempt:n)
            if FileManager.default.fileExists(atPath:target.path){continue}
            do {try FileManager.default.copyItem(at:source,to:target);return target}
            catch {if FileManager.default.fileExists(atPath:target.path){continue};throw error}
        }
        throw ConfigError.invalid("Could not choose an unused Desktop filename.")
    }
    func addPNG(_ data:Data) throws -> URL {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source)>0,CGImageSourceCreateImageAtIndex(source,0,nil) != nil else {throw ConfigError.invalid("The dragged image could not be read.")}
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd 'at' HH.mm.ss";let name="Screenshot \(formatter.string(from:Date())).png"
        for n in 0..<1000 {
            let target=uniqueTarget(name,attempt:n)
            do {try data.write(to:target,options:.withoutOverwriting);return target}
            catch {if FileManager.default.fileExists(atPath:target.path){continue};throw error}
        }
        throw ConfigError.invalid("Could not choose an unused screenshot filename.")
    }
    func thumbnail(_ url:URL,maxPixels:Int=180)->String? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxPixels] as CFDictionary) else{return nil}
        let data=NSMutableData();guard let output=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)else{return nil};CGImageDestinationAddImage(output,image,nil);guard CGImageDestinationFinalize(output)else{return nil}
        return "data:image/png;base64,"+(data as Data).base64EncodedString()
    }
}
