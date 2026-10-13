import Foundation
import Darwin

/// Debug-only bounded numeric observations; no identifiers or crypto material.
enum E2eeArchiveCost {
    static func record(_ phase: String, _ reason: String, _ started: UInt64, bytes: Int = 0) {
        #if DEBUG
        let elapsed=(DispatchTime.now().uptimeNanoseconds-started)/1000
        var usage=rusage();let peak = phase == "http" && getrusage(0,&usage)==0 ? usage.ru_maxrss : 0
        log.info("archive_cost phase=\(phase) reason=\(reason) latency_us=\(elapsed) encoded_bytes=\(bytes) peak_rss_bytes=\(peak)",subsystems:.mls)
        #endif
    }
}
