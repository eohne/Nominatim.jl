# =============================================================================
# Constants describing the Nominatim web service.
# =============================================================================

"The public Nominatim server run by the OpenStreetMap Foundation."
const PUBLIC_NOMINATIM_URL = "https://nominatim.openstreetmap.org"

"""
The public server allows at most one request per second
(<https://operations.osmfoundation.org/policies/nominatim/>).
"""
const PUBLIC_SERVER_MINIMUM_SECONDS_BETWEEN_REQUESTS = 1.0

"`/search` returns at most this many results per request."
const MAXIMUM_SEARCH_LIMIT = 40

"`/lookup` accepts at most this many OSM ids per request."
const MAXIMUM_LOOKUP_IDS = 50

"""
Query parameters that make Nominatim return everything it knows about a place.
They are sent with every `/search`, `/reverse` and `/lookup` request.
"""
const FULL_DETAIL_PARAMETERS = Dict{String, String}(
    "format" => "jsonv2",
    "addressdetails" => "1",   # the address split into house_number, road, city, …
    "extratags" => "1",        # extra OSM tags: website, phone, opening_hours, wikidata, …
    "namedetails" => "1",      # every name variant: name:en, short_name, official_name, …
    "entrances" => "1",        # tagged entrances of buildings
    "polygon_geojson" => "1",  # the full geometry (point, line or polygon) as GeoJSON
)

"The address fields accepted by a structured `/search` request."
const STRUCTURED_ADDRESS_FIELDS = (:amenity, :street, :city, :county, :state, :country, :postalcode)

"""
Nominatim's `place_rank` (called address rank in its docs) → a readable match
level, from <https://nominatim.org/release-docs/latest/customize/Ranking/>.
The first range that contains the rank wins.
"""
const MATCH_LEVELS_BY_RANK = (
    (28:30, :house_or_poi),   # a house number, building, shop, …
    (26:27, :street),
    (25:25, :locality),       # squares, farms, named localities
    (22:24, :neighbourhood),
    (17:21, :suburb),
    (13:16, :city),
    (10:12, :county),
    (5:9,   :state),
    (4:4,   :country),
    (0:3,   :other),
)
