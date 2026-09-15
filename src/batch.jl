# =============================================================================
# Many queries at once: geocode_batch and reverse_geocode_batch.
#
# Both send one request per input (Nominatim has no batch endpoint), optionally
# several at a time against your own server, and write every answer to a
# checkpoint file as it arrives. If a run is interrupted, calling the function
# again with the same checkpoint file skips everything already answered.
# =============================================================================

"Input column names that hold a whole address as free text."
const FREE_TEXT_COLUMNS = (:query, :address, :q)

"Other common names for the structured address fields."
const ADDRESS_COLUMN_ALIASES = Dict(
    :zip => :postalcode, :zipcode => :postalcode, :zip_code => :postalcode,
    :postcode => :postalcode, :postal_code => :postalcode,
)

"""
    BatchQuery

One address from the input of [`geocode_batch`](@ref), ready to send.

- `address_parameters` - `q` for free text, or the structured fields; empty if
  the input row had no address at all.
- `description` - the address as readable text, for the `input_query` column.
- `requested_house_number` - the house number found in the input (may be `""`).
"""
struct BatchQuery
    address_parameters::Dict{String, String}
    description::String
    requested_house_number::String
end

"A table cell as clean text: `missing`/`nothing` → `\"\"`; ZIP codes keep leading zeros."
function cell_text(value, column::Symbol)::String
    (value === missing || value === nothing) && return ""
    if column === :postalcode && value isa Integer
        return lpad(string(value), 5, '0')
    end
    return String(strip(string(value)))
end

"""
    normalize_batch_input(addresses) -> Vector{BatchQuery}

Accepts:
- a vector of address strings (free-text search);
- a `DataFrame` (or a vector of NamedTuples) with **either** a free-text column
  (`query`, `address` or `q`) **or** structured columns: `street`, `city`,
  `county`, `state`, `country`, `postalcode` (also `zip`, `zipcode`, `postcode`,
  `postal_code`), `amenity`. Other columns are ignored.
"""
function normalize_batch_input(addresses)::Vector{BatchQuery}
    if addresses isa AbstractVector{<:AbstractString}
        return [free_text_batch_query(text) for text in addresses]
    elseif addresses isa AbstractVector && all(row -> row isa NamedTuple, addresses)
        return normalize_batch_input(DataFrame(addresses))
    elseif addresses isa AbstractDataFrame
        return batch_queries_from_table(addresses)
    end
    throw(ArgumentError(
        "geocode_batch expects a vector of address strings, a DataFrame, or a vector of " *
        "NamedTuples, but got a $(typeof(addresses))."
    ))
end

function free_text_batch_query(text)::BatchQuery
    cleaned = cell_text(text, :query)
    isempty(cleaned) && return BatchQuery(Dict{String, String}(), "", "")
    return BatchQuery(Dict("q" => cleaned), cleaned, extract_house_number(cleaned))
end

