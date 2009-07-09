module lanczos
!
! abstract: Contains variables and routines for preconditioned
!           Lanczos minimizer following Mike Fisher's algorithm.
!
! program history log:
!   2007-05-16  tremolet
!   2007-07-11  tremolet - increment sensitivity to obs
!   2007-11-23  todling  - add timers
!   2009-01-18  todling  - minimal changes to interface w/ quad-based evaljgrad
!                          NOTE: no attempt made to reproduce across pe's yet
!
! Subroutines Included:
!   congrad       - Main minimization routine
!   setup_precond - Prepare the preconditioner
!   save_precond  - Save eigenvectors for constructing the next preconditioner
!   precond       - Preconditioner itself (called from congrad, internal)
!
! Variable Definitions:
!   LMPCGL  : .T. ====> precondition conjugate-gradient minimization
!   R_MAX_CNUM_PC : Maximum allowed condition number for the preconditioner
!   NPCVECS : number of vectors which make up the preconditioner
!
!   YVCGLPC: eigenvectors (from an earlier minimization)
!            that are used to construct the preconditioner.
!   RCGLPC : eigenvalues (from an earlier minimization)
!            that are used to construct the preconditioner.
!   NVCGLPC: the number of eigenpairs used to form the preconditioner.
!
!   YVCGLEV: eigenvectors for the current minimization.
!   RCGLEV : eigenvalues for the current minimization.
!   NVCGLEV: the number of eigenpairs for the current minimization.
!
!   YVCGLWK: work array of eigenvectors
!
! ------------------------------------------------------------------------------
use kinds, only: r_kind,i_kind,r_quad
use constants, only: zero, one, half, two
use jfunc, only: iter
use control_vectors
use file_utility, only : get_lun
use timermod, only: timer_ini, timer_fnl
! ------------------------------------------------------------------------------

implicit none
save
private
public congrad, setup_congrad, save_precond, congrad_ad, read_lanczos

! ------------------------------------------------------------------------------

logical :: LMPCGL = .false.
real(r_kind) :: R_MAX_CNUM_PC = 10.0_r_kind
real(r_kind) :: xmin_ritz = 1.0_r_kind
real(r_kind) :: pkappa = 0.1_r_kind

integer(i_kind) :: NPCVECS, NVCGLPC, NVCGLEV, NWRVECS
REAL(r_kind), ALLOCATABLE :: RCGLPC(:)
REAL(r_kind), ALLOCATABLE :: RCGLEV(:)

integer(i_kind) :: mype,nprt,jiter,maxiter
logical :: l4dvar,lanczosave
REAL(r_kind), allocatable :: zlancs(:,:)

TYPE(control_vector), ALLOCATABLE, DIMENSION(:) :: YVCGLPC
TYPE(control_vector), ALLOCATABLE, DIMENSION(:) :: YVCGLEV
TYPE(control_vector), ALLOCATABLE, DIMENSION(:) :: YVCGLWK
type(control_vector), allocatable, dimension(:) :: cglwork

! --------------------------------------
REAL             :: Z_DEFAULT_REAL      ! intentionally not real(r_kind)
integer(i_kind), PARAMETER :: N_DEFAULT_REAL_KIND = KIND(Z_DEFAULT_REAL)
DOUBLE PRECISION :: DL_DOUBLE_PRECISION ! intentionally not real(r_double)
integer(i_kind), PARAMETER :: N_DOUBLE_KIND       = KIND(DL_DOUBLE_PRECISION)
! --------------------------------------

! ------------------------------------------------------------------------------
contains
! ------------------------------------------------------------------------------
! CONGRAD
! ------------------------------------------------------------------------------
subroutine setup_congrad(kpe,kprt,kiter,kiterstart,kmaxit,kwrvecs, &
                         ld4dvar,ldsave)
implicit none
integer(i_kind), intent(in) :: kpe,kprt,kiter,kiterstart,kmaxit,kwrvecs
logical, intent(in) :: ld4dvar,ldsave
integer(i_kind) :: ii

mype=kpe
nprt=kprt
jiter=kiter
maxiter=kmaxit
nwrvecs=kwrvecs
l4dvar=ld4dvar
lanczosave=ldsave

if (allocated(zlancs)) deallocate(zlancs)
allocate(zlancs(maxiter+1,4))
zlancs=zero

allocate(cglwork(maxiter+1))
DO ii=1,kmaxit+1
  CALL allocate_cv(cglwork(ii))
  cglwork(ii)=zero
ENDDO

if (jiter==kiterstart) then
  NPCVECS=0
  NVCGLPC=0
  NVCGLEV=0
endif

if (jiter>1) call setup_precond()

if (mype==0) write(6,*)'setup_congrad end'
call inquire_cv

end subroutine setup_congrad
! ------------------------------------------------------------------------------
subroutine congrad(xhat,pcost,gradx,preduc,kmaxit,iobsconv,lsavevecs)

IMPLICIT NONE

