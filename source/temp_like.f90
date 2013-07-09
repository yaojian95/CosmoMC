    module temp_like_camspec
    !    use settings, only: MPIrank
    !use AMLutils

    implicit none

    private
    integer, parameter :: campc = KIND(1.d0)

    real(campc), dimension(:), allocatable :: X_data
    real(campc),  dimension(:,:), allocatable :: c_inv
    integer :: Nspec,nX,num_ells,nXfromdiff, CAMspec_lmax
    integer, dimension(:), allocatable  :: lminX, lmaxX, npt
    integer, parameter :: lmax_sz = 5000
    real(campc) :: sz_143_temp(lmax_sz)
    real(campc) :: ksz_temp(lmax_sz), tszxcib_temp(lmax_sz)

    real(campc), dimension(:,:), allocatable :: beam_cov,beam_cov_inv
    real(campc), dimension(:,:,:), allocatable :: beam_modes ! mode#, l, spec#
    integer :: num_modes_per_beam,beam_lmax,beam_Nspec,cov_dim

    integer, allocatable :: marge_indices(:),marge_indices_reverse(:)
    integer, allocatable :: keep_indices(:),keep_indices_reverse(:)
    real(campc), allocatable :: beam_conditional_mean(:,:)
    logical, allocatable :: want_marge(:)
    integer marge_num, keep_num

    logical :: make_cov_marged = .false.
    real(campc) :: beam_factor = 2.7_campc

    logical :: want_spec(4) = .true.
    integer :: camspec_lmins(4) =0
    integer :: camspec_lmaxs(4) =0

    logical :: storeall=.false.
    integer :: countnum
    integer :: camspec_beam_mcmc_num = 1
    !    character*100 storeroot,storename,storenumstring
    !   character*100 :: bestroot,bestnum,bestname
    character(LEN=*), parameter :: CAMSpec_like_version = 'CovSpec_v1_cuts'
    public like_init,calc_like,CAMSpec_like_version, camspec_beam_mcmc_num, &
    want_spec,camspec_lmins,camspec_lmaxs

    contains

    !!Does not seem to be actually faster
    !function CAMSpec_Quad(Mat,vec)
    !real(campc), intent(in) :: Mat(:,:)
    !real(campc) vec(:), CAMSpec_Quad
    !real(campc) Outv(nx)
    !real(campc)  mult, beta
    !real(campc) ddot
    !external ddot
    !
    !
    !mult = 1
    !beta = 0
    !call DSYMV('U',nX,mult,Mat,nX,vec, 1,beta, Outv,1)
    !CAMSpec_Quad = ddot(nX, vec, 1, outv, 1)
    !
    !end function CAMSpec_Quad

    subroutine CAMspec_ReadNormSZ(fname, templt)
    character(LEN=*), intent(in) :: fname
    real(campc) :: templt(lmax_sz)
    integer i, dummy
    real(campc) :: renorm

    open(48, file=fname, form='formatted', status='unknown')
    do i=2,lmax_sz
        read(48,*) dummy,templt(i)
        if (dummy/=i) stop 'CAMspec_ReadNormSZ: inconsistency in file read'
    enddo
    close(48)

    renorm=1.d0/templt(3000)
    templt=templt*renorm
    end subroutine CAMspec_ReadNormSZ

    subroutine like_init(like_file, sz143_file, tszxcib_file, ksz_file, beam_file)
    use MatrixUtils
    integer :: i, j,k,l
    character(LEN=1024), intent(in) :: like_file, sz143_file, ksz_file, tszxcib_file, beam_file
    logical, save :: needinit=.true.
    real(campc) , allocatable:: fid_cl(:,:), beam_cov(:,:), beam_cov_full(:,:)
    integer if1,if2, ie1, ie2, ii, jj, L2
    real(campc) :: fid_theory
    real(campc), dimension(:), allocatable :: X_data_in
    real(campc),  dimension(:,:), allocatable :: cov
    integer, allocatable :: indices(:),np(:)
    integer ix

    ! cl_ksz_148_tbo.dat file is in D_l, format l D_l, from l=2 to 10000
    ! tsz_x_cib_template.txt is is (l D_l), from l=2 to 9999, normalized to unity
    !    at l=3000

    if(.not. needinit) return

    open(48, file=like_file, form='unformatted', status='unknown')

    read(48) Nspec,nX
    allocate(lminX(Nspec))
    allocate(lmaxX(Nspec))
    allocate(np(Nspec))
    allocate(npt(Nspec))
    allocate(X_data_in(nX))
    allocate(cov(nX,nX))
    allocate(indices(nX))


    read(48) (lminX(i), lmaxX(i), np(i), npt(i), i = 1, Nspec)
    read(48) X_data_in !(X_data(i), i=1, nX)
    read(48) cov !((c_inv(i, j), j = 1, nX), i = 1,  nX) !covarianbce
    read(48) !((c_inv(i, j), j = 1, nX), i = 1,  nX) !inver covariuance
    close(48)

    !Cut on L ranges
    print *,'Determining L ranges'
    j=0
    ix=0
    npt(1)=1
    if(.not. want_spec(1)) stop 'One beam mode may not be right here'
    do i=1,Nspec
        do l = lminX(i), lmaxX(i)
            j =j+1
            if (want_spec(i) .and. (camspec_lmins(i)==0 .or. l>=camspec_lmins(i)) &
            .and. (camspec_lmaxs(i)==0 .or. l<=camspec_lmaxs(i)) ) then
                ix =ix+1
                indices(ix) = j
            end if
        end do
        if (want_spec(i)) then
            if (camspec_lmins(i)/=0) lminX(i) = max(camspec_lmins(i), lminX(i))
            if (camspec_lmaxs(i)/=0) lmaxX(i) = min(camspec_lmaxs(i), lmaxX(i))
        else
            lmaxX(i) =0
        end if
        if (i<NSpec) npt(i+1) = ix+1
        print *, 'spec ',i, 'lmin,lmax, start ix = ', lminX(i),lmaxX(i), npt(i)
    end do
    if (j/=nx) stop 'Error cutting camspec cov matrix'
    nX = ix
    allocate(X_data(nX))
    allocate(c_inv(nX,nX))
    do i=1, nX
        c_inv(:,i) = cov(indices(1:nX),indices(i))
        X_data(i) = X_data_in(indices(i))
    end do
    !    call Matrix_inverse(c_inv)
    deallocate(cov)

    CAMspec_lmax = maxval(lmaxX)
    allocate(fid_cl(CAMspec_lmax,4))
    !   allocate(fid_theory(CAMspec_lmax))

    !open(48, file='./data/base_planck_CAMspec_lowl_lowLike_highL.bestfit_cl', form='formatted', status='unknown')
    !do i=2,CAMspec_lmax
    !    read(48,*) j,fid_theory(i)
    !    if (j/=i) stop 'error reading fiducial C_l for beams'
    !enddo
    !close(48)

    open(48, file='./data/camspec_foregrounds.dat', form='formatted', status='unknown')
    do i=2,CAMspec_lmax
        read(48,*) j,fid_theory, fid_cl(i,:)
        if (j/=i) stop 'error reading fiducial foreground C_l for beams'
        fid_cl(i,:) = (fid_cl(i,:) + fid_theory)/(i*(i+1)) !want C_l/2Pi foregrounds+theory
    enddo
    close(48)

    call CAMspec_ReadNormSZ(sz143_file, sz_143_temp)
    call CAMspec_ReadNormSZ(ksz_file, ksz_temp)
    call CAMspec_ReadNormSZ(tszxcib_file, tszxcib_temp)

    open(48, file=beam_file, form='unformatted', status='unknown')
    read(48) beam_Nspec,num_modes_per_beam,beam_lmax
    if(beam_Nspec.ne.Nspec) stop 'Problem: beam_Nspec != Nspec'
    allocate(beam_modes(num_modes_per_beam,0:beam_lmax,beam_Nspec))
    cov_dim=beam_Nspec*num_modes_per_beam
    allocate(beam_cov_inv(cov_dim,cov_dim))
    allocate(beam_cov_full(cov_dim,cov_dim))
    read(48) (((beam_modes(i,l,j),j=1,Nspec),l=0,beam_lmax),i=1,num_modes_per_beam)
    read(48) ((beam_cov_full(i,j),j=1,cov_dim),i=1,cov_dim)  ! beam_cov
    read(48) ((beam_cov_inv(i,j),j=1,cov_dim),i=1,cov_dim) ! beam_cov_inv
    close(48)

    allocate(want_marge(cov_dim))
    want_marge=.true.
    want_marge(1:camspec_beam_mcmc_num)=.false.
    marge_num=count(want_marge)
    keep_num=cov_dim-marge_num
    allocate(marge_indices(marge_num))
    allocate(marge_indices_reverse(cov_dim))
    allocate(keep_indices(keep_num))
    allocate(keep_indices_reverse(cov_dim))
    print *,'beam marginalizing:',marge_num,'keeping',keep_num

    j=0
    k=0
    do i=1,cov_dim
        if (want_marge(i)) then
            j=j+1
            marge_indices(j) = i
        else
            k=k+1
            keep_indices(k)=i
        end if
        marge_indices_reverse(i)=j
        keep_indices_reverse(i)=k
    end do
    if (marge_num>0) then
        allocate(beam_cov(marge_num, marge_num))
        beam_cov = beam_cov_inv(marge_indices,marge_indices)
        call Matrix_Inverse(beam_cov)

        do if2=1,beam_Nspec
            if (want_spec(if2)) then
                do if1=1,beam_Nspec
                    if (want_spec(if1)) then
                        do ie2=1,num_modes_per_beam
                            do ie1=1,num_modes_per_beam
                                ii=ie1+num_modes_per_beam*(if1-1)
                                jj=ie2+num_modes_per_beam*(if2-1)
                                if (want_marge(ii) .and. want_marge(jj)) then
                                    do L2 = lminX(if2),lmaxX(if2)
                                        c_inv(npt(if1):npt(if1)+lmaxX(if1)-lminX(if1),npt(if2)+L2 -lminX(if2) ) = &
                                        c_inv(npt(if1):npt(if1)+lmaxX(if1)-lminX(if1),npt(if2)+L2 -lminX(if2) ) + &
                                        beam_factor**2*beam_modes(ie1,lminX(if1):lmaxX(if1),if1)* &
                                        beam_cov(marge_indices_reverse(ii),marge_indices_reverse(jj)) * beam_modes(ie2,L2,if2) &
                                        *fid_cl(L2,if2)*fid_cl(lminX(if1):lmaxX(if1),if1)
                                    end do
                                end if
                            enddo
                        enddo
                    end if
                enddo
            end if
        enddo
        ! print *,'after', c_inv(500,500), c_inv(npt(3)-500,npt(3)-502),  c_inv(npt(4)-1002,npt(4)-1000)

        allocate(beam_conditional_mean(marge_num, keep_num))
        beam_conditional_mean=-matmul(beam_cov, beam_cov_inv(marge_indices,keep_indices))

        if (make_cov_marged .and. marge_num>0) then
            if (beam_factor > 1) stop 'check you really want beam_factor>1 in output marged file'
            call Matrix_inverse(c_inv)
            open(48, file=trim(like_file)//'_beam_marged', form='unformatted', status='unknown')
            write(48) Nspec,nX
            write(48) (lminX(i), lmaxX(i), np(i), npt(i), i = 1, Nspec)
            write(48) (X_data(i), i=1, nX)
            dummy=-1
            write(48) dummy !inver covariance, assume not used
            write(48) ((c_inv(i, j), j = 1, nX), i = 1,  nX) !inver covariuance
            close(48)
            open(48, file=trim(like_file)//'_conditionals', form='formatted', status='unknown')
            do i=1, marge_num
                write(48,*) beam_conditional_mean(i,:)
            end do
            close(48)
            stop
        end if

        deallocate(beam_cov_inv)
        if (keep_num>0) then
            allocate(beam_cov_inv(keep_num,keep_num))
            beam_cov_inv = beam_cov_full(keep_indices,keep_indices)
            call Matrix_inverse(beam_cov_inv)
        end if
    end if
    call Matrix_inverse(c_inv)

    countnum=0

    needinit=.false.

    end subroutine like_init


    subroutine calc_like(zlike,  cell_cmb, freq_params)
    real(campc), intent(in)  :: freq_params(:)
    real(campc), dimension(0:) :: cell_cmb
    integer ::  j, l, ii,jj
    real(campc) , allocatable, save ::  X_beam_corr_model(:), Y(:),  C_foregrounds(:,:)
    real(campc) zlike
    real(campc) A_ps_100, A_ps_143, A_ps_217, A_cib_143, A_cib_217, A_sz, r_ps, r_cib, ncib, cal0, cal1, cal2, xi, A_ksz
    real(campc) zCIB
    real(campc) ztemp
    real(campc) beam_params(cov_dim),beam_coeffs(beam_Nspec,num_modes_per_beam)
    integer :: ie1,ie2,if1,if2, ix
    integer num_non_beam
    real(campc) cl_cib(CAMspec_lmax) !CIB
    real(campc), parameter :: sz_bandpass100_nom143 = 2.022d0
    real(campc), parameter :: cib_bandpass143_nom143 = 1.134d0
    real(campc), parameter :: sz_bandpass143_nom143 = 0.95d0
    real(campc), parameter :: cib_bandpass217_nom217 = 1.33d0
    real(campc), parameter :: ps_scale  = 1.d-6/9.d0
    real(campc) :: A_cib_217_bandpass, A_sz_143_bandpass, A_cib_143_bandpass

    !    real(campc) atime

    if (.not. allocated(lminX)) then
        print*, 'like_init should have been called before attempting to call calc_like.'
        stop
    end if
    if(Nspec.ne.4) then
        print*, 'Nspec inconsistent with foreground corrections in calc_like.'
        stop
    end if
    if (.not. allocated(Y)) then
        allocate(X_beam_corr_model(1:nX))
        allocate(Y(1:nX))
        allocate(C_foregrounds(CAMspec_lmax,Nspec))
        C_foregrounds=0
    end if

    ! atime = MPI_Wtime()

    num_non_beam = 14
    if (size(freq_params) < num_non_beam +  beam_Nspec*num_modes_per_beam) stop 'CAMspec: not enough parameters'
    A_ps_100=freq_params(1)
    A_ps_143 = freq_params(2)
    A_ps_217 = freq_params(3)
    A_cib_143 =freq_params(4)
    A_cib_217 =freq_params(5)
    A_sz = freq_params(6)  !143
    r_ps = freq_params(7)
    r_cib = freq_params(8)
    ncib = freq_params(9)
    cal0 = freq_params(10)
    cal1 = freq_params(11)
    cal2 = freq_params(12)
    xi = freq_params(13)
    A_ksz = freq_params(14)

    if (keep_num>0) then
        beam_params = freq_params(num_non_beam+1:num_non_beam+cov_dim)
        !set marged beam parameters to their mean subject to fixed non-marged modes
        if (marge_num>0) beam_params(marge_indices) = matmul(beam_conditional_mean, beam_params(keep_indices))

        do ii=1,beam_Nspec
            do jj=1,num_modes_per_beam
                ix = jj+num_modes_per_beam*(ii-1)
                beam_coeffs(ii,jj)=beam_params(ix)
            enddo
        enddo
    else
        beam_coeffs=0
    end if

    do l=1, CAMspec_lmax
        cl_cib(l) = (real(l,campc)/3000)**(ncib)
    end do

    !   100 foreground
    !
    do l = lminX(1), lmaxX(1)
        C_foregrounds(l,1)= A_ps_100*ps_scale+  &
        ( A_ksz*ksz_temp(l) + A_sz*sz_bandpass100_nom143*sz_143_temp(l) )/(l*(l+1))
        X_beam_corr_model(l-lminX(1)+1) = ( cell_cmb(l) + C_foregrounds(l,1) )* corrected_beam(1,l)/cal0
    end do

    !   143 foreground
    !
    A_sz_143_bandpass = A_sz * sz_bandpass143_nom143
    A_cib_143_bandpass = A_cib_143 * cib_bandpass143_nom143
    do l = lminX(2), lmaxX(2)
        zCIB = A_cib_143_bandpass*cl_cib(l)
        C_foregrounds(l,2)= A_ps_143*ps_scale + &
        (zCIB +  A_ksz*ksz_temp(l) + A_sz_143_bandpass*sz_143_temp(l) &
        -2.0*sqrt(A_cib_143_bandpass * A_sz_143_bandpass)*xi*tszxcib_temp(l) )/(l*(l+1))
        X_beam_corr_model(l-lminX(2)+npt(2)) =  (cell_cmb(l)+ C_foregrounds(l,2))*corrected_beam(2,l)/cal1
    end do

    !   217 foreground
    !
    A_cib_217_bandpass = A_cib_217 * cib_bandpass217_nom217
    do l = lminX(3), lmaxX(3)
        zCIB = A_cib_217_bandpass*cl_cib(l)
        C_foregrounds(l,3) = A_ps_217*ps_scale + (zCIB + A_ksz*ksz_temp(l) )/(l*(l+1))
        X_beam_corr_model(l-lminX(3)+npt(3)) = (cell_cmb(l)+ C_foregrounds(l,3))* corrected_beam(3,l)/cal2
    end do

    !   143x217 foreground
    !
    do l = lminX(4), lmaxX(4)
        zCIB = sqrt(A_cib_143_bandpass*A_cib_217_bandpass)*cl_cib(l)
        C_foregrounds(l,4) = r_ps*sqrt(A_ps_143*A_ps_217)*ps_scale + &
        ( r_cib*zCIB + A_ksz*ksz_temp(l) -sqrt(A_cib_217_bandpass * A_sz_143_bandpass)*xi*tszxcib_temp(l) )/(l*(l+1))
        X_beam_corr_model(l-lminX(4)+npt(4)) =  ( cell_cmb(l) + C_foregrounds(l,4))*corrected_beam(4,l)/sqrt(cal1*cal2)
    end do

    Y = X_data - X_beam_corr_model

    zlike = 0
    !$OMP parallel do private(j,ztemp) reduction(+:zlike) schedule(static,16)
    do  j = 1, nX
        ztemp= dot_product(Y(j+1:nX), c_inv(j+1:nX, j))
        zlike=zlike+ (ztemp*2 +c_inv(j, j)*Y(j))*Y(j)
    end do
    !    zlike = 0
    !    do  j = 1, nX
    !       ztemp= 0
    !       do  i = 1, nX
    !          ztemp = ztemp + Y(i)*c_inv(i, j)
    !       end do
    !       zlike=zlike+ztemp*Y(j)
    !    end do
    !   zlike = CAMSpec_Quad(c_inv, Y)

    if (keep_num>0) then
        do if2=1,beam_Nspec
            do if1=1,beam_Nspec
                do ie2=1,num_modes_per_beam
                    jj=ie2+num_modes_per_beam*(if2-1)
                    if (.not. want_marge(jj)) then
                        do ie1=1,num_modes_per_beam
                            ii=ie1+num_modes_per_beam*(if1-1)
                            if (.not. want_marge(ii)) then
                                zlike=zlike+beam_coeffs(if1,ie1)*&
                                beam_cov_inv(keep_indices_reverse(ii),keep_indices_reverse(jj))*beam_coeffs(if2,ie2)
                            end if
                        enddo
                    end if
                enddo
            enddo
        enddo
    end if

    if (want_spec(1)) zlike=zlike+ ((cal0/cal1-1.0006d0)/0.0004d0)**2
    if (any(want_spec(3:4))) zlike=zlike+ ((cal2/cal1-0.9966d0)/0.0015d0)**2

    contains

    real(campc) function corrected_beam(spec_num,l)
    integer, intent(in) :: spec_num,l
    integer :: i

    corrected_beam=1.d0
    do i=1,num_modes_per_beam
        corrected_beam=corrected_beam+beam_coeffs(spec_num,i)*beam_modes(i,l,spec_num)*beam_factor
    enddo
    end function corrected_beam

    end subroutine calc_like


    end module temp_like_camspec
