# =============================================================================
# Talking to the server: building request URLs, waiting our turn, retrying
# temporary failures, and returning the response body.
# =============================================================================

"""
    escape_query_value(text) -> String

Percent-encode `text` for use in a URL query string. Letters, digits and `-._~`
stay as they are; every other byte becomes `%XX`.
"""
function escape_query_value(text::AbstractString)::String
    escaped = IOBuffer()
    for byte in codeunits(String(text))
        character = Char(byte)
        if isascii(character) && (isletter(character) || isdigit(character) || character in "-._~")
            write(escaped, character)
        else
            write(escaped, '%', uppercase(string(byte, base = 16, pad = 2)))
        end
    end
    return String(take!(escaped))
end

"""
    build_request_url(client, endpoint, query_parameters) -> String

The full URL for `endpoint` (e.g. `"search"`) with the given parameters, plus the
client's `email` and `accept-language`. Parameters are sorted so that the same
query always produces the same URL, which keeps the cache effective.
"""
function build_request_url(client::NominatimClient, endpoint::AbstractString,
                           query_parameters::AbstractDict{String, String})::String
    all_parameters = Dict{String, String}(query_parameters)
    if !isempty(client.email)
        all_parameters["email"] = client.email
    end
    if !isempty(client.accept_language) && !haskey(all_parameters, "accept-language")
        all_parameters["accept-language"] = client.accept_language
    end

    query_string = join(
        ("$(escape_query_value(name))=$(escape_query_value(value))" for (name, value) in sort(collect(all_parameters))),
        '&',
    )
    return "$(client.base_url)/$(endpoint)?$(query_string)"
end

"""
    wait_for_our_turn(client)

Sleep until at least `client.minimum_seconds_between_requests` have passed since
the previous request of this client. Tasks sharing the client queue up here.
"""
function wait_for_our_turn(client::NominatimClient)
    client.minimum_seconds_between_requests <= 0 && return nothing
    pacer = client.pacer
    lock(pacer.lock) do
        seconds_to_wait = pacer.time_of_last_request + client.minimum_seconds_between_requests - time()
        if seconds_to_wait > 0
            sleep(seconds_to_wait)
        end
        pacer.time_of_last_request = time()
    end
    return nothing
end

"""
    is_retryable_network_error(error) -> Bool

True for failures that are usually temporary (a dropped connection, a timeout),
where trying the same request again a little later is reasonable.

In HTTP.jl 2.x, connection problems and timeouts are subtypes of
`HTTP.HTTPError`; the one we do not retry is `HTTP.StatusError` (and we switch
those off anyway with `status_exception = false`).
"""
function is_retryable_network_error(error)::Bool
    is_http_transport_error = error isa HTTP.HTTPError && !(error isa HTTP.StatusError)
    return is_http_transport_error ||
           error isa Base.IOError ||
           error isa EOFError
end

"""
    seconds_to_wait_before_retry(response, attempt_number) -> Float64

Honour the server's `Retry-After` header if it sent one; otherwise wait 2, 4, 8, …
seconds.
"""
function seconds_to_wait_before_retry(response, attempt_number::Integer)::Float64
    if response !== nothing
        retry_after = HTTP.header(response, "Retry-After", "")
        parsed_seconds = tryparse(Float64, strip(retry_after))
        if parsed_seconds !== nothing && parsed_seconds >= 0
            return min(parsed_seconds, 300.0)
        end
    end
    return Float64(2^attempt_number)
end

"""
    nominatim_get(client, endpoint, query_parameters) -> String

Send a GET request to `client.base_url/endpoint` and return the response body.

- Uses the cache if the client has one.
- Waits for the client's rate limit before every attempt.
- Retries network errors, HTTP 429 ("too many requests") and HTTP 5xx, up to
  `client.maximum_retries` extra times.
- Throws a [`NominatimError`](@ref) for any other non-200 answer.
"""
function nominatim_get(client::NominatimClient, endpoint::AbstractString,
                       query_parameters::AbstractDict{String, String})::String
    url = build_request_url(client, endpoint, query_parameters)

    cached_body = read_cached_response(client, url)
    cached_body === nothing || return cached_body

    headers = ["User-Agent" => client.user_agent, "Accept" => "application/json"]
    attempt_number = 0

    while true
        attempt_number += 1
        another_attempt_is_allowed = attempt_number <= client.maximum_retries

        wait_for_our_turn(client)

        response = nothing
        try
            response = HTTP.get(
                url;
                headers = headers,
                read_idle_timeout = client.readtimeout_seconds,  # give up if no data arrives for this long
                status_exception = false,  # we check the status ourselves below
                retry = false,             # retries are handled by this loop
            )
        catch error
            if !(is_retryable_network_error(error) && another_attempt_is_allowed)
                rethrow()
            end
            seconds_to_wait = seconds_to_wait_before_retry(nothing, attempt_number)
            @warn "Nominatim request failed; retrying in $(seconds_to_wait) seconds." url attempt_number exception = error
            sleep(seconds_to_wait)
            continue
        end

        response_body = String(response.body)

        if response.status == 200
            write_cached_response(client, url, response_body)
            return response_body
        end

        should_retry = response.status == 429 || response.status >= 500
        if should_retry && another_attempt_is_allowed
            seconds_to_wait = seconds_to_wait_before_retry(response, attempt_number)
            @warn "Nominatim returned HTTP $(response.status); retrying in $(seconds_to_wait) seconds." url attempt_number
            sleep(seconds_to_wait)
            continue
        end

        throw(NominatimError(response.status, extract_error_message(response_body), url))
    end
end
