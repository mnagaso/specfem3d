! module for storing info. concering io
module io_server
  use specfem_par, only: CUSTOM_REAL, NPROC

  implicit none

  integer :: n_msg_seismo_each_proc=2,n_seismo_type=0
  integer :: n_procs_with_rec
  integer :: n_msg_surf_each_proc=3,surf_offset
  integer :: n_msg_shake_each_proc=3
  integer :: n_msg_vol_each_proc=0

  real(kind=CUSTOM_REAL), dimension(:,:),   allocatable   :: seismo_pres
  real(kind=CUSTOM_REAL), dimension(:,:,:), allocatable   :: seismo_disp, seismo_velo, seismo_acce
  integer, dimension(:,:), allocatable                    :: id_rec_globs

  integer                                           :: size_surf_array=0, surf_xdmf_pos
  real(kind=CUSTOM_REAL), dimension(:), allocatable :: surf_x,   surf_y,   surf_z,  &
                                                       surf_ux,  surf_uy,  surf_uz, &
                                                       shake_ux, shake_uy, shake_uz

  ! output file names
  character(len=64) :: fname_h5_seismo     = ""
  character(len=64) :: fname_h5_data_surf  = ""
  character(len=64) :: fname_h5_data_vol   = ""
  character(len=64) :: fname_h5_data_shake = ""

  character(len=64) :: fname_xdmf_surf     = ""
  character(len=64) :: fname_xdmf_vol      = ""
  character(len=64) :: fname_xdmf_vol_step = ""
  character(len=64) :: fname_xdmf_shake    = ""

contains
  function i2c(k) result(str)
  !   "Convert an integer to string."
      integer, intent(in) :: k
      character(len=20) str
      write (str, "(i20)") k
      str = adjustl(str)
  end function i2c

  function r2c(k) result(str)
  !   "Convert an real to string."
      real(kind=CUSTOM_REAL), intent(in) :: k
      character(len=20) str
      write (str, *) k
      str = adjustl(str)
  end function r2c

end module io_server


subroutine do_io_start_idle()
  use my_mpi
  use specfem_par
  use io_server

  implicit none

  integer :: ier

  ! vars seismo
  integer,dimension(0:NPROC-1) :: islice_num_rec_local
  integer                      :: status(MPI_STATUS_SIZE)
  integer                      :: rec_count_seismo=0, n_recv_msg_seismo, max_num_rec,idump,max_seismo_out=0
  integer                      :: it_offset=0, seismo_out_count=0
  integer, dimension(1)        :: nrec_temp

  ! vars surface movie
  integer                       :: rec_count_surf=0, n_recv_msg_surf,surf_out_count=0, it_io,max_surf_out=0
  integer, dimension(0:NPROC-1) :: nfaces_perproc, surface_offset

  ! vars shakemap
  integer :: rec_count_shake=0, n_recv_msg_shake, shake_out_count=0,max_shake_out=0

  ! vars volumne movie
  integer                       :: rec_count_vol=0, n_recv_msg_vol, vol_out_count=0, max_vol_out=0
  integer, dimension(0:NPROC-1) :: rec_count_vol_par_proc
  integer, dimension(0:NPROC-1) :: nelm_par_proc, nglob_par_proc ! storing the number of elements and gll nodes 
  logical, dimension(5)         :: val_type_mov ! true if movie file will be created, (pressure, div_glob, div, curlxyz, velocity_xyz)

  ! prepare for receiving message from write_seismograms
  print *, "io node is waiting for the first message"

  !
  ! initialization seismo 
  !

  ! get receiver info from compute nodes
  call get_receiver_info(islice_num_rec_local)
 
  ! initialize output file for seismo
  call do_io_seismogram_init()

  ! count the number of procs having receivers (n_procs_with_rec) 
  ! and the number of receivers on each procs (islice...)
  call count_nprocs_with_recs(islice_num_rec_local) 

  ! check the seismo types to be saved
  call count_seismo_type()
 
  ! allocate temporal arrays for seismo signals
  call allocate_seismo_arrays(islice_num_rec_local)

  ! initialize receive count
  ! count the number of messages being sent
  n_recv_msg_seismo = n_procs_with_rec*n_msg_seismo_each_proc*n_seismo_type

  max_seismo_out = int(NSTEP/NTSTEP_BETWEEN_OUTPUT_SEISMOS)
  if (mod(NSTEP,NTSTEP_BETWEEN_OUTPUT_SEISMOS) /= 0) max_seismo_out = max_seismo_out+1

  !
  ! initialize surface movie
  !
  if (MOVIE_SURFACE .or. CREATE_SHAKEMAP) then
    call surf_mov_init(nfaces_perproc, surface_offset)
    if (MOVIE_SURFACE) then
      n_recv_msg_surf = n_msg_surf_each_proc*NPROC
      print *, "surf move init done"
      call write_xdmf_surface_header()

      max_surf_out = int(NSTEP/NTSTEP_BETWEEN_FRAMES)
    endif
  !
  ! initialize shakemap
  !
    if (CREATE_SHAKEMAP) then
      call shakemap_init(nfaces_perproc, surface_offset)
      n_recv_msg_shake = n_msg_shake_each_proc*NPROC
      print *, "shakemap init done"
      max_shake_out = 1
    endif
  endif
  !
  ! initialize volume movie
  !
  if (MOVIE_VOLUME) then
    call movie_volume_init(nelm_par_proc,nglob_par_proc)
    print *, "movie volume init done"
    n_recv_msg_vol = n_msg_vol_each_proc*NPROC
    max_vol_out    = int(NSTEP/NTSTEP_BETWEEN_FRAMES)

    ! initialize rec count par processor
    rec_count_vol_par_proc(:) = 0

    ! initialize flags for the value types to be written out
    val_type_mov(:) = .false.
  endif ! if MOVIE_VOLUME

 !
 ! idling loop
 !
  do while (seismo_out_count < max_seismo_out .or. &
            surf_out_count   < max_surf_out   .or. &
            shake_out_count  < max_shake_out  .or. &
            vol_out_count    < max_vol_out)
    ! waiting for a mpi message
    call idle_mpi_io(status)

    ! debug output
    !print *,                 "msg: " , status(MPI_TAG) , " rank: ", status(MPI_SOURCE), &
    !          "  counters, seismo: " , rec_count_seismo, "/"      , n_recv_msg_seismo,  &
    !                      ", surf: " , rec_count_surf  , "/"      , n_recv_msg_surf,    &
    !                      ", shake: ", rec_count_shake , "/"      , n_recv_msg_shake,   &
    !                      ", vol: "  , rec_count_vol   , "/"      , n_recv_msg_vol

    !
    ! receive seismograms
    !

    ! receive the global id of received 
    if (status(MPI_TAG) == io_tag_seismo_ids_rec) then
      call recv_id_rec(status)
      rec_count_seismo = rec_count_seismo+1
    endif
 
    if (status(MPI_TAG) == io_tag_seismo_body_disp .or. & 
        status(MPI_TAG) == io_tag_seismo_body_velo .or. & 
        status(MPI_TAG) == io_tag_seismo_body_acce .or. & 
        status(MPI_TAG) == io_tag_seismo_body_pres      & 
    ) then
      call recv_seismo_data(status,islice_num_rec_local,rec_count_seismo)
      rec_count_seismo = rec_count_seismo+1
    endif
  
    !
    ! receive surface movie data
    !
    if (MOVIE_SURFACE) then
      if (status(MPI_TAG) == io_tag_surface_ux .or. &
          status(MPI_TAG) == io_tag_surface_uy .or. &
          status(MPI_TAG) == io_tag_surface_uz      &
      ) then
        call recv_surf_data(status, nfaces_perproc, surface_offset)
        rec_count_surf = rec_count_surf+1
      endif
    endif

    !
    ! receive shakemap data
    !
    if (CREATE_SHAKEMAP) then
      if (status(MPI_TAG) == io_tag_shake_ux .or. &
          status(MPI_TAG) == io_tag_shake_uy .or. &
          status(MPI_TAG) == io_tag_shake_uz      &
      ) then
        call recv_shake_data(status, nfaces_perproc, surface_offset)
        rec_count_shake = rec_count_shake+1
      endif
    endif

    !
    ! receive volume movie data
    !
    if (MOVIE_VOLUME) then
      if ( status(MPI_TAG) == io_tag_vol_pres    .or. &
           status(MPI_TAG) == io_tag_vol_divglob .or. &
           status(MPI_TAG) == io_tag_vol_div     .or. &
           status(MPI_TAG) == io_tag_vol_curlx   .or. &
           status(MPI_TAG) == io_tag_vol_curly   .or. &
           status(MPI_TAG) == io_tag_vol_curlz   .or. &
           status(MPI_TAG) == io_tag_vol_velox   .or. &
           status(MPI_TAG) == io_tag_vol_veloy   .or. &
           status(MPI_TAG) == io_tag_vol_veloz        &
      ) then
        it_io = NTSTEP_BETWEEN_FRAMES*(vol_out_count+1)
        call recv_write_vol_data(status,rec_count_vol,it_io,rec_count_vol_par_proc, val_type_mov)
        rec_count_vol = rec_count_vol+1
        ! finish gathering the whole data at each time step
        if (rec_count_vol == n_recv_msg_vol) then
          rec_count_vol = 0 ! reset counter
          vol_out_count = vol_out_count+1
          if (vol_out_count==1) then
            ! create xdmf header file
            call write_xdmf_vol_header(nelm_par_proc,nglob_par_proc)
         endif

         call write_xdmf_vol_body_header(it_io)
         call write_xdmf_vol_body(it_io, nelm_par_proc, nglob_par_proc, val_type_mov)
         call write_xdmf_vol_body_close()
 
        endif
      endif
    endif

    !
    ! check if all data is collected then write
    !

    ! write seismo
    if (rec_count_seismo == n_recv_msg_seismo) then
      it_offset        = seismo_out_count*NTSTEP_BETWEEN_OUTPUT_SEISMOS ! calculate the offset of timestep
      call write_seismograms_io(it_offset)
      rec_count_seismo = 0 ! reset the counter then wait for the messages of next iteration.
      seismo_out_count = seismo_out_count+1
    endif
 
    ! write surf movie
    if (MOVIE_SURFACE .and. rec_count_surf == n_recv_msg_surf) then
      it_io          = NTSTEP_BETWEEN_FRAMES*(surf_out_count+1)
      call write_surf_io(it_io)
      rec_count_surf = 0 ! reset counter
      surf_out_count = surf_out_count+1

      ! write out xdmf at each timestep
      call write_xdmf_surface_body(it_io)
    endif

    ! write shakemap
    if (CREATE_SHAKEMAP .and. rec_count_shake == n_recv_msg_shake) then
      call write_shake_io()
      rec_count_shake = 0
      shake_out_count = shake_out_count+1
      ! write out xdmf at each timestep
      call write_xdmf_shakemap()
    endif

    ! movie data will be written as soon as it is received