type(control_vector), intent(inout) :: xhat
real(r_kind)    , intent(out) :: pcost
type(control_vector), intent(inout) :: gradx
real(r_kind)    , intent(inout) :: preduc
integer(i_kind) , intent(inout) :: kmaxit
integer(i_kind) , intent(in) :: iobsconv
logical, intent(in) :: lsavevecs

character(len=*), parameter :: myname='congrad'
type(control_vector) :: grad0,zww
type(control_vector) :: xiter,xsens
real(r_quad)    :: pcostq
real(r_kind)    :: zbeta(2:kmaxit+1),zdelta(kmaxit),zv(kmaxit+1,kmaxit+1),&
 & zbnds(kmaxit),zritz(kmaxit+1),zsave(kmaxit+1,4),&
 & zqg0(kmaxit+1), zsstwrk(2*kmaxit)
real(r_kind)    :: zdla, zbetad, zz, zeta
real(r_kind)    :: zbndlm, zgnorm, znorm2l1, zreqrd, ztheta1, za
real(r_kind)    :: zcost, zgrad
integer(i_kind) :: ing,ingood,itheta1,jm,imaxevecs,ii,jj,jk,isize
integer(i_kind) :: kminit, kmaxevecs,iunit
logical :: lsavinc, lldone
character(len=17) :: clfile

! --------------------------------------

!--- initialize timer
  call timer_ini('congrad')

kminit = kmaxit
kmaxevecs = kmaxit
lldone=.false.
if (kmaxit>maxiter) then
  write(6,*)'setup_congrad: kmaxit>maxiter',kmaxit,maxiter
  call stop2(138)
end if

if (mype==0) write(6,*) '---- Lanczos Solver ----'

!--- allocate distributed storage

call allocate_cv(grad0)
call allocate_cv(zww)

!--- 'zeta' is an upper bound on the relative error of the gradient.

zeta  = 1.0e-4_r_kind

zreqrd = preduc

!--- change of variable to account for preconditioning

if (LMPCGL) call precond(xhat,+2)

zgnorm = SQRT( DOT_PRODUCT (gradx,gradx))

if (mype==0) write (6,*)'grepmin Starting point: Estimated gradient norm=',zgnorm

if (LMPCGL) call precond(gradx,-2)

cglwork(1) = gradx
znorm2l1 = DOT_PRODUCT(cglwork(1),cglwork(1))
cglwork(1)%values = cglwork(1)%values / SQRT(znorm2l1)

!--- save initial control vector and gradient

grad0 = gradx

zqg0(1) = DOT_PRODUCT(cglwork(1),grad0)

!--- Lanczos iteration starts here

ingood = 0
iter   = 1
Lanczos_loop : DO

!--- evaluate the Hessian applied to the latest Lanczos vector

  do jj=1,zww%lencv
    zww%values(jj) = xhat%values(jj) + cglwork(iter)%values(jj)
  enddo

  if (LMPCGL) call precond(zww,-2)

  lsavinc=.false.
  call evaljgrad(zww,pcostq,gradx,lsavinc,nprt,myname)
  pcost=pcostq

  if (LMPCGL) call precond(gradx,-2)

  do jj=1,gradx%lencv
    gradx%values(jj) = gradx%values(jj) - grad0%values(jj)
  enddo

!--- calculate zdelta

  zdelta(iter) = DOT_PRODUCT(cglwork(iter),gradx)

  if (zdelta(iter)<=zero) then
    if (mype==0) write(6,*)'congrad stopping: J" not positive definite',zdelta(iter)
    iter = iter-1
    EXIT Lanczos_loop
  endif

!--- Calculate the new Lanczos vector (This is the Lanczos recurrence)

  do jj=1,gradx%lencv
    gradx%values(jj) = gradx%values(jj) - zdelta(iter) * cglwork(iter)%values(jj)
  enddo
  if (iter>1) then
    do jj=1,gradx%lencv
      gradx%values(jj) = gradx%values(jj) - zbeta(iter) * cglwork(iter-1)%values(jj)
    enddo
  endif

!--- orthonormalize gradient against previous gradients

  do jm=iter,1,-1
    zdla = DOT_PRODUCT(gradx,cglwork(jm))
    do jj=1,gradx%lencv
      gradx%values(jj) = gradx%values(jj) - zdla*cglwork(jm)%values(jj)
    enddo
  enddo

  zbeta(iter+1) = SQRT(DOT_PRODUCT(gradx,gradx))

  do jj=1,gradx%lencv
    cglwork(iter+1)%values(jj) = gradx%values(jj) / zbeta(iter+1)
  enddo

  zqg0(iter+1) = DOT_PRODUCT(cglwork(iter+1),grad0)

!--- calculate the reduction in the gradient norm and cost

  zlancs(1:iter,1) =  zdelta(1:iter)
  zlancs(2:iter,2) =  zbeta (2:iter)
  zlancs(1:iter,3) = -zqg0  (1:iter)

  call ptsv

  do jj=1,zww%lencv
    zww%values(jj) = grad0%values(jj) &
                 & + (zbeta(iter+1)*zlancs(iter,3))*cglwork(iter+1)%values(jj)
  enddo

  do jj=1,iter
    do ii=1,zww%lencv
      zww%values(ii)  = zww%values(ii)  - cglwork(jj)%values(ii)*zqg0(jj)
    enddo
  enddo

  if (LMPCGL) call precond(zww,+2)

  preduc = SQRT(DOT_PRODUCT(zww,zww))
  if (mype==0) write (6,*)'grepmin Estimated gradient norm=',preduc

  preduc = preduc/zgnorm
  if (mype==0) write (6,*)'Estimated reduction in norm of gradient is: ',preduc

