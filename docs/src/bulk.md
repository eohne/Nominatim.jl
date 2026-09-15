# Bulk geocoding

Nominatim has no batch endpoint, so [`geocode_batch`](@ref) sends one request per
address. How fast that goes depends entirely on the server:

| Server | Speed | Suitable for |
|---|---|---|
| Public (`nominatim.openstreetmap.org`) | 1 query/second, one at a time; jobs longer than a day are cut to 4/minute | up to a few thousand addresses |
| Your own | as fast as your machine answers, many at a time | millions |

To set up your own server, see [Running your own server](self_hosting.md).

## Input

A vector of strings:

```julia
results = geocode_batch(["350 5th Ave, New York, NY 10118",
                         "1600 Pennsylvania Ave NW, Washington, DC 20500"])
```

Or a `DataFrame` (or vector of NamedTuples) with structured columns, which usually
match more precisely:

```julia
using DataFrames

addresses = DataFrame(
    street = ["350 5th Ave", "1600 Pennsylvania Ave NW"],
    city   = ["New York", "Washington"],
    state  = ["NY", "DC"],
    zip    = [10118, 20500],          # integer ZIP codes keep their leading zeros
)
results = geocode_batch(addresses; countrycodes = "us")
```

Recognised columns (case-insensitive):

- **free text:** `query`, `address` or `q`
- **structured:** `street` (house number and street), `city`, `county`, `state`,
  `country`, `postalcode` (or `zip`, `zipcode`, `postcode`, `postal_code`),
  `amenity`

Use one kind or the other; other columns are ignored.

## Output

One row per input, in input order:

| Column | |
|---|---|
| `input_index`, `input_query` | which input the row belongs to |
| `status` | `"matched"`, `"no_match"`, `"error"`, `"empty_input"` |
| `error_message` | why a query failed |
| `requested_house_number`, `house_number_matches` | the house number in your input, and whether the result has it |
| `name`, `display_name`, `category`, `place_type`, `addresstype` | what is there |
| `latitude`, `longitude` | |
| `match_level`, `place_rank`, `likely_interpolated`, `importance` | match quality |
| `address_house_number` … `address_country_code` | address parts |
| `bbox_south`, `bbox_north`, `bbox_west`, `bbox_east` | bounding box |
| `osm_type`, `osm_id`, `place_id` | identifiers |
| `address_json`, `extratags_json`, `namedetails_json`, `entrances_json`, `geometry_geojson` | everything else, as JSON text |

With `expand = true`, every extra tag and name variant gets its own column too
(`tag_website`, `tag_phone`, `name_short_name`, …).

Keep only exact address-point matches:

```julia
exact = filter(results) do row
    row.status == "matched" &&
    row.match_level == "house_or_poi" &&
    row.house_number_matches === true &&
    row.likely_interpolated === false
end
```

## Large jobs on your own server

```julia
using Nominatim, DataFrames, CSV

client = NominatimClient(base_url = "http://127.0.0.1:8088")
addresses = CSV.read("addresses.csv", DataFrame)

results = geocode_batch(addresses; client,
                        countrycodes = "us",
                        concurrent_requests = 12,
                        checkpoint_file = "addresses.checkpoint.jsonl")

CSV.write("addresses_geocoded.csv", results)
```

- **`concurrent_requests`**: how many queries run at once. Start around the number
  of API worker processes (`-w` in the gunicorn command, or `GUNICORN_WORKERS` for
  Docker) and watch the queries/second in the progress log; more is not faster
  once the server is saturated. The public server always gets 1.
- **`checkpoint_file`**: every answer is appended to this file the moment it
  arrives. If the run stops (crash, Ctrl+C, restart), run **the same call** again:
  answered queries are read back from the file and only the rest is sent. Queries
  that ended in an error are not stored, so they are retried. An entry is only
  reused if the query at that position is unchanged.
- Progress is logged every 30 seconds (`progress_every_seconds`).
- Record `server_status(client).data_updated` with your results: it is the date
  of the OpenStreetMap data you geocoded against.

The checkpoint file stores the raw server answers (a few kB per address), so it
doubles as a complete, re-parseable record of the run.

## How fast is it?

Measured on a laptop (Intel Core Ultra 9 185H, NVMe SSD, WSL2 with 48 GB RAM and
10 cores, 8 gunicorn workers, US database of 90 GB), structured US addresses,
`concurrent_requests = 12`:

| Situation | Throughput | 1 million addresses |
|---|---|---|
| Server just started (database not in memory) | 12–15 queries/s at first | — |
| After ~1,500 new addresses | ~50 queries/s | ~5.5 h |
| Addresses the server has seen before | ~100 queries/s | ~2.8 h |
| Average over the first 2,000 new addresses | 25–31 queries/s | — |

- The first minutes are slow while PostgreSQL reads the database into memory;
  throughput then keeps rising. Plan a large run as one long job rather than many
  short ones with server restarts in between.
- More than about 12 concurrent requests did not help with 8 server workers.
- Requesting full detail (extra tags, name variants, geometry) costs no
  measurable time: the database search dominates.
- **Sorting the input by state / ZIP code / street does not help.** In repeated
  cold-start runs on the same 2,040 addresses (60 ZIP codes), shuffled order was
  as fast or slightly faster (25–27 vs 31 queries/s).
- Nominatim has no multi-address request, and one would not help: sending the
  request and parsing the JSON take under a millisecond, the search itself
  20–150 ms.

## Coordinates to addresses

```julia
results = reverse_geocode_batch(latitudes, longitudes; client,
                                concurrent_requests = 12,
                                checkpoint_file = "points.checkpoint.jsonl")
```

Missing or `NaN` coordinates get `status = "empty_input"`.
