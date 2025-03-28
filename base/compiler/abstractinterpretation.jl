# This file is a part of Julia. License is MIT: https://julialang.org/license

#############
# constants #
#############

const _REF_NAME = Ref.body.name

#########
# logic #
#########

# See if the inference result of the current statement's result value might affect
# the final answer for the method (aside from optimization potential and exceptions).
# To do that, we need to check both for slot assignment and SSA usage.
call_result_unused(frame::InferenceState, currpc::Int) =
    isexpr(frame.src.code[currpc], :call) && isempty(frame.ssavalue_uses[currpc])
call_result_unused(si::StmtInfo) = !si.used

function get_max_methods(mod::Module, interp::AbstractInterpreter)
    max_methods = ccall(:jl_get_module_max_methods, Cint, (Any,), mod) % Int
    max_methods < 0 ? InferenceParams(interp).MAX_METHODS : max_methods
end

function get_max_methods(@nospecialize(f), mod::Module, interp::AbstractInterpreter)
    if f !== nothing
        fmm = typeof(f).name.max_methods
        fmm !== UInt8(0) && return Int(fmm)
    end
    return get_max_methods(mod, interp)
end

const empty_bitset = BitSet()

function should_infer_this_call(sv::InferenceState)
    if sv.params.unoptimize_throw_blocks
        # Disable inference of calls in throw blocks, since we're unlikely to
        # need their types. There is one exception however: If up until now, the
        # function has not seen any side effects, we would like to make sure there
        # aren't any in the throw block either to enable other optimizations.
        if is_stmt_throw_block(get_curr_ssaflag(sv))
            should_infer_for_effects(sv) || return false
        end
    end
    return true
end

function should_infer_for_effects(sv::InferenceState)
    effects = Effects(sv)
    return is_terminates(effects) && is_effect_free(effects)
end

function abstract_call_gf_by_type(interp::AbstractInterpreter, @nospecialize(f),
                                  arginfo::ArgInfo, si::StmtInfo, @nospecialize(atype),
                                  sv::InferenceState, max_methods::Int)
    ⊑ᵢ = ⊑(typeinf_lattice(interp))
    if !should_infer_this_call(sv)
        add_remark!(interp, sv, "Skipped call in throw block")
        nonoverlayed = false
        if isoverlayed(method_table(interp)) && is_nonoverlayed(sv.ipo_effects)
            # as we may want to concrete-evaluate this frame in cases when there are
            # no overlayed calls, try an additional effort now to check if this call
            # isn't overlayed rather than just handling it conservatively
            matches = find_matching_methods(arginfo.argtypes, atype, method_table(interp),
                InferenceParams(interp).MAX_UNION_SPLITTING, max_methods)
            if !isa(matches, FailedMethodMatch)
                nonoverlayed = matches.nonoverlayed
            end
        else
            nonoverlayed = true
        end
        # At this point we are guaranteed to end up throwing on this path,
        # which is all that's required for :consistent-cy. Of course, we don't
        # know anything else about this statement.
        effects = Effects(; consistent=ALWAYS_TRUE, nonoverlayed)
        return CallMeta(Any, effects, NoCallInfo())
    end

    argtypes = arginfo.argtypes
    matches = find_matching_methods(argtypes, atype, method_table(interp),
        InferenceParams(interp).MAX_UNION_SPLITTING, max_methods)
    if isa(matches, FailedMethodMatch)
        add_remark!(interp, sv, matches.reason)
        return CallMeta(Any, Effects(), NoCallInfo())
    end

    (; valid_worlds, applicable, info) = matches
    update_valid_age!(sv, valid_worlds)
    napplicable = length(applicable)
    rettype = Bottom
    edges = MethodInstance[]
    conditionals = nothing # keeps refinement information of call argument types when the return type is boolean
    seen = 0               # number of signatures actually inferred
    any_const_result = false
    const_results = Union{Nothing,ConstResult}[]
    multiple_matches = napplicable > 1
    fargs = arginfo.fargs
    all_effects = EFFECTS_TOTAL
    if !matches.nonoverlayed
        # currently we don't have a good way to execute the overlayed method definition,
        # so we should give up pure/concrete eval when any of the matched methods is overlayed
        f = nothing
        all_effects = Effects(all_effects; nonoverlayed=false)
    end

    # try pure-evaluation
    val = pure_eval_call(interp, f, applicable, arginfo)
    val !== nothing && return CallMeta(val, all_effects, MethodResultPure(info)) # TODO: add some sort of edge(s)

    for i in 1:napplicable
        match = applicable[i]::MethodMatch
        method = match.method
        sig = match.spec_types
        if bail_out_toplevel_call(interp, sig, sv)
            # only infer concrete call sites in top-level expressions
            add_remark!(interp, sv, "Refusing to infer non-concrete call site in top-level expression")
            rettype = Any
            break
        end
        this_rt = Bottom
        splitunions = false
        # TODO: this used to trigger a bug in inference recursion detection, and is unmaintained now
        # sigtuple = unwrap_unionall(sig)::DataType
        # splitunions = 1 < unionsplitcost(sigtuple.parameters) * napplicable <= InferenceParams(interp).MAX_UNION_SPLITTING
        if splitunions
            splitsigs = switchtupleunion(sig)
            for sig_n in splitsigs
                result = abstract_call_method(interp, method, sig_n, svec(), multiple_matches, si, sv)
                (; rt, edge, effects) = result
                this_argtypes = isa(matches, MethodMatches) ? argtypes : matches.applicable_argtypes[i]
                this_arginfo = ArgInfo(fargs, this_argtypes)
                const_call_result = abstract_call_method_with_const_args(interp,
                    result, f, this_arginfo, si, match, sv)
                const_result = nothing
                if const_call_result !== nothing
                    if const_call_result.rt ⊑ᵢ rt
                        rt = const_call_result.rt
                        (; effects, const_result, edge) = const_call_result
                    end
                end
                all_effects = merge_effects(all_effects, effects)
                push!(const_results, const_result)
                any_const_result |= const_result !== nothing
                edge === nothing || push!(edges, edge)
                this_rt = tmerge(this_rt, rt)
                if bail_out_call(interp, this_rt, sv)
                    break
                end
            end
            this_conditional = ignorelimited(this_rt)
            this_rt = widenwrappedconditional(this_rt)
        else
            result = abstract_call_method(interp, method, sig, match.sparams, multiple_matches, si, sv)
            (; rt, edge, effects) = result
            this_conditional = ignorelimited(rt)
            this_rt = widenwrappedconditional(rt)
            # try constant propagation with argtypes for this match
            # this is in preparation for inlining, or improving the return result
            this_argtypes = isa(matches, MethodMatches) ? argtypes : matches.applicable_argtypes[i]
            this_arginfo = ArgInfo(fargs, this_argtypes)
            const_call_result = abstract_call_method_with_const_args(interp,
                result, f, this_arginfo, si, match, sv)
            const_result = nothing
            if const_call_result !== nothing
                this_const_conditional = ignorelimited(const_call_result.rt)
                this_const_rt = widenwrappedconditional(const_call_result.rt)
                # return type of const-prop' inference can be wider than that of non const-prop' inference
                # e.g. in cases when there are cycles but cached result is still accurate
                if this_const_rt ⊑ᵢ this_rt
                    this_conditional = this_const_conditional
                    this_rt = this_const_rt
                    (; effects, const_result, edge) = const_call_result
                end
            end
            all_effects = merge_effects(all_effects, effects)
            push!(const_results, const_result)
            any_const_result |= const_result !== nothing
            edge === nothing || push!(edges, edge)
        end
        @assert !(this_conditional isa Conditional) "invalid lattice element returned from inter-procedural context"
        seen += 1
        rettype = tmerge(ipo_lattice(interp), rettype, this_rt)
        if this_conditional !== Bottom && is_lattice_bool(ipo_lattice(interp), rettype) && fargs !== nothing
            if conditionals === nothing
                conditionals = Any[Bottom for _ in 1:length(argtypes)],
                               Any[Bottom for _ in 1:length(argtypes)]
            end
            for i = 1:length(argtypes)
                cnd = conditional_argtype(this_conditional, sig, argtypes, i)
                conditionals[1][i] = tmerge(conditionals[1][i], cnd.thentype)
                conditionals[2][i] = tmerge(conditionals[2][i], cnd.elsetype)
            end
        end
        if bail_out_call(interp, rettype, sv)
            break
        end
    end

    if any_const_result && seen == napplicable
        @assert napplicable == nmatches(info) == length(const_results)
        info = ConstCallInfo(info, const_results)
    end

    if seen != napplicable
        # there may be unanalyzed effects within unseen dispatch candidate,
        # but we can still ignore nonoverlayed effect here since we already accounted for it
        all_effects = merge_effects(all_effects, EFFECTS_UNKNOWN)
    elseif isa(matches, MethodMatches) ? (!matches.fullmatch || any_ambig(matches)) :
            (!all(matches.fullmatches) || any_ambig(matches))
        # Account for the fact that we may encounter a MethodError with a non-covered or ambiguous signature.
        all_effects = Effects(all_effects; nothrow=false)
    end

    rettype = from_interprocedural!(ipo_lattice(interp), rettype, sv, arginfo, conditionals)

    # Also considering inferring the compilation signature for this method, so
    # it is available to the compiler in case it ends up needing it.
    if infer_compilation_signature(interp) && 1 == seen == napplicable && rettype !== Any && rettype !== Union{} && !is_removable_if_unused(all_effects)
        match = applicable[1]::MethodMatch
        method = match.method
        sig = match.spec_types
        mi = specialize_method(match; preexisting=true)
        if mi !== nothing && !const_prop_methodinstance_heuristic(interp, match, mi, arginfo, sv)
            csig = get_compileable_sig(method, sig, match.sparams)
            if csig !== nothing && csig !== sig
                abstract_call_method(interp, method, csig, match.sparams, multiple_matches, StmtInfo(false), sv)
            end
        end
    end

    if call_result_unused(si) && !(rettype === Bottom)
        add_remark!(interp, sv, "Call result type was widened because the return value is unused")
        # We're mainly only here because the optimizer might want this code,
        # but we ourselves locally don't typically care about it locally
        # (beyond checking if it always throws).
        # So avoid adding an edge, since we don't want to bother attempting
        # to improve our result even if it does change (to always throw),
        # and avoid keeping track of a more complex result type.
        rettype = Any
    end
    add_call_backedges!(interp, rettype, all_effects, edges, matches, atype, sv)
    if !isempty(sv.pclimitations) # remove self, if present
        delete!(sv.pclimitations, sv)
        for caller in sv.callers_in_cycle
            delete!(sv.pclimitations, caller)
        end
    end
    return CallMeta(rettype, all_effects, info)
end

struct FailedMethodMatch
    reason::String
end

struct MethodMatches
    applicable::Vector{Any}
    info::MethodMatchInfo
    valid_worlds::WorldRange
    mt::Core.MethodTable
    fullmatch::Bool
    nonoverlayed::Bool
end
any_ambig(info::MethodMatchInfo) = info.results.ambig
any_ambig(m::MethodMatches) = any_ambig(m.info)

struct UnionSplitMethodMatches
    applicable::Vector{Any}
    applicable_argtypes::Vector{Vector{Any}}
    info::UnionSplitInfo
    valid_worlds::WorldRange
    mts::Vector{Core.MethodTable}
    fullmatches::Vector{Bool}
    nonoverlayed::Bool
end
any_ambig(m::UnionSplitMethodMatches) = any(any_ambig, m.info.matches)

function find_matching_methods(argtypes::Vector{Any}, @nospecialize(atype), method_table::MethodTableView,
                               union_split::Int, max_methods::Int)
    # NOTE this is valid as far as any "constant" lattice element doesn't represent `Union` type
    if 1 < unionsplitcost(argtypes) <= union_split
        split_argtypes = switchtupleunion(argtypes)
        infos = MethodMatchInfo[]
        applicable = Any[]
        applicable_argtypes = Vector{Any}[] # arrays like `argtypes`, including constants, for each match
        valid_worlds = WorldRange()
        mts = Core.MethodTable[]
        fullmatches = Bool[]
        nonoverlayed = true
        for i in 1:length(split_argtypes)
            arg_n = split_argtypes[i]::Vector{Any}
            sig_n = argtypes_to_type(arg_n)
            mt = ccall(:jl_method_table_for, Any, (Any,), sig_n)
            mt === nothing && return FailedMethodMatch("Could not identify method table for call")
            mt = mt::Core.MethodTable
            result = findall(sig_n, method_table; limit = max_methods)
            if result === missing
                return FailedMethodMatch("For one of the union split cases, too many methods matched")
            end
            (; matches, overlayed) = result
            nonoverlayed &= !overlayed
            push!(infos, MethodMatchInfo(matches))
            for m in matches
                push!(applicable, m)
                push!(applicable_argtypes, arg_n)
            end
            valid_worlds = intersect(valid_worlds, matches.valid_worlds)
            thisfullmatch = any(match::MethodMatch->match.fully_covers, matches)
            found = false
            for (i, mt′) in enumerate(mts)
                if mt′ === mt
                    fullmatches[i] &= thisfullmatch
                    found = true
                    break
                end
            end
            if !found
                push!(mts, mt)
                push!(fullmatches, thisfullmatch)
            end
        end
        return UnionSplitMethodMatches(applicable,
                                       applicable_argtypes,
                                       UnionSplitInfo(infos),
                                       valid_worlds,
                                       mts,
                                       fullmatches,
                                       nonoverlayed)
    else
        mt = ccall(:jl_method_table_for, Any, (Any,), atype)
        if mt === nothing
            return FailedMethodMatch("Could not identify method table for call")
        end
        mt = mt::Core.MethodTable
        result = findall(atype, method_table; limit = max_methods)
        if result === missing
            # this means too many methods matched
            # (assume this will always be true, so we don't compute / update valid age in this case)
            return FailedMethodMatch("Too many methods matched")
        end
        (; matches, overlayed) = result
        fullmatch = any(match::MethodMatch->match.fully_covers, matches)
        return MethodMatches(matches.matches,
                             MethodMatchInfo(matches),
                             matches.valid_worlds,
                             mt,
                             fullmatch,
                             !overlayed)
    end
end

