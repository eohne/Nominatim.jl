# =============================================================================
# The error type thrown when a Nominatim server rejects a request.
# =============================================================================

"""
    NominatimError(http_status, message, url)

Thrown when a Nominatim server answers with an error instead of results, for
example a malformed request (HTTP 400), a block for exceeding the usage policy
(HTTP 403 or 429), or a server problem that persisted through all retries.

# Fields
- `http_status::Int` - the HTTP status code the server returned.
- `message::String`  - the server's explanation.
- `url::String`      - the request that failed.
"""
struct NominatimError <: Exception
    http_status::Int
    message::String
    url::String
end

function Base.showerror(io::IO, error::NominatimError)
    print(io, "NominatimError: the server returned HTTP ", error.http_status, " for ", error.url, "\n")
    print(io, "Message from the server: ", error.message)
    if error.http_status in (403, 429)
        print(io, "\nThe public server blocks clients that exceed its usage policy ",
                  "(1 request/second, identifying User-Agent, cached results). ",
                  "See https://operations.osmfoundation.org/policies/nominatim/")
    end
end

"""
    extract_error_message(response_body::AbstractString) -> String

Turn an error response body into a short human-readable message.

Nominatim reports errors either as JSON (`{"error": {"code": 400, "message": "…"}}`
or `{"error": "…"}`) or, from proxies in front of it, as HTML.
"""
function extract_error_message(response_body::AbstractString)::String
    try
        parsed_body = JSON3.read(response_body)
        if parsed_body isa JSON3.Object && haskey(parsed_body, :error)
            error_value = parsed_body[:error]
            if error_value isa JSON3.Object && haskey(error_value, :message)
                return string(error_value[:message])
            end
            return string(error_value)
        end
    catch
        # Not JSON - fall through to the HTML handling below.
    end

    text_without_html_tags = replace(response_body, r"<[^>]*>" => " ")
    text_with_single_spaces = replace(text_without_html_tags, r"\s+" => " ")
    return String(strip(text_with_single_spaces))
end
