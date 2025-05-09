#include <iostream>

#include <cuComplex.h>
#include <cufinufft/contrib/helper_cuda.h>

#include "spreadinterp3d.cuh"
#include <cufinufft/common.h>
#include <cufinufft/memtransfer.h>
#include <cufinufft/spreadinterp.h>

using namespace cufinufft::memtransfer;
using namespace cufinufft::common;

namespace cufinufft {
namespace spreadinterp {

// Functor to handle function selection (nuptsdriven vs subprob)
struct Interp3DDispatcher {
  template<int ns, typename T>
  int operator()(int nf1, int nf2, int nf3, int M, cufinufft_plan_t<T> *d_plan,
                 int blksize) const {
    switch (d_plan->opts.gpu_method) {
    case 1:
      return cuinterp3d_nuptsdriven<T, ns>(nf1, nf2, nf3, M, d_plan, blksize);
    case 2:
      return cuinterp3d_subprob<T, ns>(nf1, nf2, nf3, M, d_plan, blksize);
    default:
      std::cerr << "[cuinterp3d] error: incorrect method, should be 1 or 2\n";
      return FINUFFT_ERR_METHOD_NOTVALID;
    }
  }
};

// Updated cuinterp3d using generic dispatch
template<typename T> int cuinterp3d(cufinufft_plan_t<T> *d_plan, int blksize) {
  /*
    A wrapper for different interpolation methods.

    Methods available:
        (1) Non-uniform points driven
        (2) Subproblem

    Melody Shih 07/25/19

    Now the function is updated to dispatch based on ns. This is to avoid alloca which
    it seems slower according to the MRI community.
    Marco Barbone 01/30/25
  */
  return launch_dispatch_ns<Interp3DDispatcher, T>(
      Interp3DDispatcher(), d_plan->spopts.nspread, d_plan->nf1, d_plan->nf2, d_plan->nf3,
      d_plan->M, d_plan, blksize);
}

template<typename T, int ns>
int cuinterp3d_nuptsdriven(int nf1, int nf2, int nf3, int M, cufinufft_plan_t<T> *d_plan,
                           int blksize) {
  const auto stream = d_plan->stream;

  T es_c    = d_plan->spopts.ES_c;
  T es_beta = d_plan->spopts.ES_beta;
  T sigma   = d_plan->spopts.upsampfac;

  int *d_idxnupts = d_plan->idxnupts;

  T *d_kx               = d_plan->kx;
  T *d_ky               = d_plan->ky;
  T *d_kz               = d_plan->kz;
  cuda_complex<T> *d_c  = d_plan->c;
  cuda_complex<T> *d_fw = d_plan->fw;

  const dim3 threadsPerBlock{16, 1, 1};
  const dim3 blocks{(M + threadsPerBlock.x - 1) / threadsPerBlock.x, 1, 1};

  if (d_plan->opts.gpu_kerevalmeth) {
    for (int t = 0; t < blksize; t++) {
      interp_3d_nupts_driven<T, 1, ns><<<blocks, threadsPerBlock, 0, stream>>>(
          d_kx, d_ky, d_kz, d_c + t * M, d_fw + t * nf1 * nf2 * nf3, M, nf1, nf2, nf3,
          es_c, es_beta, sigma, d_idxnupts);
      RETURN_IF_CUDA_ERROR
    }
  } else {
    for (int t = 0; t < blksize; t++) {
      interp_3d_nupts_driven<T, 0, ns><<<blocks, threadsPerBlock, 0, stream>>>(
          d_kx, d_ky, d_kz, d_c + t * M, d_fw + t * nf1 * nf2 * nf3, M, nf1, nf2, nf3,
          es_c, es_beta, sigma, d_idxnupts);
      RETURN_IF_CUDA_ERROR
    }
  }

  return 0;
}

template<typename T, int ns>
int cuinterp3d_subprob(int nf1, int nf2, int nf3, int M, cufinufft_plan_t<T> *d_plan,
                       int blksize) {
  auto &stream = d_plan->stream;

  int maxsubprobsize = d_plan->opts.gpu_maxsubprobsize;

  // assume that bin_size_x > ns/2;
  int bin_size_x = d_plan->opts.gpu_binsizex;
  int bin_size_y = d_plan->opts.gpu_binsizey;
  int bin_size_z = d_plan->opts.gpu_binsizez;
  int numbins[3];
  numbins[0] = ceil((T)nf1 / bin_size_x);
  numbins[1] = ceil((T)nf2 / bin_size_y);
  numbins[2] = ceil((T)nf3 / bin_size_z);

  T *d_kx               = d_plan->kx;
  T *d_ky               = d_plan->ky;
  T *d_kz               = d_plan->kz;
  cuda_complex<T> *d_c  = d_plan->c;
  cuda_complex<T> *d_fw = d_plan->fw;

  int *d_binsize         = d_plan->binsize;
  int *d_binstartpts     = d_plan->binstartpts;
  int *d_numsubprob      = d_plan->numsubprob;
  int *d_subprobstartpts = d_plan->subprobstartpts;
  int *d_idxnupts        = d_plan->idxnupts;
  int *d_subprob_to_bin  = d_plan->subprob_to_bin;
  int totalnumsubprob    = d_plan->totalnumsubprob;

  T sigma   = d_plan->spopts.upsampfac;
  T es_c    = d_plan->spopts.ES_c;
  T es_beta = d_plan->spopts.ES_beta;
  const auto sharedplanorysize =
      shared_memory_required<T>(3, d_plan->spopts.nspread, d_plan->opts.gpu_binsizex,
                                d_plan->opts.gpu_binsizey, d_plan->opts.gpu_binsizez);

  if (d_plan->opts.gpu_kerevalmeth == 1) {
    if (const auto finufft_err =
            cufinufft_set_shared_memory(interp_3d_subprob<T, 1, ns>, 3, *d_plan)) {
      return finufft_err;
    }
    for (int t = 0; t < blksize; t++) {
      interp_3d_subprob<T, 1, ns><<<totalnumsubprob, 256, sharedplanorysize, stream>>>(
          d_kx, d_ky, d_kz, d_c + t * M, d_fw + t * nf1 * nf2 * nf3, M, nf1, nf2, nf3,
          es_c, es_beta, sigma, d_binstartpts, d_binsize, bin_size_x, bin_size_y,
          bin_size_z, d_subprob_to_bin, d_subprobstartpts, d_numsubprob, maxsubprobsize,
          numbins[0], numbins[1], numbins[2], d_idxnupts);
      RETURN_IF_CUDA_ERROR
    }
  } else {
    if (const auto finufft_err =
            cufinufft_set_shared_memory(interp_3d_subprob<T, 0, ns>, 3, *d_plan)) {
      return finufft_err;
    }
    for (int t = 0; t < blksize; t++) {
      interp_3d_subprob<T, 0, ns><<<totalnumsubprob, 256, sharedplanorysize, stream>>>(
          d_kx, d_ky, d_kz, d_c + t * M, d_fw + t * nf1 * nf2 * nf3, M, nf1, nf2, nf3,
          es_c, es_beta, sigma, d_binstartpts, d_binsize, bin_size_x, bin_size_y,
          bin_size_z, d_subprob_to_bin, d_subprobstartpts, d_numsubprob, maxsubprobsize,
          numbins[0], numbins[1], numbins[2], d_idxnupts);
      RETURN_IF_CUDA_ERROR
    }
  }

  return 0;
}

template int cuinterp3d<float>(cufinufft_plan_t<float> *d_plan, int blksize);
template int cuinterp3d<double>(cufinufft_plan_t<double> *d_plan, int blksize);

} // namespace spreadinterp
} // namespace cufinufft
