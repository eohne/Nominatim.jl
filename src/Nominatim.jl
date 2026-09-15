"""
    Nominatim

A readable Julia client for [Nominatim](https://nominatim.org/), the open-source
geocoder built on OpenStreetMap data.

It works against the public server (`https://nominatim.openstreetmap.org`,
rate-limited to one request per second) and, more usefully for large jobs,
against your own Nominatim server, where there is no limit.

Every request asks Nominatim for everything it can return: the address broken
into parts, extra OSM tags (website, opening hours, …), all name variants,
entrances, and the full geometry.

- Search by free text or by address fields → [`search`](@ref), [`geocode`](@ref)
- Coordinates to address → [`reverse_geocode`](@ref)
- Known OSM objects → [`lookup`](@ref), [`place_details`](@ref)
- Many addresses at once, resumable → [`geocode_batch`](@ref),
  [`reverse_geocode_batch`](@ref)
- Results as a table → [`places_dataframe`](@ref)
- Server health → [`server_status`](@ref)
"""
module Nominatim

using DataFrames
using Dates
using HTTP
using JSON3
using Scratch
using SHA

# Configuration
export NominatimClient, NominatimError, default_client, set_default_client!

# One query at a time
export search, geocode, reverse_geocode, lookup, place_details, server_status

# Results
export Place, BoundingBox, places_dataframe

# Many queries at once
export geocode_batch, reverse_geocode_batch

# The order of these files matters only for readability: each file builds on the
# helpers defined in the files above it.
include("constants.jl")
include("errors.jl")
include("client.jl")
include("cache.jl")
include("http_requests.jl")
include("place.jl")
include("match_quality.jl")
include("queries.jl")
include("dataframes.jl")
include("batch.jl")

end # module Nominatim