"""
    from_interprocedural!(ipo_lattice::AbstractLattice, rt, sv::InferenceState, arginfo::ArgInfo, maybecondinfo) -> newrt

Converts inter-procedural return type `rt` into a local lattice element `newrt`,
that is appropriate in the context of current local analysis frame `sv`, especially:
- unwraps `rt::LimitedAccuracy` and collects its limitations into the current frame `sv`
- converts boolean `rt` to new boolean `newrt` in a way `newrt` can propagate extra conditional
  refinement information, e.g. translating `rt::InterConditional` into `newrt::Conditional`
  that holds a type constraint information about a variable in `sv`

This function _should_ be used wherever we propagate results returned from
`abstract_call_method` or `abstract_call_method_with_const_args`.

When `maybecondinfo !== nothing`, this function also tries extra conditional argument type refinement.
In such cases `maybecondinfo` should be either of:
- `maybecondinfo::Tuple{Vector{Any},Vector{Any}}`: precomputed argument type refinement information
- method call signature tuple type
When we deal with multiple `MethodMatch`es, it's better to precompute `maybecondinfo` by
`tmerge`ing argument signature type of each method call.
"""
function from_interprocedural!(ipo_lattice::AbstractLattice, @nospecialize(rt), sv::InferenceState, arginfo::ArgInfo, @nospecialize(maybecondinfo))
    rt = collect_limitations!(rt, sv)
    if is_lattice_bool(ipo_lattice, rt)
        if maybecondinfo === nothing
            rt = widenconditional(rt)
        else
            rt = from_interconditional(ipo_lattice, rt, sv, arginfo, maybecondinfo)
        end
    end
    @assert !(rt isa InterConditional) "invalid lattice element returned from inter-procedural context"
    return rt
end

function collect_limitations!(@nospecialize(typ), sv::InferenceState)
    if isa(typ, LimitedAccuracy)
        union!(sv.pclimitations, typ.causes)
        return typ.typ
    end
    return typ
end

function from_interconditional(ipo_lattice::AbstractLattice, @nospecialize(typ),
        sv::InferenceState, (; fargs, argtypes)::ArgInfo, @nospecialize(maybecondinfo))
    lattice = widenlattice(ipo_lattice)
    fargs === nothing && return widenconditional(typ)
    slot = 0
    thentype = elsetype = Any
    condval = maybe_extract_const_bool(typ)
    for i in 1:length(fargs)
        # find the first argument which supports refinement,
        # and intersect all equivalent arguments with it
        arg = ssa_def_slot(fargs[i], sv)
        arg isa SlotNumber || continue # can't refine
        old = argtypes[i]
        old isa Type || continue # unlikely to refine
        id = slot_id(arg)
        if slot == 0 || id == slot
            if isa(maybecondinfo, Tuple{Vector{Any},Vector{Any}})
                # if we have already computed argument refinement information, apply that now to get the result
                new_thentype = maybecondinfo[1][i]
                new_elsetype = maybecondinfo[2][i]
            else
                # otherwise compute it on the fly
                cnd = conditional_argtype(typ, maybecondinfo, argtypes, i)
                new_thentype = cnd.thentype
                new_elsetype = cnd.elsetype
            end
            if condval === false
                thentype = Bottom
            elseif ⊑(lattice, new_thentype, thentype)
                thentype = new_thentype
            else
                thentype = tmeet(lattice, thentype, widenconst(new_thentype))
            end
            if condval === true
                elsetype = Bottom
            elseif ⊑(lattice, new_elsetype, elsetype)
                elsetype = new_elsetype
            else
                elsetype = tmeet(lattice, elsetype, widenconst(new_elsetype))
            end
            if (slot > 0 || condval !== false) && ⋤(lattice, thentype, old)
                slot = id
            elseif (slot > 0 || condval !== true) && ⋤(lattice, elsetype, old)
                slot = id
            else # reset: no new useful information for this slot
                thentype = elsetype = Any
                if slot > 0
                    slot = 0
                end
            end
        end
    end
    if thentype === Bottom && elsetype === Bottom
        return Bottom # accidentally proved this call to be dead / throw !
    elseif slot > 0
        return Conditional(slot, thentype, elsetype) # record a Conditional improvement to this slot
    end
    return widenconditional(typ)
end

function conditional_argtype(@nospecialize(rt), @nospecialize(sig), argtypes::Vector{Any}, i::Int)
    if isa(rt, InterConditional) && rt.slot == i
        return rt
    else
        thentype = elsetype = tmeet(widenconditional(argtypes[i]), fieldtype(sig, i))
        condval = maybe_extract_const_bool(rt)
        condval === true && (elsetype = Bottom)
        condval === false && (thentype = Bottom)
        return InterConditional(i, thentype, elsetype)
    end
end

function add_call_backedges!(interp::AbstractInterpreter,
    @nospecialize(rettype), all_effects::Effects,
    edges::Vector{MethodInstance}, matches::Union{MethodMatches,UnionSplitMethodMatches}, @nospecialize(atype),
    sv::InferenceState)
    # we don't need to add backedges when:
    # - a new method couldn't refine (widen) this type and
    # - the effects are known to not provide any useful IPO information
    if rettype === Any
        if !isoverlayed(method_table(interp))
            # we can ignore the `nonoverlayed` property if `interp` doesn't use
            # overlayed method table at all since it will never be tainted anyway
            all_effects = Effects(all_effects; nonoverlayed=false)
        end
        if all_effects === Effects()
            return
        end
    end
    for edge in edges
        add_backedge!(sv, edge)
    end
    # also need an edge to the method table in case something gets
    # added that did not intersect with any existing method
    if isa(matches, MethodMatches)
        matches.fullmatch || add_mt_backedge!(sv, matches.mt, atype)
    else
        for (thisfullmatch, mt) in zip(matches.fullmatches, matches.mts)
            thisfullmatch || add_mt_backedge!(sv, mt, atype)
        end
    end
end

const RECURSION_UNUSED_MSG = "Bounded recursion detected with unused result. Annotated return type may be wider than true result."
const RECURSION_MSG = "Bounded recursion detected. Call was widened to force convergence."

function abstract_call_method(interp::AbstractInterpreter, method::Method, @nospecialize(sig), sparams::SimpleVector, hardlimit::Bool, si::StmtInfo, sv::InferenceState)
    if method.name === :depwarn && isdefined(Main, :Base) && method.module === Main.Base
        add_remark!(interp, sv, "Refusing to infer into `depwarn`")
        return MethodCallResult(Any, false, false, nothing, Effects())
    end

    # Limit argument type tuple growth of functions:
    # look through the parents list to see if there's a call to the same method
    # and from the same method.
    # Returns the topmost occurrence of that repeated edge.
    edgecycle = edgelimited = false
    topmost = nothing

    for infstate in InfStackUnwind(sv)
        if method === infstate.linfo.def
            if infstate.linfo.specTypes::Type == sig::Type
                # avoid widening when detecting self-recursion
                # TODO: merge call cycle and return right away
                if call_result_unused(si)
                    add_remark!(interp, sv, RECURSION_UNUSED_MSG)
                    # since we don't use the result (typically),
                    # we have a self-cycle in the call-graph, but not in the inference graph (typically):
                    # break this edge now (before we record it) by returning early
                    # (non-typically, this means that we lose the ability to detect a guaranteed StackOverflow in some cases)
                    return MethodCallResult(Any, true, true, nothing, Effects())
                end
                topmost = nothing
                edgecycle = true
                break
            end
            topmost === nothing || continue
            if edge_matches_sv(infstate, method, sig, sparams, hardlimit, sv)
                topmost = infstate
                edgecycle = true
            end
        end
    end

    if topmost !== nothing
        sigtuple = unwrap_unionall(sig)::DataType
        msig = unwrap_unionall(method.sig)::DataType
        spec_len = length(msig.parameters) + 1
        ls = length(sigtuple.parameters)

        if method === sv.linfo.def
            # Under direct self-recursion, permit much greater use of reducers.
            # here we assume that complexity(specTypes) :>= complexity(sig)
            comparison = sv.linfo.specTypes
            l_comparison = length((unwrap_unionall(comparison)::DataType).parameters)
            spec_len = max(spec_len, l_comparison)
        else
            comparison = method.sig
        end

        if isdefined(method, :recursion_relation)
            # We don't require the recursion_relation to be transitive, so
            # apply a hard limit
            hardlimit = true
        end

        # see if the type is actually too big (relative to the caller), and limit it if required
        newsig = limit_type_size(sig, comparison, hardlimit ? comparison : sv.linfo.specTypes, InferenceParams(interp).TUPLE_COMPLEXITY_LIMIT_DEPTH, spec_len)

        if newsig !== sig
            # continue inference, but note that we've limited parameter complexity
            # on this call (to ensure convergence), so that we don't cache this result
            if call_result_unused(si)
                add_remark!(interp, sv, RECURSION_UNUSED_MSG)
                # if we don't (typically) actually care about this result,
                # don't bother trying to examine some complex abstract signature
                # since it's very unlikely that we'll try to inline this,
                # or want make an invoke edge to its calling convention return type.
                # (non-typically, this means that we lose the ability to detect a guaranteed StackOverflow in some cases)
                return MethodCallResult(Any, true, true, nothing, Effects())
            end
            add_remark!(interp, sv, RECURSION_MSG)
            topmost = topmost::InferenceState
            parentframe = topmost.parent
            poison_callstack(sv, parentframe === nothing ? topmost : parentframe)
            sig = newsig
            sparams = svec()
            edgelimited = true
        end
    end

    # if sig changed, may need to recompute the sparams environment
    if isa(method.sig, UnionAll) && isempty(sparams)
        recomputed = ccall(:jl_type_intersection_with_env, Any, (Any, Any), sig, method.sig)::SimpleVector
        #@assert recomputed[1] !== Bottom
        # We must not use `sig` here, since that may re-introduce structural complexity that
        # our limiting heuristic sought to eliminate. The alternative would be to not increment depth over covariant contexts,
        # but we prefer to permit inference of tuple-destructuring, so we don't do that right now
        # For example, with a signature such as `Tuple{T, Ref{T}} where {T <: S}`
        # we might want to limit this to `Tuple{S, Ref}`, while type-intersection can instead give us back the original type
        # (which moves `S` back up to a lower comparison depth)
        # Optionally, we could try to drive this to a fixed point, but I think this is getting too complex,
        # and this would only cause more questions and more problems
        # (the following is only an example, most of the statements are probable in the wrong order):
        #     newsig = sig
        #     seen = IdSet()
        #     while !(newsig in seen)
        #         push!(seen, newsig)
        #         lsig = length((unwrap_unionall(sig)::DataType).parameters)
        #         newsig = limit_type_size(newsig, sig, sv.linfo.specTypes, InferenceParams(interp).TUPLE_COMPLEXITY_LIMIT_DEPTH, lsig)
        #         recomputed = ccall(:jl_type_intersection_with_env, Any, (Any, Any), newsig, method.sig)::SimpleVector
        #         newsig = recomputed[2]
        #     end
        #     sig = ?
        sparams = recomputed[2]::SimpleVector
    end

    (; rt, edge, effects) = typeinf_edge(interp, method, sig, sparams, sv)

    if edge === nothing
        edgecycle = edgelimited = true
    end

    # we look for the termination effect override here as well, since the :terminates effect
    # may have been tainted due to recursion at this point even if it's overridden
    if is_effect_overridden(sv, :terminates_globally)
        # this frame is known to terminate
        effects = Effects(effects, terminates=true)
    elseif is_effect_overridden(method, :terminates_globally)
        # this edge is known to terminate
        effects = Effects(effects; terminates=true)
    elseif edgecycle
        # Some sort of recursion was detected.
        if edge !== nothing && !edgelimited && !is_edge_recursed(edge, sv)
            # no `MethodInstance` cycles -- don't taint :terminate
        else
            # we cannot guarantee that the call will terminate
            effects = Effects(effects; terminates=false)
        end
    end

    return MethodCallResult(rt, edgecycle, edgelimited, edge, effects)
end

function edge_matches_sv(frame::InferenceState, method::Method, @nospecialize(sig), sparams::SimpleVector, hardlimit::Bool, sv::InferenceState)
    # The `method_for_inference_heuristics` will expand the given method's generator if
    # necessary in order to retrieve this field from the generated `CodeInfo`, if it exists.
    # The other `CodeInfo`s we inspect will already have this field inflated, so we just
    # access it directly instead (to avoid regeneration).
    callee_method2 = method_for_inference_heuristics(method, sig, sparams) # Union{Method, Nothing}

    inf_method2 = frame.src.method_for_inference_limit_heuristics # limit only if user token match
    inf_method2 isa Method || (inf_method2 = nothing)
    if callee_method2 !== inf_method2
        return false
    end
    if !hardlimit
        # if this is a soft limit,
        # also inspect the parent of this edge,
        # to see if they are the same Method as sv
        # in which case we'll need to ensure it is convergent
        # otherwise, we don't

        # check in the cycle list first
        # all items in here are mutual parents of all others
        if !any(p::InferenceState->matches_sv(p, sv), frame.callers_in_cycle)
            let parent = frame.parent
                parent !== nothing || return false
                parent = parent::InferenceState
                (parent.cached || parent.parent !== nothing) || return false
                matches_sv(parent, sv) || return false
            end
        end

        # If the method defines a recursion relation, give it a chance
        # to tell us that this recursion is actually ok.
        if isdefined(method, :recursion_relation)
            if Core._apply_pure(method.recursion_relation, Any[method, callee_method2, sig, frame.linfo.specTypes])
                return false
            end
        end
    end
    return true
end

# This function is used for computing alternate limit heuristics
function method_for_inference_heuristics(method::Method, @nospecialize(sig), sparams::SimpleVector)
    if isdefined(method, :generator) && method.generator.expand_early && may_invoke_generator(method, sig, sparams)
        method_instance = specialize_method(method, sig, sparams)
        if isa(method_instance, MethodInstance)
            cinfo = get_staged(method_instance)
            if isa(cinfo, CodeInfo)
                method2 = cinfo.method_for_inference_limit_heuristics
                if method2 isa Method
                    return method2
                end
            end
        end
    end
    return nothing
end

function matches_sv(parent::InferenceState, sv::InferenceState)
    sv_method2 = sv.src.method_for_inference_limit_heuristics # limit only if user token match
    sv_method2 isa Method || (sv_method2 = nothing)
    parent_method2 = parent.src.method_for_inference_limit_heuristics # limit only if user token match
    parent_method2 isa Method || (parent_method2 = nothing)
    return parent.linfo.def === sv.linfo.def && sv_method2 === parent_method2
end

function is_edge_recursed(edge::MethodInstance, sv::InferenceState)
    return any(InfStackUnwind(sv)) do infstate
        return edge === infstate.linfo
    end
end

function is_method_recursed(method::Method, sv::InferenceState)
    return any(InfStackUnwind(sv)) do infstate
        return method === infstate.linfo.def
    end
end

function is_constprop_edge_recursed(edge::MethodInstance, sv::InferenceState)
    return any(InfStackUnwind(sv)) do infstate
        return edge === infstate.linfo && any(infstate.result.overridden_by_const)
    end
