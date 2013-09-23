from cython.operator cimport dereference as deref, preincrement as inc
from libcpp.vector cimport vector
from libc.math cimport sqrt

ctypedef unsigned int uint  # needed for templates

cdef extern from "stan/prob/autocovariance.hpp" namespace "stan::prob":
    void stan_autocovariance "stan::prob::autocovariance<double>"(vector[double]& y, vector[double] acov)

cdef extern from "stan/math.hpp" namespace "stan::math":
    double sum(vector[double]& x)
    double mean(vector[double]& x)
    double variance(vector[double]& x)


cdef double get_chain_mean(dict sim, uint k, uint n):
    allsamples = sim['samples']
    warmup2 = sim['warmup2']

    slst = allsamples[k]['chains']  # chain k, an OrderedDict
    param_names = list(slst.keys())  # e.g., 'beta[1]', 'beta[2]', ...
    cdef vector[double] nv = slst[param_names[n]]  # parameter n
    cdef double mean = 0
    for i in range(nv.size() - warmup2[k]):
        mean += nv[warmup2[k] + i]
    return mean / (nv.size() - warmup2[k])


cdef void get_kept_samples(dict sim, uint k, uint n, vector[double]& samples):
    """
    
    Parameters
    ----------
    k : unsigned int
        Chain index
    n : unsigned int
        Parameter index
    """
    cdef uint i
    allsamples = sim['samples']
    n_save = sim['n_save']
    warmup2 = sim['warmup2']

    slst = allsamples[k]['chains']  # chain k, an OrderedDict
    param_names = list(slst.keys())  # e.g., 'beta[1]', 'beta[2]', ...
    cdef vector[double] nv = slst[param_names[n]]  # parameter n
    # NOTE: this creates a copy which is not optimal, RStan avoids this by
    # managing things in C++
    samples.clear()
    for i in range(nv.size() - warmup2[k]):
        samples.push_back(nv[warmup2[k] + i])


cdef vector[double] autocovariance(dict sim, uint k, uint n):
    """
    Returns the autocovariance for the specified parameter in the
    kept samples of the chain specified.
    
    Parameters
    ----------
    k : unsigned int
        Chain index
    n : unsigned int
        Parameter index

    Returns
    -------
    acov : vector[double]

    Note
    ----
    PyStan is profligate with memory here in comparison to RStan. A variety
    of copies are made where RStan passes around references. This is done
    mainly for convenience; the Cython code is simpler.
    """
    cdef vector[double]* samples = new vector[double]()
    cdef vector[double]* acov = new vector[double]()
    get_kept_samples(sim, k, n, deref(samples))
    stan_autocovariance(deref(samples), deref(acov))
    return deref(acov)

def effective_sample_size(dict sim, uint n):
    """
    Return the effective sample size for the specified parameter
    across all kept samples.

    This implementation matches BDA3's effective size description.

    Current implementation takes the minimum number of samples
    across chains as the number of samples per chain.

    Parameters
    ----------
    sim : dict
        Contains samples as well as related information (warmup, number
        of iterations, etc).
    n : int
        Parameter index

    Returns
    -------
    ess : int
    """
    cdef uint i, chain
    cdef uint m = sim['chains']

    cdef vector[uint] ns_save = sim['n_save']

    cdef vector[uint] ns_warmup2 = sim['warmup2']

    cdef vector[uint] ns_kept = [s - w for s, w in zip(sim['n_save'], sim['warmup2'])]

    cdef uint n_samples = min(ns_kept)

    cdef vector[vector[double]] acov
    cdef vector[double] acov_chain
    for chain in range(m):
        acov_chain = autocovariance(sim, chain, n)
        acov.push_back(acov_chain)

    cdef vector[double] chain_mean
    cdef vector[double] chain_var
    cdef uint n_kept_samples
    for chain in range(m):
        n_kept_samples = ns_kept[chain]
        chain_mean.push_back(get_chain_mean(sim, chain, n))
        chain_var.push_back(acov[chain][0]*n_kept_samples/(n_kept_samples-1))

    cdef double mean_var = mean(chain_var)
    cdef double var_plus = mean_var*(n_samples-1)/n_samples

    if m > 1:
        var_plus += variance(chain_mean)

    cdef vector[double] rho_hat_t
    cdef double rho_hat = 0
    cdef uint t = 0
    cdef vector[double] *acov_t
    while t < n_samples and rho_hat >= 0:
        acov_t = new vector[double](m)
        for chain in range(m):
            deref(acov_t)[chain] = acov[chain][t]
        rho_hat = 1 - (mean_var - mean(deref(acov_t))) / var_plus
        if rho_hat >= 0:
            rho_hat_t.push_back(rho_hat)
        t += 1

    cdef double ess = m*n_samples
    if rho_hat_t.size() > 0:
        ess /= 1 + 2 * sum(rho_hat_t)

    return ess


def split_potential_scale_reduction(dict sim, uint n):
    """
    Return the split potential scale reduction (split R hat) for the
    specified parameter.
    
    Current implementation takes the minimum number of samples
    across chains as the number of samples per chain.
    
    Parameters
    ----------
    n : unsigned int
        Parameter index

    Returns
    -------
    rhat : float
        Split R hat
    
    """
    cdef uint i, chain
    cdef uint n_chains = sim['chains']

    cdef vector[uint] ns_save = sim['n_save']

    cdef vector[uint] ns_warmup2 = sim['warmup2']

    cdef vector[uint] ns_kept = [s - w for s, w in zip(sim['n_save'], sim['warmup2'])]

    cdef uint n_samples = min(ns_kept)

    if n_samples % 2 == 1:
        n_samples = n_samples - 1

    cdef vector[double]* split_chain_mean = new vector[double]()
    cdef vector[double]* split_chain_var = new vector[double]()

    cdef vector[double]* samples = new vector[double]()
    cdef vector[double]* split_chain = new vector[double]()
    for chain in range(n_chains):
        get_kept_samples(sim, chain, n, deref(samples))
        # c++ vector assign isn't available in Cython; this is a workaround
        for i in range(n_samples/2):
            split_chain.push_back(deref(samples)[i])
        split_chain_mean.push_back(mean(deref(split_chain)))
        split_chain_var.push_back(variance(deref(split_chain)))

        split_chain.clear()
        for i in range(n_samples/2, n_samples):
            split_chain.push_back(deref(samples)[i])
        split_chain_mean.push_back(mean(deref(split_chain)))
        split_chain_var.push_back(variance(deref(split_chain)))

    cdef double var_between = n_samples/2 * variance(deref(split_chain_mean))
    cdef double var_within = mean(deref(split_chain_var))

    cdef double srhat = sqrt((var_between/var_within + n_samples/2 -1)/(n_samples/2))
    return srhat