!    ! trigger for terminating io server
!    if (status(MPI_TAG) == io_tag_end) then
!      call recv_i_inter(idump, 1, 0, io_tag_end)
!      rec_count_seismo=n_recv_msg_seismo ! loop out
!    endif

  enddo
  ! 
  !  end of idling loop 
  ! 

  ! deallocate arrays
  call deallocate_arrays()

end subroutine do_io_start_idle


!
! volume movie
!
subroutine movie_volume_init(nelm_par_proc,nglob_par_proc)
  use io_server
  use specfem_par
  use specfem_par_elastic
  use specfem_par_poroelastic
  use specfem_par_acoustic
  use specfem_par_movie
  use phdf5_utils
  implicit none

  integer iproc

  integer, dimension(0:NPROC-1), intent(inout) :: nelm_par_proc, nglob_par_proc ! storing the number of elements and gll nodes 

  ! make output file
  character(len=64) :: group_name
  character(len=64) :: dset_name
  type(h5io)        :: h5
  h5 = h5io()

  fname_h5_data_vol = LOCAL_PATH(1:len_trim(LOCAL_PATH))//"/movie_volume.h5"

  ! initialization of h5 file
  call h5_init(h5, fname_h5_data_vol)
  ! create a hdf5 file
  call h5_create_file(h5)

  ! get n_msg_vol_each_proc
  call recv_i_inter(n_msg_vol_each_proc, 1, 0, io_tag_vol_nmsg)

  call h5_close_file(h5)

  ! get nspec and nglob from each process
  do iproc = 0, NPROC-1
    call recv_i_inter(nelm_par_proc(iproc), 1, iproc, io_tag_vol_nspec)
    call recv_i_inter(nglob_par_proc(iproc), 1, iproc, io_tag_vol_nglob)
  enddo

end subroutine movie_volume_init


