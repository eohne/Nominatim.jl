using Nominatim
using DataFrames
using HTTP
using Sockets
using Test

# Tests that call the live public Nominatim server only run when asked for, so
# the test suite also works offline:
#
#     ENV["NOMINATIM_ONLINE_TESTS"] = "true"; import Pkg; Pkg.test()
#
const RUN_ONLINE_TESTS = lowercase(get(ENV, "NOMINATIM_ONLINE_TESTS", "false")) == "true"

const TEST_DATA_DIRECTORY = joinpath(@__DIR__, "data")
read_test_data(file_name) = read(joinpath(TEST_DATA_DIRECTORY, file_name), String)

# -----------------------------------------------------------------------------
# A tiny stand-in for a Nominatim server, answering from the files in test/data.
# It lets the batch functions be tested without the internet.
# -----------------------------------------------------------------------------

const MOCK_REQUEST_COUNT = Ref(0)

function mock_nominatim_handler(request::HTTP.Request)
    MOCK_REQUEST_COUNT[] += 1
    target = String(request.target)
    body = if startswith(target, "/status")
        read_test_data("status.json")
    elseif startswith(target, "/lookup")
        read_test_data("search_structured.json")
    elseif startswith(target, "/reverse")
        occursin("lat=0.0", target) ? read_test_data("reverse_error.json") : read_test_data("reverse.json")
    elseif startswith(target, "/search")
        if occursin("server_error", target)
            return HTTP.Response(500, "internal error")
        elseif occursin("Main", target)
            read_test_data("search_maybe_interp.json")
        elseif occursin("nowhere", target)
            read_test_data("search_empty.json")
        else
            read_test_data("search_structured.json")
        end
    else
        return HTTP.Response(404, "{\"error\": {\"code\": 404, \"message\": \"Unknown endpoint\"}}")
    end
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

function free_local_port()::Int
    port, socket = listenany(ip"127.0.0.1", 18000)
    close(socket)
    return Int(port)
end

