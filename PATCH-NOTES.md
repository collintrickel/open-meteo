# PATCH-NOTES: iig/cloud-fields

A small patch on Open-Meteo **1.8.0** (tag `1.8.0`, commit `b66bc9d5`) for the "Is It Good?" weather server
(isitgoodtofly.com, a paragliding forecast app). It adds HRRR cloud fields we need to trace the sun's ray through
the forecast clouds ("is the launch shaded?"), and two `download-gfs` options so a 48 h HRRR tail can run beside
the hourly runs ("Convert lock and forecast-hour tail"). Nothing else changes.

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
exactly as `convertCloudHeightToAboveGround` does for RRFS. Clear sky is a GRIB bitmap gap in HRRR (checked on
run 2026-11-16 02Z: `HGT:cloud base` packs 813,759 of 1,905,141 points, bitmap indicator 0), which Open-Meteo's
GRIB reader turns into NaN; NaN stays NaN (the API answers `null`). Hourly from every forecast hour incl. the
analysis; 15-minute at :15, :30, :45, :00 (instantaneous, `N min fcst`).

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
  return or error; the kernel releases it if the process dies. Works across containers on the same bind mount.
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
- `Sources/App/Gfs/GfsVariableDownloadable.swift`: GRIB index names (hourly and 15-minute), `CLMR` / `CIMIXR`, kg/kg to g/kg, `convertGfsCloudHeightToAboveGround`.
- `Sources/App/Gfs/GfsDownload.swift`: the above-ground conversion in the hourly and 15-minute loops.
- `Sources/App/Controllers/VariableHourly.swift`, `Sources/App/Helper/FlatBufferWriter/FlatBuffers+WeatherApi.swift`: the two API pressure names.
- `Sources/App/Gfs/GfsDownload.swift`, `Sources/App/Gfs/GfsConvertLock.swift`: `--min-forecast-hour`, `--convert-lock`, the tail's rules (above).
- `Sources/App/Controllers/VariableHourly.swift` `pressureLevelInput`: the two names join the `vertical_velocity` group (`return raw()`), keeping that switch exhaustive; no interpolation between levels.

## Behaviour not changed

Every existing variable keeps its GRIB name, storage, scale and API answer. The new fields are downloaded only
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
