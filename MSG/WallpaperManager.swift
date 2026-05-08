import AppKit

class WallpaperManager {
    static let shared = WallpaperManager()
    
    private let fileManager = FileManager.default
    private var originalWallpaperURLs: [String: URL] = [:]
    
    private var baseFolder: URL {
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("MSG")
        let folder = appSupport.appendingPathComponent("Wallpapers")
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func applyDarkMenuBar(to screens: [NSScreen]) {
        for screen in screens {
            guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            
            // Skip if already our modified wallpaper
            if currentURL.path.contains("MSG/Wallpapers") { continue }
            
            // Store original
            originalWallpaperURLs[screen.displayID.description] = currentURL
            
            autoreleasepool {
                if let modifiedURL = modifyWallpaper(at: currentURL, for: screen) {
                    try? NSWorkspace.shared.setDesktopImageURL(modifiedURL, for: screen, options: [:])
                }
            }
        }
    }
    
    func restoreOriginalWallpapers(to screens: [NSScreen]) {
        for screen in screens {
            let id = screen.displayID.description
            if let originalURL = originalWallpaperURLs[id] {
                try? NSWorkspace.shared.setDesktopImageURL(originalURL, for: screen, options: [:])
            }
        }
    }

    private func modifyWallpaper(at url: URL, for screen: NSScreen) -> URL? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        
        let imgSize = image.size
        let screenFrame = screen.frame
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        
        // If we can't detect menu bar height (e.g. hidden), use a standard 24px
        let barHeight = menuBarHeight > 5 ? menuBarHeight : 24
        
        // Scale the bar height based on the image/screen ratio
        let scale = imgSize.height / screenFrame.height
        let imageBarHeight = barHeight * scale
        
        let newImage = NSImage(size: imgSize)
        newImage.lockFocus()
        
        image.draw(in: NSRect(origin: .zero, size: imgSize))
        
        NSColor.black.set()
        let barRect = NSRect(x: 0, y: imgSize.height - imageBarHeight, width: imgSize.width, height: imageBarHeight)
        barRect.fill()
        
        newImage.unlockFocus()
        
        guard let tiff = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        
        let destURL = baseFolder.appendingPathComponent("wallpaper_\(screen.displayID).png")
        try? pngData.write(to: destURL)
        
        return destURL
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