subroutine recv_write_vol_data(status, rec_count_vol,it_io,rec_count_vol_par_proc,val_type_mov)
  use io_server
  use specfem_par
  use phdf5_utils
  use my_mpi
  implicit none
  
  integer, intent(in)                  :: status(MPI_STATUS_SIZE)
  integer, intent(in)                  :: rec_count_vol,it_io
  logical, dimension(5), intent(inout) :: val_type_mov
  integer, dimension(0:NPROC-1)        :: rec_count_vol_par_proc
  integer :: sender, ier, tag, arrsize, msgsize, ielm, nspecab_loc, nglobab_loc

  ! divergence and curl only in the global nodes
  real(kind=CUSTOM_REAL),dimension(:),allocatable:: temp_1d_array

  ! make output file
  character(len=10) :: tempstr
  character(len=64) :: dset_name
  character(len=64) :: group_name

  type(h5io) :: h5
  h5 = h5io()

  ! initialization of h5 file
  call h5_init(h5, fname_h5_data_vol)
  ! open hdf5 file
  call h5_open_file(h5)

  sender = status(MPI_SOURCE)
  tag    = status(MPI_TAG)
  ! get message size
  call get_size_msg(status,msgsize)

  ! create time group in h5 if this is the first message of the current iteration
  write(tempstr, "(i6.6)") it_io
  group_name = "it_"//tempstr
  if (rec_count_vol == 0) then
    ! create it group
    call h5_create_group(h5, group_name)
  endif
  call h5_open_group(h5, group_name)

  ! create or open a processor subgroup
  write(tempstr, "(i6.6)") sender
  group_name = "proc_"//tempstr
  if (rec_count_vol_par_proc(sender) == 0) then
    call h5_create_subgroup(h5, group_name)
  endif
  
  call h5_open_subgroup(h5, group_name)

  rec_count_vol_par_proc(sender) = rec_count_vol_par_proc(sender) + 1
  ! reset if this is the last message of a processor at each timestep
  if (rec_count_vol_par_proc(sender) == n_msg_vol_each_proc) rec_count_vol_par_proc(sender) = 0

  ! write
  if (tag == io_tag_vol_pres) then
    dset_name = "pressure"
    val_type_mov(1) = .true.
  elseif (tag == io_tag_vol_divglob) then
    dset_name = "div_glob"
    val_type_mov(2) = .true.
  elseif (tag == io_tag_vol_div) then
    dset_name = "div"
    val_type_mov(3) = .true.
  elseif (tag == io_tag_vol_curlx) then
    dset_name = "curl_x"
    val_type_mov(4) = .true.
  elseif (tag == io_tag_vol_curly) then
    dset_name = "curl_y"
  elseif (tag == io_tag_vol_curlz) then
    dset_name = "curl_z"
  elseif (tag == io_tag_vol_velox) then
    dset_name = "velo_x"
    val_type_mov(5) = .true.
  elseif (tag == io_tag_vol_veloy) then
    dset_name = "velo_y"
  elseif (tag == io_tag_vol_veloz) then
    dset_name = "velo_z"
  endif

  nglobab_loc = msgsize
  allocate(temp_1d_array(nglobab_loc),stat=ier)
  temp_1d_array(:) = 0._CUSTOM_REAL
  call recvv_cr_inter(temp_1d_array,msgsize,sender,tag)

  ! write
  call h5_write_dataset_1d_d(h5, dset_name, temp_1d_array)
  call h5_close_dataset(h5)

  deallocate(temp_1d_array,stat=ier)

  call h5_close_subgroup(h5)
  call h5_close_group(h5)
  call h5_close_file(h5)

end subroutine recv_write_vol_data

!
! shakemap
!
subroutine shakemap_init(nfaces_perproc, surface_offset)
  use io_server
  use phdf5_utils
  use specfem_par

  implicit none

  integer, dimension(0:NPROC-1), intent(in) :: nfaces_perproc, surface_offset
  integer                                   :: ier
  character(len=64)                         :: dset_name
  character(len=64)                         :: group_name
 
  type(h5io) :: h5
  h5 = h5io()

  fname_h5_data_shake = LOCAL_PATH(1:len_trim(LOCAL_PATH))//"/shakemap.h5"

  ! initialization of h5 file
  call h5_init(h5, fname_h5_data_shake)
  ! create a hdf5 file
  call h5_create_file(h5)

  ! information for computer node
  allocate(shake_ux(size_surf_array),stat=ier)
  allocate(shake_uy(size_surf_array),stat=ier)
  allocate(shake_uz(size_surf_array),stat=ier)

  ! write xyz coords in h5 
  group_name = "surf_coord"
  call h5_create_group(h5, group_name)
  call h5_open_group(h5, group_name)
  
  dset_name = "x"
  call h5_write_dataset_1d_d(h5, dset_name, surf_x)
  call h5_close_dataset(h5)
  dset_name = "y"
  call h5_write_dataset_1d_d(h5, dset_name, surf_y)
  call h5_close_dataset(h5)
  dset_name = "z"
  call h5_write_dataset_1d_d(h5, dset_name, surf_z)
  call h5_close_dataset(h5)
  
  call h5_close_group(h5)
  call h5_close_file(h5)

end subroutine shakemap_init

subroutine recv_shake_data(status, nfaces_perproc, surface_offset)
  use io_server
  use my_mpi
  use specfem_par  
  implicit none

  integer, dimension(0:NPROC-1), intent(in)         :: nfaces_perproc, surface_offset
  integer                                           :: ier, sender, tag, i
  integer, intent(in)                               :: status(MPI_STATUS_SIZE)
  real(kind=CUSTOM_REAL), dimension(:), allocatable :: temp_array

  sender = status(MPI_SOURCE)
  tag    = status(MPI_TAG)

  allocate(temp_array(nfaces_perproc(sender)), stat=ier)

  call recvv_cr_inter(temp_array,nfaces_perproc(sender),sender,tag)

  if (tag == io_tag_shake_ux) then
    do i = 1, size(temp_array)
      shake_ux(i+surface_offset(sender)) = temp_array(i)
    enddo
  else if (tag == io_tag_shake_uy) then
    do i = 1, size(temp_array)
      shake_uy(i+surface_offset(sender)) = temp_array(i)
    enddo
  else if (tag == io_tag_shake_uz) then
    do i = 1, size(temp_array)
      shake_uz(i+surface_offset(sender)) = temp_array(i)
    enddo
  endif

  deallocate(temp_array, stat=ier)

end subroutine recv_shake_data


subroutine write_shake_io()
  use io_server
  use phdf5_utils

  implicit none

  character(len=64) :: dset_name
  character(len=64) :: group_name
  type(h5io)        :: h5
  h5 = h5io()

  ! continue opening hdf5 file till the end of write process
  call h5_init(h5, fname_h5_data_shake)
  call h5_open_file(h5)

  ! create a group for each io step
  group_name = "shakemap"
  call h5_create_group(h5, group_name)
  call h5_open_group(h5, group_name)
  dset_name = "shakemap_ux"
  call h5_write_dataset_1d_d(h5, dset_name, shake_ux)
  call h5_close_dataset(h5)
  dset_name = "shakemap_uy"
  call h5_write_dataset_1d_d(h5, dset_name, shake_uy)
  call h5_close_dataset(h5)
  dset_name = "shakemap_uz"
  call h5_write_dataset_1d_d(h5, dset_name, shake_uz)
  call h5_close_dataset(h5)

  call h5_close_group(h5)
  call h5_close_file(h5)

end subroutine write_shake_io


!
! surface movie
!

