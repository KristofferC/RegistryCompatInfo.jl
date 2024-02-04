"""
RegistryCompatTools makes it easier to discover packages that need [compat] updates.

- `held_back_by("SomePkg")` - which packages are holding back SomePkg?
- `held_back_packages()["SomePkg"]` - which packages does SomePkg hold back?
- `find_julia_packages_github()` - discover which packages I can push to
"""
module RegistryCompatTools

using UUIDs
using Pkg
using Crayons: Box
import GitHub
using RegistryInstances
using RegistryInstances: VersionSpec
using RegistryTools

export held_back_packages, held_back_by, print_held_back, find_julia_packages_github

struct Package
    name::String
    info::PkgInfo
    max_version::VersionNumber
end

"""
    HeldBack

A struct for a package being held back. Contains the fields:
- `name`, name of the package
- `last_version`, the last version of the pacakge
- `compat`, the compat info of the package holding it back
"""
struct HeldBack
    name::String
    last_version::VersionNumber
    compat::Pkg.Types.VersionSpec
end

Base.show(io::IO, hb::HeldBack) =
    print(io, hb.name, "@", hb.last_version, " {", hb.compat, "}")
Base.print(io::IO, hb::HeldBack) = show(io, hb)

Base.show(io::IO, ::MIME"text/plain", hb::HeldBack) =
    print(io, hb.name, "@", Box.LIGHT_GREEN_FG(string(hb.last_version)), " ",
          Box.LIGHT_RED_FG(string(hb.compat)))


get_newversion(d::Dict{String}, uuid, name, default) = get(d, name, default)
get_newversion(d::Dict{UUID}, uuid, name, default) = get(d, uuid, default)

# https://github.com/JuliaRegistries/RegistryTools.jl/blob/77e2a02e62185ce865653bdae95203a3a40510f0/src/Compress.jl#L47-L72
function decompress(compressed; versions_dict)
    versions = sort!([VersionNumber(v) for v in keys(versions_dict)])
    uncompressed = Dict{VersionNumber,Dict{Any,Any}}()
    for (vers, data) in compressed
        vs = VersionSpec(vers)
        for v in versions
            v in vs || continue
            uv = get!(uncompressed, v, Dict())
            for (key, value) in data
                # the `&& uv[key] != value`
                # seems necessary here to not fail on some packages in the registry,
                # but is not present in the `RegistryTools.Compress.load` version
                if haskey(uv, key) && uv[key] != value
                    error("Overlapping ranges for $(key) in Compat. Detected for version $(v).")
                else
                    uv[key] = value
                end
            end
        end
    end
    return uncompressed
end

"""
    held_back_packages(; newversions = Dict())

Returns a vector of pairs with the first entry as package names and the values as lists of
`HeldBack` objects. Every package in the list is upper bounded to not its last version by
the package in the key. See the docs for `HeldBack` for what data it contains.

The `newversions` keyword can be used to supply unregistered version numbers for specific packages;
this can allow you to prospectively identify packages whose `[compat]` may need to
be bumped if you release the specified package version(s). The keys of `newversions`
can be `UUID` or `String`; the values should be `VersionNumber`s.
"""
function held_back_packages(; newversions=Dict{UUID,VersionNumber}())
    stdlibs = readdir(Sys.STDLIB)
    packages = Dict{UUID, Package}()
    for registry in reachable_registries()
        for (uuid, data) in registry.pkgs
            name = data.name
            info = registry_info(data)
            versions = Dict{VersionNumber, Base.SHA1}()
            for (ver, vinfo) in info.version_info
                vinfo.yanked && continue
                versions[ver] = vinfo.git_tree_sha1
            end
            nv = get_newversion(newversions, uuid, name, nothing)
            if nv !== nothing
                versions[nv] = Base.SHA1(fill(0x00, 20))
            end
            max_version = maximum(keys(versions))
            packages[UUID(uuid)] = Package(name, info, max_version)
        end
    end

    packages_holding_back = Dict{String, Vector{HeldBack}}()
    for (uuid, pkg) in packages
        info = pkg.info
        compats = decompress(compat_info(info); versions_dict=info.version_info)

        compat_max_version = if !haskey(compats, pkg.max_version)
            nothing
        else
            compats[pkg.max_version]
        end
        deps = decompress(info.deps; versions_dict=info.version_info)
        deps_max_version = get(deps, pkg.max_version, nothing)
        if deps_max_version === nothing
            # No deps at all
            continue
        end
        if compat_max_version !== nothing && deps_max_version !== nothing
            packages_being_held_back = HeldBack[]
            for (dep_name, dep_uuid) in deps_max_version
                dep_uuid = UUID(dep_uuid)
                if dep_name in stdlibs
                    continue
                end
                compat = get(compat_max_version, dep_uuid, nothing)
                # No compat at all declared
                if compat === nothing
                    continue
                end
                compat = Pkg.Types.VersionSpec(compat)
                dep_max_version = packages[dep_uuid].max_version
                if !(dep_max_version in compat)
                    push!(packages_being_held_back, HeldBack(dep_name, dep_max_version, compat))
                end
            end
            if !isempty(packages_being_held_back)
                packages_holding_back[pkg.name] = packages_being_held_back
            end
        end
    end
    return packages_holding_back
end


"""
    held_back_by(pkgname::AbstractString, version::VersionNumber)

Return a list of packages would hold back the given not-yet-registered `version` of `pkgname`.
"""
held_back_by(name::String, version::VersionNumber) = held_back_by(name, held_back_packages(; newversions=Dict(name=>version)))

"""
    held_back_by(pkgname::AbstractString, d=held_back_packages())

    Return a list of packages that are holding back `pkgname`. `d` can be obtained from [`held_back_packages`](@ref).
"""
function held_back_by(name::String, d::AbstractDict=held_back_packages())
    heldby = Set{String}()
    for (k, v) in d
        for hb in v
            hb.name == name && push!(heldby, k)
        end
    end
    return sort(collect(heldby))
end

held_back_by(name::AbstractString, args...; kwargs...) = held_back_by(String(name), args...; kwargs...)

function print_held_back(io::IO=stdout, pkgs=held_back_packages())
    color = get(io, :color, false)
    pad = maximum(textwidth, keys(pkgs))
    pkgs = collect(pkgs)
    sort!(pkgs, by=x->x.first)
    for (pkg, held_back) in pkgs
        # This is not how you are supposed to do it...
        strs = if color
            sprint.((io, x) -> show(io, MIME("text/plain"), x), held_back)
        else
            sprint.(print, held_back)
        end
        println(io, rpad(pkg, pad, '-'), "=>[", join(strs, ", "), "]")
    end
end

"""
    find_julia_packages_github()::Set{String}

Returns a set of packages that are likely to be Julia packages
that you have commit access to. Requries a github token being
stored as a `GITHUB_AUTH` env variable.
"""
function find_julia_packages_github()
    auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
    repos = available_repos(auth)
    filter!(repos) do repo
        repo.fork && return false
        endswith(repo.name, ".jl") || return false
    end
    return Set(split(repo.name, ".jl")[1] for repo in repos)
end

function available_repos(auth)
    myparams = Dict("per_page" => 100);
    repos = []
    page = 1
    while true
        myparams["page"] = page
        results = GitHub.gh_get_json(GitHub.DEFAULT_API, "/user/repos"; auth,
                                    params = myparams)
        isempty(results) && break
        page += 1
        repos_page = map(GitHub.Repo, results)
        append!(repos, repos_page)
    end
    return repos
end

end # module