function batch_queries_from_table(table::AbstractDataFrame)::Vector{BatchQuery}
    # Map every recognised column to its Nominatim field name.
    column_for_field = Dict{Symbol, Symbol}()
    for column in Symbol.(names(table))
        field = Symbol(lowercase(string(column)))
        field = get(ADDRESS_COLUMN_ALIASES, field, field)
        if field in FREE_TEXT_COLUMNS || field in STRUCTURED_ADDRESS_FIELDS
            haskey(column_for_field, field) && throw(ArgumentError(
                "Two input columns both mean \"$(field)\"; keep only one."))
            column_for_field[field] = column
        end
    end

    free_text_fields = [field for field in FREE_TEXT_COLUMNS if haskey(column_for_field, field)]
    structured_fields = [field for field in STRUCTURED_ADDRESS_FIELDS if haskey(column_for_field, field)]

    if length(free_text_fields) > 1
        throw(ArgumentError("Use only one free-text column (query, address or q)."))
    elseif !isempty(free_text_fields) && !isempty(structured_fields)
        throw(ArgumentError(
            "The input has both a free-text column ($(only(free_text_fields))) and structured " *
            "address columns ($(join(structured_fields, ", "))). Nominatim cannot combine them; " *
            "drop one kind."))
    elseif isempty(free_text_fields) && isempty(structured_fields)
        throw(ArgumentError(
            "No address columns found. Expected a free-text column (query, address or q) or " *
            "structured columns (street, city, county, state, country, postalcode/zip, amenity). " *
            "Got: $(join(names(table), ", "))."))
    end

    if !isempty(free_text_fields)
        column = column_for_field[only(free_text_fields)]
        return [free_text_batch_query(value) for value in table[!, column]]
    end

    queries = BatchQuery[]
    for row in eachrow(table)
        parameters = Dict{String, String}()
        for field in structured_fields
            value = cell_text(row[column_for_field[field]], field)
            isempty(value) || (parameters[string(field)] = value)
        end
        description = join((parameters[string(field)] for field in STRUCTURED_ADDRESS_FIELDS
                            if haskey(parameters, string(field))), ", ")
        push!(queries, BatchQuery(parameters, description, extract_house_number(get(parameters, "street", ""))))
    end
    return queries
end

"""
    request_key(endpoint, parameters) -> String

A stable text identifying one request, independent of server and client
settings. Stored in the checkpoint file so that a resumed run only reuses
answers to exactly the same question.
"""
request_key(endpoint::AbstractString, parameters::AbstractDict{String, String}) =
    endpoint * "?" * join(("$(escape_query_value(k))=$(escape_query_value(v))" for (k, v) in sort(collect(parameters))), '&')

"""
    checked_concurrency(client, concurrent_requests, number_of_requests) -> Int

The number of simultaneous requests to actually use. A rate-limited client (the
public server) always sends one at a time.
"""
function checked_concurrency(client::NominatimClient, concurrent_requests::Integer,
                             number_of_requests::Integer)::Int
    concurrent_requests >= 1 || throw(ArgumentError("concurrent_requests must be at least 1."))

    if client.minimum_seconds_between_requests > 0 && concurrent_requests > 1
        @warn "This client waits $(client.minimum_seconds_between_requests) s between requests, " *
              "so requests are sent one at a time (concurrent_requests = 1)."
        concurrent_requests = 1
    end

    if is_public_server(client) && number_of_requests > 5_000
        hours = round(number_of_requests / 3600; digits = 1)
        @warn "Geocoding $(number_of_requests) queries on the public Nominatim server takes at least " *
              "$(hours) hours, and jobs running longer than a day are limited to 4 requests per minute. " *
              "For bulk work, run your own server: see the self-hosting guide."
    end
    return Int(concurrent_requests)
end

"""
    read_checkpoint(checkpoint_file, request_keys) -> Vector{Union{Nothing, String}}

Response bodies already stored in `checkpoint_file`, by input position. An entry
is only reused if its request key matches the current input at that position.
A half-written last line (from an interrupted run) is skipped.
"""
function read_checkpoint(checkpoint_file::AbstractString,
                         request_keys::AbstractVector{String})::Vector{Union{Nothing, String}}
    stored_bodies = Vector{Union{Nothing, String}}(nothing, length(request_keys))
    isfile(checkpoint_file) || return stored_bodies

    for line in eachline(checkpoint_file)
        isempty(strip(line)) && continue
        entry = try
            JSON3.read(line)
        catch
            continue
        end
        entry isa JSON3.Object || continue
        input_index = json_int(entry, :input_index, 0)
        1 <= input_index <= length(request_keys) || continue
        json_string(entry, :request_key) == request_keys[input_index] || continue
        stored_bodies[input_index] = json_string(entry, :response_body)
    end
    return stored_bodies
end

"""
    stops_the_whole_batch(error) -> Bool

Errors that would repeat for every remaining query: the server blocking us
(HTTP 403/429 after retries), a wrong URL (404), or the user pressing Ctrl+C.
"""
stops_the_whole_batch(error) =
    error isa InterruptException ||
    (error isa NominatimError && error.http_status in (401, 403, 404, 429))