subroutine surf_mov_init(nfaces_perproc, surface_offset)
  use io_server
  use phdf5_utils
  use specfem_par

  implicit none

  integer, dimension(0:NPROC-1), intent(in) :: nfaces_perproc, surface_offset
  integer                                   :: ier
  character(len=64)                         :: dset_name
  character(len=64)                         :: group_name
 
  type(h5io) :: h5
  h5 = h5io()

  fname_h5_data_surf = LOCAL_PATH(1:len_trim(LOCAL_PATH))//"/movie_surface.h5"

  ! initialization of h5 file
  call h5_init(h5, fname_h5_data_surf)
  ! create a hdf5 file
  call h5_create_file(h5)

  ! information for computer node
  ! get nfaces_perproc_surface
  call recv_i_inter(nfaces_perproc,NPROC,0,io_tag_surface_nfaces)
  ! get faces_surface_offset
  call recv_i_inter(surface_offset,NPROC,0,io_tag_surface_offset)

  ! get xyz coordinates
  call recv_i_inter(size_surf_array, 1, 0, io_tag_surface_coord_len)
  !print *, "size surf array received: ", size_surf_array
  allocate(surf_x(size_surf_array),stat=ier)
  allocate(surf_y(size_surf_array),stat=ier)
  allocate(surf_z(size_surf_array),stat=ier)
  allocate(surf_ux(size_surf_array),stat=ier)
  allocate(surf_uy(size_surf_array),stat=ier)
  allocate(surf_uz(size_surf_array),stat=ier)

  ! x
  call recvv_cr_inter(surf_x, size_surf_array, 0, io_tag_surface_x)
  ! y
  call recvv_cr_inter(surf_y, size_surf_array, 0, io_tag_surface_y)
  ! z
  call recvv_cr_inter(surf_z, size_surf_array, 0, io_tag_surface_z)

  ! write xyz coords in h5 
  group_name = "surf_coord"
  call h5_create_group(h5, group_name)
  call h5_open_group(h5, group_name)
  
  dset_name = "x"
  call h5_write_dataset_1d_d(h5, dset_name, surf_x)
  call h5_close_dataset(h5)
  dset_name = "y"
  call h5_write_dataset_1d_d(h5, dset_name, surf_y)
  call h5_close_dataset(h5)
  dset_name = "z"
  call h5_write_dataset_1d_d(h5, dset_name, surf_z)
  call h5_close_dataset(h5)
  
  call h5_close_group(h5)
  call h5_close_file(h5)

end subroutine surf_mov_init


subroutine recv_surf_data(status, nfaces_perproc, surface_offset)
  use io_server
  use my_mpi
  use specfem_par  
  implicit none

  integer, dimension(0:NPROC-1), intent(in)         :: nfaces_perproc, surface_offset
  integer                                           :: ier, sender, tag, i
  integer                                           :: msgsize
  integer, intent(in)                               :: status(MPI_STATUS_SIZE)
  real(kind=CUSTOM_REAL), dimension(:), allocatable :: temp_array
  sender = status(MPI_SOURCE)
  tag    = status(MPI_TAG)
 
  allocate(temp_array(nfaces_perproc(sender)), stat=ier)
  call get_size_msg(status, msgsize)
 
  call recvv_cr_inter(temp_array,nfaces_perproc(sender),sender,tag)
 
  if (tag == io_tag_surface_ux) then
    do i = 1, size(temp_array)
      surf_ux(i+surface_offset(sender)) = temp_array(i)
    enddo
  else if (tag == io_tag_surface_uy) then
    do i = 1, size(temp_array)
      surf_uy(i+surface_offset(sender)) = temp_array(i)
    enddo
  else if (tag == io_tag_surface_uz) then
    do i = 1, size(temp_array)
      surf_uz(i+surface_offset(sender)) = temp_array(i)
    enddo
  endif
 
  deallocate(temp_array, stat=ier)

end subroutine recv_surf_data


subroutine write_surf_io(it_io)
  use io_server
  use phdf5_utils

  implicit none

  integer, intent(in) :: it_io
  character(len=64)   :: dset_name
  character(len=64)   :: group_name
  character(len=10)   :: tempstr
  type(h5io)          :: h5
  h5 = h5io()

  ! continue opening hdf5 file till the end of write process
  call h5_init(h5, fname_h5_data_surf)
  call h5_open_file(h5)

  ! create a group for each io step
  write(tempstr, "(i6.6)") it_io
  group_name = "it_"//tempstr
  call h5_create_group(h5, group_name)
  call h5_open_group(h5, group_name)

  dset_name = "ux"
  call h5_write_dataset_1d_d(h5, dset_name, surf_ux)
  call h5_close_dataset(h5)
  dset_name = "uy"
  call h5_write_dataset_1d_d(h5, dset_name, surf_uy)
  call h5_close_dataset(h5)
  dset_name = "uz"
  call h5_write_dataset_1d_d(h5, dset_name, surf_uz)
  call h5_close_dataset(h5)

  call h5_close_group(h5)
  call h5_close_file(h5)

end subroutine write_surf_io

! 
! seismo
! 

subroutine get_receiver_info(islice_num_rec_local)
  use specfem_par
  use my_mpi

  implicit none

  integer                      :: ier, iproc, nrec_local_temp
  integer, dimension(1)        :: nrec_temp
  integer,dimension(0:NPROC-1) :: islice_num_rec_local
 

  call recv_i_inter(nrec_temp, 1, 0, io_tag_num_recv)
  nrec = nrec_temp(1)

  do iproc = 0, NPROC-1
    call recv_i_inter(nrec_local_temp, 1, iproc, io_tag_local_rec)
    islice_num_rec_local(iproc) = nrec_local_temp
  enddo

end subroutine get_receiver_info


