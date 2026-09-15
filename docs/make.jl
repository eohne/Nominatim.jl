# Build the documentation locally:
#
#     julia --project=docs -e 'import Pkg; Pkg.develop(path = "."); Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# The pages end up in docs/build/index.html.

using Documenter
using Nominatim

makedocs(
    sitename = "Nominatim.jl",
    modules = [Nominatim],
    # No "view source" links until the package lives in a git repository.
    remotes = nothing,
    format = Documenter.HTML(prettyurls = get(ENV, "CI", "false") == "true", edit_link = nothing),
    pages = [
        "Home" => "index.md",
        "Bulk geocoding" => "bulk.md",
        "Running your own server" => "self_hosting.md",
        "API reference" => "api.md",
    ],
    # The self-hosting guide links to headings by their GitHub anchors.
    warnonly = [:cross_references, :missing_docs],
)

deploydocs(repo = "github.com/eohne/Nominatim.jl.git", devbranch = "main", push_preview = false)
