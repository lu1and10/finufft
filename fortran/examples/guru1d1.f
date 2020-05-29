c     Using guru interface from fortran for 1D type 1 transforms,
c     a math test of one output, and how to change from default options.
c     Double-precision only.
c     Legacy-style: f77, plus dynamic allocation & derived types from f90.

c     To compile (linux/GCC) from this directory, use eg (paste to one line):
      
c     gfortran-9 -fopenmp -I../../include -I/usr/include guru1d1.f
c     ../../lib/libfinufft.so -lfftw3 -lfftw3_omp -lgomp -lstdc++ -o guru1d1

c     Alex Barnett and Libin Lu 5/29/20

      program guru1d1
      implicit none

c     our fortran header, only needed if want to set options...
      include 'finufft.fh'
c     if you want to use FFTW's modes by name... (hence -I/usr/include)
      include 'fftw3.f'
c     this purely for wall-clock timer...
      include 'omp_lib.h'

c     note some inputs are int (int*4) but others BIGINT (int*8)
      integer ier,iflag
      integer*8 N,ktest,M,j,k,ktestindex
      real*8, allocatable :: xj(:)
      real*8 err,tol,pi,t,fmax
      parameter (pi=3.141592653589793238462643383279502884197d0)
      complex*16, allocatable :: cj(:),fk(:)
      complex*16 fktest
      integer*8, allocatable :: n_modes(:)
      integer type,dim,ntrans

c     this is what you use as the "opaque" ptr to ptr to finufft_plan...
      integer*8 plan
c     this (since unallocated) used to pass a NULL ptr to FINUFFT...
      integer*8, allocatable :: null
c     this is how you create the options struct in fortran...
      type(nufft_opts) opts
     
c     how many nonuniform pts
      M = 1000000
c     how many modes (not too much since FFTW_MEASURE slow later)
      N = 100000

      allocate(fk(N))
      allocate(xj(M))
      allocate(cj(M))
      print *,''
      print *,'creating data then run guru interface, default opts...'
c     create some quasi-random NU pts in [-pi,pi], complex strengths
      do j = 1,M
         xj(j) = pi * dcos(pi*j/M)
         cj(j) = dcmplx( dsin((100d0*j)/M), dcos(1.0+(50d0*j)/M))
      enddo

c     ---- SIMPLEST GURU DEMO WITH DEFAULT OPTS (as in simple1d1) ---------
c     mandatory parameters to FINUFFT guru interface...
      type = 1
      dim = 1
      ntrans = 1
      iflag = 1
      tol = 1d-9
      allocate(n_modes(3))
      n_modes(1) = N
c     (note since dim=1, unused entries on n_modes are never read)
      t = omp_get_wtime()
c     null here uses default options
      call finufft_makeplan(type,dim,n_modes,iflag,ntrans,
     $     tol,plan,null,ier)
c     note for type 1 or 2, arguments 6-9 ignored...
      call finufft_setpts(plan,M,xj,null,null,null,
     $     null,null,null,ier)
c     Do it: reads cj (strengths), writes fk (mode coeffs) and ier (status)
      call finufft_exec(plan,cj,fk,ier)
      t = omp_get_wtime()-t
      if (ier.eq.0) then
         print '("done in ",f6.3," sec, ",e10.2" NU pts/s")',t,M/t
      else
         print *,'failed! ier=',ier
      endif
      call finufft_destroy(plan,ier)

      
c     math test: single output mode with given freq (not array index) k
      ktest = N/3
      fktest = dcmplx(0,0)
      do j=1,M
         fktest = fktest + cj(j) * dcmplx( dcos(ktest*xj(j)),
     $        dsin(iflag*ktest*xj(j)) )
      enddo
c     compute inf norm of fk coeffs for use in rel err
      fmax = 0
      do k=1,N
         fmax = max(fmax,cdabs(fk(k)))
      enddo
      ktestindex = ktest + N/2 + 1
      print '("rel err for mode k=",i10," is ",e10.2)',ktest,
     $     cdabs(fk(ktestindex)-fktest)/fmax

c     ----------- GURU DEMO WITH NEW OPTIONS, MULTIPLE EXECS ----------
      print *,''
      print *, 'setting new options, rerun guru interface...'
      call finufft_default_opts(opts)
c     refer to fftw3.f to set various FFTW plan modes...
      opts%fftw = FFTW_ESTIMATE_PATIENT
      opts%debug = 1
c     note you need a fresh plan if change opts
      call finufft_makeplan(type,dim,n_modes,iflag,ntrans,
     $     tol,plan,opts,ier)
      call finufft_setpts(plan,M,xj,null,null,null,
     $     null,null,null,ier)
c     Do it: reads cj (strengths), writes fk (mode coeffs) and ier (status)
      call finufft_exec(plan,cj,fk,ier)
c     change the strengths
      do j = 1,M
         cj(j) = dcmplx( dsin((10d0*j)/M), dcos(2.0+(20d0*j)/M))
      enddo
c     do another transform using same NU pts
      call finufft_exec(plan,cj,fk,ier)
c     change the NU pts then do another transform w/ existing strengths...
      do j = 1,M
         xj(j) = pi/2.0 * dcos(pi*j/M)
      enddo
      call finufft_setpts(plan,M,xj,null,null,null,
     $     null,null,null,ier)
      call finufft_exec(plan,cj,fk,ier)
      if (ier.eq.0) then
         print *,'done.'
      else
         print *,'failed! ier=',ier
      endif
      call finufft_destroy(plan,ier)
      
      stop
      end
