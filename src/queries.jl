# =============================================================================
# One query at a time: /search, /reverse, /lookup, /details and /status.
# =============================================================================

"""
    as_comma_list(value) -> String

`"us"` stays `"us"`; `["us", "ca"]` becomes `"us,ca"`.
"""
as_comma_list(value::AbstractString) = String(value)
as_comma_list(values::Union{AbstractVector, Tuple}) = join(string.(values), ',')

"""
    search_filter_parameters(; kwargs...) -> Dict{String, String}

The optional `/search` filters, turned into query parameters. Shared by the
free-text and the structured form of [`search`](@ref).
"""
function search_filter_parameters(; limit::Integer,
                                    countrycodes,
                                    viewbox,
                                    bounded::Bool,
                                    layer,
                                    featuretype,
                                    exclude_place_ids,
                                    dedupe::Bool,
                                    polygon_threshold,
                                    extra_parameters::AbstractDict)::Dict{String, String}
    if limit < 1 || limit > MAXIMUM_SEARCH_LIMIT
        throw(ArgumentError("limit must be between 1 and $(MAXIMUM_SEARCH_LIMIT) (Nominatim's maximum), but got $(limit)."))
    end

    parameters = copy(FULL_DETAIL_PARAMETERS)
    parameters["limit"] = string(limit)
    parameters["dedupe"] = dedupe ? "1" : "0"

    countrycodes === nothing || (parameters["countrycodes"] = lowercase(as_comma_list(countrycodes)))
    layer === nothing || (parameters["layer"] = as_comma_list(layer))
    featuretype === nothing || (parameters["featureType"] = string(featuretype))
    exclude_place_ids === nothing || (parameters["exclude_place_ids"] = as_comma_list(exclude_place_ids))
    polygon_threshold === nothing || (parameters["polygon_threshold"] = string(polygon_threshold))

    if viewbox !== nothing
        length(viewbox) == 4 || throw(ArgumentError(
            "viewbox must be (min_longitude, min_latitude, max_longitude, max_latitude)."))
        parameters["viewbox"] = join(string.(viewbox), ',')
        parameters["bounded"] = bounded ? "1" : "0"
    elseif bounded
        throw(ArgumentError("bounded = true needs a viewbox."))
    end

    for (name, value) in extra_parameters
        parameters[string(name)] = string(value)
    end
    return parameters
end

"""
    search(query::AbstractString; client, limit, countrycodes, viewbox, bounded,
           layer, featuretype, exclude_place_ids, dedupe, polygon_threshold,
           extra_parameters) -> Vector{Place}

    search(; street, city, county, state, country, postalcode, amenity,
           client, limit, …) -> Vector{Place}

Find places matching a free-text `query`, or a structured address. Returns all
candidates, best first (empty if nothing matched). Every result carries the full
detail Nominatim can return (see [`Place`](@ref)).

Structured search is usually more precise for addresses: Nominatim does not have
to guess which part of the text is the city.

# Keywords
- `client = default_client()` - the server to ask (see [`NominatimClient`](@ref)).
- `limit = 10` - maximum number of results (1–40).
- `countrycodes` - restrict to countries, e.g. `"us"` or `["us", "ca"]`.
- `viewbox = (min_longitude, min_latitude, max_longitude, max_latitude)` - prefer
  results in this box; with `bounded = true`, only return results inside it.
- `layer` - `"address"`, `"poi"`, `"railway"`, `"natural"`, `"manmade"`, or a vector.
- `featuretype` - `"country"`, `"state"`, `"city"` or `"settlement"`.
- `exclude_place_ids` - place ids to skip (for paging through results).
- `dedupe = true` - merge duplicates (e.g. one street split into several ways).
- `polygon_threshold` - simplify returned geometries to this tolerance (degrees).
- `extra_parameters = Dict()` - any other Nominatim parameter, passed through.
- Structured form only: `street` (house number and street name), `city`,
  `county`, `state`, `country`, `postalcode`, `amenity` (name or type of POI).
  Structured search cannot be combined with a free-text query.

# Examples
```julia
search("Empire State Building")
search(street = "350 5th Ave", city = "New York", state = "NY", country = "us")
search("coffee"; viewbox = (-74.02, 40.70, -73.93, 40.80), bounded = true, limit = 40)
```
"""
function search(query::AbstractString;
                client::NominatimClient = default_client(),
                limit::Integer = 10,
                countrycodes = nothing,
                viewbox = nothing,
                bounded::Bool = false,
                layer = nothing,
                featuretype = nothing,
                exclude_place_ids = nothing,
                dedupe::Bool = true,
                polygon_threshold = nothing,
                extra_parameters::AbstractDict = Dict{String, String}())::Vector{Place}
    isempty(strip(query)) && throw(ArgumentError("The search query is empty."))

    parameters = search_filter_parameters(; limit, countrycodes, viewbox, bounded, layer,
                                            featuretype, exclude_place_ids, dedupe,
                                            polygon_threshold, extra_parameters)
    parameters["q"] = String(strip(query))
    return parse_place_list(nominatim_get(client, "search", parameters))
end

