using Distributions, Parameters, DynamicHMC, LogDensityProblems, TransformVariables
using Random, StatsFuns
import Distributions: pdf,logpdf,rand

export LBA,pdf,logpdf,rand

Base.@kwdef struct LBA{T1,T2,T3,T4} <: ContinuousUnivariateDistribution
    ν::T1
    A::T2
    k::T3
    τ::T4
    σ::Float64 = 1.0
end

Base.broadcastable(x::LBA) = Ref(x)

###
### simulation
###

function selectWinner(dt)
    if any(x -> x > 0,dt)
        mi, mv = 0, Inf
        for (i, t) in enumerate(dt)
            if (t > 0) && (t < mv)
                mi = i
                mv = t
            end
        end
    else
        return 1,-1.0
    end
    return mi,mv
end

function sampleDriftRates(ν,σ)
    noPositive=true
    v = similar(ν)
    while noPositive
        v = [rand(Normal(d,σ)) for d in ν]
        any(x->x>0,v) ? noPositive=false : nothing
    end
    return v
end

function rand(d::LBA)
    @unpack τ,A,k,ν,σ = d
    b=A+k
    N = length(ν)
    v = sampleDriftRates(ν,σ)
    a = rand(Uniform(0,A),N)
    dt = @. (b-a)/v
    choice,mn = selectWinner(dt)
    rt = τ .+ mn
    return choice,rt
end

function rand(d::LBA,N::Int)
    choice = fill(0,N)
    rt = fill(0.0,N)
    for i in 1:N
        choice[i], rt[i] = rand(d)
    end
    return (choice = choice, rt = rt)
end

function simulateLBA(;Nd,v=[1.0,1.5,2.0],A=.8,k=.2,tau=.4,kwargs...)
    return (rand(LBA(ν=v,A=A,k=k,τ=tau),Nd)...,N=Nd,Nc=length(v))
end

###
### log densities
###

function logpdf(d::LBA,data::T) where {T<:NamedTuple}
    return sum(logpdf.(d,data...))
end

function logpdf(dist::LBA,data::Array{<:Tuple,1})
    LL = 0.0
    for d in data
        LL += logpdf(dist,d...)
    end
    return LL
end

function logpdf(d::LBA,c,rt)
    @unpack τ,A,k,ν,σ = d
    b = A + k
    logden = 0.0
    rt < τ ? (return 1e-10) : nothing
    for (i,v) in enumerate(ν)
        if c == i
            logden += logdens(d,v,rt)
        else
            logden += log_tail_cumulative(d,v,rt)
        end
    end
    logden - log1mexp(logpnegative(d))
end

logpdf(d::LBA,data::Tuple) = logpdf(d,data...)

function logdens(d::LBA, v, rt)
    @unpack τ,A,k,ν,σ = d
    dt = rt-τ; b=A+k
    n1 = (b-A-dt*v)/(dt*σ)
    n2 = (b-dt*v)/(dt*σ)
    Δcdfs = cdf(Normal(0,1),n2) - cdf(Normal(0,1),n1)
    Δpdfs = pdf(Normal(0,1),n1) - pdf(Normal(0,1),n2)
    -log(A) + logaddexp(log(σ) + log(Δpdfs), log(v) * log(Δcdfs))
end

function log_tail_cumulative(d::LBA,v,rt)
    @unpack τ,A,k,ν,σ = d
    dt = rt-τ; b=A+k
    n1 = (b-A-dt*v)/(dt*σ)
    n2 = (b-dt*v)/(dt*σ)
    log(-((b-A-dt*v)/A)*cdf(Normal(0,1),n1) +
          ((b-dt*v)/A)*cdf(Normal(0,1),n2) - ((dt*σ)/A)*pdf(Normal(0,1),n1) +
          ((dt*σ)/A)*pdf(Normal(0,1),n2))
end

function logpnegative(d::LBA)
    @unpack ν,σ=d
    sum(v -> logcdf(Normal(0,1),-v/σ), ν)
end

struct LBAProb{T}
    data::T
    N::Int
    Nc::Int
end

function (problem::LBAProb)(θ)
    @unpack data=problem
    @unpack v,A,k,tau=θ
    d = LBA(ν=v,A=A,k=k,τ=tau)
    minRT = minimum(last, data)
    logprior = (sum(logpdf.(TruncatedNormal(0,3,0,Inf), v)) +
                logpdf(TruncatedNormal(.8,.4,0,Inf),A) +
                logpdf(TruncatedNormal(.2,.3,0,Inf),k) +
                logpdf(TruncatedNormal(.4,.1,0,minRT), tau))
    loglikelihood = logpdf(d, data)
end

function sampleDHMC(choice,rt,N,Nc,nsamples)
    data = [(c,r) for (c,r) in zip(choice,rt)]
    return sampleDHMC(data,N,Nc,nsamples)
end

N = 10
data = simulateLBA(Nd = N)
p = LBAProb(collect(zip(data.choice, data.rt)), N, data.Nc)
p((v=fill(.5,data.Nc),A=.8,k=.2,tau=.4))
trans = as((v=as(Array,asℝ₊,data.Nc),A=asℝ₊,k=asℝ₊,tau=asℝ₊))
P = TransformedLogDensity(trans, p)
∇P = ADgradient(:ForwardDiff, P)
results = mcmc_with_warmup(Random.GLOBAL_RNG, ∇P, 1000)
posterior = trans.(results.chain)
