# PATCH-NOTES: iig/cloud-fields

A small patch on Open-Meteo **1.8.0** (tag `1.8.0`, commit `b66bc9d5`) for the "Is It Good?" weather server
(isitgoodtofly.com, a paragliding forecast app). It adds HRRR cloud fields we need to trace the sun's ray through
the forecast clouds ("is the launch shaded?"), two `download-gfs` options so a 48 h HRRR tail can run beside
the hourly runs ("Convert lock and forecast-hour tail"), and one storage rule for HRRR and RRFS cloud heights so
clear sky and fill values never turn into heights ("Clear sky and fill values"). Nothing else changes.

Branch: `iig/cloud-fields` in https://github.com/collintrickel/open-meteo. Built into the image
`iig/open-meteo:1.8.0-iig.N` by `server/build-image.sh` in the Is It Good? repository.

## What

**HRRR cloud heights** (`hrrr_conus` from `wrfprs`, `hrrr_conus_15min` from `wrfsubh`):

| Stored name | GRIB message | Notes |
|---|---|---|
| `cloud_base` | `HGT:cloud base` | lowest cloud base |
| `cloud_top` | `HGT:cloud top` | highest cloud top |
| `cloud_ceiling` | `HGT:cloud ceiling` | lowest broken/overcast base |

Same storage as RRFS's `cloud_base` / `cloud_top` / `cloud_ceiling` (`NcepRrfsVariable.swift`): metres **above
ground**, scale factor 0.1, linear interpolation, no previous-forecast storage, not elevation-corrected. GRIB
heights are above sea level: the download subtracts the HRRR model terrain (`HSURF`; sea = 0) and clamps at 0,
with the same rule as RRFS (`CloudHeight.convertToAboveGround`). Clear sky is a GRIB bitmap gap in HRRR (checked on
run 2026-11-16 02Z: `HGT:cloud base` packs 813,759 of 1,905,141 points, bitmap indicator 0), which Open-Meteo's
GRIB reader turns into NaN; it is stored as "no value" and the API answers `null` ("Clear sky and fill values").
Hourly from every forecast hour incl. the analysis; 15-minute at :15, :30, :45, :00 (instantaneous, `N min fcst`;
`60 min fcst` at :00).

**HRRR cloud water and cloud ice on pressure levels** (`hrrr_conus`, from `wrfprs`):

| Stored name | GRIB message | Unit |
|---|---|---|
| `cloud_water_mixing_ratio_<p>hPa` | `CLMR:<p> mb` | kg/kg in GRIB, stored g/kg |
| `cloud_ice_mixing_ratio_<p>hPa` | `CIMIXR:<p> mb` | kg/kg in GRIB, stored g/kg |

Levels: every 25 hPa from 1000 to 400 hPa, plus 300 hPa (26 levels; `HrrrPressureVariableSchema.cloudMixingRatioLevels`).
Scale factor 1000 (0.001 g/kg; the GRIB precision is 1e-5 kg/kg), linear interpolation. Two new
`GfsPressureVariableType` cases; HRRR's schema allows them only on those levels; GFS 0.25°'s schema now lists its
seven types explicitly instead of `allCases`, so it doesn't gain them. The forecast API gets the same two names in
`ForecastPressureVariableType`, so `hourly=cloud_water_mixing_ratio_850hPa` is served straight from the stored
field (no derivation). FlatBuffers: the SDK (1.30.0) has no mixing-ratio variable, so these map to `undefined`
with their pressure level; JSON and CSV carry the full names.

## Clear sky and fill values (iig.3)

**The problem (iig.1 and iig.2, and stock RRFS).** A cell with no cloud height was stored as NaN. Convert writes a run
into the time series by skipping NaN (`OmFileSplitter`: NaN means "not downloaded, keep what is there"), so an hour
that a newer run calls clear kept the older run's height. Three more paths made heights out of "no cloud": convert
fills NaN gaps in time linearly (`interpolateInplaceLinear`), so a clear hour between two cloudy hours got a height
between them; the API fills 15-minute steps from hourly data linearly (`interpolateLinear`); and the HRRR API mixes
the 15-minute domain over the hourly one by filling NaN from the lower priority (`GenericReaderMixerSameVariableType`),
so a 15-minute "clear" took the interpolated hourly value.

**RRFS fill values (stock).** RRFS writes "no cloud top" as **-5000** (no bitmap), not NaN: on run 2026-11-16 18Z f01
its 771,164 cloud-top cells of -5000 are exactly the cells where cloud base has no value (bitmap). The stock check
only caught `<= -99999`, so -5000 minus terrain clamped to a top of **0 m**; under it, cloud base was NaN, so convert
kept an older run's base. That is "RRFS tops of 0 under real bases": the same problem, fixed the same way here. HRRR
has no fill values (bitmap only; every packed value checked positive on 2026-11-16 18Z f00 and f03).

