import Foundation

/// IIG patch (PATCH-NOTES.md, "Clear sky and fill values"): one rule for stored cloud heights, HRRR and RRFS
/// `cloud_base`, `cloud_top` and `cloud_ceiling` (hourly and 15-minute).
///
/// A run with no height at a cell (clear sky; or no top, which HRRR often has under a real base) stores `noValue`,
/// not NaN. Convert skips NaN when it writes a run into the time series (`OmFileSplitter`), so a NaN would keep an
/// older run's height in that hour. NaN keeps its stock meaning: not downloaded (the older value stays).
/// The API turns `noValue` back into null (`VariableHourlyDeriver`), and time interpolation
/// (`ReaderInterpolation.linearCloudHeight`) never blends it with a height.
enum CloudHeight {
    /// Stored for "this run has no height here", in metres. Negative, so never a real height (stored heights are
    /// clamped at 0), and exact in storage: -100 at scale factor 0.1.
    static let noValue: Float = -1000

    /// A stored or read value is `noValue`. Every real height is 0 or more, so any negative value is one.
    @inline(__always)
    static func isNoValue(_ value: Float) -> Bool {
        return value < 0
    }

    /// GRIB heights (metres above sea level) at or below this are fill values, not heights: RRFS writes -5000 for
    /// "no cloud top" (checked on run 2026-11-16 18Z, exactly the cells where cloud base has no value), the stock
    /// check was -99999. The lowest land on the grid is about -90 m.
    static let fillAtOrBelow: Float = -1000

    /// GRIB heights at or above this are fill values too (GRIB's 9.999e20 "missing" where a file has no bitmap).
    /// The highest cloud top in HRRR or RRFS is about 20 km.
    static let fillAtOrAbove: Float = 100_000

    /// One GRIB height (metres above sea level) to the stored height (metres above ground). No value in the GRIB
    /// (NaN: the bitmap) and fill values become `noValue` before the terrain is subtracted, so a fill never clamps
    /// to a fake 0. Terrain: sea is -999 in the elevation file and counts as 0; unknown terrain gives NaN (not
    /// written). A height below the terrain clamps to 0, as stock.
    @inline(__always)
    static func aboveGround(msl value: Float, terrain: Float) -> Float {
        if value.isNaN || value <= fillAtOrBelow || value >= fillAtOrAbove {
            return noValue
        }
        let terrain = terrain == -999 ? 0 : terrain
        if terrain.isNaN {
            return .nan
        }
        return max(value - terrain, 0)
    }

    /// `aboveGround` for a whole field; `elevation` is the domain's terrain file, cell by cell.
    static func convertToAboveGround(data: inout [Float], elevation: [Float]) {
        for i in data.indices {
            data[i] = aboveGround(msl: data[i], terrain: elevation[i])
        }
    }

    /// A value `fraction` (0-1) of the way from `a` to `b`. Linear between two heights. Next to `noValue` it takes
    /// the nearer of the two, and half-way `noValue`: a step between "no cloud" and a height is never given a
    /// height between them. On `a` itself (fraction 0) it is `a`; otherwise NaN on either side gives NaN, as linear.
    @inline(__always)
    static func interpolate(_ a: Float, _ b: Float, fraction: Float) -> Float {
        if fraction == 0 {
            return a
        }
        if a.isNaN || b.isNaN {
            return .nan
        }
        if isNoValue(a) || isNoValue(b) {
            if fraction < 0.5 {
                return isNoValue(a) ? noValue : a
            }
            if fraction > 0.5 {
                return isNoValue(b) ? noValue : b
            }
            return noValue
        }
        return a * (1 - fraction) + b * fraction
    }

    /// Stored values to API values: `noValue` to NaN (null in JSON).
    static func toNull(_ data: [Float]) -> [Float] {
        return data.map { isNoValue($0) ? .nan : $0 }
    }
}