function search(; client::NominatimClient = default_client(),
                  amenity::AbstractString = "",
                  street::AbstractString = "",
                  city::AbstractString = "",
                  county::AbstractString = "",
                  state::AbstractString = "",
                  country::AbstractString = "",
                  postalcode::AbstractString = "",
                  limit::Integer = 10,
                  countrycodes = nothing,
                  viewbox = nothing,
                  bounded::Bool = false,
                  layer = nothing,
                  featuretype = nothing,
                  exclude_place_ids = nothing,
                  dedupe::Bool = true,
                  polygon_threshold = nothing,
                  extra_parameters::AbstractDict = Dict{String, String}())::Vector{Place}
    address_fields = (; amenity, street, city, county, state, country, postalcode)
    if all(value -> isempty(strip(value)), values(address_fields))
        throw(ArgumentError(
            "Give a free-text query, search(\"350 5th Ave, New York\"), or at least one " *
            "address field: $(join(STRUCTURED_ADDRESS_FIELDS, ", "))."
        ))
    end

    parameters = search_filter_parameters(; limit, countrycodes, viewbox, bounded, layer,
                                            featuretype, exclude_place_ids, dedupe,
                                            polygon_threshold, extra_parameters)
    for (field, value) in pairs(address_fields)
        isempty(strip(value)) || (parameters[string(field)] = String(strip(value)))
    end
    return parse_place_list(nominatim_get(client, "search", parameters))
end

"""
    geocode(query::AbstractString; kwargs...) -> Union{Nothing, Place}
    geocode(; street, city, state, postalcode, country, …) -> Union{Nothing, Place}

The best match for an address, or `nothing` if there is none. Takes the same
keywords as [`search`](@ref).

Check `place.match_level` before trusting the coordinates: a street-level match
(`:street`) means the house number was not found.

```julia
place = geocode("350 5th Ave, New York, NY 10118")
place.name, place.latitude, place.longitude, place.match_level
```
"""
function geocode(query::AbstractString; kwargs...)::Union{Nothing, Place}
    results = search(query; limit = 1, kwargs...)
    return isempty(results) ? nothing : first(results)
end

function geocode(; kwargs...)::Union{Nothing, Place}
    results = search(; limit = 1, kwargs...)
    return isempty(results) ? nothing : first(results)
end

"""
    reverse_geocode(latitude, longitude; client, zoom = 18, layer, polygon_threshold,
                    extra_parameters) -> Union{Nothing, Place}

The address (or object) at a location, or `nothing` if there is nothing there
(e.g. the open ocean).

`zoom` sets the level of detail: 18 = building, 17 = street, 16 = major street,
14 = neighbourhood, 13 = village/suburb, 10 = city, 8 = county, 5 = state,
3 = country.

`layer` limits what may be returned: `"address"`, `"poi"`, `"railway"`,
`"natural"`, `"manmade"` (default: address and POI).

```julia
reverse_geocode(40.74844, -73.98566)          # Empire State Building
reverse_geocode(40.74844, -73.98566; zoom = 10)  # New York
```
"""
function reverse_geocode(latitude::Real, longitude::Real;
                         client::NominatimClient = default_client(),
                         zoom::Integer = 18,
                         layer = nothing,
                         polygon_threshold = nothing,
                         extra_parameters::AbstractDict = Dict{String, String}())::Union{Nothing, Place}
    parameters = reverse_parameters(latitude, longitude; zoom, layer, polygon_threshold, extra_parameters)
    return parse_single_place(nominatim_get(client, "reverse", parameters))
end

"""
    reverse_parameters(latitude, longitude; zoom, layer, polygon_threshold, extra_parameters)
        -> Dict{String, String}

The query parameters for one `/reverse` request, after checking the inputs.
Shared by [`reverse_geocode`](@ref) and [`reverse_geocode_batch`](@ref).
"""
function reverse_parameters(latitude::Real, longitude::Real;
                            zoom::Integer, layer, polygon_threshold,
                            extra_parameters::AbstractDict)::Dict{String, String}
    -90 <= latitude <= 90 || throw(ArgumentError("latitude must be between -90 and 90, but got $(latitude)."))
    -180 <= longitude <= 180 || throw(ArgumentError("longitude must be between -180 and 180, but got $(longitude)."))
    0 <= zoom <= 18 || throw(ArgumentError("zoom must be between 0 and 18, but got $(zoom)."))

    parameters = copy(FULL_DETAIL_PARAMETERS)
    parameters["lat"] = string(Float64(latitude))
    parameters["lon"] = string(Float64(longitude))
    parameters["zoom"] = string(zoom)
    layer === nothing || (parameters["layer"] = as_comma_list(layer))
    polygon_threshold === nothing || (parameters["polygon_threshold"] = string(polygon_threshold))
    for (name, value) in extra_parameters
        parameters[string(name)] = string(value)
    end
    return parameters
end

