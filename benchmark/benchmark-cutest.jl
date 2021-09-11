include("config.jl")
Pkg.add(PackageSpec(name="CUTEst",rev="main")) # will be removed once the new CUTEst version is released

@everywhere using CUTEst

if SOLVER == "master" || SOLVER == "current"
    @everywhere begin
        using MadNLP, MadNLPHSL
        solver = nlp -> madnlp(nlp,linear_solver=MadNLPMa57,max_wall_time=900.,tol=1e-6, print_level=PRINT_LEVEL)
        function get_status(code::MadNLP.Status)
            if code == MadNLP.SOLVE_SUCCEEDED
                return 1
            elseif code == MadNLP.SOLVED_TO_ACCEPTABLE_LEVEL
                return 2
            else
                return 3
            end
        end
    end
elseif SOLVER == "ipopt"
    @everywhere begin
        solver = nlp -> ipopt(nlp,linear_solver="ma57",max_cpu_time=900.,tol=1e-6, print_level=PRINT_LEVEL)
        using NLPModelsIpopt
        function get_status(code::Symbol)
            if code == :first_order
                return 1
            elseif code == :acceptable
                return 2
            else
                return 3
            end
        end
    end
elseif SOLVER == "knitro"
    # TODO
else
    error("Proper SOLVER should be given")
end


@everywhere function decodemodel(name)
    println("Decoding $name")
    finalize(CUTEstModel(name))
end

@everywhere function evalmodel(name,solver;gcoff=false)
    println("Solving $name")
    nlp = CUTEstModel(name; decode=false)
    try
        gcoff && GC.enable(false);
        mem = @allocated begin
            t = @elapsed begin
                retval = solver(nlp)
            end
        end
        gcoff && GC.enable(true);
        finalize(nlp)
        return (status=get_status(retval.status),time=t,mem=mem,iter=retval.iter)
    catch e
        finalize(nlp)
        throw(e)
    end
end

function benchmark(solver,probs;warm_up_probs = [])
    println("Warming up (forcing JIT compile)")
    broadcast(decodemodel,warm_up_probs)
    [remotecall_fetch.(prob->evalmodel(prob,solver;gcoff=GCOFF),i,warm_up_probs) for i in procs() if i!= 1]

    println("Decoding problems")
    broadcast(decodemodel,probs)

    println("Solving problems")
    retvals = pmap(prob->evalmodel(prob,solver),probs)
    status = [retval.status for retval in retvals]
    time   = [retval.time for retval in retvals]
    mem    = [retval.mem for retval in retvals]
    iter   = [retval.iter for retval in retvals]
    status,time,mem,iter
end

exclude = [
    "PFIT1","PFIT2","PFIT4","DENSCHNE","SPECANNE","DJTL", "EG3","OET7",
    "PRIMAL3","TAX213322","TAXR213322","TAX53322","TAXR53322","HIMMELP2","MOSARQP2","LUKVLE11",
    "CYCLOOCT","CYCLOOCF","LIPPERT1","GAUSSELM","A2NSSSSL",
    "YATP1LS","YATP2LS","YATP1CLS","YATP2CLS","BA-L52LS","BA-L73LS","BA-L21LS","CRESC132"
]


if QUICK
    probs = readdlm("cutest-quick-names.csv")[:]
else
    probs = CUTEst.select()
end

filter!(e->!(e in exclude),probs)

status,time,mem,iter = benchmark(solver,probs;warm_up_probs = ["EIGMINA"])

writedlm("name-cutest.csv",probs,',')
writedlm("status-cutest-$(SOLVER).csv",status),','
writedlm("time-cutest-$(SOLVER).csv",time,',')
writedlm("mem-cutest-$(SOLVER).csv",mem,',')
writedlm("iter-cutest-$(SOLVER).csv",iter,',')