!--- determine eigenvalues and eigenvectors of the tri-diagonal problem

  zlancs(1:iter  ,4) = zdelta(1:iter)
  zlancs(1:iter-1,1) = zbeta (2:iter)

  if (iter /= 1) then
    call steqr
  else
    zv(1,1) = one
  endif

  zritz(1:iter) = zlancs(1:iter,4)

  if (mype==0) write(6,*)'congrad: ritz values are: ',zritz(1:iter)

!--- estimate error bounds

  zbndlm = zeta*zritz(iter)

  zbnds(1:iter) = abs(zbeta(iter+1)*zv(iter,1:iter))
  if (mype==0) write (6,*)'congrad: error bounds are: ',zbnds(1:iter)

!--- Check for exploding or negative Ritz values

  if (ANY(zritz(1:iter)<zero)) then
    if (mype==0) write(6,*)'congrad stopping: negative ritz value'
    iter = iter-1
    zlancs(1:iter  ,4) = zdelta(1:iter)
    zlancs(1:iter-1,1) = zbeta(2:iter)

    if (iter > 1) then
      call steqr
    else
      zv(1,1) = one
    endif

    zritz(1:iter) = zlancs(1:iter,4)

    zbnds(1:iter) = abs(zbeta(iter+1)*zv(iter,1:iter))
    EXIT Lanczos_loop
  endif

  if (ingood>0) then
    if (zritz(itheta1)>1.01_r_kind*ztheta1) then
      if (mype==0) write(6,*)'congrad stopping: ritz values exploding'
      if (mype==0) write(6,*)'leading ritz value=',zritz(itheta1)
      if (mype==0) write(6,*)'leading converged eigenvalue=',ztheta1
    endif
  endif

!--- Count the converged eigenvectors

  ingood = 0
  do jm=1,iter
    if (zbnds(jm)<=zbndlm) then
      ingood = ingood+1
      if (mype==0) write(6,*)'congrad: converged eigenvalue ',zritz(jm)
    endif
  enddo

!--- save leading converged eigenvalue for explosion test

  if (ingood > 0) then
    do jm=iter,1,-1
      if (zbnds(jm) <= zbndlm) then
        ztheta1 = zritz(jm)
        itheta1 = jm
        exit
      endif
    enddo
  endif

  if (mype==0) write(6,*)'congrad: End of iteration: ',iter
  if (mype==0) write(6,'(/)')

! count how many eigenpairs have converged to PKAPPA precision and have
! eigenvalue > xmin_ritz (which is 1 by default)
! (For the analysis, all eigenvalues should be >1. For the singular vector calculation,
! we are not interested in decaying modes.)
! However, when SVs are computed with projection operators, 1 may not
! be an appropriate choice for xmin_ritz

  imaxevecs = COUNT(zbnds(1:iter)/zritz(1:iter)<=pkappa .AND. zritz(1:iter)>xmin_ritz)

! Tests for end of iterations
  if (iter >= kmaxit .or. (preduc <= zreqrd .and. iter >= kminit)) &
    & EXIT Lanczos_loop

  if (imaxevecs >= kmaxevecs) then
    if (mype==0) write(6,*)imaxevecs,' eigenpairs converged to precision ',pkappa
    if (mype==0) write(6,'(/)')
    EXIT Lanczos_loop
  endif

! Test convergence in observation space
  if (iobsconv>=2) then

!   Compute actual increment
    zsave=zlancs
    zlancs(1:iter,1) =  zdelta(1:iter)
    zlancs(2:iter,2) =  zbeta (2:iter)
    zlancs(1:iter,3) = -zqg0  (1:iter)
    call ptsv

    call allocate_cv(xiter)
    call allocate_cv(xsens)
    xiter=zero
    do jj=1,iter
      do ii=1,xiter%lencv
        xiter%values(ii) = xiter%values(ii)  + cglwork(jj)%values(ii)*zlancs(jj,3)
      enddo
    enddo
    if (LMPCGL) call precond(xiter,-2)
    xsens=xiter

!   Compute observation impact
    call congrad_ad(xsens,iter)
    call test_obsens(xiter,xsens)

!   Clean-up
    call deallocate_cv(xiter)
    call deallocate_cv(xsens)
    zlancs=zsave
  endif

!--- Increment the iteration counter

  iter = iter+1
  if (ingood>0) itheta1 = itheta1+1

ENDDO Lanczos_loop

!--- end of Lanczos iteration

lldone=.true.

