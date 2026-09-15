# Nominatim.jl

A readable Julia client for [Nominatim](https://nominatim.org/), the open-source
geocoder built on OpenStreetMap data. Free, no API key.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/eohne/Nominatim.jl")
```

## Choosing a server

```julia
using Nominatim

# The public server: identify your application (required by its usage policy).
# Limited to 1 request per second; responses are cached on disk.
client = NominatimClient(user_agent = "HousingStudy/1.0 (me@university.edu)")

# Your own server (see "Running your own server"): no limits, no cache.
client = NominatimClient(base_url = "http://127.0.0.1:8088")

# Use it everywhere without passing client = … each time:
set_default_client!(client)
```

The environment variables `NOMINATIM_URL`, `NOMINATIM_USER_AGENT` and
`NOMINATIM_EMAIL` set the defaults too.

## One address

```julia
place = geocode(street = "350 5th Ave", city = "New York", state = "NY",
                postalcode = "10118", country = "us")
```

```
Place: Empire State Building
  display_name: Empire State Building, 350, 5th Avenue, Koreatown, …, New York, 10118, United States
  coordinates:  40.7484421, -73.9856589
  what:         office=yes
  match_level:  :house_or_poi
  boundingbox:  BoundingBox(south=40.7479255, north=40.7489585, west=-73.9865012, east=-73.9848166)
  osm:          way 34633854
```

Everything Nominatim returns is in the [`Place`](@ref):

```julia
place.name                      # "Empire State Building"
place.latitude, place.longitude
place.boundingbox
place.address["house_number"]   # "350"
place.address["postcode"]       # "10118"
place.extratags["website"]      # "https://www.esbnyc.com/explore"
place.extratags["opening_hours"]
place.namedetails["short_name"] # "ESB"
place.geometry_geojson          # the building outline as GeoJSON
place.raw                       # the original JSON
```

Free text works too, but structured fields are usually more precise:

```julia
geocode("350 5th Ave, New York, NY 10118")
search("Main St, Springfield"; countrycodes = "us", limit = 10)   # all candidates
```

## Coordinates to address

```julia
reverse_geocode(40.74844, -73.98566)             # building level
reverse_geocode(40.74844, -73.98566; zoom = 10)  # city level
```

## Is the match exact?

Nominatim always returns *something* close if it can. A request for a house
number it doesn't know usually returns the **street**. Three fields tell you
what you got:

| Field | Meaning |
|---|---|
| `match_level` | `:house_or_poi` (a house number, building or POI), `:street`, `:locality`, `:neighbourhood`, `:suburb`, `:city`, `:county`, `:state`, `:country` |
| `likely_interpolated` | `true` if the position is estimated from an address range (OpenStreetMap interpolation line or US TIGER data) instead of a mapped address point |
| `house_number_matches` (batch results) | whether the result has the house number you asked for |

```julia
place = geocode(street = "123 Main St", city = "Springfield", state = "IL", country = "us")
place.match_level                                  # :street → not at number 123
Nominatim.house_number_matches(place, "123")       # false
```

For exact, address-point results keep rows where `match_level == :house_or_poi`,
`house_number_matches == true` and `likely_interpolated == false`.

`likely_interpolated` is a heuristic: Nominatim has no field that states the
source directly. It follows the documented output of interpolated results
(`place=house` on a way).

## Many addresses

See [Bulk geocoding](bulk.md).

## Other endpoints

```julia
lookup(["W34633854", "R19761182"])       # known OpenStreetMap objects, 50 per request
place_details(place)                      # everything stored about one object
server_status(client)                     # is it up, and how fresh is the data?
places_dataframe([place1, place2])        # results as a table
```

## Data licence

Data © OpenStreetMap contributors, available under the
[Open Database License](https://www.openstreetmap.org/copyright). Publications
using the results must credit OpenStreetMap.
