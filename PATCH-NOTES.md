# PATCH-NOTES: iig/cloud-fields

A small patch on Open-Meteo **1.8.0** (tag `1.8.0`, commit `b66bc9d5`) for the "Is It Good?" weather server
(isitgoodtofly.com, a paragliding forecast app). It adds HRRR cloud fields we need to trace the sun's ray through
the forecast clouds ("is the launch shaded?"). Nothing else changes.

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

## Files

- `Sources/App/Gfs/GfsVariable.swift`: `GfsSurfaceField` cloud heights and metadata; pressure types, scale, interpolation, unit; HRRR schema levels; GFS 0.25° type list.
- `Sources/App/Gfs/GfsDomainVariable.swift`: cloud heights in `HrrrSurfaceVariable` and `Hrrr15MinSurfaceVariable` (what the API reads).
- `Sources/App/Gfs/GfsVariableDownloadable.swift`: GRIB index names (hourly and 15-minute), `CLMR` / `CIMIXR`, kg/kg to g/kg, `convertGfsCloudHeightToAboveGround`.
- `Sources/App/Gfs/GfsDownload.swift`: the above-ground conversion in the hourly and 15-minute loops.
- `Sources/App/Controllers/VariableHourly.swift`, `Sources/App/Helper/FlatBufferWriter/FlatBuffers+WeatherApi.swift`: the two API pressure names.
- `Sources/App/Controllers/VariableHourly.swift` `pressureLevelInput`: the two names join the `vertical_velocity` group (`return raw()`), keeping that switch exhaustive; no interpolation between levels.

## Behaviour not changed

Every existing variable keeps its GRIB name, storage, scale and API answer. The new fields are downloaded only
when named (`--only-variables`), or with no list: a plain `download-gfs hrrr_conus` (surface) now also fetches the
three cloud heights, and `--upper-level` also fetches the mixing ratios. GFS, GEFS and NAM are untouched.

## Why

The app's cloud-shade hint follows the sun's slanted ray from a launch through nearby forecast clouds. HRRR's
column sunlight only sees cloud straight overhead; the ray needs cloud base and top per cell (15-minute), and, for
layered skies, cloud water and ice per level (hourly). RRFS already has the heights in Open-Meteo; HRRR didn't.

## License

Open-Meteo is AGPL-3.0 (`LICENSE`). This patch is published under the same license in this public fork, and the
server that runs it links here. Weather data: NOAA HRRR (public domain).