"""
    osm_id_code(osm_id) -> String

Normalise an OpenStreetMap id to the `"N123"` / `"W123"` / `"R123"` form that
`/lookup` expects. Accepts that form, or a pair such as `("way", 123)` or
`(:node, 123)`.
"""
function osm_id_code(osm_id::AbstractString)::String
    code = uppercase(strip(osm_id))
    occursin(r"^[NWR]\d+$", code) || throw(ArgumentError(
        "OSM ids look like \"N123\", \"W123\" or \"R123\", but got \"$(osm_id)\"."))
    return code
end

function osm_id_code(osm_id::Tuple{Union{AbstractString, Symbol}, Integer})::String
    type_name, number = osm_id
    letter = uppercase(first(string(type_name)))
    letter in ('N', 'W', 'R') || throw(ArgumentError(
        "The OSM type must be node, way or relation, but got $(type_name)."))
    return string(letter, number)
end

osm_id_code(place::Place) = osm_id_code((place.osm_type, place.osm_id))

"""
    lookup(osm_ids; client, polygon_threshold, extra_parameters) -> Vector{Place}

Fetch known OpenStreetMap objects with full detail. `osm_ids` is a vector of
`"N123"` / `"W123"` / `"R123"` codes, `(type, id)` pairs, or `Place`s. Longer
lists are split into requests of 50 automatically. Objects the server does not
know are silently left out.

```julia
lookup(["W34633854", "R19761182"])   # Empire State Building, White House
```
"""
function lookup(osm_ids::AbstractVector;
                client::NominatimClient = default_client(),
                polygon_threshold = nothing,
                extra_parameters::AbstractDict = Dict{String, String}())::Vector{Place}
    codes = String[osm_id_code(osm_id) for osm_id in osm_ids]
    places = Place[]
    for chunk in Iterators.partition(codes, MAXIMUM_LOOKUP_IDS)
        parameters = copy(FULL_DETAIL_PARAMETERS)
        parameters["osm_ids"] = join(chunk, ',')
        polygon_threshold === nothing || (parameters["polygon_threshold"] = string(polygon_threshold))
        for (name, value) in extra_parameters
            parameters[string(name)] = string(value)
        end
        append!(places, parse_place_list(nominatim_get(client, "lookup", parameters)))
    end
    return places
end

"""
    place_details(osm_id; client, category) -> Dict{String, Any}
    place_details(place::Place; client) -> Dict{String, Any}

Everything Nominatim stores about one object, from its `/details` endpoint: all
names and address tags, the computed postcode, the full address hierarchy
(`"address"`), linked places, keywords, dependent addresses (`"hierarchy"`),
entrances and geometry.

The output format differs from [`Place`](@ref) and is returned as plain Dicts.
Meant for inspecting individual results, not for bulk use.

`osm_id` is `"W34633854"` or `("way", 34633854)`. `category` picks the entry when
one OSM object has several main tags (e.g. `"tourism"`).
"""
function place_details(osm_id; client::NominatimClient = default_client(),
                       category::Union{Nothing, AbstractString} = nothing)::Dict{String, Any}
    code = osm_id_code(osm_id)
    parameters = Dict{String, String}(
        "format" => "json",
        "osmtype" => code[1:1],
        "osmid" => code[2:end],
        "addressdetails" => "1",
        "keywords" => "1",
        "linkedplaces" => "1",
        "hierarchy" => "1",
        "group_hierarchy" => "1",
        "polygon_geojson" => "1",
        "entrances" => "1",
    )
    category === nothing || (parameters["class"] = category)
    parsed = JSON3.read(nominatim_get(client, "details", parameters))
    return plain_julia_value(parsed)
end

place_details(place::Place; client::NominatimClient = default_client()) =
    place_details(osm_id_code(place); client, category = place.category)

"""
    server_status(client = default_client()) -> NamedTuple

Whether the server is working, and how fresh its data is:
`(ok, status, message, data_updated, software_version, database_version)`.

`data_updated` is the date of the OpenStreetMap data (a `DateTime`, UTC); record
it with your results so they are reproducible.
"""
function server_status(client::NominatimClient = default_client())
    parsed = JSON3.read(nominatim_get_uncached(client, "status", Dict("format" => "json")))
    status_code = json_int(parsed, :status, -1)
    updated_text = json_string(parsed, :data_updated)
    data_updated = isempty(updated_text) ? missing :
        something(tryparse(DateTime, first(updated_text, 19), dateformat"yyyy-mm-ddTHH:MM:SS"), missing)
    return (
        ok = status_code == 0,
        status = status_code,
        message = json_string(parsed, :message),
        data_updated = data_updated,
        software_version = json_string(parsed, :software_version),
        database_version = json_string(parsed, :database_version),
    )
end

"""
    nominatim_get_uncached(client, endpoint, query_parameters) -> String

Like [`nominatim_get`](@ref) but never reads or writes the cache (for `/status`,
whose answer changes).
"""
function nominatim_get_uncached(client::NominatimClient, endpoint::AbstractString,
                                query_parameters::AbstractDict{String, String})::String
    uncached_client = NominatimClient(client.base_url, client.user_agent, client.email,
                                      client.accept_language, client.minimum_seconds_between_requests,
                                      client.readtimeout_seconds, client.maximum_retries,
                                      nothing, client.pacer)
    return nominatim_get(uncached_client, endpoint, query_parameters)
end
