# Nominatim.jl
[![Docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://eohne.github.io/Nominatim.jl/dev/)
[![CI](https://github.com/eohne/Nominatim.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/eohne/Nominatim.jl/actions/workflows/CI.yml)
[![Online tests](https://github.com/eohne/Nominatim.jl/actions/workflows/OnlineTests.yml/badge.svg)](https://github.com/eohne/Nominatim.jl/actions/workflows/OnlineTests.yml)
[![Documentation](https://github.com/eohne/Nominatim.jl/actions/workflows/Documenter.yml/badge.svg)](https://github.com/eohne/Nominatim.jl/actions/workflows/Documenter.yml)

A readable Julia client for [Nominatim](https://nominatim.org/), the open-source
geocoder built on OpenStreetMap data. Free, no API key.

- **Exact addresses → coordinates**, by free text or by address fields.
- **Everything Nominatim knows** about the match: the name of what is there,
  its category (office, restaurant, house, …), the full address, bounding box,
  geometry, website, phone, opening hours, name variants and entrances.
- **Honest match quality**: house-level vs street-level matches, whether the
  house number matches your input, and a flag for interpolated (estimated)
  addresses.
- **Bulk geocoding** that can be interrupted and resumed, with parallel requests
  against your own server.
- Works with the **public server** (its usage policy is enforced for you) or
  **your own server** (no limits).

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/eohne/Nominatim.jl")
```

## Quick start

```julia
using Nominatim

# Public server: identify your application, as its usage policy requires.
client = NominatimClient(user_agent = "HousingStudy/1.0 (me@university.edu)")

place = geocode(street = "350 5th Ave", city = "New York", state = "NY",
                country = "us"; client)

place.name                      # "Empire State Building"
place.latitude, place.longitude # 40.7484421, -73.9856589
place.match_level               # :house_or_poi
place.address["postcode"]       # "10118"
place.extratags["website"]      # "https://www.esbnyc.com/explore"

reverse_geocode(40.74844, -73.98566; client)
```

A search for a house number Nominatim doesn't know returns the street, and says so:

```julia
place = geocode(street = "123 Main St", city = "Springfield", state = "IL", country = "us"; client)
place.match_level               # :street
```

## Many addresses

```julia
using DataFrames

addresses = DataFrame(street = ["350 5th Ave", "1600 Pennsylvania Ave NW"],
                      city = ["New York", "Washington"],
                      state = ["NY", "DC"], zip = [10118, 20500])

results = geocode_batch(addresses; client, countrycodes = "us",
                        checkpoint_file = "addresses.checkpoint.jsonl")
```

`results` has one row per address: status, whether the house number matches,
name, coordinates, match level, the interpolation flag, every address part,
bounding box, and all extra tags.

The public server handles one query per second. **For large jobs, run your own
server**; the step-by-step guide covers Windows (WSL2, with or without Docker)
and any Ubuntu machine:

**➡ [Running your own Nominatim server](docs/src/self_hosting.md)**

Then point the client at it and send many requests at once:

```julia
client = NominatimClient(base_url = "http://127.0.0.1:8088")
results = geocode_batch(addresses; client, concurrent_requests = 12,
                        checkpoint_file = "addresses.checkpoint.jsonl")
```

## Documentation

The full documentation, including the API reference, is at
**<https://eohne.github.io/Nominatim.jl/stable/>** (latest release) and
**<https://eohne.github.io/Nominatim.jl/dev/>** (latest `main`).

The pages can also be read directly in this repository:

- [Getting started and match quality](docs/src/index.md)
- [Bulk geocoding](docs/src/bulk.md)
- [Running your own server](docs/src/self_hosting.md)

## Usage policy and licence

If you use `nominatim.openstreetmap.org` you agree to its
[usage policy](https://operations.osmfoundation.org/policies/nominatim/): at most
one request per second, an identifying User-Agent, and cached results. This
package enforces all three by default.

Data © OpenStreetMap contributors, [ODbL 1.0](https://www.openstreetmap.org/copyright).
