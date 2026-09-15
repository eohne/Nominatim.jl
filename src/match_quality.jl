# =============================================================================
# How good is a match? Match level from the address rank, interpolation, and
# whether the house number matches the one you asked for.
# =============================================================================

"""
    match_level_for_rank(place_rank::Integer) -> Symbol

Translate Nominatim's address rank into a readable match level, following
<https://nominatim.org/release-docs/latest/customize/Ranking/>:

| rank  | level            |
|-------|------------------|
| 28–30 | `:house_or_poi`  |
| 26–27 | `:street`        |
| 25    | `:locality`      |
| 22–24 | `:neighbourhood` |
| 17–21 | `:suburb`        |
| 13–16 | `:city`          |
| 10–12 | `:county`        |
| 5–9   | `:state`         |
| 4     | `:country`       |
| other | `:other`         |

A search for `"123 Main St, Springfield, IL"` that only finds the street returns
rank 26, i.e. `:street`: the coordinates are somewhere on Main Street, not at
number 123.
"""
function match_level_for_rank(place_rank::Integer)::Symbol
    for (ranks, level) in MATCH_LEVELS_BY_RANK
        place_rank in ranks && return level
    end
    return :other
end

"""
    is_likely_interpolated(category, place_type, osm_type) -> Bool

`true` when the result is probably an estimated position on an address range
rather than a mapped address point.

Nominatim returns such results as `category = "place"`, `type = "house"`, with
`osm_type = "way"`: the way is either an OpenStreetMap interpolation line or,
for US TIGER data, the street
(<https://nominatim.org/release-docs/latest/api/Output/>).

This is a heuristic: Nominatim has no field that states the source directly,
and a rare untagged area carrying only an address would also match. Mapped
address points come back as nodes (`place=house` on a node) or as buildings
(`category = "building"`).
"""
function is_likely_interpolated(category::AbstractString, place_type::AbstractString,
                                osm_type::AbstractString)::Bool
    return category == "place" && place_type == "house" && osm_type == "way"
end

"""
    extract_house_number(address_text) -> String

The house number at the start of a street address, or `""` if there is none.

```julia
extract_house_number("350 5th Ave")          # "350"
extract_house_number("1600A Pennsylvania")   # "1600A"
extract_house_number("12-14 Main St")        # "12-14"
extract_house_number("Main St")              # ""
```
"""
function extract_house_number(address_text::AbstractString)::String
    found = match(r"^\s*(\d+[A-Za-z]?(?:\s*[-/]\s*\d+[A-Za-z]?)?)(?=[\s,]|$)", address_text)
    return found === nothing ? "" : replace(found.captures[1], r"\s+" => "")
end

"Lowercase and remove spaces, so `\"12 A\"` and `\"12a\"` compare equal."
normalize_house_number(text::AbstractString) = lowercase(replace(text, r"\s+" => ""))

"""
    house_number_matches(place::Place, requested_house_number) -> Union{Missing, Bool}

Whether the result carries the house number you asked for.

- `missing` if you did not ask for a house number.
- `false` if the result has no house number (e.g. a street-level match) or a
  different one.
- `true` if it is the same number, one of several listed (`"10;12"`), or inside a
  listed range (`"10-20"`).
"""
function house_number_matches(place::Place, requested_house_number::AbstractString)::Union{Missing, Bool}
    requested = normalize_house_number(requested_house_number)
    isempty(requested) && return missing

    returned = normalize_house_number(get(place.address, "house_number", ""))
    isempty(returned) && return false

    for candidate in split(returned, r"[;,]")
        candidate == requested && return true

        range_match = match(r"^(\d+)-(\d+)$", candidate)
        requested_number = tryparse(Int, requested)
        if range_match !== nothing && requested_number !== nothing
            low, high = parse(Int, range_match.captures[1]), parse(Int, range_match.captures[2])
            low <= requested_number <= high && return true
        end
    end
    return false
end