if (mype==0) then
  write(6,*)'Summary of Lanczos iteration:'
  write(6,*)'   Number of iterations performed: ',iter
  write(6,*)'   Maximum allowed number of iterations: ',kmaxit
  write(6,*)'   Minimum allowed number of iterations: ',kminit
  write(6,*)'   Required reduction in norm of gradient: ',zreqrd
  write(6,*)'   Achieved reduction in norm of gradient: ',preduc
  if (preduc > zreqrd) then
    write(6,*)'   *** Failed to meet convergence criterion ***'
  endif
  write(6,*)'   Number of sufficiently-converged eigenpairs: ',imaxevecs
endif

!--- Calculate the solution vector and gradient

zlancs(1:iter,1) =  zdelta(1:iter)
zlancs(2:iter,2) =  zbeta (2:iter)
zlancs(1:iter,3) = -zqg0  (1:iter)

call ptsv

do jj=1,gradx%lencv
  gradx%values(jj) = grad0%values(jj) &
                 & + zbeta(iter+1)*cglwork(iter+1)%values(jj)*zlancs(iter,3)
enddo

do jj=1,iter
  do ii=1,xhat%lencv
    xhat%values(ii)  = xhat%values(ii)  + cglwork(jj)%values(ii)*zlancs(jj,3)
    gradx%values(ii) = gradx%values(ii) - cglwork(jj)%values(ii)*zqg0(jj)
  enddo
enddo

!--- transform control variable and gradient back to unpreconditioned space

if (LMPCGL) then
  call precond(xhat,-2)
  call precond(gradx,+2)
endif

!--- Compute observation impact
if (iobsconv>=1) then
  call allocate_cv(xsens)
  xsens=xhat

  call congrad_ad(xsens,iter)
  call test_obsens(xhat,xsens)

  call deallocate_cv(xsens)
endif

!--- Save lanczos vectors (if required for adjoint)

if (lanczosave) then
  do jj=1,iter
    clfile='lanczvec.XXX.YYYY'
    WRITE(clfile(10:12),'(I3.3)') jiter
    WRITE(clfile(14:17),'(I4.4)') jj
    call write_cv(cglwork(jj),clfile)
  ENDDO

  if (mype==0) then
    iunit=get_lun()
    clfile='zlanczos.XXX'
    WRITE(clfile(10:12),'(I3.3)') jiter
    write(6,*)'Writing Lanczos coef. to file ',clfile

    open(iunit,file=trim(clfile),form='unformatted')
    write(iunit)maxiter
    write(iunit)zlancs(1:maxiter+1,1:4)
    close(iunit)
  endif
endif

!--- Calculate sufficiently converged eigenvectors of the preconditioned Hessian

if (lsavevecs) then
  zbnds(1:iter) = zbnds(1:iter)/zritz(1:iter)

  NVCGLEV = 0
  do jk=iter,1,-1
    if (zbnds(jk) <= pkappa .AND. zritz(jk) > xmin_ritz) then
      NVCGLEV=NVCGLEV+1
    endif
  ENDDO
  if (mype==0) write(6,*) &
    & 'Number of eigenpairs converged to requested accuracy NVCGLEV=',NVCGLEV

  ALLOCATE(RCGLEV(NVCGLEV))
  ALLOCATE (YVCGLEV(NVCGLEV))
  DO ii=1,NVCGLEV
    CALL allocate_cv(YVCGLEV(ii))
  ENDDO

  ii=0
  do jk=iter,1,-1
    if (zbnds(jk) <= pkappa .AND. zritz(jk) > xmin_ritz) then
      ii = ii+1
      RCGLEV(ii) = zritz(jk)
      YVCGLEV(ii) = zero
      isize=size(YVCGLEV(ii)%values)
      do jm=1,iter
        do jj=1,isize
          YVCGLEV(ii)%values(jj)=YVCGLEV(ii)%values(jj) + cglwork(jm)%values(jj)*zv(jm,jk)
        enddo
      enddo

      do jm=1,ii-1
        zdla=DOT_PRODUCT (YVCGLEV(jm),YVCGLEV(ii))
        do jj=1,isize
          YVCGLEV(ii)%values(jj) = YVCGLEV(ii)%values(jj) - zdla*YVCGLEV(jm)%values(jj)
        enddo
      enddo

      zdla=DOT_PRODUCT (YVCGLEV(ii),YVCGLEV(ii))
      YVCGLEV(ii)%values = YVCGLEV(ii)%values / sqrt(zdla)
    endif
  ENDDO

  if (mype==0.and.NVCGLEV>0) then
    write(6,'(/)')
    write(6,*)'Calculated eigenvectors for the following eigenvalues:'
    write(6,*)'RCGLEV=',RCGLEV(1:NVCGLEV)
    write(6,'(/)')
  endif

endif

!--- release memory, etc.

call deallocate_cv(grad0)
call deallocate_cv(zww)

!--- return the number of iterations actually performed

kmaxit=iter

!--- finalize timer
  call timer_fnl('congrad')

return

!-----------------------------------------------------------------------
contains
!-----------------------------------------------------------------------
!   STEQR - Simplified interface to LAPACK routines SSTEQR/DSTEQR
!-----------------------------------------------------------------------
subroutine steqr