subroutine allocate_seismo_arrays(islice_num_rec_local)
  use specfem_par
  use io_server

  implicit none

  integer, dimension(0:NPROC-1), intent(in) :: islice_num_rec_local
  integer                                   :: ier, max_num_rec, nstep_temp

  if (NTSTEP_BETWEEN_OUTPUT_SEISMOS >= NSTEP) then
    nstep_temp = NSTEP
  else
    nstep_temp = NTSTEP_BETWEEN_OUTPUT_SEISMOS
  endif

  ! allocate id_rec_globs for storing global id of receivers
  max_num_rec = maxval(islice_num_rec_local)
  allocate(id_rec_globs(max_num_rec,0:NPROC-1),stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array id_rec_globs')
  if (ier /= 0) stop 'error allocating array id_rec_globs'

  if (SAVE_SEISMOGRAMS_DISPLACEMENT) then
    allocate(seismo_disp(NDIM,nrec,nstep_temp),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seimo_disp')
    if (ier /= 0) stop 'error allocating array seismo_disp'
  endif
  if (SAVE_SEISMOGRAMS_VELOCITY) then
    allocate(seismo_velo(NDIM,nrec,nstep_temp),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seismo_velo')
    if (ier /= 0) stop 'error allocating array seismo_velo'
  endif
  if (SAVE_SEISMOGRAMS_ACCELERATION) then
    allocate(seismo_acce(NDIM,nrec,nstep_temp),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seismo_acce')
    if (ier /= 0) stop 'error allocating array seismo_acce'
  endif
  if (SAVE_SEISMOGRAMS_PRESSURE) then
    allocate(seismo_pres(nrec,nstep_temp),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seismo_pres')
    if (ier /= 0) stop 'error allocating array seismo_pres'
  endif

end subroutine allocate_seismo_arrays


subroutine deallocate_arrays()
  use specfem_par
  use io_server

  implicit none

  integer :: ier

  deallocate(id_rec_globs,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error deallocating array id_rec_globs')
  if (ier /= 0) stop 'error deallocating array id_rec_globs'

  deallocate(surf_x,stat=ier)
  deallocate(surf_y,stat=ier)
  deallocate(surf_z,stat=ier)

  ! surface movie
  deallocate(surf_ux,stat=ier)
  deallocate(surf_uy,stat=ier)
  deallocate(surf_uz,stat=ier)

end subroutine deallocate_arrays


subroutine count_seismo_type()
  use specfem_par
  use io_server

  implicit none

  integer :: n_type

  if (SAVE_SEISMOGRAMS_DISPLACEMENT) n_type = n_type+1
  if (SAVE_SEISMOGRAMS_VELOCITY)     n_type = n_type+1
  if (SAVE_SEISMOGRAMS_ACCELERATION) n_type = n_type+1
  if (SAVE_SEISMOGRAMS_PRESSURE)     n_type = n_type+1

  n_seismo_type = n_type

end subroutine count_seismo_type


subroutine recv_id_rec(status)
  use my_mpi
  use io_server
  use specfem_par
  implicit none

  integer, intent(in) :: status(MPI_STATUS_SIZE)
  integer             :: sender

  sender = status(MPI_SOURCE)
  call recv_i_inter(id_rec_globs(:,sender), size(id_rec_globs(:,sender)), sender, io_tag_seismo_ids_rec)

end subroutine recv_id_rec


subroutine recv_seismo_data(status, islice_num_rec_local, rec_count_seismo)
  use my_mpi
  use specfem_par
  use io_server
  implicit none

  integer, dimension(0:NPROC-1), intent(in) :: islice_num_rec_local
  integer, intent(in)                       :: status(MPI_STATUS_SIZE), rec_count_seismo

  integer :: count, rec_id_glob, sender, nrec_passed, irec_passed, tag, irec, id_rec_glob, ier
  real(kind=CUSTOM_REAL), dimension(:,:,:), allocatable :: seismo_temp
  integer                                               :: msg_size

  sender       = status(MPI_SOURCE)
  tag          = status(MPI_TAG)
  nrec_passed  = islice_num_rec_local(sender)
  call get_size_msg(status,msg_size)

  ! get vector values i.e. disp, velo, acce
  if (tag /= io_tag_seismo_body_pres) then
    ! allocate temp array size
    allocate(seismo_temp(NDIM,nrec_passed,NTSTEP_BETWEEN_OUTPUT_SEISMOS),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seismo_temp')
    if (ier /= 0) stop 'error allocating array seismo_temp'

    count = msg_size 
    call recvv_cr_inter(seismo_temp, count, sender, tag)

  ! get scalar value i.e. pres
  else
    allocate(seismo_temp(1,nrec_passed,NTSTEP_BETWEEN_OUTPUT_SEISMOS),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array seismo_temp')
    if (ier /= 0) stop 'error allocating array seismo_temp'
    count = msg_size 
    call recvv_cr_inter(seismo_temp, count, sender, tag)
  endif

  ! set local array to the global array
  do irec_passed=1,nrec_passed
    id_rec_glob = id_rec_globs(irec_passed,sender)
    ! disp
    if (tag == io_tag_seismo_body_disp) then
      seismo_disp(:,id_rec_glob,:) = seismo_temp(:,irec_passed,:)
    ! velo
    elseif (tag == io_tag_seismo_body_velo) then
      seismo_velo(:,id_rec_glob,:) = seismo_temp(:,irec_passed,:)
    ! acce
    elseif (tag == io_tag_seismo_body_acce) then
      seismo_acce(:,id_rec_glob,:) = seismo_temp(:,irec_passed,:)
    ! pres
    else
      seismo_pres(id_rec_glob,:) = seismo_temp(1,irec_passed,:)
    endif
  enddo

  ! deallocate temp array
  deallocate(seismo_temp,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error deallocating array seismo_temp')
  if (ier /= 0) stop 'error allocating dearray seismo_temp'

end subroutine recv_seismo_data


! counts number of local receivers for each slice
subroutine count_nprocs_with_recs(islice_num_rec_local)
  use my_mpi
  use specfem_par, only: nrec,NPROC
  use io_server

  implicit none

  integer, dimension(0:NPROC-1) :: islice_num_rec_local
  integer                       :: irec, iproc
  
  do iproc = 0, NPROC-1
    if (islice_num_rec_local(iproc) > 0) &
      n_procs_with_rec = n_procs_with_rec+1
  enddo

end subroutine count_nprocs_with_recs


subroutine do_io_seismogram_init()
  use specfem_par
  use phdf5_utils
  use io_server

  implicit none

  ! local parameters
  ! timing

  ! hdf5 varianles
  character(len=64) :: fname_h5_base = "seismograms.h5"
  type(h5io)        :: h5

  ! mpi variables
  integer :: info, comm, error

  ! arrays
  integer                                                 :: i, irec
  real(kind=CUSTOM_REAL), dimension(NSTEP)                :: time_array
  real(kind=CUSTOM_REAL), dimension(:,:), allocatable     :: val_array2d
  real(kind=CUSTOM_REAL), dimension(:,:,:), allocatable   :: val_array3d
  character(len=MAX_LENGTH_STATION_NAME), dimension(nrec) :: stations
  character(len=MAX_LENGTH_NETWORK_NAME), dimension(nrec) :: networks
  real(kind=CUSTOM_REAL), dimension(nrec,3)               :: rec_coords

  ! hdf5 utility
  h5 = h5io()
  fname_h5_seismo = trim(OUTPUT_FILES)//fname_h5_base

  ! initialze hdf5
  call h5_init(h5, fname_h5_seismo)

  ! create file
  call h5_create_file(h5)

  ! create time dataset it = 1 ~ NSTEP
  do i = 1, NSTEP
    if (SIMULATION_TYPE == 1) then ! forward simulation ! distinguish between single and double precision for reals 
      time_array(i) = real( dble(i-1)*DT - t0 ,kind=CUSTOM_REAL)
    else if (SIMULATION_TYPE == 3) then
      ! adjoint simulation: backward/reconstructed wavefields
      ! distinguish between single and double precision for reals
      ! note: compare time_t with time used for source term
      time_array(i) = real( dble(NSTEP-i)*DT - t0 ,kind=CUSTOM_REAL)
    endif
  enddo

  ! time array
  call h5_write_dataset_1d_d_no_group(h5, "time", time_array)
  call h5_close_dataset(h5)


  ! read out_list_stations.txt generated at locate_receivers.f90:431 here to write in the h5 file.
  open(unit=IOUT_SU,file=trim(OUTPUT_FILES)//'output_list_stations.txt', &
       status='unknown',action='read',iostat=error)
  if (error /= 0) &
    call exit_mpi(myrank,'error opening file '//trim(OUTPUT_FILES)//'output_list_stations.txt')
  ! writes station infos
  do irec=1,nrec
    read(IOUT_SU,*) stations(irec),networks(irec), rec_coords(irec, 1), rec_coords(irec, 2), rec_coords(irec, 3)
  enddo
  ! closes output file
  close(IOUT_SU)
  
  ! coordination
  call h5_write_dataset_2d_r_no_group(h5, "coords", rec_coords)
  call h5_close_dataset(h5)

  ! station name
  call h5_write_dataset_1d_c_no_group(h5, "station", stations)
  call h5_close_dataset(h5)

  ! network name
  call h5_write_dataset_1d_c_no_group(h5, "network", networks)
  call h5_close_dataset(h5)

  ! prepare datasets for physical values
  if (SAVE_SEISMOGRAMS_DISPLACEMENT) then
    allocate(val_array3d(NDIM,nrec,NSTEP),stat=error) 
    call h5_create_dataset_collect(h5, "disp", shape(val_array3d), 3, CUSTOM_REAL)
    deallocate(val_array3d)
  endif
  if (SAVE_SEISMOGRAMS_VELOCITY) then
    allocate(val_array3d(NDIM,nrec,NSTEP),stat=error)
    call h5_create_dataset_collect(h5, "velo", shape(val_array3d), 3, CUSTOM_REAL)
    deallocate(val_array3d)
  endif
  if (SAVE_SEISMOGRAMS_ACCELERATION) then
    allocate(val_array3d(NDIM,nrec,NSTEP),stat=error)
    call h5_create_dataset_collect(h5, "acce", shape(val_array3d), 3, CUSTOM_REAL)
    deallocate(val_array3d)
  endif
  if (SAVE_SEISMOGRAMS_PRESSURE) then
    allocate(val_array2d(nrec,NSTEP),stat=error)
    call h5_create_dataset_collect(h5, "pres", shape(val_array2d), 2, CUSTOM_REAL)
    deallocate(val_array2d)
  endif

end subroutine do_io_seismogram_init


subroutine write_seismograms_io(it_offset)
  use specfem_par
  use io_server
  use phdf5_utils

  implicit none

  integer, intent(in) :: it_offset
  character(len=4) component
  integer :: t_upper

  ! hdf5 vals
  type(h5io) :: h5

  ! initialze hdf5
  call h5_init(h5, fname_h5_seismo)
  call h5_open_file(h5)

  ! check if the array length to be written > total timestep
  if (it_offset+NTSTEP_BETWEEN_OUTPUT_SEISMOS > NSTEP) then
    t_upper = NSTEP - it_offset
  else
    t_upper = NTSTEP_BETWEEN_OUTPUT_SEISMOS
  endif

  ! writes out this seismogram
  if (SAVE_SEISMOGRAMS_DISPLACEMENT) then
    component = 'disp'
    call h5_write_dataset_3d_r_collect_hyperslab(h5, component, seismo_disp(:,:,1:t_upper), (/0, 0, it_offset/), .false.)
  endif
  if (SAVE_SEISMOGRAMS_VELOCITY) then
    component = 'velo'
    call h5_write_dataset_3d_r_collect_hyperslab(h5, component, seismo_velo(:,:,1:t_upper), (/0, 0, it_offset/), .false.)
  endif
  if (SAVE_SEISMOGRAMS_ACCELERATION) then
    component = 'acce'
    call h5_write_dataset_3d_r_collect_hyperslab(h5, component, seismo_acce(:,:,1:t_upper), (/0, 0, it_offset/), .false.)
  endif
  if (SAVE_SEISMOGRAMS_PRESSURE) then
    component = 'pres'
    call h5_write_dataset_2d_r_collect_hyperslab(h5, component, seismo_pres(:,1:t_upper), (/0, it_offset/), .false.)
  endif

  call h5_close_file(h5)

end subroutine write_seismograms_io

!
! xdmf output routines
!
subroutine write_xdmf_surface_header()
  use specfem_par
  use io_server
  implicit none
  integer :: num_elm

  num_elm = int(size(surf_x)/4)

  ! writeout xdmf file for surface movie
  fname_xdmf_surf = trim(OUTPUT_FILES)//"/movie_surface.xmf"

  open(unit=xdmf_surf, file=fname_xdmf_surf)

  write(xdmf_surf,'(a)') '<?xml version="1.0" ?>'
  write(xdmf_surf,*) '<!DOCTYPE Xdmf SYSTEM "Xdmf.dtd" []>'
  write(xdmf_surf,*) '<Xdmf Version="3.0">'
  write(xdmf_surf,*) '  <Domain Name="mesh">'
  write(xdmf_surf,*) '    <Topology Name="topo" TopologyType="Quadrilateral" NumberOfElements="'//trim(i2c(num_elm))//'"/>'
  write(xdmf_surf,*) '    <Geometry GeometryType="X_Y_Z">'
  write(xdmf_surf,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="' &
                                                        //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_x)))//'">'
  write(xdmf_surf,*) '        ./DATABASES_MPI/movie_surface.h5:/surf_coord/x'
  write(xdmf_surf,*) '      </DataItem>'
  write(xdmf_surf,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                        //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_y)))//'">'
  write(xdmf_surf,*) '        ./DATABASES_MPI/movie_surface.h5:/surf_coord/y'
  write(xdmf_surf,*) '      </DataItem>'
  write(xdmf_surf,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                       //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_z)))//'">'
  write(xdmf_surf,*) '        ./DATABASES_MPI/movie_surface.h5:/surf_coord/z'
  write(xdmf_surf,*) '      </DataItem>'
  write(xdmf_surf,*) '    </Geometry>'

  write(xdmf_surf,*) '    <Grid Name="fensap" GridType="Collection" CollectionType="Temporal" >'
  write(xdmf_surf,*) '    </Grid>'

  write(xdmf_surf,*) '  </Domain>'
  write(xdmf_surf,*) '</Xdmf>'
! 20 lines
  
  ! position where the additional data will be inserted
  surf_xdmf_pos = 17

  close(xdmf_surf)

end subroutine write_xdmf_surface_header


subroutine write_xdmf_surface_body(it_io)
  use specfem_par
  use io_server
 
  implicit none

  integer, intent(in) :: it_io
  integer             :: i

  character(len=20)  :: it_str
  character(len=20)  :: temp_str

  ! create a group for each io step
 
  ! open xdmf file
  open(unit=xdmf_surf, file=fname_xdmf_surf)

  ! skip lines till the position where we want to write new information
  do i = 1, surf_xdmf_pos
    read(xdmf_surf, *)
  enddo

  ! append data link of this time step
  write(it_str, "(i6.6)") it_io
  write(xdmf_surf,*) '<Grid Name="surf_mov" GridType="Uniform">'
  write(xdmf_surf,*) '  <Time Value="'//trim(r2c(sngl((it_io-1)*DT-t0)))//'" />'
  write(xdmf_surf,*) '  <Topology Reference="/Xdmf/Domain/Topology" />'
  write(xdmf_surf,*) '  <Geometry Reference="/Xdmf/Domain/Geometry" />'
  write(xdmf_surf,*) '  <Attribute Name="ux" AttributeType="Scalar" Center="Node">'
  write(xdmf_surf,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                     //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_ux)))//'">'
  write(xdmf_surf,*) '      ./DATABASES_MPI/movie_surface.h5:/it_'//trim(it_str)//'/ux'
  write(xdmf_surf,*) '    </DataItem>'
  write(xdmf_surf,*) '  </Attribute>'
  write(xdmf_surf,*) '  <Attribute Name="uy" AttributeType="Scalar" Center="Node">'
  write(xdmf_surf,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                     //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_uy)))//'">'
  write(xdmf_surf,*) '      ./DATABASES_MPI/movie_surface.h5:/it_'//trim(it_str)//'/uy'
  write(xdmf_surf,*) '    </DataItem>'
  write(xdmf_surf,*) '  </Attribute>'
  write(xdmf_surf,*) '  <Attribute Name="uz" AttributeType="Scalar" Center="Node">'
  write(xdmf_surf,*) '     <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                     //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_uz)))//'">'
  write(xdmf_surf,*) '       ./DATABASES_MPI/movie_surface.h5:/it_'//trim(it_str)//'/uz'
  write(xdmf_surf,*) '     </DataItem>'
  write(xdmf_surf,*) '  </Attribute>'
  write(xdmf_surf,*) '</Grid>'
  write(xdmf_surf,*) '</Grid>'
  write(xdmf_surf,*) '</Domain>'
  write(xdmf_surf,*) '</Xdmf>'
!
  surf_xdmf_pos = surf_xdmf_pos+20

  close(xdmf_surf)

end subroutine write_xdmf_surface_body


subroutine write_xdmf_shakemap()
  use specfem_par
  use io_server
  implicit none
  integer :: num_elm

  num_elm = int(size(surf_x)/4)

  ! writeout xdmf file for surface movie
  fname_xdmf_shake = trim(OUTPUT_FILES)//"/shakemap.xmf"

  open(unit=xdmf_shake, file=fname_xdmf_shake)

  write(xdmf_shake,'(a)') '<?xml version="1.0" ?>'
  write(xdmf_shake,*) '<!DOCTYPE Xdmf SYSTEM "Xdmf.dtd" []>'
  write(xdmf_shake,*) '<Xdmf Version="3.0">'
  write(xdmf_shake,*) '  <Domain Name="shakemap">'
  write(xdmf_shake,*) '  <Grid>'
  write(xdmf_shake,*) '    <Topology Name="topo" TopologyType="Quadrilateral" NumberOfElements="'//trim(i2c(num_elm))//'"/>'
  write(xdmf_shake,*) '    <Geometry GeometryType="X_Y_Z">'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="' &
                                                    //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_x)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/surf_coord/x'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                    //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_y)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/surf_coord/y'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                   //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(surf_z)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/surf_coord/z'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '    </Geometry>'
  write(xdmf_shake,*) '    <Attribute Name="shake_ux" AttributeType="Scalar" Center="Node">'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                  //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(shake_ux)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/shakemap/shakemap_ux'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '    </Attribute>'
  write(xdmf_shake,*) '    <Attribute Name="shake_uy" AttributeType="Scalar" Center="Node">'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                 //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(shake_uy)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/shakemap/shakemap_uy'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '    </Attribute>'
  write(xdmf_shake,*) '    <Attribute Name="shake_uz" AttributeType="Scalar" Center="Node">'
  write(xdmf_shake,*) '      <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(i2c(size(shake_uz)))//'">'
  write(xdmf_shake,*) '        ./DATABASES_MPI/shakemap.h5:/shakemap/shakemap_uz'
  write(xdmf_shake,*) '      </DataItem>'
  write(xdmf_shake,*) '    </Attribute>'
  write(xdmf_shake,*) '  </Grid>'
  write(xdmf_shake,*) '  </Domain>'
  write(xdmf_shake,*) '</Xdmf>'
  

  close(xdmf_shake)

end subroutine write_xdmf_shakemap


subroutine write_xdmf_vol_header(nelm_par_proc,nglob_par_proc)
  use specfem_par
  use io_server
  implicit none

  integer, dimension(0:NPROC-1), intent(in) :: nelm_par_proc, nglob_par_proc
  character(len=20)                         :: proc_str, it_str,nelm, nglo
  integer                                   :: iproc, iiout, nout

  ! writeout xdmf file for volume movie
  fname_xdmf_vol = trim(OUTPUT_FILES)//"/movie_volume.xmf"

  open(unit=xdmf_vol, file=fname_xdmf_vol)
 
  ! definition of topology and geometry
  ! refer only control nodes (8 or 27) as a coarse output
  ! data array need to be extracted from full data array on gll points
  write(xdmf_vol,'(a)') '<?xml version="1.0" ?>'
  write(xdmf_vol,*) '<!DOCTYPE Xdmf SYSTEM "Xdmf.dtd" []>'
  write(xdmf_vol,*) '<Xdmf xmlns:xi="http://www.w3.org/2003/XInclude" Version="3.0">'
  write(xdmf_vol,*) '<Domain>'
  write(xdmf_vol,*) '    <!-- mesh info -->'
  write(xdmf_vol,*) '    <Grid Name="mesh" GridType="Collection"  CollectionType="Spatial">'
  ! loop for writing information of mesh partitions
  do iproc=0,NPROC-1
    nelm=i2c(nelm_par_proc(iproc)*64)
    nglo=i2c(nglob_par_proc(iproc))
    write(proc_str, "(i6.6)") iproc

    write(xdmf_vol,*) '<Grid Name="mesh_'//trim(proc_str)//'">'
    write(xdmf_vol,*) '<Topology TopologyType="Mixed" NumberOfElements="'//trim(nelm)//'">'
    write(xdmf_vol,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Int" Precision="4" Dimensions="'&
                           //trim(nelm)//' 9">'
    write(xdmf_vol,*) '       ./DATABASES_MPI/external_mesh.h5:/proc_'//trim(proc_str)//'/spec_elm_conn_xdmf'
    write(xdmf_vol,*) '    </DataItem>'
    write(xdmf_vol,*) '</Topology>'
    write(xdmf_vol,*) '<Geometry GeometryType="X_Y_Z">'
    write(xdmf_vol,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                        //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
    write(xdmf_vol,*) '       ./DATABASES_MPI/external_mesh.h5:/proc_'//trim(proc_str)//'/xstore_dummy'
    write(xdmf_vol,*) '    </DataItem>'
    write(xdmf_vol,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                        //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
    write(xdmf_vol,*) '       ./DATABASES_MPI/external_mesh.h5:/proc_'//trim(proc_str)//'/ystore_dummy'
    write(xdmf_vol,*) '    </DataItem>'
    write(xdmf_vol,*) '    <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                        //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
    write(xdmf_vol,*) '       ./DATABASES_MPI/external_mesh.h5:/proc_'//trim(proc_str)//'/zstore_dummy'
    write(xdmf_vol,*) '    </DataItem>'
    write(xdmf_vol,*) '</Geometry>'
    write(xdmf_vol,*) '</Grid>'
  enddo

  ! loop for writing xml includes of timestep information
  nout = int(NSTEP/NTSTEP_BETWEEN_FRAMES) +1 
  write(xdmf_vol,*) '</Grid>' ! close mesh info
  write(xdmf_vol,*) '<!-- time series data -->'
  write(xdmf_vol,*) '<Grid Name="results" GridType="Collection" CollectionType="Temporal">'
    do iiout = 1,nout-1
      if (iiout /= nout-1) then
        write(it_str, "(i6.6)") iiout*NTSTEP_BETWEEN_FRAMES
      else
        write(it_str, "(i6.6)") NSTEP
      endif
      write(xdmf_vol,*) '    <xi:include href="it_'//trim(it_str)//'.xmf" />'
    enddo
  write(xdmf_vol,*) '</Grid>'

  write(xdmf_vol,*) '</Domain>'
  write(xdmf_vol,*) '</Xdmf>'
  
  close(xdmf_vol)

end subroutine write_xdmf_vol_header


subroutine write_xdmf_vol_body(it_io,nelm_par_proc, nglob_par_proc, val_type_mov)
  use specfem_par
  use io_server
  implicit none

  integer, intent(in)                       :: it_io
  integer, dimension(0:NPROC-1), intent(in) :: nelm_par_proc, nglob_par_proc
  logical, dimension(5), intent(in)         :: val_type_mov
  character(len=20) :: it_str, proc_str, type_str, type_str1, type_str2, nglo
  integer           :: itype,iproc

  ! writeout xdmf file for volume movie
  write(it_str, "(i6.6)") it_io

  open(unit=xdmf_vol_step, file=fname_xdmf_vol_step, position="append", action="write")


  do iproc=0, NPROC-1
    write(proc_str, "(i6.6)") iproc
    nglo=i2c(nglob_par_proc(iproc))
 
    write(xdmf_vol_step, *)  '<Grid Name="data_'//trim(proc_str)//'" Type="Uniform">'
    write(xdmf_vol_step, *)  '    <Topology Reference="/Xdmf/Domain/Grid[@Name=''mesh'']/Grid[@Name=''mesh_'&
                                      //trim(proc_str)//''']/Topology" />'
    write(xdmf_vol_step, *)  '    <Geometry Reference="/Xdmf/Domain/Grid[@Name=''mesh'']/Grid[@Name=''mesh_'&
                                      //trim(proc_str)//''']/Geometry" />'
 
    do itype=1,5
      if (val_type_mov(itype)) then
 
        if (itype < 4) then

          ! write pressure
          if (itype == 1) then
             type_str = "pressure"
          ! write div_glob
          elseif (itype == 2) then
             type_str = "div_glob"
          ! write div
          elseif (itype == 3) then
            type_str = "div"
          endif

          write(xdmf_vol_step, *)  '    <Attribute Name="'//trim(type_str)//'" AttributeType="Scalar" Center="Node">'
          write(xdmf_vol_step, *)  '        <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                              //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
          write(xdmf_vol_step, *)  '            ./DATABASES_MPI/movie_volume.h5:/it_'&
                                                 //trim(it_str)//'/proc_'//trim(proc_str)//'/'//trim(type_str)
          write(xdmf_vol_step, *)  '        </DataItem>'
          write(xdmf_vol_step, *)  '    </Attribute>'

        else  ! curl or velocity
          ! write curl xyz
          if (val_type_mov(itype) .and. itype == 4) then
            type_str  = "curl_x"
            type_str1 = "curl_y"
            type_str2 = "curl_z"
          else if (val_type_mov(itype) .and. itype == 5) then
            ! write velocity xyz
            type_str  = "velo_x"
            type_str1 = "velo_y"
            type_str2 = "velo_z"
          endif
          ! x
          write(xdmf_vol_step, *)  '    <Attribute Name="'//trim(type_str)//'" AttributeType="Scalar" Center="Node">'
          write(xdmf_vol_step, *)  '        <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
          write(xdmf_vol_step, *)  '            ./DATABASES_MPI/movie_volume.h5:/it_'&
                                                //trim(it_str)//'/proc_'//trim(proc_str)//'/'//trim(type_str)
          write(xdmf_vol_step, *)  '        </DataItem>'
          write(xdmf_vol_step, *)  '    </Attribute>'
 
          ! y
          write(xdmf_vol_step, *)  '    <Attribute Name="'//trim(type_str1)//'" AttributeType="Scalar" Center="Node">'
          write(xdmf_vol_step, *)  '        <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
          write(xdmf_vol_step, *)  '            ./DATABASES_MPI/movie_volume.h5:/it_'&
                                                //trim(it_str)//'/proc_'//trim(proc_str)//'/'//trim(type_str1)
          write(xdmf_vol_step, *)  '        </DataItem>'
          write(xdmf_vol_step, *)  '    </Attribute>'
          ! z
          write(xdmf_vol_step, *)  '    <Attribute Name="'//trim(type_str2)//'" AttributeType="Scalar" Center="Node">'
          write(xdmf_vol_step, *)  '        <DataItem ItemType="Uniform" Format="HDF" NumberType="Float" Precision="'&
                                                //trim(i2c(CUSTOM_REAL))//'" Dimensions="'//trim(nglo)//'">'
          write(xdmf_vol_step, *)  '            ./DATABASES_MPI/movie_volume.h5:/it_'&
                                                //trim(it_str)//'/proc_'//trim(proc_str)//'/'//trim(type_str2)
          write(xdmf_vol_step, *)  '        </DataItem>'
          write(xdmf_vol_step, *)  '    </Attribute>'
 
        endif
 
      endif ! if vol_type_mov == true
    enddo
    write(xdmf_vol_step, *)  '</Grid>'
  enddo

  close(xdmf_vol_step)

end subroutine write_xdmf_vol_body

subroutine write_xdmf_vol_body_header(it_io)
  use specfem_par
  use io_server
  implicit none
  integer, intent(in) :: it_io
  character(len=20)   :: it_str

  write(it_str, "(i6.6)") it_io
  fname_xdmf_vol_step = trim(OUTPUT_FILES)//"it_"//trim(it_str)//".xmf"

  open(unit=xdmf_vol_step, file=fname_xdmf_vol_step)
  write(xdmf_vol_step,*) '<Grid Name="result"  GridType="Collection"  CollectionType="Spatial">'
  write(xdmf_vol_step,*) '<Time Value="'//trim(r2c(sngl((it_io-1)*DT-t0)))//'" />'

  close(xdmf_vol_step)
end subroutine write_xdmf_vol_body_header


subroutine write_xdmf_vol_body_close()
  use specfem_par
  use io_server
  implicit none
  
  open(unit=xdmf_vol_step, file=fname_xdmf_vol_step, position="append", action="write")
  write(xdmf_vol_step, *) '</Grid>'
  close(xdmf_vol_step)
end subroutine write_xdmf_vol_body_close
 