**The rule** (`Sources/App/Helper/CloudHeight.swift`), for HRRR `hrrr_conus` and `hrrr_conus_15min` and RRFS
`ncep_rrfs_conus`, `ncep_rrfs_conus_15min` and `ncep_rrfs_north_america` (`cloud_base`, `cloud_top`,
`cloud_ceiling`):

- **Download:** no value in the GRIB (NaN: the bitmap) and fill values (at or below -1000 m or at or above 100 km
  above sea level) become `CloudHeight.noValue` = **-1000 m** *before* the terrain is subtracted, so a fill never
  clamps to 0. Real heights: minus terrain, clamped at 0, as before. Unknown terrain still gives NaN.
- **Storage:** -1000 m is stored exactly (-100 at scale factor 0.1) and is never a real height (those are 0 or more),
  so any negative stored value means "no value in this run". Convert writes it like any value: a newer run's clear
  hour replaces an older run's height. NaN keeps its stock meaning (not downloaded: the older value stays).
- **Time interpolation:** a new `ReaderInterpolation.linearCloudHeight`, used by these fields and by every place
  that interpolates in time: the API's 15-minute steps from hourly data and convert's gap fill. Between two heights
  it is linear, as before. Next to "no value" it takes the nearer step and, half-way, "no value" (`CloudHeight.interpolate`):
  a step between "no cloud" and a height never gets a height between them. Hourly from 15-minute data was already
  the instantaneous value (no blending).
- **API:** `VariableHourlyDeriver` turns "no value" into NaN (`null`) for `cloud_base`, `cloud_top` and `cloud_ceiling`
  on those domains (`storesCloudHeightNoValue`). It runs after the HRRR hourly and 15-minute domains are mixed, so a
  15-minute "no cloud" is never filled from the hourly domain. API answers are unchanged in form: a height in metres
  above ground, or `null`.

**Why a stored value and not NaN.** NaN is the only "missing" the stock code has, and every writer and reader treats it
as "unknown, take something else": the older run, a gap fill, the lower-priority domain. "No cloud" is a forecast,
not an unknown, so it needs its own value. A negative height is the one value that can't collide with a real one,
and keeping it through the reader's mixer (not NaN until the deriver) closes the 15-minute path too.

**What the data says about tops** (checked with `server/tools/grib-point.sh` in the Is It Good? repository, run
2026-11-16 18Z): HRRR writes no cloud top at about half of the cells that have a cloud base (446,910 of 856,246 at f00;
525,902 of 970,278 at f03). The API answers `null` for such a top under a real base: that is HRRR's answer, not a
missing download. RRFS has a top wherever it has a base. In both models a few hundred cells have the top below the
base (1,345 HRRR f00, 151 RRFS f01); stored as they come.

**Change over:** values written before iig.3 stay until a newer run writes the same hour: NaN there reads as `null`
(as before), an older stale height or an RRFS top of 0 stays until then. HRRR's hourly runs replace hours 0-18 within
the hour, the 48 h tail its hours within 6 h; RRFS within its own run length.

**Not changed:** `ncep_rrfs_seamless` mixes RRFS 15-minute and hourly data *after* deriving each, so a 15-minute
`null` there can still take the hourly RRFS value of the nearer hour (a model height, never a blend). Is It Good?
asks `ncep_rrfs_conus`. Other models' cloud heights (DMI, ICON, MeteoSwiss) are untouched.

## Convert lock and forecast-hour tail (`download-gfs`)

Lets the 48 h tail of HRRR's 00/06/12/18Z cycles download beside the hourly runs without delaying them: the hourly
job runs `--max-forecast-hour 18` every hour, a second job runs `--run <cycle> --min-forecast-hour 19
--max-forecast-hour 48` for the long cycles, as long as it needs. Both pass the same `--convert-lock <file>`.

- `--min-forecast-hour N`: forecast hours below N are left out (the same filter as `--max-forecast-hour`; the HRRR
  15-minute loop runs `N...max` too). Above 0 it makes a **tail run**, which:
  - writes no `static/meta.json` (it names the newest run, which the app shows as the run's age; a tail of an older
    cycle would roll it back) and no full-run files (`data_run/<domain>/<run>/`, which belong to the run's head;
    only with `DATA_RUN_DIRECTORY` set);
  - under the lock, reads `static/meta.json`: if a newer run has been converted since, the tail leaves out the hours
    before that run's `data_end_time`, so an older cycle never overwrites newer hours (a 00Z tail finishing at 03:40Z
    keeps 03Z's hours 19-21 Z). Hours left out are not written (convert skips NaN), the newer values stay.
- `--convert-lock <path>`: an exclusive `flock` (blocking; logged `convert-lock: waiting for <path>` and
  `convert-lock: acquired after N s`, then `released`) around `GenericVariableHandle.convert` and the tail's
  meta.json check. Downloading (GRIB fetch, decoding, the per-hour spatial temp files) stays outside it. Released on
  return or error; the kernel releases it if the process dies. Works across containers on the same bind mount. The
  file is opened read-only (created if missing), so it may belong to another user.