integer(i_kind) :: info

if (r_kind == N_DEFAULT_REAL_KIND) then
  call SSTEQR ('I',iter,zlancs(1,4),zlancs,zv,kmaxit+1,zsstwrk,info)
ELSEIF (r_kind == N_DOUBLE_KIND) then
  call DSTEQR ('I',iter,zlancs(1,4),zlancs,zv,kmaxit+1,zsstwrk,info)
else
  write(6,*)'steqr: r_kind is neither default real nor double precision'
  call stop2(319)
endif

if (info /= 0) then
  write (6,*) 'Error in congrad: SSTEQR/DSTEQR returned info=',info
  write(6,*) 'steqr: SSTEQR/DSTEQR returned non-zero info'
  call stop2(320)
endif

end subroutine steqr

!-----------------------------------------------------------------------
!   PTSV - Simplified interface to LAPACK routines SPTSV/DPTSV
!-----------------------------------------------------------------------
subroutine ptsv

integer(i_kind) :: info

if (r_kind == N_DEFAULT_REAL_KIND) then
  call SPTSV (iter,1,zlancs(1,1),zlancs(2,2),zlancs(1,3),kmaxit+1,info)
ELSEIF (r_kind == N_DOUBLE_KIND) then
  call DPTSV (iter,1,zlancs(1,1),zlancs(2,2),zlancs(1,3),kmaxit+1,info)
else
  write(6,*) 'r_kind is neither default real nor double precision'
  call stop2(321)
endif

if (info /= 0) then
  write (6,*) 'Error in congrad: SPTSV/DPTSV returned ',info
  write(6,*)'CONGRAD: SPTSV/DPTSV returned non-zero info'
  call stop2(322)
endif

end subroutine ptsv

! ------------------------------------------------------------------------------
end subroutine congrad
! ------------------------------------------------------------------------------

! ------------------------------------------------------------------------------
subroutine congrad_ad(xsens,kiter)

! abstract: Apply product of adjoint of estimated Hessian to a vector.

implicit none
type(control_vector), intent(inout) :: xsens
integer(i_kind), intent(in) :: kiter

real(r_kind) :: zaa(kiter),zzz
integer(i_kind) :: ii,jj

!--- initialize timer
call timer_ini('congrad_ad')

zzz=dot_product(xsens,xsens)
if (mype==0) write(6,888)'congrad_ad: Norm  input=',sqrt(zzz)

if (LMPCGL) call precond(xsens,-2)

zaa=zero
do jj=1,kiter
  zaa(jj)=dot_product(xsens,cglwork(jj))
enddo
do jj=2,kiter
  zaa(jj)=zaa(jj)-zlancs(jj,2)*zaa(jj-1)
enddo
zaa(kiter)=zaa(kiter)/zlancs(kiter,1)
do jj=kiter-1,1,-1
  zaa(jj)=zaa(jj)/zlancs(jj,1) - zaa(jj+1)*zlancs(jj+1,2)
enddo
xsens=zero
do jj=1,kiter
  do ii=1,xsens%lencv
    xsens%values(ii) = xsens%values(ii) + zaa(jj) * cglwork(jj)%values(ii)
  enddo
enddo

if (LMPCGL) call precond(xsens,-2)

zzz=dot_product(xsens,xsens)
if (mype==0) write(6,888)'congrad_ad: Norm output=',sqrt(zzz)
888 format(A,3(1X,ES24.18))

!--- finalize timer
call timer_fnl('congrad_ad')

return
end subroutine congrad_ad
! ------------------------------------------------------------------------------

! ------------------------------------------------------------------------------
!   SAVE_PRECOND - Save eigenvectors from CONGRAD for next minimization
! ------------------------------------------------------------------------------
subroutine save_precond(ldsave)

IMPLICIT NONE

logical, intent(in) :: ldsave

REAL(r_kind), ALLOCATABLE :: zmat(:,:)
INTEGER(i_kind) :: ii,jj, info, iunit, ivecs
REAL(r_kind) :: zz
CHARACTER(LEN=13) :: clfile

if (ldsave) then

!--- read eigenvalues of the preconditioner

  NPCVECS = NVCGLEV+NVCGLPC
  if (mype==0) write(6,*)'save_precond: NVCGLEV,NVCGLPC,NPCVECS=', &
                                      & NVCGLEV,NVCGLPC,NPCVECS

  ALLOCATE(YVCGLWK(npcvecs))
  ii=0

!--- copy preconditioner vectors to work file

  if (mype==0.and.NVCGLPC>0) write(6,*)'save_precond: RCGLPC=',RCGLPC
  DO jj=1,NVCGLPC
    ii=ii+1
    zz=sqrt(RCGLPC(jj)-one)
    CALL allocate_cv(YVCGLWK(ii))
    YVCGLWK(ii)%values = zz * YVCGLPC(jj)%values
    CALL deallocate_cv(YVCGLPC(jj))
  ENDDO
  IF (ALLOCATED(YVCGLPC)) DEALLOCATE(YVCGLPC)
  IF (ALLOCATED( RCGLPC)) deallocate( RCGLPC)
  NVCGLPC=0

