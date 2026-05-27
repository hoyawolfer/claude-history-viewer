import Foundation
import CoreServices

/// FSEvents 包装：递归监听目录树，把变化路径以批为单位回调。
/// 内部已经做 1 秒 latency 聚合，外层不需要再加防抖。
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let directory: URL
    private let queue: DispatchQueue
    private var handler: (([URL]) -> Void)?

    init(directory: URL) {
        self.directory = directory
        self.queue = DispatchQueue(label: "FileWatcher.\(directory.lastPathComponent)")
    }

    deinit { stop() }

    func start(onChange: @escaping ([URL]) -> Void) {
        stop()
        self.handler = onChange

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [directory.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes  // eventPaths 用 CFArray<CFString>
          | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
                var urls: [URL] = []
                for i in 0..<CFArrayGetCount(cfArray) {
                    let raw = CFArrayGetValueAtIndex(cfArray, i)
                    let cfStr = unsafeBitCast(raw, to: CFString.self)
                    urls.append(URL(fileURLWithPath: cfStr as String))
                }
                _ = count
                watcher.handler?(urls)
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,        // 1 秒批
            flags
        ) else {
            print("[FileWatcher] FSEventStreamCreate failed for \(directory.path)")
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        if !FSEventStreamStart(s) {
            print("[FileWatcher] FSEventStreamStart failed")
            FSEventStreamRelease(s)
            return
        }
        self.stream = s
        print("[FileWatcher] watching \(directory.path)")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        self.stream = nil
    }
}
