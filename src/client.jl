# =============================================================================
# NominatimClient: which server to talk to, how to identify ourselves, how fast
# we may send requests, and where to cache responses.
# =============================================================================

"""
    RequestPacer

Makes sure requests from one client are spaced at least
`minimum_seconds_between_requests` apart, even when many tasks share the client.
"""
mutable struct RequestPacer
    lock::ReentrantLock
    time_of_last_request::Float64
end

RequestPacer() = RequestPacer(ReentrantLock(), 0.0)

"""
    NominatimClient(; base_url, user_agent, email, accept_language,
                      minimum_seconds_between_requests, readtimeout_seconds,
                      maximum_retries, cache)

Settings shared by every request to one Nominatim server.

# Keywords
- `base_url` - the server, e.g. `"http://127.0.0.1:8088"` for your own server.
  Default: the environment variable `NOMINATIM_URL`, otherwise the public server
  `$(PUBLIC_NOMINATIM_URL)`.
- `user_agent` - identifies your application, e.g.
  `"MyStudy/1.0 (me@university.edu)"`. **Required for the public server** (its
  usage policy blocks generic User-Agents). Default: `ENV["NOMINATIM_USER_AGENT"]`,
  or `"Nominatim.jl"` for your own server.
- `email` - optional contact address sent with each request, which the public
  server's operators use to reach you instead of blocking you. Default:
  `ENV["NOMINATIM_EMAIL"]`.
- `accept_language` - preferred language of names and addresses (`"en"`).
- `minimum_seconds_between_requests` - `1.0` for the public server (and it may
  not be lower), `0.0` for any other server.
- `readtimeout_seconds` - give up if the server sends nothing for this long (`60`).
- `maximum_retries` - retries after network errors, HTTP 429 and HTTP 5xx (`3`).
- `cache` - where to store responses so repeated queries don't hit the server:
  - `:auto` (default): on for the public server (the usage policy requires
    caching), off for your own server;
  - `true`: on, in this package's scratch space;
  - `false`: off;
  - a folder path: on, in that folder.

# Examples
```julia
public_client = NominatimClient(user_agent = "HousingStudy/1.0 (me@university.edu)")
local_client  = NominatimClient(base_url = "http://127.0.0.1:8088")
```
"""
struct NominatimClient
    base_url::String
    user_agent::String
    email::String
    accept_language::String
    minimum_seconds_between_requests::Float64
    readtimeout_seconds::Int
    maximum_retries::Int
    cache_directory::Union{Nothing, String}
    pacer::RequestPacer
end

function NominatimClient(; base_url::AbstractString = get(ENV, "NOMINATIM_URL", PUBLIC_NOMINATIM_URL),
                           user_agent::AbstractString = get(ENV, "NOMINATIM_USER_AGENT", ""),
                           email::AbstractString = get(ENV, "NOMINATIM_EMAIL", ""),
                           accept_language::AbstractString = "en",
                           minimum_seconds_between_requests::Union{Nothing, Real} = nothing,
                           readtimeout_seconds::Integer = 60,
                           maximum_retries::Integer = 3,
                           cache::Union{Symbol, Bool, AbstractString} = :auto)
    cleaned_base_url = String(rstrip(strip(base_url), '/'))
    if !startswith(cleaned_base_url, "http://") && !startswith(cleaned_base_url, "https://")
        throw(ArgumentError("base_url must start with http:// or https://, but got \"$(base_url)\"."))
    end

    talks_to_public_server = is_public_server_url(cleaned_base_url)

    if talks_to_public_server
        if isempty(strip(user_agent))
            throw(ArgumentError(
                "The public Nominatim server requires a User-Agent that identifies your " *
                "application, e.g. NominatimClient(user_agent = \"MyStudy/1.0 (me@university.edu)\"). " *
                "You can also set ENV[\"NOMINATIM_USER_AGENT\"]. " *
                "See https://operations.osmfoundation.org/policies/nominatim/"
            ))
        end
    end
    chosen_user_agent = isempty(strip(user_agent)) ? "Nominatim.jl" : String(strip(user_agent))

    if minimum_seconds_between_requests === nothing
        chosen_pause = talks_to_public_server ? PUBLIC_SERVER_MINIMUM_SECONDS_BETWEEN_REQUESTS : 0.0
    else
        chosen_pause = Float64(minimum_seconds_between_requests)
        if chosen_pause < 0
            throw(ArgumentError("minimum_seconds_between_requests cannot be negative."))
        end
        if talks_to_public_server && chosen_pause < PUBLIC_SERVER_MINIMUM_SECONDS_BETWEEN_REQUESTS
            throw(ArgumentError(
                "The public Nominatim server allows at most one request per second, so " *
                "minimum_seconds_between_requests must be at least 1.0 (got $(chosen_pause))."
            ))
        end
    end

    if readtimeout_seconds < 1
        throw(ArgumentError("readtimeout_seconds must be at least 1."))
    end
    if maximum_retries < 0
        throw(ArgumentError("maximum_retries cannot be negative."))
    end

    return NominatimClient(
        cleaned_base_url,
        chosen_user_agent,
        String(strip(email)),
        String(accept_language),
        chosen_pause,
        Int(readtimeout_seconds),
        Int(maximum_retries),
        resolve_cache_directory(cache, talks_to_public_server),
        RequestPacer(),
    )
end

"True if `url` points at the OpenStreetMap Foundation's public Nominatim server."
is_public_server_url(url::AbstractString) = occursin("nominatim.openstreetmap.org", lowercase(url))

"True if `client` talks to the public Nominatim server."
is_public_server(client::NominatimClient) = is_public_server_url(client.base_url)

function Base.show(io::IO, client::NominatimClient)
    print(io, "NominatimClient(\"", client.base_url, "\"")
    if client.minimum_seconds_between_requests > 0
        print(io, ", ≥", client.minimum_seconds_between_requests, " s between requests")
    end
    print(io, client.cache_directory === nothing ? ", no cache" : ", cached", ")")
end

# -----------------------------------------------------------------------------
# The default client, used when a function is called without `client = …`.
# -----------------------------------------------------------------------------

const DEFAULT_CLIENT = Ref{Union{Nothing, NominatimClient}}(nothing)

"""
    default_client() -> NominatimClient

The client used when you don't pass `client = …`. It is created on first use from
the environment variables `NOMINATIM_URL`, `NOMINATIM_USER_AGENT` and
`NOMINATIM_EMAIL`, or set explicitly with [`set_default_client!`](@ref).
"""
function default_client()::NominatimClient
    if DEFAULT_CLIENT[] === nothing
        DEFAULT_CLIENT[] = NominatimClient()
    end
    return DEFAULT_CLIENT[]
end

"""
    set_default_client!(client::NominatimClient) -> NominatimClient

Use `client` for every call that does not pass `client = …` explicitly.

```julia
set_default_client!(NominatimClient(base_url = "http://127.0.0.1:8088"))
geocode("350 5th Ave, New York, NY")   # goes to your own server
```
"""
function set_default_client!(client::NominatimClient)
    DEFAULT_CLIENT[] = client
    return client
end