!--- copy and transform eigenvectors of preconditioned Hessian

  if (mype==0.and.NVCGLEV>0) write(6,*)'save_precond: RCGLEV=',RCGLEV
  DO jj=1,NVCGLEV
    ii=ii+1
    zz=sqrt(RCGLEV(jj)-one)
    CALL allocate_cv(YVCGLWK(ii))
    YVCGLWK(ii)%values = zz * YVCGLEV(jj)%values
    CALL deallocate_cv(YVCGLEV(jj))
  ENDDO
  IF (ALLOCATED(YVCGLEV)) DEALLOCATE(YVCGLEV)
  IF (ALLOCATED( RCGLEV)) deallocate( RCGLEV)
  NVCGLEV=0

  if (mype==0) write(6,*)'save_precond: NVCGLPC,NVCGLEV,npcvecs,ii=', &
                                        NVCGLPC,NVCGLEV,npcvecs,ii
  if (ii/=npcvecs) then
    write(6,*)'save_precond: error number of vectors',ii,npcvecs
    call stop2(139)
  end if

!---  form the inner matrix for the Shermann-Morrison-Woodbury inversion

  ALLOCATE(zmat(npcvecs,npcvecs))
  do jj=1,npcvecs
    do ii=jj,npcvecs
      zmat(ii,jj) = DOT_PRODUCT (YVCGLWK(jj),YVCGLWK(ii))
    ENDDO
    zmat(jj,jj) = zmat(jj,jj) + one
  ENDDO

!--- Cholesky decompose

  if (mype==0) write(6,*)'save_precond: call dpotrf npcvecs=',npcvecs
  if (r_kind==N_DEFAULT_REAL_KIND) then
    call SPOTRF('L',npcvecs,zmat,npcvecs,info)
  ELSEIF (r_kind==N_DOUBLE_KIND) then
    call DPOTRF('L',npcvecs,zmat,npcvecs,info)
  else
    write(6,*)'save_precond: r_kind is neither default real nor double precision'
    call stop2(323)
  endif

  if (info/=0) then
    write(6,*)'save_precond: error computing Cholesky decomposition'
    write(6,*)'SPOTRF/DPOTRF returns info=',info
    call stop2(324)
  endif

!--- transform vectors

  do jj=1,npcvecs
    do ii=1,jj-1
      YVCGLWK(jj)%values = YVCGLWK(jj)%values - zmat(jj,ii)*YVCGLWK(ii)%values
    enddo
    YVCGLWK(jj)%values = YVCGLWK(jj)%values / zmat(jj,jj)
  ENDDO

!--- Save the eigenvectors

  if (l4dvar) then
    ivecs=MIN(npcvecs,nwrvecs)
    DO jj=1,ivecs
      clfile='evec.XXX.YYYY'
      WRITE(clfile(6:8) ,'(I3.3)') jiter
      WRITE(clfile(10:13),'(I4.4)') jj
      call write_cv(YVCGLWK(jj),clfile)
    ENDDO

    if (mype==0) then
      iunit=78
      clfile='numpcvecs.XXX'
      WRITE(clfile(11:13),'(I3.3)') jiter
      open(iunit,file=clfile)
      write(iunit,*)ivecs
      close(iunit)
    endif

    DO ii=1,npcvecs
      CALL deallocate_cv(YVCGLWK(ii))
    ENDDO
    DEALLOCATE(YVCGLWK)
  else
    do ii=nwrvecs+1,npcvecs
      CALL deallocate_cv(YVCGLWK(ii))
    enddo
    npcvecs=MIN(npcvecs,nwrvecs)
  endif

  DEALLOCATE(zmat)
endif

do ii=1,maxiter+1
  call deallocate_cv(cglwork(ii))
enddo
deallocate(cglwork)

return
end subroutine save_precond

! ------------------------------------------------------------------------------
!   SETUP_PRECOND - Calculates the preconditioner for congrad
! ------------------------------------------------------------------------------
subroutine setup_precond()

IMPLICIT NONE

INTEGER(i_kind), allocatable :: indarr(:)
REAL(r_kind), allocatable :: zq(:),zlam(:),zU(:,:),zUUT(:,:),zwork(:),zzz(:)
INTEGER(i_kind) :: info,ik,inpcv,ji,jj,jk,ii,iunit
REAL(r_kind) :: za, zps
CHARACTER(LEN=13) :: clfile

!--- read vectors, apply change of variable and copy to work file

if (l4dvar) then
  iunit=78
  clfile='numpcvecs.XXX'
  WRITE(clfile(11:13),'(I3.3)') jiter-1
  open(iunit,file=clfile)
  read(iunit,*)npcvecs
  close(iunit)

  if (npcvecs<1) then
    write(6,*)'setup_precond: no vectors for preconditioner',npcvecs
    call stop2(140)
  end if

  ALLOCATE(YVCGLWK(npcvecs))
  DO ii=1,npcvecs
    CALL allocate_cv(YVCGLWK(ii))
  ENDDO

  do jj=1,npcvecs
    clfile='evec.XXX.YYYY'
    WRITE(clfile(6:8) ,'(I3.3)') jiter-1
    WRITE(clfile(10:13),'(I4.4)') jj
    call read_cv(yvcglwk(jj),clfile)
  ENDDO
