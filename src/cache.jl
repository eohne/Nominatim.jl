# =============================================================================
# A simple response cache: one file per request URL, named by the URL's SHA-1.
#
# The public server's usage policy requires caching, and clients that repeat
# the same query get blocked. Against your own server caching is off by default,
# because a bulk run would create millions of small files; resumable batch runs
# use a checkpoint file instead (see batch.jl).
# =============================================================================

"""
    resolve_cache_directory(cache, talks_to_public_server) -> Union{Nothing, String}

Turn the `cache` keyword of [`NominatimClient`](@ref) into a folder path, or
`nothing` when caching is off.
"""
function resolve_cache_directory(cache::Union{Symbol, Bool, AbstractString},
                                 talks_to_public_server::Bool)
    if cache isa Symbol
        cache === :auto || throw(ArgumentError("cache must be :auto, true, false or a folder path, but got :$(cache)."))
        return talks_to_public_server ? default_cache_directory() : nothing
    elseif cache isa Bool
        return cache ? default_cache_directory() : nothing
    else
        mkpath(cache)
        return String(cache)
    end
end

"The package's own scratch-space folder for cached responses."
default_cache_directory() = @get_scratch!("response_cache")

"The file that holds the cached response for `url`."
cache_file_path(cache_directory::AbstractString, url::AbstractString) =
    joinpath(cache_directory, bytes2hex(sha1(url)) * ".json")

"""
    read_cached_response(client, url) -> Union{Nothing, String}

The cached response body for `url`, or `nothing` if there is none (or caching is off).
"""
function read_cached_response(client::NominatimClient, url::AbstractString)
    client.cache_directory === nothing && return nothing
    path = cache_file_path(client.cache_directory, url)
    return isfile(path) ? read(path, String) : nothing
end

"""
    write_cached_response(client, url, response_body)

Store `response_body` for `url`. Writes to a temporary file first and then
renames it, so an interrupted write never leaves a half-written cache entry.
"""
function write_cached_response(client::NominatimClient, url::AbstractString, response_body::AbstractString)
    client.cache_directory === nothing && return nothing
    path = cache_file_path(client.cache_directory, url)
    temporary_path = path * ".partial." * string(rand(UInt32))
    write(temporary_path, response_body)
    mv(temporary_path, path; force = true)
    return nothing
end

"""
    clear_cache!(client::NominatimClient = default_client()) -> Int

Delete every cached response of `client` and return how many were deleted.
"""
function clear_cache!(client::NominatimClient = default_client())::Int
    client.cache_directory === nothing && return 0
    cached_files = filter(name -> endswith(name, ".json"), readdir(client.cache_directory))
    for file_name in cached_files
        rm(joinpath(client.cache_directory, file_name); force = true)
    end
    return length(cached_files)
end
