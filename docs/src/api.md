# API reference

```@docs
Nominatim
```

## Server and settings

```@docs
NominatimClient
default_client
set_default_client!
server_status
NominatimError
Nominatim.clear_cache!
```

## One query at a time

```@docs
search
geocode
reverse_geocode
lookup
place_details
```

## Many queries at once

```@docs
geocode_batch
reverse_geocode_batch
```

## Results

```@docs
Place
BoundingBox
places_dataframe
```

## Match quality

```@docs
Nominatim.match_level_for_rank
Nominatim.is_likely_interpolated
Nominatim.house_number_matches
Nominatim.extract_house_number
```
