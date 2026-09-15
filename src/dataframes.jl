# =============================================================================
# Results as a table: one row per Place, with every field as a column.
# =============================================================================

"""
Address parts that get their own column in [`places_dataframe`](@ref), in this
order. Every other address part is still in the `address_json` column, and in
its own column with `expand = true`.
"""
const ADDRESS_COLUMNS = (
    "house_number", "road", "neighbourhood", "suburb", "hamlet", "village", "town",
    "city", "county", "state", "ISO3166-2-lvl4", "postcode", "country", "country_code",
)

"Column name for an address part: `\"ISO3166-2-lvl4\"` → `:address_state_code`."
function address_column_name(address_part::AbstractString)::Symbol
    address_part == "ISO3166-2-lvl4" && return :address_state_code
    return Symbol("address_", replace(address_part, r"[^A-Za-z0-9_]" => "_"))
end

"""
    place_row(place::Union{Nothing, Place}) -> NamedTuple

One table row. A `nothing` (no match) becomes a row of `missing`s, so that
results line up with their inputs.
"""
function place_row(place::Union{Nothing, Place})
    if place === nothing
        address_values = NamedTuple{Tuple(address_column_name.(ADDRESS_COLUMNS))}(
            ntuple(_ -> missing, length(ADDRESS_COLUMNS)))
        return (
            name = missing, display_name = missing, category = missing, place_type = missing,
            addresstype = missing, latitude = missing, longitude = missing,
            match_level = missing, place_rank = missing, likely_interpolated = missing,
            importance = missing, address_values...,
            bbox_south = missing, bbox_north = missing, bbox_west = missing, bbox_east = missing,
            osm_type = missing, osm_id = missing, place_id = missing,
            address_json = missing, extratags_json = missing, namedetails_json = missing,
            entrances_json = missing, geometry_geojson = missing,
        )
    end

    address_values = NamedTuple{Tuple(address_column_name.(ADDRESS_COLUMNS))}(
        Tuple(let value = get(place.address, part, ""); isempty(value) ? missing : value end
              for part in ADDRESS_COLUMNS))
    box = place.boundingbox
    return (
        name = isempty(place.name) ? missing : place.name,
        display_name = place.display_name,
        category = place.category,
        place_type = place.place_type,
        addresstype = place.addresstype,
        latitude = place.latitude,
        longitude = place.longitude,
        match_level = string(place.match_level),
        place_rank = place.place_rank,
        likely_interpolated = place.likely_interpolated,
        importance = place.importance,
        address_values...,
        bbox_south = box === missing ? missing : box.south,
        bbox_north = box === missing ? missing : box.north,
        bbox_west = box === missing ? missing : box.west,
        bbox_east = box === missing ? missing : box.east,
        osm_type = place.osm_type,
        osm_id = place.osm_id,
        place_id = place.place_id,
        address_json = JSON3.write(place.address),
        extratags_json = isempty(place.extratags) ? missing : JSON3.write(place.extratags),
        namedetails_json = isempty(place.namedetails) ? missing : JSON3.write(place.namedetails),
        entrances_json = isempty(place.entrances) ? missing : JSON3.write(place.entrances),
        geometry_geojson = place.geometry_geojson,
    )
end

"""
    places_dataframe(places; expand = false) -> DataFrame

A table with one row per result. `nothing` entries (no match) become rows of
`missing`, so the output lines up with the input.

Columns:
- what is there: `name`, `display_name`, `category`, `place_type`, `addresstype`
- where: `latitude`, `longitude`, `bbox_south`, `bbox_north`, `bbox_west`,
  `bbox_east`, `geometry_geojson`
- match quality: `match_level`, `place_rank`, `likely_interpolated`, `importance`
- address: `address_house_number`, `address_road`, `address_neighbourhood`,
  `address_suburb`, `address_hamlet`, `address_village`, `address_town`,
  `address_city`, `address_county`, `address_state`, `address_state_code`
  (e.g. `"US-NY"`), `address_postcode`, `address_country`, `address_country_code`
- identifiers: `osm_type`, `osm_id`, `place_id`
- everything else, as JSON text: `address_json` (all address parts),
  `extratags_json`, `namedetails_json`, `entrances_json`

With `expand = true`, every address part, extra tag and name variant that occurs
in any result also gets its own column, prefixed `address_`, `tag_` and `name_`
(e.g. `tag_website`, `tag_opening_hours`, `name_short_name`).
"""
function places_dataframe(places::AbstractVector; expand::Bool = false)::DataFrame
    for place in places
        (place === nothing || place isa Place) || throw(ArgumentError(
            "places_dataframe expects Place results (or nothing), but got a $(typeof(place))."))
    end

    table = DataFrame([place_row(place) for place in places])
    if isempty(places)
        table = DataFrame([name => Union{Missing, Any}[] for name in keys(place_row(nothing))])
    end

    expand && add_expanded_tag_columns!(table, places)
    return table
end

"""
    add_expanded_tag_columns!(table, places)

Add one column per address part, extra tag and name variant found in `places`.
"""
function add_expanded_tag_columns!(table::DataFrame, places::AbstractVector)
    tag_sources = (
        (:address, "address_"),
        (:extratags, "tag_"),
        (:namedetails, "name_"),
    )
    for (field, prefix) in tag_sources
        all_keys = sort(unique(Iterators.flatten(
            keys(getfield(place, field)) for place in places if place !== nothing)))
        for key in all_keys
            column_name = prefix == "address_" ? address_column_name(key) :
                          Symbol(prefix, replace(key, r"[^A-Za-z0-9_]" => "_"))
            hasproperty(table, column_name) && continue
            table[!, column_name] = Union{Missing, String}[
                place === nothing ? missing : let value = get(getfield(place, field), key, nothing)
                    value === nothing ? missing : value
                end
                for place in places
            ]
        end
    end
    return table
end