endif

allocate(indarr(npcvecs))
allocate(zq(npcvecs),zlam(npcvecs),zU(npcvecs,npcvecs))
allocate(zUUT(npcvecs,npcvecs),zwork(3*npcvecs),zzz(npcvecs))

!--- Perform Householder transformations to reduce the matrix of vectors
!--- to upper triangular

do jj=1,npcvecs
  CALL ALLGATHER_CVSECTION(yvcglwk(jj),zq(1:jj),1,jj)

  zps = DOT_PRODUCT(yvcglwk(jj),yvcglwk(jj)) - DOT_PRODUCT(zq(1:jj),zq(1:jj))

  if (zq(jj) < zero) then
    zU(jj,jj) = -sqrt(zps+zq(jj)*zq(jj))
  else
    zU(jj,jj) =  sqrt(zps+zq(jj)*zq(jj))
  endif

  zq(jj) = zq(jj) - zU(jj,jj)

  do jk=1,jj-1
    zU(jk,jj) = zq(jk)
  ENDDO

  zps = zps + zq(jj)*zq(jj)

  zzz(1:jj-1)=zero
  zzz(jj)=zq(jj)
  CALL SET_CVSECTION(zzz(1:jj),yvcglwk(jj),1,jj)

  do jk=1,yvcglwk(jj)%lencv
    yvcglwk(jj)%values(jk) = yvcglwk(jj)%values(jk) * sqrt(two/zps)
  enddo

!--- we now have the Householder vector in yvcglwk(jj), and the non-zero
!--- elements of the transformed vector in ZU. Now apply the Householder
!--- transformations to the remaining vectors.

  do ji=jj+1,npcvecs
    zps = DOT_PRODUCT (yvcglwk(jj),yvcglwk(ji))
    do jk=1,yvcglwk(ji)%lencv
      yvcglwk(ji)%values(jk) = yvcglwk(ji)%values(jk) - zps*yvcglwk(jj)%values(jk)
    enddo
  ENDDO
ENDDO

!--- Multiply the upper triangle by its transpose and find eigenvectors
!--- and eigenvalues

do jj=1,npcvecs
  do ji=jj+1,npcvecs
    zU(ji,jj) = zero
  enddo
enddo

do jj=1,npcvecs
  do ji=jj,npcvecs
    zUUT(ji,jj) = zero
    do jk=ji,npcvecs
      zUUT(ji,jj) = zUUT(ji,jj) + zU(ji,jk)*zU(jj,jk)
    ENDDO
  ENDDO
ENDDO

if (r_kind==N_DEFAULT_REAL_KIND) then
  call SSYEV('V','L',npcvecs,zUUT,npcvecs,zlam,zwork,SIZE(zwork),info)
ELSEIF (r_kind==N_DOUBLE_KIND) then
  call DSYEV('V','L',npcvecs,zUUT,npcvecs,zlam,zwork,SIZE(zwork),info)
else
  write(6,*)'setup_precond: r_kind is neither default real nor double precision'
  call stop2(325)
endif

if (info/=0) then
  write(6,*)'setup_precond: SSYEV/DSYEV returned with info=',info
  write(6,*)'setup_precond: SSYEV/DSYEV returned non-zero return code'
  call stop2(326)
endif

!--- convert to eigenvalues of the preconditioner

do jk=1,npcvecs
  zlam(jk) = one / (one - zlam(jk))
ENDDO

if (mype==0) write(6,*)'setup_precond: eigenvalues found are: ',(zlam(ji),ji=1,npcvecs)

!--- sort eigenvalues with eigenvalues larger than 1 after eigenvalues
!--- smaller than 1 and with eigenvalues larger than 1 sorted in decreasing
!--- order

do ji=1,npcvecs
  indarr(ji) = ji
ENDDO

!--- straight insertion sort courtesy of Numerical Recipies

do jj=2,npcvecs
  za = zlam(jj)
  ik = indarr(jj)
  do ji=jj-1,1,-1
    if (zlam(ji)>one .and. (zlam(ji)>=za .or. za<=one)) then
      ii=ji
      exit
    else
      ii=0
    endif
    zlam(ji+1) = zlam(ji)
    indarr(ji+1) = indarr(ji)
  ENDDO
  zlam(ii+1) = za
  indarr(ii+1) = ik
ENDDO

inpcv = npcvecs

do while (zlam(inpcv) <= zero)
  if (mype==0) write(6,*)'Warning - eigenvalue less than 1: ',zlam(inpcv)
  inpcv = inpcv-1
  if (inpcv == 0) then
    if (mype==0) write(6,*)'setup_precond: cannot form preconditioner - '//&
     & 'no positive eigenvalues.'
    if (mype==0) write(6,*)'setup_precond: minimisation will not be preconditioned.'
    EXIT
  endif
enddo