@testset "Nominatim" begin

    @testset "Client settings" begin
        # The public server needs an identifying User-Agent and at most 1 request/second.
        @test_throws ArgumentError NominatimClient(base_url = "https://nominatim.openstreetmap.org", user_agent = "")
        @test_throws ArgumentError NominatimClient(base_url = "https://nominatim.openstreetmap.org",
                                                   user_agent = "Test", minimum_seconds_between_requests = 0.5)
        public_client = NominatimClient(base_url = "https://nominatim.openstreetmap.org",
                                        user_agent = "Nominatim.jl tests", cache = false)
        @test public_client.minimum_seconds_between_requests == 1.0
        @test Nominatim.is_public_server(public_client)

        # Your own server: no pause, no cache, trailing slash removed.
        local_client = NominatimClient(base_url = "http://localhost:8088/")
        @test local_client.base_url == "http://localhost:8088"
        @test local_client.minimum_seconds_between_requests == 0.0
        @test local_client.cache_directory === nothing
        @test local_client.user_agent == "Nominatim.jl"

        @test_throws ArgumentError NominatimClient(base_url = "localhost:8088")
        @test_throws ArgumentError NominatimClient(base_url = "http://localhost:8088", maximum_retries = -1)
        @test_throws ArgumentError NominatimClient(base_url = "http://localhost:8088", cache = :sometimes)

        @test occursin("localhost:8088", sprint(show, local_client))
    end

    @testset "URL building" begin
        @test Nominatim.escape_query_value("350 5th Ave, New York") == "350%205th%20Ave%2C%20New%20York"
        @test Nominatim.escape_query_value("Café") == "Caf%C3%A9"
        @test Nominatim.escape_query_value("a-b_c.d~e") == "a-b_c.d~e"

        client = NominatimClient(base_url = "http://localhost:8088", email = "me@example.org")
        url = Nominatim.build_request_url(client, "search", Dict("q" => "Berlin", "limit" => "1"))
        @test startswith(url, "http://localhost:8088/search?")
        @test occursin("q=Berlin", url)
        @test occursin("email=me%40example.org", url)
        @test occursin("accept-language=en", url)
        # Same parameters in any order give the same URL (important for the cache).
        @test url == Nominatim.build_request_url(client, "search", Dict("limit" => "1", "q" => "Berlin"))
    end

    @testset "Response cache" begin
        cache_folder = mktempdir()
        client = NominatimClient(base_url = "http://localhost:8088", cache = cache_folder)
        @test client.cache_directory == cache_folder
        @test Nominatim.read_cached_response(client, "http://x/search?q=1") === nothing
        Nominatim.write_cached_response(client, "http://x/search?q=1", "[]")
        @test Nominatim.read_cached_response(client, "http://x/search?q=1") == "[]"
        @test Nominatim.clear_cache!(client) == 1
        @test Nominatim.read_cached_response(client, "http://x/search?q=1") === nothing
    end

    @testset "Parsing results" begin
        places = Nominatim.parse_place_list(read_test_data("search_structured.json"))
        @test length(places) == 1
        place = only(places)
        @test place.name == "Empire State Building"
        @test place.osm_type == "way"
        @test place.osm_id == 34633854
        @test place.latitude ≈ 40.7484421
        @test place.longitude ≈ -73.9856589
        @test place.category == "office"
        @test place.place_rank == 30
        @test place.match_level == :house_or_poi
        @test !place.likely_interpolated
        @test place.address["house_number"] == "350"
        @test place.address["postcode"] == "10118"
        @test place.extratags["website"] == "https://www.esbnyc.com/explore"
        @test place.namedetails["short_name"] == "ESB"
        @test place.boundingbox.south ≈ 40.7479255
        @test place.boundingbox.east ≈ -73.9848166
        @test occursin("Polygon", place.geometry_geojson)
        @test isempty(place.entrances)
        @test occursin("Empire State Building", sprint(show, place))
        @test occursin("match_level", sprint(show, MIME"text/plain"(), place))

        street_result = first(Nominatim.parse_place_list(read_test_data("search_maybe_interp.json")))
        @test street_result.match_level == :street
        @test !haskey(street_result.address, "house_number")

        @test isempty(Nominatim.parse_place_list(read_test_data("search_empty.json")))
        @test Nominatim.parse_single_place(read_test_data("reverse_error.json")) === nothing
        reverse_result = Nominatim.parse_single_place(read_test_data("reverse.json"))
        @test reverse_result.address["road"] == "5th Avenue"
        @test isempty(reverse_result.extratags)   # "extratags": null
    end

    @testset "Match quality" begin
        @test Nominatim.match_level_for_rank(30) == :house_or_poi
        @test Nominatim.match_level_for_rank(26) == :street
        @test Nominatim.match_level_for_rank(16) == :city
        @test Nominatim.match_level_for_rank(4) == :country
        @test Nominatim.match_level_for_rank(99) == :other

        @test Nominatim.is_likely_interpolated("place", "house", "way")
        @test !Nominatim.is_likely_interpolated("place", "house", "node")
        @test !Nominatim.is_likely_interpolated("building", "house", "way")

        @test Nominatim.extract_house_number("350 5th Ave") == "350"
        @test Nominatim.extract_house_number("1600A Pennsylvania Ave") == "1600A"
        @test Nominatim.extract_house_number("12 - 14 Main St") == "12-14"
        @test Nominatim.extract_house_number("5th Ave") == ""
        @test Nominatim.extract_house_number("Main St 5") == ""

        place = only(Nominatim.parse_place_list(read_test_data("search_structured.json")))
        @test Nominatim.house_number_matches(place, "350") === true
        @test Nominatim.house_number_matches(place, "352") === false
        @test Nominatim.house_number_matches(place, "") === missing

        # Lists and ranges of house numbers
        ranged = Nominatim.parse_place(Nominatim.JSON3.read(
            """{"lat":"1","lon":"2","address":{"house_number":"10-20;24"}}"""))
        @test Nominatim.house_number_matches(ranged, "15") === true
        @test Nominatim.house_number_matches(ranged, "24") === true
        @test Nominatim.house_number_matches(ranged, "22") === false
    end

    @testset "Results as a DataFrame" begin
        place = only(Nominatim.parse_place_list(read_test_data("search_structured.json")))
        table = places_dataframe([place, nothing])
        @test nrow(table) == 2
        @test table.name[1] == "Empire State Building"
        @test table.address_state_code[1] == "US-NY"
        @test table.match_level[1] == "house_or_poi"
        @test ismissing(table.latitude[2])

        expanded = places_dataframe([place]; expand = true)
        @test expanded.tag_website[1] == "https://www.esbnyc.com/explore"
        @test expanded.name_short_name[1] == "ESB"
        @test ncol(expanded) > ncol(places_dataframe([place]))

        @test nrow(places_dataframe(Place[])) == 0
        @test_throws ArgumentError places_dataframe([42])
    end

    @testset "Batch input" begin
        from_strings = Nominatim.normalize_batch_input(["350 5th Ave, New York", ""])
        @test from_strings[1].address_parameters == Dict("q" => "350 5th Ave, New York")
        @test from_strings[1].requested_house_number == "350"
        @test isempty(from_strings[2].address_parameters)

        structured = Nominatim.normalize_batch_input(DataFrame(
            street = ["350 5th Ave"], City = ["New York"], zip = [2134], other = [1]))
        @test structured[1].address_parameters == Dict("street" => "350 5th Ave", "city" => "New York",
                                                       "postalcode" => "02134")
        @test structured[1].description == "350 5th Ave, New York, 02134"

        from_named_tuples = Nominatim.normalize_batch_input([(address = "White House",)])
        @test from_named_tuples[1].address_parameters == Dict("q" => "White House")

        @test_throws ArgumentError Nominatim.normalize_batch_input(DataFrame(query = ["x"], city = ["y"]))
        @test_throws ArgumentError Nominatim.normalize_batch_input(DataFrame(name = ["x"]))
        @test_throws ArgumentError Nominatim.normalize_batch_input(DataFrame(zip = ["1"], postcode = ["2"]))
        @test_throws ArgumentError Nominatim.normalize_batch_input(42)
    end

    @testset "Queries and batches against a mock server" begin
        port = free_local_port()
        server = HTTP.serve!(mock_nominatim_handler, "127.0.0.1", port)
        try
            client = NominatimClient(base_url = "http://127.0.0.1:$(port)", maximum_retries = 0)

            status = server_status(client)
            @test status.ok
            @test status.software_version == "5.3.0"

            @test geocode("350 5th Ave, New York"; client).name == "Empire State Building"
            @test geocode(street = "350 5th Ave", city = "New York"; client).osm_id == 34633854
            @test geocode("nowhere at all"; client) === nothing
            @test reverse_geocode(40.74844, -73.98566; client).address["house_number"] == "350"
            @test reverse_geocode(0, 0; client) === nothing
            @test length(lookup(["W34633854"]; client)) == 1

            @test_throws ArgumentError search(; client)
            @test_throws ArgumentError search("x"; client, limit = 41)
            @test_throws ArgumentError reverse_geocode(91, 0; client)
            @test_throws ArgumentError Nominatim.osm_id_code("X12")
            @test Nominatim.osm_id_code(("way", 12)) == "W12"

            # A batch with a match, a street-level match, no match, an empty row and a server error
            addresses = ["350 5th Ave, New York", "123 Main St, Springfield", "nowhere at all", "", "server_error"]
            checkpoint_file = joinpath(mktempdir(), "run.checkpoint.jsonl")
            results = geocode_batch(addresses; client, checkpoint_file, concurrent_requests = 3)

            @test nrow(results) == 5
            @test results.input_index == 1:5
            @test results.status == ["matched", "matched", "no_match", "empty_input", "error"]
            @test results.name[1] == "Empire State Building"
            @test results.house_number_matches[1] === true
            @test results.match_level[2] == "street"
            @test results.house_number_matches[2] === false
            @test occursin("500", results.error_message[5])
            @test countlines(checkpoint_file) == 3   # errors are not stored, so they are retried

            # Running again resumes: only the failed query is sent again.
            requests_before = MOCK_REQUEST_COUNT[]
            resumed = geocode_batch(addresses; client, checkpoint_file)
            @test MOCK_REQUEST_COUNT[] - requests_before == 1
            @test resumed.status == results.status
            @test isequal(resumed.latitude, results.latitude)

            # A changed input at the same position is not taken from the checkpoint.
            changed = copy(addresses)
            changed[1] = "White House"
            requests_before = MOCK_REQUEST_COUNT[]
            geocode_batch(changed; client, checkpoint_file)
            @test MOCK_REQUEST_COUNT[] - requests_before == 2

            # A 404 means a wrong server address: stop instead of failing every row.
            wrong_client = NominatimClient(base_url = "http://127.0.0.1:$(port)/wrong", maximum_retries = 0)
            @test_throws Exception geocode_batch(["350 5th Ave"]; client = wrong_client)

            reverse_results = reverse_geocode_batch([40.74844, 0.0, NaN], [-73.98566, 0.0, 1.0]; client)
            @test reverse_results.status == ["matched", "no_match", "empty_input"]
            @test reverse_results.address_road[1] == "5th Avenue"
            @test_throws ArgumentError reverse_geocode_batch([1.0], [1.0, 2.0]; client)
        finally
            close(server)
        end
    end

    if RUN_ONLINE_TESTS
        @testset "Live public server" begin
            client = NominatimClient(user_agent = "Nominatim.jl test suite (https://github.com/eohne/Nominatim.jl)",
                                     cache = false)
            @test server_status(client).ok

            place = geocode(street = "350 5th Ave", city = "New York", state = "NY", country = "us"; client)
            @test place !== nothing
            @test place.match_level == :house_or_poi
            @test abs(place.latitude - 40.7484) < 0.01

            at_location = reverse_geocode(38.8977, -77.0365; client)
            @test at_location !== nothing
            @test get(at_location.address, "country_code", "") == "us"
        end
    end
end