end

function is_constprop_method_recursed(method::Method, sv::InferenceState)
    return any(InfStackUnwind(sv)) do infstate
        return method === infstate.linfo.def && any(infstate.result.overridden_by_const)
    end
end

# keeps result and context information of abstract_method_call, which will later be used for
# backedge computation, and concrete evaluation or constant-propagation
struct MethodCallResult
    rt
    edgecycle::Bool
    edgelimited::Bool
    edge::Union{Nothing,MethodInstance}
    effects::Effects
    function MethodCallResult(@nospecialize(rt),
                              edgecycle::Bool,
                              edgelimited::Bool,
                              edge::Union{Nothing,MethodInstance},
                              effects::Effects)
        return new(rt, edgecycle, edgelimited, edge, effects)
    end
end

function pure_eval_eligible(interp::AbstractInterpreter,
    @nospecialize(f), applicable::Vector{Any}, arginfo::ArgInfo)
    # XXX we need to check that this pure function doesn't call any overlayed method
    return f !== nothing &&
           length(applicable) == 1 &&
           is_method_pure(applicable[1]::MethodMatch) &&
           is_all_const_arg(arginfo, #=start=#2)
end

function is_method_pure(method::Method, @nospecialize(sig), sparams::SimpleVector)
    if isdefined(method, :generator)
        method.generator.expand_early || return false
        mi = specialize_method(method, sig, sparams)
        isa(mi, MethodInstance) || return false
        staged = get_staged(mi)
        (staged isa CodeInfo && (staged::CodeInfo).pure) || return false
        return true
    end
    return method.pure
end
is_method_pure(match::MethodMatch) = is_method_pure(match.method, match.spec_types, match.sparams)

function pure_eval_call(interp::AbstractInterpreter,
    @nospecialize(f), applicable::Vector{Any}, arginfo::ArgInfo)
    pure_eval_eligible(interp, f, applicable, arginfo) || return nothing
    return _pure_eval_call(f, arginfo)
end
function _pure_eval_call(@nospecialize(f), arginfo::ArgInfo)
    args = collect_const_args(arginfo, #=start=#2)
    value = try
        Core._apply_pure(f, args)
    catch
        return nothing
    end
    return Const(value)
end

# - true: eligible for concrete evaluation
# - false: eligible for semi-concrete evaluation
# - nothing: not eligible for either of it
function concrete_eval_eligible(interp::AbstractInterpreter,
    @nospecialize(f), result::MethodCallResult, arginfo::ArgInfo)
    # disable all concrete-evaluation if this function call is tainted by some overlayed
    # method since currently there is no direct way to execute overlayed methods
    isoverlayed(method_table(interp)) && !is_nonoverlayed(result.effects) && return nothing
    if f !== nothing && result.edge !== nothing && is_foldable(result.effects)
        if is_all_const_arg(arginfo, #=start=#2)
            return true
        else
            # TODO: `is_nothrow` is not an actual requirement here, this is just a hack
            # to avoid entering semi concrete eval while it doesn't properly override effects
            return is_nothrow(result.effects) ? false : nothing
        end
    end
    return nothing
end

is_all_const_arg(arginfo::ArgInfo, start::Int) = is_all_const_arg(arginfo.argtypes, start::Int)
function is_all_const_arg(argtypes::Vector{Any}, start::Int)
    for i = start:length(argtypes)
        a = widenconditional(argtypes[i])
        isa(a, Const) || isconstType(a) || issingletontype(a) || return false
    end
    return true
end

collect_const_args(arginfo::ArgInfo, start::Int) = collect_const_args(arginfo.argtypes, start)
function collect_const_args(argtypes::Vector{Any}, start::Int)
    return Any[ let a = widenconditional(argtypes[i])
                    isa(a, Const) ? a.val :
                    isconstType(a) ? (a::DataType).parameters[1] :
                    (a::DataType).instance
                end for i = start:length(argtypes) ]
end

struct InvokeCall
    types     # ::Type
    lookupsig # ::Type
    InvokeCall(@nospecialize(types), @nospecialize(lookupsig)) = new(types, lookupsig)
end

function concrete_eval_call(interp::AbstractInterpreter,
    @nospecialize(f), result::MethodCallResult, arginfo::ArgInfo, si::StmtInfo,
    sv::InferenceState, invokecall::Union{Nothing,InvokeCall}=nothing)
    eligible = concrete_eval_eligible(interp, f, result, arginfo)
    eligible === nothing && return false
    if eligible
        args = collect_const_args(arginfo, #=start=#2)
        if invokecall !== nothing
            # this call should be `invoke`d, rewrite `args` back now
            pushfirst!(args, f, invokecall.types)
            f = invoke
        end
        world = get_world_counter(interp)
        edge = result.edge::MethodInstance
        value = try
            Core._call_in_world_total(world, f, args...)
        catch
            # The evaluation threw. By :consistent-cy, we're guaranteed this would have happened at runtime
            return ConstCallResults(Union{}, ConcreteResult(edge, result.effects), result.effects, edge)
        end
        return ConstCallResults(Const(value), ConcreteResult(edge, EFFECTS_TOTAL, value), EFFECTS_TOTAL, edge)
    else # eligible for semi-concrete evaluation
        return true
    end
end

has_conditional(argtypes::Vector{Any}) = any(@nospecialize(x)->isa(x, Conditional), argtypes)
has_conditional((; argtypes)::ArgInfo) = has_conditional(argtypes)

function const_prop_enabled(interp::AbstractInterpreter, sv::InferenceState, match::MethodMatch)
    if !InferenceParams(interp).ipo_constant_propagation
        add_remark!(interp, sv, "[constprop] Disabled by parameter")
        return false
    end
    if is_no_constprop(match.method)
        add_remark!(interp, sv, "[constprop] Disabled by method parameter")
        return false
    end
    return true
end

struct ConstCallResults
    rt::Any
    const_result::ConstResult
    effects::Effects
    edge::MethodInstance
    ConstCallResults(@nospecialize(rt),
                     const_result::ConstResult,
                     effects::Effects,
                     edge::MethodInstance) =
        new(rt, const_result, effects, edge)
end

struct ConditionalArgtypes <: ForwardableArgtypes
    arginfo::ArgInfo
    sv::InferenceState
end

"""
    matching_cache_argtypes(linfo::MethodInstance, argtypes::ConditionalArgtypes)

The implementation is able to forward `Conditional` of `argtypes`,
as well as the other general extended lattice inforamtion.
"""
function matching_cache_argtypes(linfo::MethodInstance, argtypes::ConditionalArgtypes)
    (; arginfo, sv) = argtypes
    (; fargs, argtypes) = arginfo
    given_argtypes = Vector{Any}(undef, length(argtypes))
    def = linfo.def::Method
    nargs = Int(def.nargs)
    cache_argtypes, overridden_by_const = matching_cache_argtypes(linfo)
    local condargs = nothing
    for i in 1:length(argtypes)
        argtype = argtypes[i]
        # forward `Conditional` if it conveys a constraint on any other argument
        if isa(argtype, Conditional) && fargs !== nothing
            cnd = argtype
            slotid = find_constrained_arg(cnd, fargs, sv)
            if slotid !== nothing
                # using union-split signature, we may be able to narrow down `Conditional`
                sigt = widenconst(slotid > nargs ? argtypes[slotid] : cache_argtypes[slotid])
                thentype = tmeet(cnd.thentype, sigt)
                elsetype = tmeet(cnd.elsetype, sigt)
                if thentype === Bottom && elsetype === Bottom
                    # we accidentally proved this method match is impossible
                    # TODO bail out here immediately rather than just propagating Bottom ?
                    given_argtypes[i] = Bottom
                else
                    if condargs === nothing
                        condargs = Tuple{Int,Int}[]
                    end
                    push!(condargs, (slotid, i))
                    given_argtypes[i] = Conditional(slotid, thentype, elsetype)
                end
                continue
            end
        end
        given_argtypes[i] = widenconditional(argtype)
    end
    if condargs !== nothing
        given_argtypes = let condargs=condargs
            va_process_argtypes(given_argtypes, linfo) do isva_given_argtypes::Vector{Any}, last::Int
                # invalidate `Conditional` imposed on varargs
                for (slotid, i) in condargs
                    if slotid ≥ last && (1 ≤ i ≤ length(isva_given_argtypes)) # `Conditional` is already widened to vararg-tuple otherwise
                        isva_given_argtypes[i] = widenconditional(isva_given_argtypes[i])
                    end
                end
            end
        end
    else
        given_argtypes = va_process_argtypes(given_argtypes, linfo)
    end
    return pick_const_args!(cache_argtypes, overridden_by_const, given_argtypes)
end

function abstract_call_method_with_const_args(interp::AbstractInterpreter,
    result::MethodCallResult, @nospecialize(f), arginfo::ArgInfo, si::StmtInfo, match::MethodMatch,
    sv::InferenceState, invokecall::Union{Nothing,InvokeCall}=nothing)
    if !const_prop_enabled(interp, sv, match)
        return nothing
    end
    if is_removable_if_unused(result.effects)
        if isa(result.rt, Const) || call_result_unused(si)
            add_remark!(interp, sv, "[constprop] No more information to be gained")
            return nothing
        end
    end
    res = concrete_eval_call(interp, f, result, arginfo, si, sv, invokecall)
    isa(res, ConstCallResults) && return res
    mi = maybe_get_const_prop_profitable(interp, result, f, arginfo, si, match, sv)
    mi === nothing && return nothing
    # try semi-concrete evaluation
    if res::Bool && !has_conditional(arginfo)
        mi_cache = WorldView(code_cache(interp), sv.world)
        code = get(mi_cache, mi, nothing)
        if code !== nothing
            ir = codeinst_to_ir(interp, code)
            if isa(ir, IRCode)
                irsv = IRInterpretationState(interp, ir, mi, sv.world, arginfo.argtypes)
                rt = ir_abstract_constant_propagation(interp, irsv)
                if !isa(rt, Type) || typeintersect(rt, Bool) === Union{}
                    return ConstCallResults(rt, SemiConcreteResult(mi, ir, result.effects), result.effects, mi)
                end
            end
        end
    end
    # try constant prop'
    inf_cache = get_inference_cache(interp)
    inf_result = cache_lookup(typeinf_lattice(interp), mi, arginfo.argtypes, inf_cache)
    if inf_result === nothing
        # if there might be a cycle, check to make sure we don't end up
        # calling ourselves here.
        if result.edgecycle && (result.edgelimited ?
            is_constprop_method_recursed(match.method, sv) :
            # if the type complexity limiting didn't decide to limit the call signature (`result.edgelimited = false`)
            # we can relax the cycle detection by comparing `MethodInstance`s and allow inference to
            # propagate different constant elements if the recursion is finite over the lattice
            is_constprop_edge_recursed(mi, sv))
            add_remark!(interp, sv, "[constprop] Edge cycle encountered")
            return nothing
        end
        inf_result = InferenceResult(mi, ConditionalArgtypes(arginfo, sv))
        if !any(inf_result.overridden_by_const)
            add_remark!(interp, sv, "[constprop] Could not handle constant info in matching_cache_argtypes")
            return nothing
        end
        frame = InferenceState(inf_result, #=cache=#:local, interp)
        if frame === nothing
            add_remark!(interp, sv, "[constprop] Could not retrieve the source")
            return nothing # this is probably a bad generated function (unsound), but just ignore it
        end
        frame.parent = sv
        if !typeinf(interp, frame)
            add_remark!(interp, sv, "[constprop] Fresh constant inference hit a cycle")
            return nothing
        end
        @assert !isa(inf_result.result, InferenceState)
    else
        if isa(inf_result.result, InferenceState)
            add_remark!(interp, sv, "[constprop] Found cached constant inference in a cycle")
            return nothing
        end
    end
    return ConstCallResults(inf_result.result, ConstPropResult(inf_result), inf_result.ipo_effects, mi)
end

# if there's a possibility we could get a better result with these constant arguments
# (hopefully without doing too much work), returns `MethodInstance`, or nothing otherwise
function maybe_get_const_prop_profitable(interp::AbstractInterpreter,
    result::MethodCallResult, @nospecialize(f), arginfo::ArgInfo, si::StmtInfo,
    match::MethodMatch, sv::InferenceState)
    method = match.method
    force = force_const_prop(interp, f, method)
    force || const_prop_entry_heuristic(interp, result, si, sv) || return nothing
    nargs::Int = method.nargs
    method.isva && (nargs -= 1)
    length(arginfo.argtypes) < nargs && return nothing
    if !const_prop_argument_heuristic(interp, arginfo, sv)
        add_remark!(interp, sv, "[constprop] Disabled by argument and rettype heuristics")
        return nothing
    end
    all_overridden = is_all_overridden(arginfo, sv)
    if !force && !const_prop_function_heuristic(interp, f, arginfo, nargs, all_overridden,
            is_nothrow(sv.ipo_effects), sv)
        add_remark!(interp, sv, "[constprop] Disabled by function heuristic")
        return nothing
    end
    force |= all_overridden
    mi = specialize_method(match; preexisting=!force)
    if mi === nothing
        add_remark!(interp, sv, "[constprop] Failed to specialize")
        return nothing
    end
    mi = mi::MethodInstance
    if !force && !const_prop_methodinstance_heuristic(interp, match, mi, arginfo, sv)
        add_remark!(interp, sv, "[constprop] Disabled by method instance heuristic")
        return nothing
    end
    return mi
end

function const_prop_entry_heuristic(interp::AbstractInterpreter, result::MethodCallResult, si::StmtInfo, sv::InferenceState)
    if call_result_unused(si) && result.edgecycle
        add_remark!(interp, sv, "[constprop] Disabled by entry heuristic (edgecycle with unused result)")
        return false
    end
    # check if this return type is improvable (i.e. whether it's possible that with more
    # information, we might get a more precise type)
    rt = result.rt
    if isa(rt, Type)
        # could always be improved to `Const`, `PartialStruct` or just a more precise type,
        # unless we're already at `Bottom`
        if rt === Bottom
            add_remark!(interp, sv, "[constprop] Disabled by entry heuristic (erroneous result)")
            return false
        else
            return true
        end
    elseif isa(rt, PartialStruct) || isa(rt, InterConditional)
        # could be improved to `Const` or a more precise wrapper
        return true
    elseif isa(rt, LimitedAccuracy)
        # optimizations like inlining are disabled for limited frames,
        # thus there won't be much benefit in constant-prop' here
        add_remark!(interp, sv, "[constprop] Disabled by entry heuristic (limited accuracy)")
        return false
    else
        if isa(rt, Const)
            if !is_nothrow(result.effects)
                # Could still be improved to Bottom (or at least could see the effects improved)
                return true
            end
        end
        add_remark!(interp, sv, "[constprop] Disabled by entry heuristic (unimprovable result)")
        return false
    end
end

# determines heuristically whether if constant propagation can be worthwhile
# by checking if any of given `argtypes` is "interesting" enough to be propagated
function const_prop_argument_heuristic(interp::AbstractInterpreter, (; fargs, argtypes)::ArgInfo, sv::InferenceState)
    for i in 1:length(argtypes)
        a = argtypes[i]
        if isa(a, Conditional) && fargs !== nothing
            is_const_prop_profitable_conditional(a, fargs, sv) && return true
        else
            a = widenconditional(a)
            has_nontrivial_const_info(typeinf_lattice(interp), a) && is_const_prop_profitable_arg(a) && return true
        end
    end
    return false
end

function is_const_prop_profitable_arg(@nospecialize(arg))
    # have new information from argtypes that wasn't available from the signature
    if isa(arg, PartialStruct)
        for b in arg.fields
            isconstType(b) && return true
            is_const_prop_profitable_arg(b) && return true
        end
    end
    isa(arg, PartialOpaque) && return true
    isa(arg, Const) || return true
    val = arg.val
    # don't consider mutable values useful constants
    return isa(val, Symbol) || isa(val, Type) || !ismutable(val)
end

function is_const_prop_profitable_conditional(cnd::Conditional, fargs::Vector{Any}, sv::InferenceState)
    slotid = find_constrained_arg(cnd, fargs, sv)
    if slotid !== nothing
        return true
    end
    # as a minor optimization, we just check the result is a constant or not,
    # since both `has_nontrivial_const_info`/`is_const_prop_profitable_arg` return `true`
    # for `Const(::Bool)`
    return isa(widenconditional(cnd), Const)
end

function find_constrained_arg(cnd::Conditional, fargs::Vector{Any}, sv::InferenceState)
    slot = cnd.slot
    for i in 1:length(fargs)
        arg = ssa_def_slot(fargs[i], sv)
        if isa(arg, SlotNumber) && slot_id(arg) == slot
            return i
        end
    end
    return nothing
end

# checks if all argtypes has additional information other than what `Type` can provide
function is_all_overridden((; fargs, argtypes)::ArgInfo, sv::InferenceState)
    for a in argtypes
        if isa(a, Conditional) && fargs !== nothing
            is_const_prop_profitable_conditional(a, fargs, sv) || return false
        else
            a = widenconditional(a)
            is_forwardable_argtype(a) || return false
        end
    end
    return true
end

function force_const_prop(interp::AbstractInterpreter, @nospecialize(f), method::Method)
    return is_aggressive_constprop(method) ||
           InferenceParams(interp).aggressive_constant_propagation ||
           istopfunction(f, :getproperty) ||
           istopfunction(f, :setproperty!)
end

function const_prop_function_heuristic(
    interp::AbstractInterpreter, @nospecialize(f), (; argtypes)::ArgInfo,
    nargs::Int, all_overridden::Bool, still_nothrow::Bool, _::InferenceState)
    ⊑ᵢ = ⊑(typeinf_lattice(interp))
    if nargs > 1
        if istopfunction(f, :getindex) || istopfunction(f, :setindex!)
            arrty = argtypes[2]
            # don't propagate constant index into indexing of non-constant array
            if arrty isa Type && arrty <: AbstractArray && !issingletontype(arrty)
                # For static arrays, allow the constprop if we could possibly
                # deduce nothrow as a result.
                if !still_nothrow || ismutabletype(arrty)
                    return false
                end
            elseif arrty ⊑ᵢ Array
                return false
            end
        elseif istopfunction(f, :iterate)
            itrty = argtypes[2]
            if itrty ⊑ᵢ Array
                return false
            end
        end
    end
    if !all_overridden && (istopfunction(f, :+) || istopfunction(f, :-) || istopfunction(f, :*) ||
                           istopfunction(f, :(==)) || istopfunction(f, :!=) ||
                           istopfunction(f, :<=) || istopfunction(f, :>=) || istopfunction(f, :<) || istopfunction(f, :>) ||
                           istopfunction(f, :<<) || istopfunction(f, :>>))
        # it is almost useless to inline the op when all the same type,
        # but highly worthwhile to inline promote of a constant
        length(argtypes) > 2 || return false
        t1 = widenconst(argtypes[2])
        for i in 3:length(argtypes)
            at = argtypes[i]
            ty = isvarargtype(at) ? unwraptv(at) : widenconst(at)
            if ty !== t1
                return true
            end
        end
        return false
    end
    return true
end

# This is a heuristic to avoid trying to const prop through complicated functions
# where we would spend a lot of time, but are probably unlikely to get an improved
# result anyway.
function const_prop_methodinstance_heuristic(interp::AbstractInterpreter,
    match::MethodMatch, mi::MethodInstance, arginfo::ArgInfo, sv::InferenceState)
    method = match.method
    if method.is_for_opaque_closure
        # Not inlining an opaque closure can be very expensive, so be generous
        # with the const-prop-ability. It is quite possible that we can't infer
        # anything at all without const-propping, so the inlining check below
        # isn't particularly helpful here.
        return true
    end
    # Peek at the inferred result for the function to determine if the optimizer
    # was able to cut it down to something simple (inlineable in particular).
    # If so, there's a good chance we might be able to const prop all the way
    # through and learn something new.
    if isdefined(method, :source) && is_inlineable(method.source)
        return true
    else
        flag = get_curr_ssaflag(sv)
        if is_stmt_inline(flag)
            # force constant propagation for a call that is going to be inlined
            # since the inliner will try to find this constant result
            # if these constant arguments arrive there
            return true
        elseif is_stmt_noinline(flag)
            # this call won't be inlined, thus this constant-prop' will most likely be unfruitful
            return false
        else
            code = get(code_cache(interp), mi, nothing)
            if isdefined(code, :inferred)
                if isa(code, CodeInstance)
                    inferred = @atomic :monotonic code.inferred
                else
                    inferred = code.inferred
                end
                # TODO propagate a specific `CallInfo` that conveys information about this call
                if inlining_policy(interp, inferred, NoCallInfo(), IR_FLAG_NULL, mi, arginfo.argtypes) !== nothing
                    return true
                end
            end
        end
    end
    return false # the cache isn't inlineable, so this constant-prop' will most likely be unfruitful
end

# This is only for use with `Conditional`.
# In general, usage of this is wrong.
ssa_def_slot(@nospecialize(arg), sv::IRCode) = nothing
function ssa_def_slot(@nospecialize(arg), sv::InferenceState)
    code = sv.src.code
    init = sv.currpc
    while isa(arg, SSAValue)
        init = arg.id
        arg = code[init]
    end
    if arg isa SlotNumber
        # found this kind of pattern:
        # %init = SlotNumber(x)
        # [...]
        # goto if not isa(%init, T)
        # now conservatively make sure there isn't potentially another conflicting assignment
        # to the same slot between the def and usage
        # we can assume the IR is sorted, since the front-end only creates SSA values in order
        for i = init:(sv.currpc-1)
            e = code[i]
            if isexpr(e, :(=)) && e.args[1] === arg
                return nothing
            end
        end
    else
        # there might still be the following kind of pattern (see #45499):
        # %init = ...
        # [...]
        # SlotNumber(x) = %init
        # [...]
        # goto if not isa(%init, T)
        # let's check if there is a slot assigned to the def SSA value but also there isn't
        # any potentially conflicting assignment to the same slot
        arg = nothing
        def = SSAValue(init)
        for i = (init+1):(sv.currpc-1)
            e = code[i]
            if isexpr(e, :(=))
                lhs = e.args[1]
                if isa(lhs, SlotNumber)
                    lhs === arg && return nothing
                    rhs = e.args[2]
                    if rhs === def
                        arg = lhs
                    end
                end
            end
        end
    end
    return arg
end

# `typ` is the inferred type for expression `arg`.
# if the expression constructs a container (e.g. `svec(x,y,z)`),
# refine its type to an array of element types.
# Union of Tuples of the same length is converted to Tuple of Unions.
# returns an array of types
function precise_container_type(interp::AbstractInterpreter, @nospecialize(itft), @nospecialize(typ),
                                sv::Union{InferenceState, IRCode})
    if isa(typ, PartialStruct) && typ.typ.name === Tuple.name
        return typ.fields, nothing
    end

    if isa(typ, Const)
        val = typ.val
        if isa(val, SimpleVector) || isa(val, Tuple)
            return Any[ Const(val[i]) for i in 1:length(val) ], nothing # avoid making a tuple Generator here!
        end
    end

    tti0 = widenconst(typ)
    tti = unwrap_unionall(tti0)
    if isa(tti, DataType) && tti.name === _NAMEDTUPLE_NAME
        # A NamedTuple iteration is the same as the iteration of its Tuple parameter:
        # compute a new `tti == unwrap_unionall(tti0)` based on that Tuple type
        tti = unwraptv(tti.parameters[2])
        tti0 = rewrap_unionall(tti, tti0)
    end
    if isa(tti, Union)
        utis = uniontypes(tti)
        if any(@nospecialize(t) -> !isa(t, DataType) || !(t <: Tuple) || !isknownlength(t), utis)
            return Any[Vararg{Any}], nothing
        end
        ltp = length((utis[1]::DataType).parameters)
        for t in utis
            if length((t::DataType).parameters) != ltp
                return Any[Vararg{Any}], nothing
            end
        end
        result = Any[ Union{} for _ in 1:ltp ]
        for t in utis
            tps = (t::DataType).parameters
            _all(valid_as_lattice, tps) || continue
            for j in 1:ltp
                result[j] = tmerge(result[j], rewrap_unionall(tps[j], tti0))
            end
        end
        return result, nothing
    elseif tti0 <: Tuple
        if isa(tti0, DataType)
            return Any[ p for p in tti0.parameters ], nothing
        elseif !isa(tti, DataType)
            return Any[Vararg{Any}], nothing
        else
            len = length(tti.parameters)
            last = tti.parameters[len]
            va = isvarargtype(last)
            elts = Any[ fieldtype(tti0, i) for i = 1:len ]
            if va
                elts[len] = Vararg{elts[len]}
            end
            return elts, nothing
        end
    elseif tti0 === SimpleVector || tti0 === Any
        return Any[Vararg{Any}], nothing
    elseif tti0 <: Array
        return Any[Vararg{eltype(tti0)}], nothing
    else
        return abstract_iteration(interp, itft, typ, sv)
    end
end

# simulate iteration protocol on container type up to fixpoint
function abstract_iteration(interp::AbstractInterpreter, @nospecialize(itft), @nospecialize(itertype), sv::Union{InferenceState, IRCode})
    if isa(itft, Const)
        iteratef = itft.val
    else
        return Any[Vararg{Any}], nothing
    end
    @assert !isvarargtype(itertype)
    call = abstract_call_known(interp, iteratef, ArgInfo(nothing, Any[itft, itertype]), StmtInfo(true), sv)
    stateordonet = call.rt
    info = call.info
    # Return Bottom if this is not an iterator.
    # WARNING: Changes to the iteration protocol must be reflected here,
    # this is not just an optimization.
    # TODO: this doesn't realize that Array, SimpleVector, Tuple, and NamedTuple do not use the iterate protocol
    stateordonet === Bottom && return Any[Bottom], AbstractIterationInfo(CallMeta[CallMeta(Bottom, call.effects, info)])
    valtype = statetype = Bottom
    ret = Any[]
    calls = CallMeta[call]
    stateordonet_widened = widenconst(stateordonet)

    # Try to unroll the iteration up to MAX_TUPLE_SPLAT, which covers any finite
    # length iterators, or interesting prefix
    while true
        if stateordonet_widened === Nothing
            return ret, AbstractIterationInfo(calls)
        end
        if Nothing <: stateordonet_widened || length(ret) >= InferenceParams(interp).MAX_TUPLE_SPLAT
            break
        end
        if !isa(stateordonet_widened, DataType) || !(stateordonet_widened <: Tuple) || isvatuple(stateordonet_widened) || length(stateordonet_widened.parameters) != 2
            break
        end
        nstatetype = getfield_tfunc(typeinf_lattice(interp), stateordonet, Const(2))
        # If there's no new information in this statetype, don't bother continuing,
        # the iterator won't be finite.
        if ⊑(typeinf_lattice(interp), nstatetype, statetype)
            return Any[Bottom], nothing
        end
        valtype = getfield_tfunc(typeinf_lattice(interp), stateordonet, Const(1))
        push!(ret, valtype)
        statetype = nstatetype
        call = abstract_call_known(interp, iteratef, ArgInfo(nothing, Any[Const(iteratef), itertype, statetype]), StmtInfo(true), sv)
        stateordonet = call.rt
        stateordonet_widened = widenconst(stateordonet)
        push!(calls, call)
    end
    # From here on, we start asking for results on the widened types, rather than
    # the precise (potentially const) state type
    # statetype and valtype are reinitialized in the first iteration below from the
    # (widened) stateordonet, which has not yet been fully analyzed in the loop above
    statetype = Bottom
    valtype = Bottom
    may_have_terminated = Nothing <: stateordonet_widened
    while valtype !== Any
        nounion = typeintersect(stateordonet_widened, Tuple{Any,Any})
        if nounion !== Union{} && !isa(nounion, DataType)
            # nounion is of a type we cannot handle
            valtype = Any
            break
        end
        if nounion === Union{} || (nounion.parameters[1] <: valtype && nounion.parameters[2] <: statetype)
            # reached a fixpoint or iterator failed/gave invalid answer
            if !hasintersect(stateordonet_widened, Nothing)
                # ... but cannot terminate
                if !may_have_terminated
                    #  ... and cannot have terminated prior to this loop
                    return Any[Bottom], nothing
                else
                    # iterator may have terminated prior to this loop, but not during it
                    valtype = Bottom
                end
            end
            break
        end
        valtype = tmerge(valtype, nounion.parameters[1])
        statetype = tmerge(statetype, nounion.parameters[2])
        stateordonet = abstract_call_known(interp, iteratef, ArgInfo(nothing, Any[Const(iteratef), itertype, statetype]), StmtInfo(true), sv).rt
        stateordonet_widened = widenconst(stateordonet)
    end
    if valtype !== Union{}
        push!(ret, Vararg{valtype})
    end
    return ret, nothing
end

# do apply(af, fargs...), where af is a function value
function abstract_apply(interp::AbstractInterpreter, argtypes::Vector{Any}, si::StmtInfo,
                        sv::Union{InferenceState, IRCode},
                        max_methods::Int = get_max_methods(sv.mod, interp))
    itft = argtype_by_index(argtypes, 2)
    aft = argtype_by_index(argtypes, 3)
    (itft === Bottom || aft === Bottom) && return CallMeta(Bottom, EFFECTS_THROWS, NoCallInfo())
    aargtypes = argtype_tail(argtypes, 4)
    aftw = widenconst(aft)
    if !isa(aft, Const) && !isa(aft, PartialOpaque) && (!isType(aftw) || has_free_typevars(aftw))
        if !isconcretetype(aftw) || (aftw <: Builtin)
            add_remark!(interp, sv, "Core._apply_iterate called on a function of a non-concrete type")
            # bail now, since it seems unlikely that abstract_call will be able to do any better after splitting
            # this also ensures we don't call abstract_call_gf_by_type below on an IntrinsicFunction or Builtin
            return CallMeta(Any, Effects(), NoCallInfo())
        end
    end
    res = Union{}
    nargs = length(aargtypes)
    splitunions = 1 < unionsplitcost(aargtypes) <= InferenceParams(interp).MAX_APPLY_UNION_ENUM
    ctypes = [Any[aft]]
    infos = Vector{MaybeAbstractIterationInfo}[MaybeAbstractIterationInfo[]]
    effects = EFFECTS_TOTAL
    for i = 1:nargs
        ctypes´ = Vector{Any}[]
        infos′ = Vector{MaybeAbstractIterationInfo}[]
        for ti in (splitunions ? uniontypes(aargtypes[i]) : Any[aargtypes[i]])
            if !isvarargtype(ti)
                cti_info = precise_container_type(interp, itft, ti, sv)
                cti = cti_info[1]::Vector{Any}
                info = cti_info[2]::MaybeAbstractIterationInfo
            else
                cti_info = precise_container_type(interp, itft, unwrapva(ti), sv)
                cti = cti_info[1]::Vector{Any}
                info = cti_info[2]::MaybeAbstractIterationInfo
                # We can't represent a repeating sequence of the same types,
                # so tmerge everything together to get one type that represents
                # everything.
                argt = cti[end]
                if isvarargtype(argt)
                    argt = unwrapva(argt)
                end
                for i in 1:(length(cti)-1)
                    argt = tmerge(argt, cti[i])
                end
                cti = Any[Vararg{argt}]
            end
            if any(@nospecialize(t) -> t === Bottom, cti)
                continue
            end
            for j = 1:length(ctypes)
                ct = ctypes[j]::Vector{Any}
                if isvarargtype(ct[end])
                    # This is vararg, we're not gonna be able to do any inlining,
                    # drop the info
                    info = nothing
                    tail = tuple_tail_elem(unwrapva(ct[end]), cti)
                    push!(ctypes´, push!(ct[1:(end - 1)], tail))
                else
                    push!(ctypes´, append!(ct[:], cti))
                end
                push!(infos′, push!(copy(infos[j]), info))
            end
        end
        ctypes = ctypes´
        infos = infos′
    end
    retinfos = ApplyCallInfo[]
    retinfo = UnionSplitApplyCallInfo(retinfos)
    for i = 1:length(ctypes)
        ct = ctypes[i]
        arginfo = infos[i]
        lct = length(ct)
        # truncate argument list at the first Vararg
        for i = 1:lct-1
            cti = ct[i]
            if isvarargtype(cti)
                ct[i] = tuple_tail_elem(unwrapva(cti), ct[(i+1):lct])
                resize!(ct, i)
                break
            end
        end
        call = abstract_call(interp, ArgInfo(nothing, ct), si, sv, max_methods)
        push!(retinfos, ApplyCallInfo(call.info, arginfo))
        res = tmerge(res, call.rt)
        effects = merge_effects(effects, call.effects)
        if bail_out_apply(interp, res, sv)
            if i != length(ctypes)
                # No point carrying forward the info, we're not gonna inline it anyway
                retinfo = NoCallInfo()
            end
            break
        end
    end
    # TODO: Add a special info type to capture all the iteration info.
    # For now, only propagate info if we don't also union-split the iteration
    return CallMeta(res, effects, retinfo)
end

function argtype_by_index(argtypes::Vector{Any}, i::Int)
    n = length(argtypes)
    na = argtypes[n]
    if isvarargtype(na)
        return i >= n ? unwrapva(na) : argtypes[i]
    else
        return i > n ? Bottom : argtypes[i]
    end
end

function argtype_tail(argtypes::Vector{Any}, i::Int)
    n = length(argtypes)
    if isvarargtype(argtypes[n]) && i > n
        i = n
    end
    return argtypes[i:n]
end

function abstract_call_builtin(interp::AbstractInterpreter, f::Builtin, (; fargs, argtypes)::ArgInfo,
                               sv::Union{InferenceState, IRCode}, max_methods::Int)
    @nospecialize f
    la = length(argtypes)
    lattice = typeinf_lattice(interp)
    ⊑ᵢ = ⊑(lattice)
    if f === Core.ifelse && fargs isa Vector{Any} && la == 4
        cnd = argtypes[2]
        if isa(cnd, Conditional)
            newcnd = widenconditional(cnd)
            tx = argtypes[3]
            ty = argtypes[4]
            if isa(newcnd, Const)
                # if `cnd` is constant, we should just respect its constantness to keep inference accuracy
                return newcnd.val::Bool ? tx : ty
            else
                # try to simulate this as a real conditional (`cnd ? x : y`), so that the penalty for using `ifelse` instead isn't too high
                a = ssa_def_slot(fargs[3], sv)
                b = ssa_def_slot(fargs[4], sv)
                if isa(a, SlotNumber) && cnd.slot == slot_id(a)
                    tx = (cnd.thentype ⊑ᵢ tx ? cnd.thentype : tmeet(lattice, tx, widenconst(cnd.thentype)))
                end
                if isa(b, SlotNumber) && cnd.slot == slot_id(b)
                    ty = (cnd.elsetype ⊑ᵢ ty ? cnd.elsetype : tmeet(lattice, ty, widenconst(cnd.elsetype)))
                end
                return tmerge(lattice, tx, ty)
            end
        end
    end
    rt = builtin_tfunction(interp, f, argtypes[2:end], sv)
    if (rt === Bool || (isa(rt, Const) && isa(rt.val, Bool))) && isa(fargs, Vector{Any})
        # perform very limited back-propagation of type information for `is` and `isa`
        if f === isa
            a = ssa_def_slot(fargs[2], sv)
            if isa(a, SlotNumber)
                aty = widenconst(argtypes[2])
                if rt === Const(false)
                    return Conditional(a, Union{}, aty)
                elseif rt === Const(true)
                    return Conditional(a, aty, Union{})
                end
                tty_ub, isexact_tty = instanceof_tfunc(argtypes[3])
                if isexact_tty && !isa(tty_ub, TypeVar)
                    tty_lb = tty_ub # TODO: this would be wrong if !isexact_tty, but instanceof_tfunc doesn't preserve this info
                    if !has_free_typevars(tty_lb) && !has_free_typevars(tty_ub)
                        ifty = typeintersect(aty, tty_ub)
                        if iskindtype(tty_ub) && ifty !== Bottom
                            # `typeintersect` may be unable narrow down `Type`-type
                            ifty = tty_ub
                        end
                        valid_as_lattice(ifty) || (ifty = Union{})
                        elty = typesubtract(aty, tty_lb, InferenceParams(interp).MAX_UNION_SPLITTING)
                        return Conditional(a, ifty, elty)
                    end
                end
            end
        elseif f === (===)
            a = ssa_def_slot(fargs[2], sv)
            b = ssa_def_slot(fargs[3], sv)
            aty = argtypes[2]
            bty = argtypes[3]
            # if doing a comparison to a singleton, consider returning a `Conditional` instead
            if isa(aty, Const) && isa(b, SlotNumber)
                if rt === Const(false)
                    aty = Union{}
                    bty = widenconditional(bty)
                elseif rt === Const(true)
                    bty = Union{}
                elseif bty isa Type && isdefined(typeof(aty.val), :instance) # can only widen a if it is a singleton
                    bty = typesubtract(bty, typeof(aty.val), InferenceParams(interp).MAX_UNION_SPLITTING)
                else
                    bty = widenconditional(bty)
                end
                return Conditional(b, aty, bty)
            end
            if isa(bty, Const) && isa(a, SlotNumber)
                if rt === Const(false)
                    bty = Union{}
                    aty = widenconditional(aty)
                elseif rt === Const(true)
                    aty = Union{}
                elseif aty isa Type && isdefined(typeof(bty.val), :instance) # same for b
                    aty = typesubtract(aty, typeof(bty.val), InferenceParams(interp).MAX_UNION_SPLITTING)
                else
                    aty = widenconditional(aty)
                end
                return Conditional(a, bty, aty)
            end
            # narrow the lattice slightly (noting the dependency on one of the slots), to promote more effective smerge
            if isa(b, SlotNumber)
                return Conditional(b, rt === Const(false) ? Union{} : bty, rt === Const(true) ? Union{} : bty)
            end
            if isa(a, SlotNumber)
                return Conditional(a, rt === Const(false) ? Union{} : aty, rt === Const(true) ? Union{} : aty)
            end
        elseif f === Core.Compiler.not_int
            aty = argtypes[2]
            if isa(aty, Conditional)
                ifty = aty.elsetype
                elty = aty.thentype
                if rt === Const(false)
                    ifty = Union{}
                elseif rt === Const(true)
                    elty = Union{}
                end
                return Conditional(aty.slot, ifty, elty)
            end
        elseif f === isdefined
            uty = argtypes[2]
            a = ssa_def_slot(fargs[2], sv)
            if isa(uty, Union) && isa(a, SlotNumber)
                fld = argtypes[3]
                thentype = Bottom
                elsetype = Bottom
                for ty in uniontypes(uty)
                    cnd = isdefined_tfunc(ty, fld)
                    if isa(cnd, Const)
                        if cnd.val::Bool
                            thentype = tmerge(thentype, ty)
                        else
                            elsetype = tmerge(elsetype, ty)
                        end
                    else
                        thentype = tmerge(thentype, ty)
                        elsetype = tmerge(elsetype, ty)
                    end
                end
                return Conditional(a, thentype, elsetype)
            end
        end
    end
    @assert !isa(rt, TypeVar) "unhandled TypeVar"
    return rt
end

function abstract_call_unionall(argtypes::Vector{Any})
    if length(argtypes) == 3
        canconst = true
        a3 = argtypes[3]
        if isa(a3, Const)
            body = a3.val
        elseif isType(a3)
            body = a3.parameters[1]
            canconst = false
        else
            return Any
        end
        if !isa(body, Type) && !isa(body, TypeVar)
            return Any
        end
        if has_free_typevars(body)
            a2 = argtypes[2]
            if isa(a2, Const)
                tv = a2.val
            elseif isa(a2, PartialTypeVar)
                tv = a2.tv
                canconst = false
            else
                return Any
            end
            !isa(tv, TypeVar) && return Any
            body = UnionAll(tv, body)
        end
        ret = canconst ? Const(body) : Type{body}
        return ret
    end
    return Any
end

function abstract_invoke(interp::AbstractInterpreter, (; fargs, argtypes)::ArgInfo, si::StmtInfo, sv::InferenceState)
    ft′ = argtype_by_index(argtypes, 2)
    ft = widenconst(ft′)
    ft === Bottom && return CallMeta(Bottom, EFFECTS_THROWS, NoCallInfo())
    (types, isexact, isconcrete, istype) = instanceof_tfunc(argtype_by_index(argtypes, 3))
    isexact || return CallMeta(Any, Effects(), NoCallInfo())
    unwrapped = unwrap_unionall(types)
    if types === Bottom || types === Any || !(unwrapped isa DataType)
        return CallMeta(Bottom, EFFECTS_THROWS, NoCallInfo())
    end
    argtype = argtypes_to_type(argtype_tail(argtypes, 4))
    nargtype = typeintersect(types, argtype)
    nargtype === Bottom && return CallMeta(Bottom, EFFECTS_THROWS, NoCallInfo())
    nargtype isa DataType || return CallMeta(Any, Effects(), NoCallInfo()) # other cases are not implemented below
    isdispatchelem(ft) || return CallMeta(Any, Effects(), NoCallInfo()) # check that we might not have a subtype of `ft` at runtime, before doing supertype lookup below
    ft = ft::DataType
    lookupsig = rewrap_unionall(Tuple{ft, unwrapped.parameters...}, types)::Type
    nargtype = Tuple{ft, nargtype.parameters...}
    argtype = Tuple{ft, argtype.parameters...}
    match, valid_worlds, overlayed = findsup(lookupsig, method_table(interp))
    match === nothing && return CallMeta(Any, Effects(), NoCallInfo())
    update_valid_age!(sv, valid_worlds)
    method = match.method
    tienv = ccall(:jl_type_intersection_with_env, Any, (Any, Any), nargtype, method.sig)::SimpleVector
    ti = tienv[1]; env = tienv[2]::SimpleVector
    result = abstract_call_method(interp, method, ti, env, false, si, sv)
    (; rt, edge, effects) = result
    match = MethodMatch(ti, env, method, argtype <: method.sig)
    res = nothing
    sig = match.spec_types
    argtypes′ = invoke_rewrite(argtypes)
    fargs′ = fargs === nothing ? nothing : invoke_rewrite(fargs)
    arginfo = ArgInfo(fargs′, argtypes′)
    # # typeintersect might have narrowed signature, but the accuracy gain doesn't seem worth the cost involved with the lattice comparisons
    # for i in 1:length(argtypes′)
    #     t, a = ti.parameters[i], argtypes′[i]
    #     argtypes′[i] = t ⊑ a ? t : a
    # end
    𝕃ₚ = ipo_lattice(interp)
    f = overlayed ? nothing : singleton_type(ft′)
    invokecall = InvokeCall(types, lookupsig)
    const_call_result = abstract_call_method_with_const_args(interp,
        result, f, arginfo, si, match, sv, invokecall)
    const_result = nothing
    if const_call_result !== nothing
        if ⊑(𝕃ₚ, const_call_result.rt, rt)
            (; rt, effects, const_result, edge) = const_call_result
        end
    end
    rt = from_interprocedural!(𝕃ₚ, rt, sv, arginfo, sig)
    effects = Effects(effects; nonoverlayed=!overlayed)
    info = InvokeCallInfo(match, const_result)
    edge !== nothing && add_invoke_backedge!(sv, lookupsig, edge)
    return CallMeta(rt, effects, info)
end

function invoke_rewrite(xs::Vector{Any})
    x0 = xs[2]
    newxs = xs[3:end]
    newxs[1] = x0
    return newxs
end

function abstract_finalizer(interp::AbstractInterpreter, argtypes::Vector{Any}, sv::InferenceState)
    if length(argtypes) == 3
        finalizer_argvec = Any[argtypes[2], argtypes[3]]
        call = abstract_call(interp, ArgInfo(nothing, finalizer_argvec), StmtInfo(false), sv, 1)
        return CallMeta(Nothing, Effects(), FinalizerInfo(call.info, call.effects))
    end
    return CallMeta(Nothing, Effects(), NoCallInfo())
end

# call where the function is known exactly
function abstract_call_known(interp::AbstractInterpreter, @nospecialize(f),
        arginfo::ArgInfo, si::StmtInfo, sv::Union{InferenceState, IRCode},
        max_methods::Int = isa(sv, InferenceState) ? get_max_methods(f, sv.mod, interp) : 0)
    (; fargs, argtypes) = arginfo
    la = length(argtypes)

    if isa(f, Builtin)
        if f === _apply_iterate
            return abstract_apply(interp, argtypes, si, sv, max_methods)
        elseif f === invoke
            return abstract_invoke(interp, arginfo, si, sv)
        elseif f === modifyfield!
            return abstract_modifyfield!(interp, argtypes, si, sv)
        elseif f === Core.finalizer
            return abstract_finalizer(interp, argtypes, sv)
        end
        rt = abstract_call_builtin(interp, f, arginfo, sv, max_methods)
        effects = builtin_effects(typeinf_lattice(interp), f, argtypes[2:end], rt)
        return CallMeta(rt, effects, NoCallInfo())
    elseif isa(f, Core.OpaqueClosure)
        # calling an OpaqueClosure about which we have no information returns no information
        return CallMeta(Any, Effects(), NoCallInfo())
    elseif f === TypeVar
        # Manually look through the definition of TypeVar to
        # make sure to be able to get `PartialTypeVar`s out.
        (la < 2 || la > 4) && return CallMeta(Union{}, EFFECTS_UNKNOWN, NoCallInfo())
        n = argtypes[2]
        ub_var = Const(Any)
        lb_var = Const(Union{})
        if la == 4
            ub_var = argtypes[4]
            lb_var = argtypes[3]
        elseif la == 3
            ub_var = argtypes[3]
        end
        return CallMeta(typevar_tfunc(n, lb_var, ub_var), EFFECTS_UNKNOWN, NoCallInfo())
    elseif f === UnionAll
        return CallMeta(abstract_call_unionall(argtypes), EFFECTS_UNKNOWN, NoCallInfo())
    elseif f === Tuple && la == 2
        aty = argtypes[2]
        ty = isvarargtype(aty) ? unwrapva(aty) : widenconst(aty)
        if !isconcretetype(ty)
            return CallMeta(Tuple, EFFECTS_UNKNOWN, NoCallInfo())
        end
    elseif is_return_type(f)
        return return_type_tfunc(interp, argtypes, si, sv)
    elseif la == 2 && istopfunction(f, :!)
        # handle Conditional propagation through !Bool
        aty = argtypes[2]
        if isa(aty, Conditional)
            call = abstract_call_gf_by_type(interp, f, ArgInfo(fargs, Any[Const(f), Bool]), si, Tuple{typeof(f), Bool}, sv, max_methods) # make sure we've inferred `!(::Bool)`
            return CallMeta(Conditional(aty.slot, aty.elsetype, aty.thentype), call.effects, call.info)
        end
    elseif la == 3 && istopfunction(f, :!==)
        # mark !== as exactly a negated call to ===
        rty = abstract_call_known(interp, (===), arginfo, si, sv, max_methods).rt
        if isa(rty, Conditional)
            return CallMeta(Conditional(rty.slot, rty.elsetype, rty.thentype), EFFECTS_TOTAL, NoCallInfo()) # swap if-else
        elseif isa(rty, Const)
            return CallMeta(Const(rty.val === false), EFFECTS_TOTAL, MethodResultPure())
        end
        return CallMeta(rty, EFFECTS_TOTAL, NoCallInfo())
    elseif la == 3 && istopfunction(f, :(>:))
        # mark issupertype as a exact alias for issubtype
        # swap T1 and T2 arguments and call <:
        if fargs !== nothing && length(fargs) == 3
            fargs = Any[<:, fargs[3], fargs[2]]
        else
            fargs = nothing
        end
        argtypes = Any[typeof(<:), argtypes[3], argtypes[2]]
        return CallMeta(abstract_call_known(interp, <:, ArgInfo(fargs, argtypes), si, sv, max_methods).rt, EFFECTS_TOTAL, NoCallInfo())
    elseif la == 2 &&
           (a2 = argtypes[2]; isa(a2, Const)) && (svecval = a2.val; isa(svecval, SimpleVector)) &&
           istopfunction(f, :length)
        # mark length(::SimpleVector) as @pure
        return CallMeta(Const(length(svecval)), EFFECTS_TOTAL, MethodResultPure())
    elseif la == 3 &&
           (a2 = argtypes[2]; isa(a2, Const)) && (svecval = a2.val; isa(svecval, SimpleVector)) &&
           (a3 = argtypes[3]; isa(a3, Const)) && (idx = a3.val; isa(idx, Int)) &&
           istopfunction(f, :getindex)
        # mark getindex(::SimpleVector, i::Int) as @pure
        if 1 <= idx <= length(svecval) && isassigned(svecval, idx)
            return CallMeta(Const(getindex(svecval, idx)), EFFECTS_TOTAL, MethodResultPure())
        end
    elseif la == 2 && istopfunction(f, :typename)
        return CallMeta(typename_static(argtypes[2]), EFFECTS_TOTAL, MethodResultPure())
    elseif la == 3 && istopfunction(f, :typejoin)
        if is_all_const_arg(arginfo, #=start=#2)
            val = _pure_eval_call(f, arginfo)
            return CallMeta(val === nothing ? Type : val, EFFECTS_TOTAL, MethodResultPure())
        end
    end
    atype = argtypes_to_type(argtypes)
    return abstract_call_gf_by_type(interp, f, arginfo, si, atype, sv, max_methods)
end

function abstract_call_opaque_closure(interp::AbstractInterpreter,
    closure::PartialOpaque, arginfo::ArgInfo, si::StmtInfo, sv::InferenceState, check::Bool=true)
    sig = argtypes_to_type(arginfo.argtypes)
    result = abstract_call_method(interp, closure.source, sig, Core.svec(), false, si, sv)
    (; rt, edge, effects) = result
    tt = closure.typ
    sigT = (unwrap_unionall(tt)::DataType).parameters[1]
    match = MethodMatch(sig, Core.svec(), closure.source, sig <: rewrap_unionall(sigT, tt))
    𝕃ₚ = ipo_lattice(interp)
    ⊑ₚ = ⊑(𝕃ₚ)
    const_result = nothing
    if !result.edgecycle
        const_call_result = abstract_call_method_with_const_args(interp, result,
            nothing, arginfo, si, match, sv)
        if const_call_result !== nothing
            if const_call_result.rt ⊑ₚ rt
                (; rt, effects, const_result, edge) = const_call_result
            end
        end
    end
    if check # analyze implicit type asserts on argument and return type
        ftt = closure.typ
        (aty, rty) = (unwrap_unionall(ftt)::DataType).parameters
        rty = rewrap_unionall(rty isa TypeVar ? rty.lb : rty, ftt)
        if !(rt ⊑ₚ rty && tuple_tfunc(𝕃ₚ, arginfo.argtypes[2:end]) ⊑ₚ rewrap_unionall(aty, ftt))
            effects = Effects(effects; nothrow=false)
        end
    end
    rt = from_interprocedural!(𝕃ₚ, rt, sv, arginfo, match.spec_types)
    info = OpaqueClosureCallInfo(match, const_result)
    edge !== nothing && add_backedge!(sv, edge)
    return CallMeta(rt, effects, info)
end

function most_general_argtypes(closure::PartialOpaque)
    ret = Any[]
    cc = widenconst(closure)
    argt = (unwrap_unionall(cc)::DataType).parameters[1]
    if !isa(argt, DataType) || argt.name !== typename(Tuple)
        argt = Tuple
    end
    return most_general_argtypes(closure.source, argt, false)
end

# call where the function is any lattice element
function abstract_call(interp::AbstractInterpreter, arginfo::ArgInfo, si::StmtInfo,
                       sv::Union{InferenceState, IRCode}, max_methods::Union{Int, Nothing} = isa(sv, IRCode) ? 0 : nothing)
    argtypes = arginfo.argtypes
    ft = argtypes[1]
    f = singleton_type(ft)
    if isa(ft, PartialOpaque)
        newargtypes = copy(argtypes)
        newargtypes[1] = ft.env
        return abstract_call_opaque_closure(interp,
            ft, ArgInfo(arginfo.fargs, newargtypes), si, sv, #=check=#true)
    elseif (uft = unwrap_unionall(widenconst(ft)); isa(uft, DataType) && uft.name === typename(Core.OpaqueClosure))
        return CallMeta(rewrap_unionall((uft::DataType).parameters[2], widenconst(ft)), Effects(), NoCallInfo())
    elseif f === nothing
        # non-constant function, but the number of arguments is known
        # and the ft is not a Builtin or IntrinsicFunction
        if hasintersect(widenconst(ft), Union{Builtin, Core.OpaqueClosure})
            add_remark!(interp, sv, "Could not identify method table for call")
            return CallMeta(Any, Effects(), NoCallInfo())
        end
        max_methods = max_methods === nothing ? get_max_methods(sv.mod, interp) : max_methods
        return abstract_call_gf_by_type(interp, nothing, arginfo, si, argtypes_to_type(argtypes), sv, max_methods)
    end
    max_methods = max_methods === nothing ? get_max_methods(f, sv.mod, interp) : max_methods
    return abstract_call_known(interp, f, arginfo, si, sv, max_methods)
end

function sp_type_rewrap(@nospecialize(T), linfo::MethodInstance, isreturn::Bool)
    isref = false
    if T === Bottom
        return Bottom
    elseif isa(T, Type)
        if isa(T, DataType) && (T::DataType).name === _REF_NAME
            isref = true
            T = T.parameters[1]
            if isreturn && T === Any
                return Bottom # a return type of Ref{Any} is invalid
            end
        end
    else
        return Any
    end
    if isa(linfo.def, Method)
        spsig = linfo.def.sig
        if isa(spsig, UnionAll)
            if !isempty(linfo.sparam_vals)
                sparam_vals = Any[isvarargtype(v) ? TypeVar(:N, Union{}, Any) :
                                  v for v in  linfo.sparam_vals]
                T = ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), T, spsig, sparam_vals)
                isref && isreturn && T === Any && return Bottom # catch invalid return Ref{T} where T = Any
                for v in sparam_vals
                    if isa(v, TypeVar)
                        T = UnionAll(v, T)
                    end
                end
            else
                T = rewrap_unionall(T, spsig)
            end
        end
    end
    return unwraptv(T)
end

function abstract_eval_cfunction(interp::AbstractInterpreter, e::Expr, vtypes::VarTable, sv::InferenceState)
    f = abstract_eval_value(interp, e.args[2], vtypes, sv)
    # rt = sp_type_rewrap(e.args[3], sv.linfo, true)
    at = Any[ sp_type_rewrap(argt, sv.linfo, false) for argt in e.args[4]::SimpleVector ]
    pushfirst!(at, f)
    # this may be the wrong world for the call,
    # but some of the result is likely to be valid anyways
    # and that may help generate better codegen
    abstract_call(interp, ArgInfo(nothing, at), StmtInfo(false), sv)
    nothing
end

function abstract_eval_value_expr(interp::AbstractInterpreter, e::Expr, sv::Union{InferenceState, IRCode})
    head = e.head
    if head === :static_parameter
        n = e.args[1]::Int
        t = Any
        if 1 <= n <= length(sv.sptypes)
            t = sv.sptypes[n]
        end
        return t
    elseif head === :boundscheck
        return Bool
    elseif head === :the_exception
        merge_effects!(interp, sv, Effects(EFFECTS_TOTAL; consistent=ALWAYS_FALSE))
        return Any
    end
    return Any
end

function abstract_eval_special_value(interp::AbstractInterpreter, @nospecialize(e), vtypes::Union{VarTable, Nothing}, sv::Union{InferenceState, IRCode})
    if isa(e, QuoteNode)
        return Const(e.value)
    elseif isa(e, SSAValue)
        return abstract_eval_ssavalue(e, sv)
    elseif isa(e, SlotNumber)
        vtyp = vtypes[slot_id(e)]
        if vtyp.undef
            merge_effects!(interp, sv, Effects(EFFECTS_TOTAL; nothrow=false))
        end
        return vtyp.typ
    elseif isa(e, Argument)
        if !isa(vtypes, Nothing)
            return vtypes[slot_id(e)].typ
        else
            @assert isa(sv, IRCode)
            return sv.argtypes[e.n]
        end
    elseif isa(e, GlobalRef)
        return abstract_eval_globalref(interp, e, sv)
    end

    return Const(e)
end

function abstract_eval_value(interp::AbstractInterpreter, @nospecialize(e), vtypes::Union{VarTable, Nothing}, sv::Union{InferenceState, IRCode})
    if isa(e, Expr)
        return abstract_eval_value_expr(interp, e, sv)
    else
        typ = abstract_eval_special_value(interp, e, vtypes, sv)
        return collect_limitations!(typ, sv)
    end
end

function collect_argtypes(interp::AbstractInterpreter, ea::Vector{Any}, vtypes::Union{VarTable, Nothing}, sv::Union{InferenceState, IRCode})
    n = length(ea)
    argtypes = Vector{Any}(undef, n)
    @inbounds for i = 1:n
        ai = abstract_eval_value(interp, ea[i], vtypes, sv)
        if ai === Bottom
            return nothing
        end
        argtypes[i] = ai
    end
    return argtypes
end

struct RTEffects
    rt
    effects::Effects
    RTEffects(@nospecialize(rt), effects::Effects) = new(rt, effects)
end

function abstract_eval_statement_expr(interp::AbstractInterpreter, e::Expr, vtypes::Union{VarTable, Nothing},
                                      sv::Union{InferenceState, IRCode}, mi::Union{MethodInstance, Nothing})::RTEffects
    effects = EFFECTS_UNKNOWN
    ehead = e.head
    ⊑ᵢ = ⊑(typeinf_lattice(interp))
    if ehead === :call
        ea = e.args
        argtypes = collect_argtypes(interp, ea, vtypes, sv)
        if argtypes === nothing
            rt = Bottom
            effects = Effects()
        else
            arginfo = ArgInfo(ea, argtypes)
            si = StmtInfo(isa(sv, IRCode) ? true : !call_result_unused(sv, sv.currpc))
            (; rt, effects, info) = abstract_call(interp, arginfo, si, sv)
            merge_effects!(interp, sv, effects)
            if isa(sv, InferenceState)
                sv.stmt_info[sv.currpc] = info
            end
        end
        t = rt
    elseif ehead === :new
        t, isexact = instanceof_tfunc(abstract_eval_value(interp, e.args[1], vtypes, sv))
        nothrow = true
        if isconcretedispatch(t)
            ismutable = ismutabletype(t)
            fcount = fieldcount(t)
            nargs = length(e.args) - 1
            @assert fcount ≥ nargs "malformed :new expression" # syntactically enforced by the front-end
            ats = Vector{Any}(undef, nargs)
            local anyrefine = false
            local allconst = true
            for i = 1:nargs
                at = widenconditional(abstract_eval_value(interp, e.args[i+1], vtypes, sv))
                ft = fieldtype(t, i)
                nothrow && (nothrow = at ⊑ᵢ ft)
                at = tmeet(typeinf_lattice(interp), at, ft)
                at === Bottom && @goto always_throw
                if ismutable && !isconst(t, i)
                    ats[i] = ft # can't constrain this field (as it may be modified later)
                    continue
                end
                allconst &= isa(at, Const)
                if !anyrefine
                    anyrefine = has_nontrivial_const_info(typeinf_lattice(interp), at) || # constant information
                                ⋤(typeinf_lattice(interp), at, ft) # just a type-level information, but more precise than the declared type
                end
                ats[i] = at
            end
            if fcount > nargs && any(i::Int -> !is_undefref_fieldtype(fieldtype(t, i)), (nargs+1):fcount)
                # allocation with undefined field leads to undefined behavior and should taint `:consistent`-cy
                consistent = ALWAYS_FALSE
            elseif ismutable
                # mutable object isn't `:consistent`, but we can still give the return
                # type information a chance to refine this `:consistent`-cy later
                consistent = CONSISTENT_IF_NOTRETURNED
            else
                consistent = ALWAYS_TRUE
            end
            # For now, don't allow:
            # - Const/PartialStruct of mutables (but still allow PartialStruct of mutables
            #   with `const` fields if anything refined)
            # - partially initialized Const/PartialStruct
            if fcount == nargs
                if consistent === ALWAYS_TRUE && allconst
                    argvals = Vector{Any}(undef, nargs)
                    for j in 1:nargs
                        argvals[j] = (ats[j]::Const).val
                    end
                    t = Const(ccall(:jl_new_structv, Any, (Any, Ptr{Cvoid}, UInt32), t, argvals, nargs))
                elseif anyrefine
                    t = PartialStruct(t, ats)
                end
            end
        else
            consistent = ALWAYS_FALSE
            nothrow = false
        end
        effects = Effects(EFFECTS_TOTAL; consistent, nothrow)
        merge_effects!(interp, sv, effects)
    elseif ehead === :splatnew
        t, isexact = instanceof_tfunc(abstract_eval_value(interp, e.args[1], vtypes, sv))
        nothrow = false # TODO: More precision
        if length(e.args) == 2 && isconcretedispatch(t) && !ismutabletype(t)
            at = abstract_eval_value(interp, e.args[2], vtypes, sv)
            n = fieldcount(t)
            if isa(at, Const) && isa(at.val, Tuple) && n == length(at.val::Tuple) &&
                let t = t, at = at; all(i::Int->getfield(at.val::Tuple, i) isa fieldtype(t, i), 1:n); end
                nothrow = isexact
                t = Const(ccall(:jl_new_structt, Any, (Any, Any), t, at.val))
            elseif isa(at, PartialStruct) && at ⊑ᵢ Tuple && n == length(at.fields::Vector{Any}) &&
                let t = t, at = at; all(i::Int->(at.fields::Vector{Any})[i] ⊑ᵢ fieldtype(t, i), 1:n); end
                nothrow = isexact
                t = PartialStruct(t, at.fields::Vector{Any})
            end
        end
        consistent = !ismutabletype(t) ? ALWAYS_TRUE : CONSISTENT_IF_NOTRETURNED
        effects = Effects(EFFECTS_TOTAL; consistent, nothrow)
        merge_effects!(interp, sv, effects)
    elseif ehead === :new_opaque_closure
        t = Union{}
        effects = Effects() # TODO
        merge_effects!(interp, sv, effects)
        if length(e.args) >= 4
            ea = e.args
            argtypes = collect_argtypes(interp, ea, vtypes, sv)
            if argtypes === nothing
                t = Bottom
            else
                mi′ = isa(sv, InferenceState) ? sv.linfo : mi
                t = _opaque_closure_tfunc(argtypes[1], argtypes[2], argtypes[3],
                    argtypes[4], argtypes[5:end], mi′)
                if isa(t, PartialOpaque) && isa(sv, InferenceState) && !call_result_unused(sv, sv.currpc)
                    # Infer this now so that the specialization is available to
                    # optimization.
                    argtypes = most_general_argtypes(t)
                    pushfirst!(argtypes, t.env)
                    callinfo = abstract_call_opaque_closure(interp, t,
                        ArgInfo(nothing, argtypes), StmtInfo(true), sv, #=check=#false)
                    sv.stmt_info[sv.currpc] = OpaqueClosureCreateInfo(callinfo)
                end
            end
        end
    elseif ehead === :foreigncall
        (;rt, effects) = abstract_eval_foreigncall(interp, e, vtypes, sv, mi)
        t = rt
        merge_effects!(interp, sv, effects)
    elseif ehead === :cfunction
        effects = EFFECTS_UNKNOWN
        merge_effects!(interp, sv, effects)
        t = e.args[1]
        isa(t, Type) || (t = Any)
        abstract_eval_cfunction(interp, e, vtypes, sv)
    elseif ehead === :method
        t = (length(e.args) == 1) ? Any : Nothing
        effects = EFFECTS_UNKNOWN
        merge_effects!(interp, sv, effects)
    elseif ehead === :copyast
        effects = EFFECTS_UNKNOWN
        merge_effects!(interp, sv, effects)
        t = abstract_eval_value(interp, e.args[1], vtypes, sv)
        if t isa Const && t.val isa Expr
            # `copyast` makes copies of Exprs
            t = Expr
        end
    elseif ehead === :invoke || ehead === :invoke_modify
        error("type inference data-flow error: tried to double infer a function")
    elseif ehead === :isdefined
        sym = e.args[1]
        t = Bool
        if isa(sym, SlotNumber)
            vtyp = vtypes[slot_id(sym)]
            if vtyp.typ === Bottom
                t = Const(false) # never assigned previously
            elseif !vtyp.undef
                t = Const(true) # definitely assigned previously
            end
        elseif isa(sym, Symbol)
            if isdefined(sv.mod, sym)
                t = Const(true)
            end
        elseif isa(sym, GlobalRef)
            if isdefined(sym.mod, sym.name)
                t = Const(true)
            end
        elseif isexpr(sym, :static_parameter)
            n = sym.args[1]::Int
            if 1 <= n <= length(sv.sptypes)
                spty = sv.sptypes[n]
                if isa(spty, Const)
                    t = Const(true)
                end
            end
        end
    elseif false
        @label always_throw
        t = Bottom
        effects = EFFECTS_THROWS
        merge_effects!(interp, sv, effects)
    else
        t = abstract_eval_value_expr(interp, e, sv)
    end
    return RTEffects(t, effects)
end

function abstract_eval_foreigncall(interp::AbstractInterpreter, e::Expr, vtypes::Union{VarTable, Nothing}, sv::Union{InferenceState, IRCode}, mi::Union{MethodInstance, Nothing}=nothing)
    abstract_eval_value(interp, e.args[1], vtypes, sv)
    mi′ = isa(sv, InferenceState) ? sv.linfo : mi
    t = sp_type_rewrap(e.args[2], mi′, true)
    for i = 3:length(e.args)
        if abstract_eval_value(interp, e.args[i], vtypes, sv) === Bottom
            return RTEffects(Bottom, EFFECTS_THROWS)
        end
    end
    effects = foreigncall_effects(e) do @nospecialize x
        abstract_eval_value(interp, x, vtypes, sv)
    end
    cconv = e.args[5]
    if isa(cconv, QuoteNode) && (v = cconv.value; isa(v, Tuple{Symbol, UInt8}))
        override = decode_effects_override(v[2])
        effects = Effects(
            override.consistent          ? ALWAYS_TRUE : effects.consistent,
            override.effect_free         ? ALWAYS_TRUE : effects.effect_free,
            override.nothrow             ? true        : effects.nothrow,
            override.terminates_globally ? true        : effects.terminates,
            override.notaskstate         ? true        : effects.notaskstate,
            override.inaccessiblememonly ? ALWAYS_TRUE : effects.inaccessiblememonly,
            effects.nonoverlayed)
    end
    return RTEffects(t, effects)
end

function abstract_eval_phi(interp::AbstractInterpreter, phi::PhiNode, vtypes::Union{VarTable, Nothing}, sv::Union{InferenceState, IRCode})
    rt = Union{}
    for i in 1:length(phi.values)
        isassigned(phi.values, i) || continue
        val = phi.values[i]
        rt = tmerge(typeinf_lattice(interp), rt, abstract_eval_special_value(interp, val, vtypes, sv))
    end
    return rt
end

function abstract_eval_statement(interp::AbstractInterpreter, @nospecialize(e), vtypes::VarTable, sv::InferenceState)
    if !isa(e, Expr)
        if isa(e, PhiNode)
            return abstract_eval_phi(interp, e, vtypes, sv)
        end
        return abstract_eval_special_value(interp, e, vtypes, sv)
    end
    (;rt, effects) = abstract_eval_statement_expr(interp, e, vtypes, sv, nothing)
    e = e::Expr
    @assert !isa(rt, TypeVar) "unhandled TypeVar"
    rt = maybe_singleton_const(rt)
    if !isempty(sv.pclimitations)
        if rt isa Const || rt === Union{}
            empty!(sv.pclimitations)
        else
            rt = LimitedAccuracy(rt, sv.pclimitations)
            sv.pclimitations = IdSet{InferenceState}()
        end
    end
    return rt
end

function isdefined_globalref(g::GlobalRef)
    g.binding != C_NULL && return ccall(:jl_binding_boundp, Cint, (Ptr{Cvoid},), g.binding) != 0
    return isdefined(g.mod, g.name)
end

function abstract_eval_globalref(g::GlobalRef)
    if isdefined_globalref(g) && isconst(g)
        g.binding != C_NULL && return Const(ccall(:jl_binding_value, Any, (Ptr{Cvoid},), g.binding))
        return Const(getglobal(g.mod, g.name))
    end
    ty = ccall(:jl_binding_type, Any, (Any, Any), g.mod, g.name)
    ty === nothing && return Any
    return ty
end
abstract_eval_global(M::Module, s::Symbol) = abstract_eval_globalref(GlobalRef(M, s))

function abstract_eval_globalref(interp::AbstractInterpreter, g::GlobalRef, frame::Union{InferenceState, IRCode})
    rt = abstract_eval_globalref(g)
    consistent = inaccessiblememonly = ALWAYS_FALSE
    nothrow = false
    if isa(rt, Const)
        consistent = ALWAYS_TRUE
        if is_mutation_free_argtype(rt)
            inaccessiblememonly = ALWAYS_TRUE
            nothrow = true
        else
            nothrow = true
        end
    elseif isdefined_globalref(g)
        nothrow = true
    end
    merge_effects!(interp, frame, Effects(EFFECTS_TOTAL; consistent, nothrow, inaccessiblememonly))
    return rt
end

function handle_global_assignment!(interp::AbstractInterpreter, frame::InferenceState, lhs::GlobalRef, @nospecialize(newty))
    effect_free = ALWAYS_FALSE
    nothrow = global_assignment_nothrow(lhs.mod, lhs.name, newty)
    inaccessiblememonly = ALWAYS_FALSE
    merge_effects!(interp, frame, Effects(EFFECTS_TOTAL; effect_free, nothrow, inaccessiblememonly))
    return nothing
end

abstract_eval_ssavalue(s::SSAValue, sv::InferenceState) = abstract_eval_ssavalue(s, sv.ssavaluetypes)
abstract_eval_ssavalue(s::SSAValue, src::CodeInfo) = abstract_eval_ssavalue(s, src.ssavaluetypes::Vector{Any})
function abstract_eval_ssavalue(s::SSAValue, ssavaluetypes::Vector{Any})
    typ = ssavaluetypes[s.id]
    if typ === NOT_FOUND
        return Bottom
    end
    return typ
end

function widenreturn(ipo_lattice::AbstractLattice, @nospecialize(rt), @nospecialize(bestguess), nargs::Int, slottypes::Vector{Any}, changes::VarTable)
    ⊑ₚ = ⊑(ipo_lattice)
    inner_lattice = widenlattice(ipo_lattice)
    ⊑ᵢ = ⊑(inner_lattice)
    if !(bestguess ⊑ₚ Bool) || bestguess === Bool
        # give up inter-procedural constraint back-propagation
        # when tmerge would widen the result anyways (as an optimization)
        rt = widenconditional(rt)
    else
        if isa(rt, Conditional)
            id = rt.slot
            if 1 ≤ id ≤ nargs
                old_id_type = widenconditional(slottypes[id]) # same as `(states[1]::VarTable)[id].typ`
                if (!(rt.thentype ⊑ᵢ old_id_type) || old_id_type ⊑ᵢ rt.thentype) &&
                   (!(rt.elsetype ⊑ᵢ old_id_type) || old_id_type ⊑ᵢ rt.elsetype)
                   # discard this `Conditional` since it imposes
                   # no new constraint on the argument type
                   # (the caller will recreate it if needed)
                   rt = widenconditional(rt)
               end
            else
                # discard this `Conditional` imposed on non-call arguments,
                # since it's not interesting in inter-procedural context;
                # we may give constraints on other call argument
                rt = widenconditional(rt)
            end
        end
        if isa(rt, Conditional)
            rt = InterConditional(rt.slot, rt.thentype, rt.elsetype)
        elseif is_lattice_bool(ipo_lattice, rt)
            if isa(bestguess, InterConditional)
                # if the bestguess so far is already `Conditional`, try to convert
                # this `rt` into `Conditional` on the slot to avoid overapproximation
                # due to conflict of different slots
                rt = bool_rt_to_conditional(rt, slottypes, changes, bestguess.slot)
            else
                # pick up the first "interesting" slot, convert `rt` to its `Conditional`
                # TODO: ideally we want `Conditional` and `InterConditional` to convey
                # constraints on multiple slots
                for slot_id in 1:nargs
                    rt = bool_rt_to_conditional(rt, slottypes, changes, slot_id)
                    rt isa InterConditional && break
                end
            end
        end
    end

    # only propagate information we know we can store
    # and is valid and good inter-procedurally
    isa(rt, Conditional) && return InterConditional(rt)
    isa(rt, InterConditional) && return rt
    return widenreturn_noconditional(widenlattice(ipo_lattice), rt)
end

function widenreturn_noconditional(inner_lattice::AbstractLattice, @nospecialize(rt))
    isa(rt, Const) && return rt
    isa(rt, Type) && return rt
    if isa(rt, PartialStruct)
        fields = copy(rt.fields)
        local anyrefine = false
        for i in 1:length(fields)
            a = fields[i]
            a = isvarargtype(a) ? a : widenreturn_noconditional(inner_lattice, a)
            if !anyrefine
                # TODO: consider adding && const_prop_profitable(a) here?
                anyrefine = has_const_info(a) ||
                            ⊏(inner_lattice, a, fieldtype(rt.typ, i))
            end
            fields[i] = a
        end
        anyrefine && return PartialStruct(rt.typ, fields)
    end
    if isa(rt, PartialOpaque)
        return rt # XXX: this case was missed in #39512
    end
    return widenconst(rt)
end

function handle_control_backedge!(interp::AbstractInterpreter, frame::InferenceState, from::Int, to::Int)
    if from > to
        if is_effect_overridden(frame, :terminates_locally)
            # this backedge is known to terminate
        else
            merge_effects!(interp, frame, Effects(EFFECTS_TOTAL; terminates=false))
        end
    end
    return nothing
end

struct BasicStmtChange
    changes::Union{Nothing,StateUpdate}
    type::Any # ::Union{Type, Nothing} - `nothing` if this statement may not be used as an SSA Value
    # TODO effects::Effects
    BasicStmtChange(changes::Union{Nothing,StateUpdate}, @nospecialize type) = new(changes, type)
end

@inline function abstract_eval_basic_statement(interp::AbstractInterpreter,
    @nospecialize(stmt), pc_vartable::VarTable, frame::InferenceState)
    if isa(stmt, NewvarNode)
        changes = StateUpdate(stmt.slot, VarState(Bottom, true), pc_vartable, false)
        return BasicStmtChange(changes, nothing)
    elseif !isa(stmt, Expr)
        t = abstract_eval_statement(interp, stmt, pc_vartable, frame)
        return BasicStmtChange(nothing, t)
    end
    changes = nothing
    stmt = stmt::Expr
    hd = stmt.head
    if hd === :(=)
        t = abstract_eval_statement(interp, stmt.args[2], pc_vartable, frame)
        if t === Bottom
            return BasicStmtChange(nothing, Bottom)
        end
        lhs = stmt.args[1]
        if isa(lhs, SlotNumber)
            changes = StateUpdate(lhs, VarState(t, false), pc_vartable, false)
        elseif isa(lhs, GlobalRef)
            handle_global_assignment!(interp, frame, lhs, t)
        elseif !isa(lhs, SSAValue)
            merge_effects!(interp, frame, EFFECTS_UNKNOWN)
        end
        return BasicStmtChange(changes, t)
    elseif hd === :method
        fname = stmt.args[1]
        if isa(fname, SlotNumber)
            changes = StateUpdate(fname, VarState(Any, false), pc_vartable, false)
        end
        return BasicStmtChange(changes, nothing)
    elseif (hd === :code_coverage_effect || (
            hd !== :boundscheck && # :boundscheck can be narrowed to Bool
            is_meta_expr(stmt)))
        return BasicStmtChange(nothing, Nothing)
    else
        t = abstract_eval_statement(interp, stmt, pc_vartable, frame)
        return BasicStmtChange(nothing, t)
    end
end

function update_bbstate!(lattice::AbstractLattice, frame::InferenceState, bb::Int, vartable::VarTable)
    bbtable = frame.bb_vartables[bb]
    if bbtable === nothing
        # if a basic block hasn't been analyzed yet,
        # we can update its state a bit more aggressively
        frame.bb_vartables[bb] = copy(vartable)
        return true
    else
        return stupdate!(lattice, bbtable, vartable)
    end
end

function init_vartable!(vartable::VarTable, frame::InferenceState)
    nargtypes = length(frame.result.argtypes)
    for i = 1:length(vartable)
        vartable[i] = VarState(Bottom, i > nargtypes)
    end
    return vartable
end

# make as much progress on `frame` as possible (without handling cycles)
function typeinf_local(interp::AbstractInterpreter, frame::InferenceState)
    @assert !frame.inferred
    frame.dont_work_on_me = true # mark that this function is currently on the stack
    W = frame.ip
    nargs = narguments(frame)
    slottypes = frame.slottypes
    ssavaluetypes = frame.ssavaluetypes
    bbs = frame.cfg.blocks
    nbbs = length(bbs)

    currbb = frame.currbb
    if currbb != 1
        currbb = frame.currbb = _bits_findnext(W.bits, 1)::Int # next basic block
    end

    states = frame.bb_vartables
    currstate = copy(states[currbb]::VarTable)
    while currbb <= nbbs
        delete!(W, currbb)
        bbstart = first(bbs[currbb].stmts)
        bbend = last(bbs[currbb].stmts)

        for currpc in bbstart:bbend
            frame.currpc = currpc
            empty_backedges!(frame, currpc)
            stmt = frame.src.code[currpc]
            # If we're at the end of the basic block ...
            if currpc == bbend
                # Handle control flow
                if isa(stmt, GotoNode)
                    succs = bbs[currbb].succs
                    @assert length(succs) == 1
                    nextbb = succs[1]
                    ssavaluetypes[currpc] = Any
                    handle_control_backedge!(interp, frame, currpc, stmt.label)
                    @goto branch
                elseif isa(stmt, GotoIfNot)
                    condx = stmt.cond
                    condt = abstract_eval_value(interp, condx, currstate, frame)
                    if condt === Bottom
                        ssavaluetypes[currpc] = Bottom
                        empty!(frame.pclimitations)
                        @goto find_next_bb
                    end
                    if !(isa(condt, Const) || isa(condt, Conditional)) && isa(condx, SlotNumber)
                        # if this non-`Conditional` object is a slot, we form and propagate
                        # the conditional constraint on it
                        condt = Conditional(condx, Const(true), Const(false))
                    end
                    condval = maybe_extract_const_bool(condt)
                    if !isempty(frame.pclimitations)
                        # we can't model the possible effect of control
                        # dependencies on the return
                        # directly to all the return values (unless we error first)
                        condval isa Bool || union!(frame.limitations, frame.pclimitations)
                        empty!(frame.pclimitations)
                    end
                    ssavaluetypes[currpc] = Any
                    if condval === true
                        @goto fallthrough
                    else
                        succs = bbs[currbb].succs
                        if length(succs) == 1
                            @assert condval === false || (stmt.dest === currpc + 1)
                            nextbb = succs[1]
                            @goto branch
                        end
                        @assert length(succs) == 2
                        truebb = currbb + 1
                        falsebb = succs[1] == truebb ? succs[2] : succs[1]
                        if condval === false
                            nextbb = falsebb
                            handle_control_backedge!(interp, frame, currpc, stmt.dest)
                            @goto branch
                        else
                            # We continue with the true branch, but process the false
                            # branch here.
                            if isa(condt, Conditional)
                                else_change = conditional_change(currstate, condt.elsetype, condt.slot)
                                if else_change !== nothing
                                    false_vartable = stoverwrite1!(copy(currstate), else_change)
                                else
                                    false_vartable = currstate
                                end
                                changed = update_bbstate!(typeinf_lattice(interp), frame, falsebb, false_vartable)
                                then_change = conditional_change(currstate, condt.thentype, condt.slot)
                                if then_change !== nothing
                                    stoverwrite1!(currstate, then_change)
                                end
                            else
                                changed = update_bbstate!(typeinf_lattice(interp), frame, falsebb, currstate)
                            end
                            if changed
                                handle_control_backedge!(interp, frame, currpc, stmt.dest)
                                push!(W, falsebb)
                            end
                            @goto fallthrough
                        end
                    end
                elseif isa(stmt, ReturnNode)
                    bestguess = frame.bestguess
                    rt = abstract_eval_value(interp, stmt.val, currstate, frame)
                    rt = widenreturn(ipo_lattice(interp), rt, bestguess, nargs, slottypes, currstate)
                    # narrow representation of bestguess slightly to prepare for tmerge with rt
                    if rt isa InterConditional && bestguess isa Const
                        let slot_id = rt.slot
                            old_id_type = slottypes[slot_id]
                            if bestguess.val === true && rt.elsetype !== Bottom
                                bestguess = InterConditional(slot_id, old_id_type, Bottom)
                            elseif bestguess.val === false && rt.thentype !== Bottom
                                bestguess = InterConditional(slot_id, Bottom, old_id_type)
                            end
                        end
                    end
                    # copy limitations to return value
                    if !isempty(frame.pclimitations)
                        union!(frame.limitations, frame.pclimitations)
                        empty!(frame.pclimitations)
                    end
                    if !isempty(frame.limitations)
                        rt = LimitedAccuracy(rt, copy(frame.limitations))
                    end
                    if tchanged(ipo_lattice(interp), rt, bestguess)
                        # new (wider) return type for frame
                        bestguess = tmerge(ipo_lattice(interp), bestguess, rt)
                        # TODO: if bestguess isa InterConditional && !interesting(bestguess); bestguess = widenconditional(bestguess); end
                        frame.bestguess = bestguess
                        for (caller, caller_pc) in frame.cycle_backedges
                            if !(caller.ssavaluetypes[caller_pc] === Any)
                                # no reason to revisit if that call-site doesn't affect the final result
                                push!(caller.ip, block_for_inst(caller.cfg, caller_pc))
                            end
                        end
                    end
                    ssavaluetypes[frame.currpc] = Any
                    @goto find_next_bb
                elseif isexpr(stmt, :enter)
                    # Propagate entry info to exception handler
                    l = stmt.args[1]::Int
                    catchbb = block_for_inst(frame.cfg, l)
                    if update_bbstate!(typeinf_lattice(interp), frame, catchbb, currstate)
                        push!(W, catchbb)
                    end
                    ssavaluetypes[currpc] = Any
                    @goto fallthrough
                end
                # Fall through terminator - treat as regular stmt
            end
            # Process non control-flow statements
            (; changes, type) = abstract_eval_basic_statement(interp,
                stmt, currstate, frame)
            if type === Bottom
                ssavaluetypes[currpc] = Bottom
                @goto find_next_bb
            end
            if changes !== nothing
                stoverwrite1!(currstate, changes)
                let cur_hand = frame.handler_at[currpc], l, enter
                    while cur_hand != 0
                        enter = frame.src.code[cur_hand]::Expr
                        l = enter.args[1]::Int
                        exceptbb = block_for_inst(frame.cfg, l)
                        # propagate new type info to exception handler
                        # the handling for Expr(:enter) propagates all changes from before the try/catch
                        # so this only needs to propagate any changes
                        if stupdate1!(typeinf_lattice(interp), states[exceptbb]::VarTable, changes)
                            push!(W, exceptbb)
                        end
                        cur_hand = frame.handler_at[cur_hand]
                    end
                end
            end
            if type === nothing
                ssavaluetypes[currpc] = Any
                continue
            end
            if !isempty(frame.ssavalue_uses[currpc])
                record_ssa_assign!(currpc, type, frame)
            else
                ssavaluetypes[currpc] = type
            end
        end # for currpc in bbstart:bbend

        # Case 1: Fallthrough termination
        begin @label fallthrough
            nextbb = currbb + 1
        end

        # Case 2: Directly branch to a different BB
        begin @label branch
            if update_bbstate!(typeinf_lattice(interp), frame, nextbb, currstate)
                push!(W, nextbb)
            end
        end

        # Case 3: Control flow ended along the current path (converged, return or throw)
        begin @label find_next_bb
            currbb = frame.currbb = _bits_findnext(W.bits, 1)::Int # next basic block
            currbb == -1 && break # the working set is empty
            currbb > nbbs && break

            nexttable = states[currbb]
            if nexttable === nothing
                init_vartable!(currstate, frame)
            else
                stoverwrite!(currstate, nexttable)
            end
        end
    end # while currbb <= nbbs

    frame.dont_work_on_me = false
    nothing
end

function conditional_change(state::VarTable, @nospecialize(typ), slot::Int)
    vtype = state[slot]
    oldtyp = vtype.typ
    if iskindtype(typ)
        # this code path corresponds to the special handling for `isa(x, iskindtype)` check
        # implemented within `abstract_call_builtin`
    elseif ignorelimited(typ) ⊑ ignorelimited(oldtyp)
        # approximate test for `typ ∩ oldtyp` being better than `oldtyp`
        # since we probably formed these types with `typesubstract`,
        # the comparison is likely simple
    else
        return nothing
    end
    if oldtyp isa LimitedAccuracy
        # typ is better unlimited, but we may still need to compute the tmeet with the limit
        # "causes" since we ignored those in the comparison
        typ = tmerge(typ, LimitedAccuracy(Bottom, oldtyp.causes))
    end
    return StateUpdate(SlotNumber(slot), VarState(typ, vtype.undef), state, true)
end

function bool_rt_to_conditional(@nospecialize(rt), slottypes::Vector{Any}, state::VarTable, slot_id::Int)
    old = slottypes[slot_id]
    new = widenconditional(state[slot_id].typ) # avoid nested conditional
    if new ⊑ old && !(old ⊑ new)
        if isa(rt, Const)
            val = rt.val
            if val === true
                return InterConditional(slot_id, new, Bottom)
            elseif val === false
                return InterConditional(slot_id, Bottom, new)
            end
        elseif rt === Bool
            return InterConditional(slot_id, new, new)
        end
    end
    return rt
end

# make as much progress on `frame` as possible (by handling cycles)
function typeinf_nocycle(interp::AbstractInterpreter, frame::InferenceState)
    typeinf_local(interp, frame)

    # If the current frame is part of a cycle, solve the cycle before finishing
    no_active_ips_in_callers = false
    while !no_active_ips_in_callers
        no_active_ips_in_callers = true
        for caller in frame.callers_in_cycle
            caller.dont_work_on_me && return false # cycle is above us on the stack
            if !isempty(caller.ip)
                # Note that `typeinf_local(interp, caller)` can potentially modify the other frames
                # `frame.callers_in_cycle`, which is why making incremental progress requires the
                # outer while loop.
                typeinf_local(interp, caller)
                no_active_ips_in_callers = false
            end
            caller.valid_worlds = intersect(caller.valid_worlds, frame.valid_worlds)
        end
    end
    return true
end
