# =============================================================================
# Place: one result from /search, /reverse or /lookup, with every field
# Nominatim returns, parsed into Julia types. The original JSON is kept in `raw`.
# =============================================================================

"""
    BoundingBox(south, north, west, east)

The rectangle around a place, in degrees (WGS84). For a house it is tiny; for a
street, city or state it covers the whole area.
"""
struct BoundingBox
    south::Float64
    north::Float64
    west::Float64
    east::Float64
end

Base.show(io::IO, box::BoundingBox) =
    print(io, "BoundingBox(south=", box.south, ", north=", box.north, ", west=", box.west, ", east=", box.east, ")")

"""
    Place

One result from Nominatim.

# What is there
- `name::String` - name of the object, e.g. `"Empire State Building"` (`""` if unnamed).
- `display_name::String` - the full, human-readable address.
- `category::String`, `place_type::String` - the main OpenStreetMap tag, e.g.
  `"office"` / `"government"`, `"building"` / `"house"`, `"highway"` / `"residential"`.
- `addresstype::String` - what the object counts as in an address (`"road"`, `"city"`, …).

# Where it is
- `latitude::Float64`, `longitude::Float64` - the point Nominatim returns (the
  centroid for areas and lines).
- `boundingbox::Union{Missing, BoundingBox}`
- `geometry_geojson::Union{Missing, String}` - the full geometry (point, line or
  polygon) as GeoJSON text.

# Address and extra information
- `address::Dict{String, String}` - the address split into parts: `house_number`,
  `road`, `neighbourhood`, `suburb`, `city`/`town`/`village`, `county`, `state`,
  `ISO3166-2-lvl4`, `postcode`, `country`, `country_code`, …
- `extratags::Dict{String, String}` - further OpenStreetMap tags: `website`,
  `phone`, `opening_hours`, `wikidata`, `building:levels`, …
- `namedetails::Dict{String, String}` - every name variant: `name:en`,
  `short_name`, `official_name`, `ref`, …
- `entrances::Vector{Dict{String, Any}}` - tagged entrances of a building.

# Match quality
- `place_rank::Int` - Nominatim's address rank, 30 = house/POI, 26–27 = street.
- `match_level::Symbol` - `place_rank` in words: `:house_or_poi`, `:street`,
  `:locality`, `:neighbourhood`, `:suburb`, `:city`, `:county`, `:state`,
  `:country` or `:other`.
- `likely_interpolated::Bool` - `true` when the house number is probably
  estimated from an address range (OSM interpolation line or US TIGER data)
  rather than a mapped address point. See [`is_likely_interpolated`](@ref).
- `importance::Union{Missing, Float64}` - Nominatim's relevance score (0–1).

# Identifiers
- `osm_type::String` (`"node"`, `"way"`, `"relation"`), `osm_id::Int` - the
  OpenStreetMap object; view it at `https://www.openstreetmap.org/<osm_type>/<osm_id>`.
- `place_id::Int` - Nominatim's internal id. **Not stable** between servers or imports.
- `licence::String` - the data licence notice.
- `raw` - the original JSON object, for anything not covered above.
"""
struct Place
    place_id::Int
    osm_type::String
    osm_id::Int
    latitude::Float64
    longitude::Float64
    name::String
    display_name::String
    category::String
    place_type::String
    addresstype::String
    place_rank::Int
    match_level::Symbol
    likely_interpolated::Bool
    importance::Union{Missing, Float64}
    address::Dict{String, String}
    extratags::Dict{String, String}
    namedetails::Dict{String, String}
    entrances::Vector{Dict{String, Any}}
    boundingbox::Union{Missing, BoundingBox}
    geometry_geojson::Union{Missing, String}
    licence::String
    raw::JSON3.Object
end

function Base.show(io::IO, place::Place)
    label = isempty(place.name) ? place.display_name : place.name
    print(io, "Place(\"", label, "\", ", place.latitude, ", ", place.longitude, ", :", place.match_level, ")")
end

function Base.show(io::IO, ::MIME"text/plain", place::Place)
    println(io, "Place: ", isempty(place.name) ? "(unnamed)" : place.name)
    println(io, "  display_name: ", place.display_name)
    println(io, "  coordinates:  ", place.latitude, ", ", place.longitude)
    println(io, "  what:         ", place.category, "=", place.place_type)
    print(io,   "  match_level:  :", place.match_level)
    place.likely_interpolated && print(io, " (likely interpolated)")
    println(io)
    place.boundingbox === missing || println(io, "  boundingbox:  ", place.boundingbox)
    print(io,   "  osm:          ", place.osm_type, " ", place.osm_id)
end

# -----------------------------------------------------------------------------
# Reading JSON values that may be absent, null, or a number sent as text.
# -----------------------------------------------------------------------------

"The value of `key` in `object` as a String; `\"\"` if absent or null."
function json_string(object, key::Symbol)::String
    value = get(object, key, nothing)
    return value === nothing ? "" : string(value)
