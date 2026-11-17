import Foundation
import Logging

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// IIG patch (PATCH-NOTES.md, "Convert lock and forecast-hour tail"): `download-gfs --convert-lock <path>`.
///
/// Two downloads of the same domain may run at once (Is It Good?: the hourly HRRR job to 18 h, and the 48 h tail of
/// the 00/06/12/18Z cycles from hour 19). Downloading GRIB files only writes temporary, per-process files; the steps
/// that write the domain's shared files (time-series chunks, previous-day chunks, `static/meta.json`, full-run
/// files, and the static elevation file when it is missing) run while holding an exclusive `flock` on `path`, so
/// two processes never write those files at the same time. Blocking: a second process waits, logging when it starts
/// waiting and when it has the lock. Released when `body` returns or throws, or by the kernel if the process dies.
/// Without a path, `body` just runs.
func withConvertLock<T>(path: String?, logger: Logger, what: String, _ body: () async throws -> T) async throws -> T {
    guard let path else {
        return try await body()
    }
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
        throw ConvertLockError.open(path: path, errno: errno)
    }
    defer { close(fd) }

    let start = DispatchTime.now()
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        // EWOULDBLOCK is EAGAIN on Linux and Darwin
        guard errno == EAGAIN else {
            throw ConvertLockError.lock(path: path, errno: errno)
        }
        logger.info("convert-lock: waiting for \(path) (\(what))")
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw ConvertLockError.lock(path: path, errno: errno)
            }
        }
    }
    let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    // run-job.sh (Is It Good? server) adds up the "acquired after N s" lines of a run for runs.csv
    logger.info("convert-lock: acquired after \(Int(waited.rounded())) s (\(what))")
    defer {
        flock(fd, LOCK_UN)
        logger.info("convert-lock: released (\(what))")
    }
    return try await body()
}

enum ConvertLockError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case lock(path: String, errno: Int32)

    var description: String {
        switch self {
        case .open(let path, let e): return "convert-lock: cannot open \(path): \(String(cString: strerror(e)))"
        case .lock(let path, let e): return "convert-lock: flock on \(path) failed: \(String(cString: strerror(e)))"
        }
    }
}

/// IIG patch: a forecast-hour tail (`--min-forecast-hour` above 0) of an older run must not overwrite hours a newer
/// run has already written. `static/meta.json` names the newest run converted into the domain and the end of its
/// hours (`data_end_time`, exclusive; a tail never writes meta.json). If that run is newer than `run`, drop the
/// handles before that end. Call while holding the convert lock, so meta.json can't change in between.
func dropHoursWrittenByNewerRun(domain: GenericDomain, run: Timestamp, handles: [GenericVariableHandle], logger: Logger) -> [GenericVariableHandle] {
    let path = ModelUpdateMetaFile(domain: domain.domainRegistry).getFilePath()
    guard let data = FileManager.default.contents(atPath: path),
          let meta = try? JSONDecoder().decode(ModelUpdateMetaJson.self, from: data) else {
        logger.info("Tail: no readable \(path), keeping every hour")
        return handles
    }
    let newestRun = Timestamp(meta.last_run_initialisation_time)
    guard newestRun > run else {
        return handles
    }
    let end = Timestamp(meta.data_end_time)
    let kept = handles.filter { $0.time.range.lowerBound >= end }
    if kept.count < handles.count {
        logger.info("Tail: run \(newestRun.iso8601_YYYY_MM_dd_HH_mm) already wrote hours before \(end.iso8601_YYYY_MM_dd_HH_mm); \(handles.count - kept.count) of \(handles.count) handles of run \(run.iso8601_YYYY_MM_dd_HH_mm) left out")
    }
    return kept
}