"""
    run_resumable_batch(request_keys, send_request; client, checkpoint_file,
                        concurrent_requests, progress_every_seconds)
        -> (response_bodies, error_messages)

Send `send_request(i)` for every `i` whose `request_keys[i]` is not empty and
not already in the checkpoint file. Returns the response body (or `nothing`) and
an error message (or `""`) per position.
"""
function run_resumable_batch(request_keys::Vector{String}, send_request::Function;
                             checkpoint_file::Union{Nothing, AbstractString},
                             concurrent_requests::Int,
                             progress_every_seconds::Real)
    number_of_inputs = length(request_keys)
    response_bodies = checkpoint_file === nothing ?
        Vector{Union{Nothing, String}}(nothing, number_of_inputs) :
        read_checkpoint(checkpoint_file, request_keys)
    error_messages = fill("", number_of_inputs)

    pending_positions = [i for i in 1:number_of_inputs
                         if response_bodies[i] === nothing && !isempty(request_keys[i])]
    already_done = count(!isnothing, response_bodies)
    if already_done > 0
        @info "Resuming from $(checkpoint_file): $(already_done) of $(number_of_inputs) queries already answered."
    end
    isempty(pending_positions) && return response_bodies, error_messages

    checkpoint_stream = checkpoint_file === nothing ? nothing : open(checkpoint_file, "a")
    write_lock = ReentrantLock()
    finished_count = Ref(0)
    start_time = time()
    time_of_last_report = Ref(start_time)

    try
        asyncmap(pending_positions; ntasks = concurrent_requests) do position
            try
                body = send_request(position)
                lock(write_lock) do
                    response_bodies[position] = body
                    if checkpoint_stream !== nothing
                        entry = (input_index = position, request_key = request_keys[position], response_body = body)
                        println(checkpoint_stream, JSON3.write(entry))
                        flush(checkpoint_stream)
                    end
                end
            catch error
                stops_the_whole_batch(error) && rethrow()
                error_messages[position] = sprint(showerror, error)
            end

            lock(write_lock) do
                finished_count[] += 1
                now = time()
                is_last = finished_count[] == length(pending_positions)
                if is_last || now - time_of_last_report[] >= progress_every_seconds
                    time_of_last_report[] = now
                    report_batch_progress(finished_count[], length(pending_positions), now - start_time)
                end
            end
            return nothing
        end
    finally
        checkpoint_stream === nothing || close(checkpoint_stream)
    end

    return response_bodies, error_messages
end

function report_batch_progress(finished::Int, total::Int, elapsed_seconds::Float64)
    progress_text = string("Nominatim batch: ", finished, " / ", total, " done (",
                           round(100 * finished / total; digits = 1), "%)")
    # Speed and time left are meaningless in the first second.
    if elapsed_seconds >= 1
        rate = finished / elapsed_seconds
        progress_text *= string(", ", round(rate; digits = 1), " queries/s")
        if finished < total
            progress_text *= string(", about ", format_duration((total - finished) / rate), " left")
        end
    end
    @info progress_text * "."
end

function format_duration(seconds::Real)::String
    seconds < 90 && return "$(round(Int, seconds)) s"
    seconds < 5400 && return "$(round(Int, seconds / 60)) min"
    return "$(round(seconds / 3600; digits = 1)) h"
end