- `convert` was checked as the only step writing the domain's shared files: time-series chunks and previous-day
  chunks (`OmFileSplitter.updateFromTimeOrientedStreaming3D`), `static/meta.json`, full-run files. Two other
  writes happen during download: the static **elevation file** (`static/HSURF.om`, `downloadNcepElevation`), written
  only when it is missing, now under the lock too (checked again inside, so the second process skips it); and
  `OmSpatialTimestepWriter`'s per-step files, which are per-process temporary files unless `DATA_SPATIAL_DIRECTORY`
  is set (then per-run files plus `in-progress.json` / `latest.json`; not used by Is It Good?, not locked).
- Fixed on the way: the first hour of a download had `dtSeconds` from `previousHour == 0`; with a tail the first
  hour's previous hour is itself, which gave 0 s (HRRR `precipitation` = rate × 0). The first hour now uses the
  domain's step, as hour 0 always did.
- Known difference at the seam: HRRR's instantaneous sunlight is turned into a backwards mean with the previous
  hour's clearness index for the sun below 3° (`InstantaneousSolarRadiationConverter`). A tail's first hour (f19)
  has no previous hour, so at sunrise/sunset pixels it uses its own value. The sun is that low there only.
- A tail starting at a GFS 3-hourly step would take the domain's 1 h as its first step; not used (HRRR is hourly).

## Files

- `Sources/App/Gfs/GfsVariable.swift`: `GfsSurfaceField` cloud heights and metadata; pressure types, scale, interpolation, unit; HRRR schema levels; GFS 0.25° type list.
- `Sources/App/Gfs/GfsDomainVariable.swift`: cloud heights in `HrrrSurfaceVariable` and `Hrrr15MinSurfaceVariable` (what the API reads).
- `Sources/App/Gfs/GfsVariableDownloadable.swift`: GRIB index names (hourly and 15-minute), `CLMR` / `CIMIXR`, kg/kg to g/kg.
- `Sources/App/Gfs/GfsDownload.swift`: the above-ground conversion (`CloudHeight.convertToAboveGround`) in the hourly and 15-minute loops.
- `Sources/App/Helper/CloudHeight.swift`: "no value", fill values, above ground, interpolation, null (iig.3).
- `Sources/App/Helper/Reader/GenericDomain.swift`, `Helper/Interpolation.swift`, `Helper/InterpolationInplace.swift`, `Helper/Aggregation.swift`, `Helper/Reader/GenericReader.swift`: `ReaderInterpolation.linearCloudHeight` in every switch (iig.3).
- `Sources/App/Gfs/GfsVariable.swift`, `Sources/App/NcepRrfs/NcepRrfsVariable.swift`: cloud heights use `.linearCloudHeight` (iig.3).
- `Sources/App/NcepRrfs/NcepRrfsVariableDownloadable.swift`: RRFS `convertCloudHeightToAboveGround` uses the same rule (iig.3).
- `Sources/App/Controllers/VariableHourly.swift`: `storesCloudHeightNoValue` and "no value" to `null` (iig.3).
- `Tests/AppTests/CloudHeightTests.swift` (new), `Tests/AppTests/NcepRrfsTests.swift` (`cloudHeightsAndWaterAmounts`: NaN and -99999 are now "no value") (iig.3).
- `Sources/App/Controllers/VariableHourly.swift`, `Sources/App/Helper/FlatBufferWriter/FlatBuffers+WeatherApi.swift`: the two API pressure names.
- `Sources/App/Gfs/GfsDownload.swift`, `Sources/App/Gfs/GfsConvertLock.swift`: `--min-forecast-hour`, `--convert-lock`, the tail's rules (above).
- `Sources/App/Controllers/VariableHourly.swift` `pressureLevelInput`: the two names join the `vertical_velocity` group (`return raw()`), keeping that switch exhaustive; no interpolation between levels.

## Behaviour not changed

Every existing variable keeps its GRIB name, storage, scale and API answer, except RRFS cloud heights (iig.3, "Clear
sky and fill values"): no value is stored as -1000 m instead of NaN, a "no cloud top" is `null` instead of 0, and an
hour a newer run calls clear is `null` instead of an older run's height. The new fields are downloaded only
when named (`--only-variables`), or with no list: a plain `download-gfs hrrr_conus` (surface) now also fetches the
three cloud heights, and `--upper-level` also fetches the mixing ratios. GFS, GEFS and NAM are untouched.
Without `--min-forecast-hour` and `--convert-lock`, `download-gfs` does exactly what it did (the `dtSeconds` change
gives the same value whenever the first hour is hour 0).

## Why

The app's cloud-shade hint follows the sun's slanted ray from a launch through nearby forecast clouds. HRRR's
column sunlight only sees cloud straight overhead; the ray needs cloud base and top per cell (15-minute), and, for
layered skies, cloud water and ice per level (hourly). RRFS already has the heights in Open-Meteo; HRRR didn't.

## License

Open-Meteo is AGPL-3.0 (`LICENSE`). This patch is published under the same license in this public fork, and the
server that runs it links here. Weather data: NOAA HRRR (public domain).
