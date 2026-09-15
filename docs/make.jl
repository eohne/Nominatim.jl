# Build the documentation locally:
#
#     julia --project=docs -e 'import Pkg; Pkg.develop(path = "."); Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# The pages end up in docs/build/index.html. On GitHub, the workflow
# .github/workflows/Documenter.yml runs this file and publishes the result.

using Documenter
using Nominatim

# "Edit on GitHub" and source links need a git repository with a GitHub remote.
# Outside one (e.g. a plain local copy), build without those links.
const IN_GIT_REPOSITORY = isdir(joinpath(@__DIR__, "..", ".git"))
const REPOSITORY_OPTIONS = IN_GIT_REPOSITORY ? (; repo = Remotes.GitHub("eohne", "Nominatim.jl")) :
                                                (; remotes = nothing)

makedocs(;
    sitename = "Nominatim.jl",
    modules = [Nominatim],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        edit_link = IN_GIT_REPOSITORY ? "main" : nothing,
    ),
    pages = [
        "Home" => "index.md",
        "Bulk geocoding" => "bulk.md",
        "Running your own server" => "self_hosting.md",
        "API reference" => "api.md",
    ],
    warnonly = [:cross_references, :missing_docs],
    REPOSITORY_OPTIONS...,
)

# Publishes only when running in GitHub Actions on main or a tag; does nothing locally.
deploydocs(
    repo = "github.com/eohne/Nominatim.jl.git",
    devbranch = "main",
    push_preview = false,
)