"""
    geocode_batch(addresses; client, concurrent_requests, checkpoint_file,
                  countrycodes, viewbox, bounded, layer, featuretype,
                  polygon_threshold, extra_parameters, expand,
                  progress_every_seconds) -> DataFrame

Geocode many addresses and return one row per input, in input order.

# Input
- a vector of address strings, or
- a `DataFrame` / vector of NamedTuples with a free-text column (`query`,
  `address` or `q`), **or** structured columns `street`, `city`, `county`,
  `state`, `country`, `postalcode` (`zip` works too), `amenity`.

Structured columns usually match more precisely.

# Output columns
- `input_index`, `input_query` - which input the row belongs to.
- `status` - `"matched"`, `"no_match"`, `"error"` or `"empty_input"`.
- `error_message` - why a query failed (`missing` otherwise).
- `requested_house_number`, `house_number_matches` - the house number found in
  the input, and whether the result has it (see [`house_number_matches`](@ref)).
- then every column of [`places_dataframe`](@ref): name, coordinates, match
  level, `likely_interpolated`, address parts, bounding box, extra tags, …

# Keywords
- `client = default_client()` - use your own server for large jobs.
- `concurrent_requests = 1` - simultaneous requests. On your own server, up to
  about the number of API worker processes. Always 1 on the public server.
- `checkpoint_file = nothing` - a file path (e.g. `"run.checkpoint.jsonl"`). Every
  answer is appended to it as it arrives; run the same call again after an
  interruption and answered queries are not sent again. Queries that failed are
  retried on the next run.
- `countrycodes`, `viewbox`, `bounded`, `layer`, `featuretype`,
  `polygon_threshold`, `extra_parameters` - as in [`search`](@ref), applied to
  every query. For US addresses, `countrycodes = "us"` avoids matches abroad.
- `expand = false` - add one column per tag, as in [`places_dataframe`](@ref).
- `progress_every_seconds = 30` - how often to log progress.

# Example
```julia
using Nominatim, DataFrames

client = NominatimClient(base_url = "http://127.0.0.1:8088")
addresses = DataFrame(street = ["350 5th Ave", "1600 Pennsylvania Ave NW"],
                      city = ["New York", "Washington"], state = ["NY", "DC"],
                      zip = [10118, 20500])

results = geocode_batch(addresses; client, countrycodes = "us",
                        concurrent_requests = 12,
                        checkpoint_file = "addresses.checkpoint.jsonl")

exact = filter(row -> row.match_level == "house_or_poi" && row.house_number_matches === true &&
                      !row.likely_interpolated, results)
```
"""
function geocode_batch(addresses;
                       client::NominatimClient = default_client(),
                       concurrent_requests::Integer = 1,
                       checkpoint_file::Union{Nothing, AbstractString} = nothing,
                       countrycodes = nothing,
                       viewbox = nothing,
                       bounded::Bool = false,
                       layer = nothing,
                       featuretype = nothing,
                       polygon_threshold = nothing,
                       extra_parameters::AbstractDict = Dict{String, String}(),
                       expand::Bool = false,
                       progress_every_seconds::Real = 30)::DataFrame
    queries = normalize_batch_input(addresses)

    shared_parameters = search_filter_parameters(; limit = 1, countrycodes, viewbox, bounded, layer,
                                                   featuretype, exclude_place_ids = nothing,
                                                   dedupe = true, polygon_threshold, extra_parameters)
    parameter_sets = [isempty(query.address_parameters) ? Dict{String, String}() :
                      merge(shared_parameters, query.address_parameters) for query in queries]
    request_keys = [isempty(parameters) ? "" : request_key("search", parameters) for parameters in parameter_sets]

    concurrency = checked_concurrency(client, concurrent_requests, count(!isempty, request_keys))
    response_bodies, error_messages = run_resumable_batch(
        request_keys, position -> nominatim_get(client, "search", parameter_sets[position]);
        checkpoint_file, concurrent_requests = concurrency, progress_every_seconds,
    )

    places = Vector{Union{Nothing, Place}}(nothing, length(queries))
    statuses = Vector{String}(undef, length(queries))
    for position in eachindex(queries)
        statuses[position], places[position], error_messages[position] =
            interpret_batch_answer(request_keys[position], response_bodies[position],
                                   error_messages[position], parse_place_list)
    end

    table = places_dataframe(places; expand)
    house_number_results = [
        (place === nothing || isempty(query.requested_house_number)) ? missing :
            house_number_matches(place, query.requested_house_number)
        for (query, place) in zip(queries, places)
    ]
    insertcols!(table, 1,
        :input_index => collect(1:length(queries)),
        :input_query => [query.description for query in queries],
        :status => statuses,
        :error_message => [isempty(message) ? missing : message for message in error_messages],
        :requested_house_number => [isempty(query.requested_house_number) ? missing : query.requested_house_number
                                    for query in queries],
        :house_number_matches => house_number_results,
    )
    return table