IF (inpcv>0) THEN
  if (mype==0) write(6,*)'Number of preconditioning vectors selected is ',inpcv
  if (mype==0) write(6,*)'setup_precond: selected eigenvalues are: ',(zlam(ji),ji=1,inpcv)

  IF (ALLOCATED(YVCGLPC)) THEN
    DO jj=1,NVCGLPC
      CALL DEALLOCATE_CV(YVCGLPC(jj))
    ENDDO
    DEALLOCATE(YVCGLPC)
    NVCGLPC=0
  ENDIF
  IF (ALLOCATED(RCGLPC)) DEALLOCATE(RCGLPC)

!--- Save eigenvalues
  NVCGLPC = inpcv
  ALLOCATE (RCGLPC(NVCGLPC))
  RCGLPC(:) = MIN(R_MAX_CNUM_PC,zlam(1:NVCGLPC))

  ALLOCATE (YVCGLPC(NVCGLPC))
  DO jj=1,NVCGLPC
    CALL ALLOCATE_CV(YVCGLPC(jj))
  ENDDO

!--- apply Householder transformations to the eigenvectors to get the
!--- eigenvectors of the preconditioner

  DO jj=1,NVCGLPC
    YVCGLPC(jj) = zero
    CALL SET_CVSECTION(zuut(1:npcvecs,indarr(jj)),YVCGLPC(jj),1,npcvecs)

    do ji=npcvecs,1,-1
      zps = DOT_PRODUCT (yvcglwk(ji),YVCGLPC(jj))
      do jk=1,YVCGLPC(jj)%lencv
        YVCGLPC(jj)%values(jk) = YVCGLPC(jj)%values(jk) - zps*yvcglwk(ji)%values(jk)
      enddo
    ENDDO
  ENDDO
  LMPCGL = .true.
ELSE
  NVCGLPC = 0
  LMPCGL = .false.
ENDIF

DO jj=1,npcvecs
  CALL DEALLOCATE_CV(YVCGLWK(jj))
ENDDO
DEALLOCATE(YVCGLWK)
deallocate(indarr)
deallocate(zq,zlam,zU,zUUT,zwork,zzz)
NPCVECS = 0

return
end subroutine setup_precond

! ------------------------------------------------------------------------------
!   PRECOND - Preconditioner for minimization
! ------------------------------------------------------------------------------
subroutine precond(ycvx,kmat)

IMPLICIT NONE

TYPE(CONTROL_VECTOR),INTENT(INOUT) :: ycvx
INTEGER(i_kind),INTENT(IN) :: kmat

REAL(r_kind) :: zevals(NVCGLPC),zdp(NVCGLPC)
INTEGER(i_kind) :: jk, ji

if     (kmat== 1) then
  zevals(:) = RCGLPC(:)
ELSEIF (kmat==-1) then
  zevals(:) = one/RCGLPC(:)
ELSEIF (kmat== 2) then
  zevals(1:NVCGLPC) = sqrt(RCGLPC(:))
ELSEIF (kmat==-2) then
  zevals(1:NVCGLPC) = one/sqrt(RCGLPC(:))
else
  write(6,*)'Error: invalid value for kmat in precond: ',kmat
  write(6,*)'PRECOND: invalid value for kmat' 
  call stop2(327)
endif

do jk=1,NVCGLPC
  zdp(jk) = (zevals(jk)-one)*DOT_PRODUCT(ycvx,YVCGLPC(jk))
enddo

DO jk=1,NVCGLPC
  DO ji=1,ycvx%lencv
    ycvx%values(ji) = ycvx%values(ji) + YVCGLPC(jk)%values(ji) * zdp(jk)
  ENDDO
ENDDO

return
end subroutine precond
! ------------------------------------------------------------------------------
subroutine read_lanczos(kmaxit)

IMPLICIT NONE
integer(i_kind) , intent(inout) :: kmaxit
integer(i_kind) :: jj, iunit, kiter, ilen
character(len=17) :: clfile

if (kmaxit>maxiter) then
  write(6,*) 'read_lanczos: kmaxit>maxiter',kmaxit,maxiter
  call stop2(141)
end if

do jj=1,kmaxit
  clfile='lanczvec.XXX.YYYY'
  write(clfile(10:12),'(I3.3)') jiter
  write(clfile(14:17),'(I4.4)') jj
  call read_cv(cglwork(jj),clfile)
enddo

if (mype==0) then
  iunit=get_lun()
  clfile='zlanczos.XXX'
  WRITE(clfile(10:12),'(I3.3)') jiter
  write(6,*)'Reading Lanczos coef. from file ',clfile

  open(iunit,file=trim(clfile),form='unformatted')
  read(iunit)kiter
  if (kiter>maxiter) then
     write(6,*)'read_laczos: kiter>maxiter',kiter,maxiter
     call stop2(142)
  end if
  read(iunit)zlancs(1:kiter+1,1:4)
  close(iunit)
endif
ilen=(kmaxit+1)*4
call mpl_bcast(0,ilen,zlancs)

end subroutine read_lanczos
! ------------------------------------------------------------------------------
end module lanczos