end

"The value of `key` as an Int (also when sent as text); `default` if absent or unparseable."
function json_int(object, key::Symbol, default::Int = 0)::Int
    value = get(object, key, nothing)
    value isa Integer && return Int(value)
    value isa AbstractFloat && return round(Int, value)
    value isa AbstractString && return something(tryparse(Int, value), default)
    return default
end

"The value of `key` as a Float64 (also when sent as text); `missing` if absent or unparseable."
function json_float(object, key::Symbol)::Union{Missing, Float64}
    value = get(object, key, nothing)
    value isa Real && return Float64(value)
    if value isa AbstractString
        parsed = tryparse(Float64, value)
        return parsed === nothing ? missing : parsed
    end
    return missing
end

"A JSON object of tags as `Dict{String, String}`; empty if absent or null."
function json_string_dict(object, key::Symbol)::Dict{String, String}
    value = get(object, key, nothing)
    value isa JSON3.Object || return Dict{String, String}()
    return Dict{String, String}(string(tag) => (tag_value === nothing ? "" : string(tag_value))
                                for (tag, tag_value) in value)
end

"Convert parsed JSON (objects, arrays, scalars) into plain Julia Dicts and Vectors."
function plain_julia_value(value)
    value isa JSON3.Object && return Dict{String, Any}(string(k) => plain_julia_value(v) for (k, v) in value)
    value isa JSON3.Array && return Any[plain_julia_value(v) for v in value]
    return value
end

"""
    parse_bounding_box(object) -> Union{Missing, BoundingBox}

Nominatim sends `"boundingbox": ["south", "north", "west", "east"]` as text.
"""
function parse_bounding_box(object)::Union{Missing, BoundingBox}
    values = get(object, :boundingbox, nothing)
    (values isa JSON3.Array && length(values) == 4) || return missing
    numbers = [value isa Real ? Float64(value) : tryparse(Float64, string(value)) for value in values]
    any(isnothing, numbers) && return missing
    return BoundingBox(numbers...)
end

"""
    parse_place(object::JSON3.Object) -> Place

Build a [`Place`](@ref) from one JSON result in Nominatim's `jsonv2` format.
"""
function parse_place(object::JSON3.Object)::Place
    latitude = json_float(object, :lat)
    longitude = json_float(object, :lon)
    if latitude === missing || longitude === missing
        throw(ArgumentError("A Nominatim result without coordinates: $(JSON3.write(object))"))
    end

    osm_type = json_string(object, :osm_type)
    # jsonv2 calls it "category"; the older json format calls it "class".
    category = haskey(object, :category) ? json_string(object, :category) : json_string(object, :class)
    place_type = json_string(object, :type)
    place_rank = json_int(object, :place_rank, json_int(object, :address_rank, 0))
    address = json_string_dict(object, :address)

    entrances_value = get(object, :entrances, nothing)
    entrances = entrances_value isa JSON3.Array ?
        Dict{String, Any}[plain_julia_value(entrance) for entrance in entrances_value] :
        Dict{String, Any}[]

    geometry_value = get(object, :geojson, nothing)
    geometry_geojson = geometry_value === nothing ? missing : JSON3.write(geometry_value)

    return Place(
        json_int(object, :place_id),
        osm_type,
        json_int(object, :osm_id),
        latitude,
        longitude,
        json_string(object, :name),
        json_string(object, :display_name),
        category,
        place_type,
        json_string(object, :addresstype),
        place_rank,
        match_level_for_rank(place_rank),
        is_likely_interpolated(category, place_type, osm_type),
        json_float(object, :importance),
        address,
        json_string_dict(object, :extratags),
        json_string_dict(object, :namedetails),
        entrances,
        parse_bounding_box(object),
        geometry_geojson,
        json_string(object, :licence),
        object,
    )
end

"""
    parse_place_list(response_body) -> Vector{Place}

Parse a `/search` or `/lookup` response (a JSON array of results).
"""
function parse_place_list(response_body::AbstractString)::Vector{Place}
    parsed = JSON3.read(response_body)
    if parsed isa JSON3.Object && haskey(parsed, :error)
        throw(NominatimError(200, extract_error_message(response_body), ""))
    end
    parsed isa JSON3.Array || throw(ArgumentError("Expected a JSON array of results from Nominatim."))
    return Place[parse_place(result) for result in parsed]
end

"""
    parse_single_place(response_body) -> Union{Nothing, Place}

Parse a `/reverse` response: one JSON object, or `{"error": "Unable to geocode"}`
when there is nothing at that location (returned as `nothing`).
"""
function parse_single_place(response_body::AbstractString)::Union{Nothing, Place}
    parsed = JSON3.read(response_body)
    parsed isa JSON3.Object || throw(ArgumentError("Expected a JSON object from Nominatim /reverse."))
    haskey(parsed, :error) && return nothing
    return parse_place(parsed)
end
