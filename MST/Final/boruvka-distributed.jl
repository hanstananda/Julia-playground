#=
boruvka_multithread_lightgraph:
- Julia version: 1.3.1
- Author: hanstananda
- Date: 2020-03-15
=#
@everywhere using LightGraphs, SimpleWeightedGraphs
using DelimitedFiles
@everywhere using Base
@everywhere using DataStructures
using SharedArrays
using Distributed

"""
    boruvka_mst_distributed(g)

Return a tuple `(mst, weight)` where `mst` is a vector of edges representing the
optimum (minimum, by default) spanning tree of a connected, undirected graph
`g` , and `weight` is the sum of all the edges in the solution by using
[Boruvka's algorithm](https://en.wikipedia.org/wiki/Bor%C5%AFvka%27s_algorithm).
The algorithm requires that all edges have different weights to correctly generate a minimun/maximum spanning tree
### Optional parameter(s):
- `max_iter`: Used to limit maximum number of iterations the algorithm will be performed. The default is log2(numVertex).
- `minimize=true`: if set to `false`, calculate the maximum spanning tree.
"""
function boruvka_mst_distributed(
    g::AG, 
    max_iter = round(Int64, log2(nv(g)) + 1), 
    distmx::AbstractMatrix{T} = weights(g);
    minimize = true
    )  where {T<:Real, U, AG<:AbstractGraph{U}}
    nvg = nv(g)
    connected_vs = IntDisjointSets(nvg)
        
    # maximizing Z is the same as minimizing -Z
    # mode will indicate the need for the -1 multiplication
    mode = minimize ? 1 : -1

    joined_nodes = Dict{Int, Vector{Int}}(i=>[i] for i in 1:nvg)
    MAX_WEIGHT = Inf
    cheapest = SharedVector{Float64}(nvg+1)
    cheapest_target_node = SharedVector{Int}(nvg+1)
    cheapest_source_node = SharedVector{Int}(nvg+1)
    mst = Vector{edgetype(g)}()
    sizehint!(mst, nvg - 1)
    weight = zero(Float64)
    current_iteration = 1
    println("Max iteration: ", max_iter)
    while(current_iteration< max_iter && length(mst) < nvg - 1)
        current_iteration += 1
        initcheapestarray(g, cheapest_source_node, cheapest_target_node, cheapest, MAX_WEIGHT)
        findcheapestvertex(g, cheapest_source_node, cheapest_target_node, cheapest, joined_nodes, connected_vs, distmx, mode)
        weight += contractvertex(g, cheapest_source_node, cheapest_target_node, cheapest, joined_nodes, connected_vs,
                mst, MAX_WEIGHT, mode)
    end

    return (mst=mst, weight=weight)
end

function initcheapestarray(
        g::AG,
        cheapest_source_node::SharedVector{Int},
        cheapest_target_node::SharedVector{Int},
        cheapest::SharedVector{Float64},
        MAX_WEIGHT::Float64
    ) where {U, AG<:AbstractGraph{U}}
    for i in vertices(g)
        cheapest[i] = MAX_WEIGHT
        cheapest_target_node[i] = i
        cheapest_source_node[i] = i
    end
end

function findcheapestvertex(
        g::AG,
        cheapest_source_node::SharedVector{Int},
        cheapest_target_node::SharedVector{Int},
        cheapest::SharedVector{Float64},
        joined_nodes::Dict{Int, Vector{Int}},
        connected_vs::IntDisjointSets,
        distmx::AbstractMatrix{T}, 
        mode::Int
    )  where {T<:Real, U, AG<:AbstractGraph{U}}
    source_vertices = Vector{Int}(first.(keys(joined_nodes)))
    @sync @distributed for i in source_vertices
        # println("Accessing set ",i, " with sources ", joined_nodes[i])
        for src in joined_nodes[i]
            for dst in neighbors(g, src)
                weight = distmx[src, dst]
                # println(src," -> ", dst, "=", weight, " ",  !in_same_set(connected_vs, src, dst) )
                root_src = find_root(connected_vs, src)
                root_dst = find_root(connected_vs, dst)
                if root_src != root_dst
                    if(cheapest[root_src] > weight * mode)
                        cheapest[root_src] = weight * mode
                        cheapest_target_node[root_src] = dst
                        cheapest_source_node[root_src] = src
                    end
                end
            end

        end
    end
end

function contractvertex(
        g::AG,
        cheapest_source_node::SharedVector{Int},
        cheapest_target_node::SharedVector{Int},
        cheapest::SharedVector{Float64},
        joined_nodes::Dict{Int, Vector{Int}},
        connected_vs::IntDisjointSets,
        mst::Vector,
        MAX_WEIGHT::Float64,
        mode::Int
    )::Float64  where {U, AG<:AbstractGraph{U}}
    res = zero(Float64)
    for i in vertices(g)
        if(abs( cheapest[i]- MAX_WEIGHT)> eps() && !in_same_set(connected_vs, cheapest_source_node[i], cheapest_target_node[i]))
            # Connect the vertices, add mst to answer
            set1 = find_root(connected_vs, cheapest_source_node[i])
            set2 = find_root(connected_vs, cheapest_target_node[i])
            union!(connected_vs, cheapest_source_node[i], cheapest_target_node[i])
            res += cheapest[i] * mode
            push!(mst, SimpleWeightedEdge(cheapest_source_node[i], cheapest_target_node[i], cheapest[i] * mode))
            # Merge Vertices that has been connected together
            merge_target = find_root(connected_vs, cheapest_source_node[i])
            if merge_target != set1
                for j in joined_nodes[set1]
                    push!(joined_nodes[merge_target],j)
                end
                delete!(joined_nodes,set1)
            end
            if merge_target != set2
                for j in joined_nodes[set2]
                    push!(joined_nodes[merge_target],j)
                end
                delete!(joined_nodes,set2)
            end
        end
    end
    return res
end

