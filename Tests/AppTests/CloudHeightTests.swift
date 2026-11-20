import Foundation
import Testing
@testable import App

/// IIG patch (PATCH-NOTES.md, "Clear sky and fill values")
@Suite struct CloudHeightTests {
    let no = CloudHeight.noValue

    @Test func aboveGroundTurnsNoValueAndFillsIntoNoValueBeforeTheClamp() {
        // RRFS "no cloud top" is -5000: it must not clamp to a top of 0 m
        #expect(CloudHeight.aboveGround(msl: -5000, terrain: 1879.8) == no)
        // stock RRFS fill, GRIB "missing" without a bitmap, no value (bitmap)
        #expect(CloudHeight.aboveGround(msl: -99999, terrain: 0) == no)
        #expect(CloudHeight.aboveGround(msl: 9.999e20, terrain: 0) == no)
        #expect(CloudHeight.aboveGround(msl: .nan, terrain: 1873.4) == no)
        #expect(CloudHeight.aboveGround(msl: .nan, terrain: .nan) == no)
        // real heights: above ground, clamped at 0; sea (-999) counts as 0
        #expect(CloudHeight.aboveGround(msl: 2500, terrain: 1873.5) == 626.5)
        #expect(CloudHeight.aboveGround(msl: 1800, terrain: 1873.5) == 0)
        #expect(CloudHeight.aboveGround(msl: 300, terrain: -999) == 300)
        // unknown terrain: not written (NaN), as stock
        #expect(CloudHeight.aboveGround(msl: 1500, terrain: .nan).isNaN)

        var field: [Float] = [1500, -5000, .nan]
        CloudHeight.convertToAboveGround(data: &field, elevation: [500, 1000, 0])
        #expect(field == [1000, no, no])
    }

    @Test func noValueIsStoredExactly() {
        // Int16 at scale factor 0.1, as the OM files store it: -100, read back as about -1000
        let stored = Int16((no * 0.1).rounded())
        #expect(stored == -100)
        #expect(abs(Float(stored) / 0.1 - no) < 0.01 && CloudHeight.isNoValue(Float(stored) / 0.1))
        #expect(CloudHeight.isNoValue(no))
        #expect(!CloudHeight.isNoValue(0))
        #expect(!CloudHeight.isNoValue(.nan))
    }

    @Test func interpolateNeverBlendsNoValueWithAHeight() {
        #expect(CloudHeight.interpolate(1000, 2000, fraction: 0.25) == 1250)
        #expect(CloudHeight.interpolate(1000, no, fraction: 0.25) == 1000)
        #expect(CloudHeight.interpolate(1000, no, fraction: 0.5) == no)
        #expect(CloudHeight.interpolate(1000, no, fraction: 0.75) == no)
        #expect(CloudHeight.interpolate(no, 1000, fraction: 0.25) == no)
        #expect(CloudHeight.interpolate(no, 1000, fraction: 0.5) == no)
        #expect(CloudHeight.interpolate(no, 1000, fraction: 0.75) == 1000)
        #expect(CloudHeight.interpolate(no, no, fraction: 0.5) == no)
        // NaN = missing: as linear, except on the known step itself
        #expect(CloudHeight.interpolate(1000, .nan, fraction: 0.25).isNaN)
        #expect(CloudHeight.interpolate(1000, .nan, fraction: 0) == 1000)
    }

    @Test func readerInterpolationHourlyTo15Minutes() {
        let hourly = TimerangeDt(start: Timestamp(0), nTime: 4, dtSeconds: 3600)
        let data: [Float] = [1000, no, 2000, 3000]
        let out = data.interpolate(type: .linearCloudHeight, timeOld: hourly, timeNew: hourly.with(dtSeconds: 900), latitude: 0, longitude: 0, scalefactor: 1)
        #expect(out == [1000, 1000, no, no, no, no, no, 2000, 2000, 2250, 2500, 2750, 3000, 3000, 3000, 3000])
        // nothing between "no cloud" and a height is ever a height between them
        #expect(!out.contains { $0 > 1000 && $0 < 2000 })
    }

    @Test func readerAggregation15MinutesToHourlyTakesTheInstantaneousValue() {
        let quarter = TimerangeDt(start: Timestamp(0), nTime: 8, dtSeconds: 900)
        let data: [Float] = [no, 500, 600, 700, 800, no, no, no]
        let out = data.aggregate(type: .linearCloudHeight, timeOld: quarter, timeNew: quarter.with(dtSeconds: 3600))
        #expect(out == [no, 800])
    }

    @Test func convertGapFillNeverBlendsNoValueWithAHeight() {
        var a: [Float] = [1000, .nan, .nan, .nan, no, .nan, 2000, .nan, 3000]
        a.interpolateInplace(type: .linearCloudHeight, time: TimerangeDt(start: Timestamp(0), nTime: 9, dtSeconds: 3600), grid: RegularGrid(nx: 1, ny: 1, latMin: 0, lonMin: 0, dx: 1, dy: 1), locationRange: 0..<1)
        #expect(a == [1000, 1000, no, no, no, no, 2000, 2500, 3000])

        // two locations; leading and trailing NaN stay NaN, as linear
        var b: [Float] = [.nan, no, .nan, 800, .nan, 700, .nan, .nan]
        b.interpolateInplaceLinearCloudHeight(nTime: 4)
        #expect(b[0].isNaN && b[1] == no && b[2] == no && b[3] == 800)
        #expect(b[4].isNaN && b[5] == 700 && b[6].isNaN && b[7].isNaN)
    }

    @Test func toNull() {
        let out = CloudHeight.toNull([no, 0, 1234.5, .nan])
        #expect(out[0].isNaN && out[1] == 0 && out[2] == 1234.5 && out[3].isNaN)
    }

    @Test func cloudHeightVariablesUseTheRule() {
        for v in [HrrrSurfaceVariable.cloud_base, .cloud_top, .cloud_ceiling] {
            if case .linearCloudHeight = v.interpolation {} else { Issue.record("\(v) interpolation") }
        }
        for v in [Hrrr15MinSurfaceVariable.cloud_base, .cloud_top, .cloud_ceiling] {
            if case .linearCloudHeight = v.interpolation {} else { Issue.record("\(v) interpolation") }
        }
        for v in [NcepRrfsSurfaceVariable.cloud_base, .cloud_top, .cloud_ceiling] {
            if case .linearCloudHeight = v.interpolation {} else { Issue.record("\(v) interpolation") }
        }
        for v in [NcepRrfs15MinVariable.cloud_base, .cloud_top, .cloud_ceiling] {
            if case .linearCloudHeight = v.interpolation {} else { Issue.record("\(v) interpolation") }
        }
    }
}