end

"""
    interpret_batch_answer(request_key, response_body, error_message, parse)
        -> (status, place, error_message)

Turn one stored answer into a status and at most one Place. `parse` is
`parse_place_list` (search) or `parse_single_place` (reverse).
"""
function interpret_batch_answer(request_key::AbstractString, response_body, error_message::AbstractString,
                                parse::Function)
    isempty(request_key) && return ("empty_input", nothing, "")
    isempty(error_message) || return ("error", nothing, error_message)
    response_body === nothing && return ("error", nothing, "No answer was received.")

    parsed = try
        parse(response_body)
    catch error
        return ("error", nothing, "Could not read the server's answer: " * sprint(showerror, error))
    end

    place = parsed isa AbstractVector ? (isempty(parsed) ? nothing : first(parsed)) : parsed
    return place === nothing ? ("no_match", nothing, "") : ("matched", place, "")
end

"""
    reverse_geocode_batch(latitudes, longitudes; client, zoom = 18, layer,
                          concurrent_requests, checkpoint_file, polygon_threshold,
                          extra_parameters, expand, progress_every_seconds) -> DataFrame

Find the address at many locations. Returns one row per coordinate pair, in
input order, with `input_index`, `input_latitude`, `input_longitude`, `status`
(`"matched"`, `"no_match"`, `"error"`, `"empty_input"` for missing/NaN
coordinates), `error_message`, then every column of [`places_dataframe`](@ref).

Keywords as in [`reverse_geocode`](@ref) and [`geocode_batch`](@ref).
"""
function reverse_geocode_batch(latitudes::AbstractVector, longitudes::AbstractVector;
                               client::NominatimClient = default_client(),
                               zoom::Integer = 18,
                               layer = nothing,
                               concurrent_requests::Integer = 1,
                               checkpoint_file::Union{Nothing, AbstractString} = nothing,
                               polygon_threshold = nothing,
                               extra_parameters::AbstractDict = Dict{String, String}(),
                               expand::Bool = false,
                               progress_every_seconds::Real = 30)::DataFrame
    length(latitudes) == length(longitudes) || throw(ArgumentError(
        "latitudes and longitudes must have the same length ($(length(latitudes)) ≠ $(length(longitudes)))."))

    is_usable(value) = value isa Real && isfinite(value)
    parameter_sets = [
        (is_usable(latitude) && is_usable(longitude)) ?
            reverse_parameters(latitude, longitude; zoom, layer, polygon_threshold, extra_parameters) :
            Dict{String, String}()
        for (latitude, longitude) in zip(latitudes, longitudes)
    ]
    request_keys = [isempty(parameters) ? "" : request_key("reverse", parameters) for parameters in parameter_sets]

    concurrency = checked_concurrency(client, concurrent_requests, count(!isempty, request_keys))
    response_bodies, error_messages = run_resumable_batch(
        request_keys, position -> nominatim_get(client, "reverse", parameter_sets[position]);
        checkpoint_file, concurrent_requests = concurrency, progress_every_seconds,
    )

    places = Vector{Union{Nothing, Place}}(nothing, length(request_keys))
    statuses = Vector{String}(undef, length(request_keys))
    for position in eachindex(request_keys)
        statuses[position], places[position], error_messages[position] =
            interpret_batch_answer(request_keys[position], response_bodies[position],
                                   error_messages[position], parse_single_place)
    end

    table = places_dataframe(places; expand)
    insertcols!(table, 1,
        :input_index => collect(1:length(request_keys)),
        :input_latitude => collect(latitudes),
        :input_longitude => collect(longitudes),
        :status => statuses,
        :error_message => [isempty(message) ? missing : message for message in error_messages],
    )
    return table
end
