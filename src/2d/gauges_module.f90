! ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
! ::::: Parameters, variables, subroutines related to gauges
! ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

! Contains:
!   subroutine set_gauges
!     Called initially to read from gauges.data
!   subroutine setbestsrc
!     Called each time regridding is done to determine which patch to 
!     use for interpolating to each gauge location.
!   subroutine print_gauges
!     Called each time step for each grid patch.
!     Refactored dumpgauge routine to interpolate for all gauges on patch.
!
!     Note: by default all components of q are printed at each gauge.
!     To print something different or a different precision, modify 
!     format statement 100 and/or the write statement that uses it.
!   
! Note: Updated for Clawpack 5.3.0:
!   - the dumpgauge and setbestsrc subroutines have been moved to this module 
!     and the dumpgauge subroutine has been refactored and renamed print_gauges.
!   - dumpgauge.f must be removed from Makefiles.
!   - setbestsrc uses quicksort to sort gauge numbers and
!     then figures out which gauges will be updated by grid, and stores this
!     information in new module variables mbestg1, mbestg2.
!   - print_gauges no longer uses binary search to locate first gauge handled
!     by a grid.  Instead loop over gauges specified by mbestg1, mbestg2.
!
! Note: Updated for Clawpack 5.4.0
!   - refactor so each gauge writes to its own file, and batches the writes instead of 
!     writing one at a time. This will remove the critical section and should speed up gauges a lot
!   - When array is filled, that gauge will write to file and start over. 
!   - Need to save index so know position in array where left off
!   - At checkpoint times, dump all gauges
!
! Note: Updated for Clawpack 5.4.x
!  - Add gauge formatting capabilities

module gauges_module

    implicit none
    save

    logical, private :: module_setup = .false.

    integer, parameter :: OUTGAUGEUNIT = 89
    integer :: num_gauges

    integer, parameter :: MAX_BUFFER = 1000

    ! Gauge data types
    type gauge_type
        ! Gauge number
        integer :: gauge_num

        character(len=14) :: file_name

        ! Location in time and space
        real(kind=8) :: x, y, t_start, t_end

        ! Last time recorded
        real(kind=8) :: last_time

        ! Output settings
        integer :: file_format
        real(kind=8) :: min_time_increment
        character(len=10) :: display_format
        logical, allocatable :: q_out_vars(:)
        logical, allocatable :: aux_out_vars(:)
        integer :: num_out_vars

        ! Data buffers - data holds output and time
        real(kind=8), allocatable :: data(:, :)
        integer :: level(MAX_BUFFER)

        ! Where we are in the buffer
        integer :: buffer_index
    end type gauge_type

    ! Gague array
    type(gauge_type), allocatable :: gauges(:)

    ! Gauge source info
    integer, allocatable, dimension(:) ::  mbestsrc, mbestorder, &
                          igauge, mbestg1, mbestg2

contains

    subroutine set_gauges(restart, num_eqn, num_aux, fname)

        use amr_module, only: maxgr
        use utility_module, only: get_value_count

        implicit none

        ! Input
        logical, intent(in) :: restart
        integer :: num_eqn, num_aux
        character(len=*), intent(in), optional :: fname

        ! Locals
        integer :: i, n, index
        integer :: num, pos, digit
        integer, parameter :: UNIT = 7
        character(len=128) :: header_1
        character(len=40) :: q_column, aux_column

        if (.not. module_setup) then

            ! Open file
            if (present(fname)) then
                call opendatafile(UNIT, fname)
            else
                call opendatafile(UNIT, 'gauges.data')
            endif

            read(UNIT, *) num_gauges
            allocate(gauges(num_gauges))
            
            ! Initialize gauge source data
            allocate(mbestsrc(num_gauges), mbestorder(num_gauges))
            allocate(mbestg1(maxgr), mbestg2(maxgr))
            mbestsrc = 0
            
            ! Original gauge information
            do i=1,num_gauges
                read(UNIT, *) gauges(i)%gauge_num, gauges(i)%x, gauges(i)%y, &
                              gauges(i)%t_start, gauges(i)%t_end
                gauges(i)%buffer_index = 1
                gauges(i)%last_time = gauges(i)%t_start
            enddo

            ! Read in output formats
            read(UNIT, *)
            read(UNIT, *)
            read(UNIT, *) (gauges(i)%file_format, i=1, num_gauges)
            read(UNIT, *)
            read(UNIT, *)
            read(UNIT, *) (gauges(i)%display_format, i=1, num_gauges)
            read(UNIT, *)
            read(UNIT, *)
            read(UNIT, *) (gauges(i)%min_time_increment, i=1, num_gauges)

            ! Read in q fields
            read(UNIT, *)
            read(UNIT, *)
            do i = 1, num_gauges
                allocate(gauges(i)%q_out_vars(num_eqn))
                read(UNIT, *) gauges(i)%q_out_vars

                ! Count number of vars to be output
                gauges(i)%num_out_vars = 0
                do n = 1, size(gauges(i)%q_out_vars, 1)
                    if (gauges(i)%q_out_vars(n)) then
                        gauges(i)%num_out_vars = gauges(i)%num_out_vars + 1
                    end if
                end do
            end do

            ! Read in aux fields
            if (num_aux > 0) then
                read(UNIT, *)
                read(UNIT, *)
                do i = 1, num_gauges
                    allocate(gauges(i)%aux_out_vars(num_aux))
                    read(UNIT, *) gauges(i)%aux_out_vars

                    ! Count number of vars to be output
                    do n = 1, size(gauges(i)%aux_out_vars, 1)
                        if (gauges(i)%aux_out_vars(n)) then
                            gauges(i)%num_out_vars = gauges(i)%num_out_vars + 1
                        end if
                    end do
                end do
            end if

            close(UNIT)
            ! Done reading =====================================================

            ! Allocate data buffer
            do i = 1, num_gauges
                allocate(gauges(i)%data(gauges(i)%num_out_vars + 1, MAX_BUFFER))
            end do

            ! Create gauge output files
            do i = 1, num_gauges
                gauges(i)%file_name = 'gaugexxxxx.txt'
                num = gauges(i)%gauge_num
                do pos = 10, 6, -1
                    digit = mod(num,10)
                    gauges(i)%file_name(pos:pos) = char(ichar('0') + digit)
                    num = num / 10
                end do

                ! Handle restart
                if (restart) then
                    open(unit=OUTGAUGEUNIT, file=gauges(i)%file_name,       &
                         status='old', position='append', form='formatted')
                else
                    open(unit=OUTGAUGEUNIT, file=gauges(i)%file_name,       &
                         status='unknown', position='append', form='formatted')
                    rewind OUTGAUGEUNIT

                    ! Write header
                    header_1 = "('# gauge_id= ',i5,' " //                   &
                               "location=( ',1e15.7,' ',1e15.7,' ) " //     &
                               "num_var= ',i2)"
                    write(OUTGAUGEUNIT, header_1) gauges(i)%gauge_num,      &
                                                  gauges(i)%x,              &
                                                  gauges(i)%y,              &
                                                  gauges(i)%num_out_vars

                    ! Construct column labels
                    index = 0
                    q_column = "["
                    do n=1, size(gauges(i)%q_out_vars, 1)
                        if (gauges(i)%q_out_vars(n)) then
                            write(q_column(3 * index + 2:4 + 3 * index), "(i3)") n
                            index = index + 1
                        end if  
                    end do
                    q_column(3 * index + 2:4 + 3 * index) = "]"

                    aux_column = "["
                    index = 0
                    if (allocated(gauges(i)%aux_out_vars)) then
                        do n=1, size(gauges(i)%aux_out_vars, 1)
                            if (gauges(i)%aux_out_vars(n)) then
                                write(aux_column(3 * index + 2:4 + 3 * index), "(i3)") n
                                index = index + 1
                            end if  
                        end do
                    end if
                    aux_column(3 * index + 2:4 + 3 * index) = "]"

                    write(OUTGAUGEUNIT, "(a,a,a,a)") "# level, time, q",      &
                                               trim(q_column), ", aux",       &
                                               trim(aux_column)
               endif

               close(OUTGAUGEUNIT)

            end do

            module_setup = .true.
        end if

    end subroutine set_gauges


!
! --------------------------------------------------------------------
!
    subroutine setbestsrc()
!
!     Called every time grids change, to set the best source grid patch
!     for each gauge, i.e. the finest level patch that includes the gauge.
!
!     lbase is grid level that didn't change, but since fine
!     grid may have disappeared, we still have to look starting
!     at coarsest level 1.
!
        use amr_module
        implicit none

        integer :: lev, mptr, i, k1, ki

!
! ##  set source grid for each loc from coarsest level to finest.
! ##  that way finest src grid left and old ones overwritten
! ##  this code uses fact that grids do not overlap

! # for debugging, initialize sources to 0 then check that all set
        mbestsrc = 0

        do lev = 1, lfine  
            mptr = lstart(lev)
            do
                do i = 1, num_gauges
                    if ((gauges(i)%x >= rnode(cornxlo,mptr)) .and. &
                        (gauges(i)%x <= rnode(cornxhi,mptr)) .and. &  
                        (gauges(i)%y >= rnode(cornylo,mptr)) .and. &
                        (gauges(i)%y <= rnode(cornyhi,mptr)) ) then
                        mbestsrc(i) = mptr
                    end if
                end do
                mptr = node(levelptr, mptr)
                if (mptr == 0) exit
            end do 
        end do


        do i = 1, num_gauges
          if (mbestsrc(i) .eq. 0) &
              print *, "ERROR in setting grid src for gauge data", i
        end do

        ! Sort the source arrays for easy testing during integration
        call qsorti(mbestorder,num_gauges,mbestsrc)

!     After sorting,  
!           mbestsrc(mbestorder(i)) = grid index to be used for gauge i
!     and mbestsrc(mbestorder(i)) is non-decreasing as i=1,2,..., num_gauges

!     write(6,*) '+++ mbestorder: ',mbestorder
!     write(6,*) '+++ mbestsrc: ',mbestsrc

!     Figure out the set of gauges that should be handled on each grid:  
!     after loop below, grid k should handle gauges numbered
!          mbestorder(i) for i = mbestg1(k), mbestg1(k)+1, ..., mbestg2(k)
!     This will be used for looping in print_gauges subroutine.

      ! initialize arrays to default indicating grids that contain no gauges:
        mbestg1 = 0
        mbestg2 = 0

        k1 = 0
        do i=1,num_gauges
            ki = mbestsrc(mbestorder(i))
            if (ki > k1) then
                ! new grid number seen for first time in list
                if (k1 > 0) then
                    ! mark end of gauges seen by previous grid
                    mbestg2(k1) = i-1
!                     write(6,*) '+++ k1, mbestg2(k1): ',k1,mbestg2(k1)
                endif
                mbestg1(ki) = i
!               write(6,*) '+++ ki, mbestg1(ki): ',ki,mbestg1(ki)
            endif
           k1 = ki
        enddo
        if (num_gauges > 0) then
            ! finalize 
            mbestg2(ki) = num_gauges
!           write(6,*) '+++ ki, mbestg2(ki): ',ki,mbestg2(ki)
        endif
    end subroutine setbestsrc

!
! -------------------------------------------------------------------------
!
    subroutine update_gauges(q, aux, xlow, ylow, num_eqn, mitot, mjtot, num_aux, &
                             mptr)
        !
        ! This routine is called each time step for each grid patch, to output
        ! gauge values for all gauges for which this patch is the best one to 
        ! use (i.e. at the finest refinement level).  
        
        ! It is called after ghost cells have been filled from adjacent grids
        ! at the same level, so bilinear interpolation can be used to 
        ! to compute values at any gauge location that is covered by this grid.  
        
        ! The grid patch is designated by mptr.
        ! We only want to set gauges i for which mbestsrc(i) == mptr.
        ! The array mbestsrc is reset after each regridding to indicate which
        ! grid patch is best to use for each gauge.
        
        ! This is a refactoring of dumpgauge.f from Clawpack 5.2 
        ! Loops over only the gauges to be handled by this grid, as specified
        ! by indices from mbestg1(mptr) to mbestg2(mptr)

        use amr_module, only: nestlevel, nghost, timemult, rnode, node, maxvar
        use amr_module, only: maxaux, hxposs, hyposs

        implicit none
        
        ! Input
        integer, intent(in) ::  num_eqn, mitot, mjtot, num_aux, mptr
        real(kind=8), intent(in) :: q(num_eqn, mitot, mjtot)
        real(kind=8), intent(in) :: aux(num_aux, mitot, mjtot)
        real(kind=8), intent(in) :: xlow, ylow
        
        ! Locals
        real(kind=8) :: var(maxvar + maxaux)
        real(kind=8) :: xcent, ycent, xoff, yoff, tgrid, hx, hy
        integer :: i, j, i1, i2, iindex, jindex, n, ii, index, level, var_index

        ! No gauges to record, exit
        if (num_gauges == 0) then
            return
        endif

        i1 = mbestg1(mptr)
        i2 = mbestg2(mptr)

        if (i1 == 0) then
            ! no gauges to be handled by this grid
            return
        endif

        ! Grid info
        tgrid = rnode(timemult, mptr)
        level = node(nestlevel, mptr)
        hx = hxposs(level)
        hy = hyposs(level)

        ! Main Gauge Loop ======================================================
        do i = i1, i2
            ii = mbestorder(i)
            if (mptr /= mbestsrc(ii)) then
                print *, '*** should not happen... i, ii, mbestsrc(ii), mptr:'
                print *, i, ii, mbestsrc(ii), mptr
                stop
            endif
            if (tgrid < gauges(ii)%t_start .or. tgrid > gauges(ii)%t_end) then
               cycle
            endif
            ! Minimum increment
            ! TODO Maybe always allow last time output recording?
            if (tgrid - gauges(ii)%last_time < gauges(ii)%min_time_increment) then
                cycle
            end if

            ! Compute indexing and bilinear interpolant weights
            ! Note: changed 0.5 to  0.5d0 etc.
            iindex =  int(.5d0 + (gauges(ii)%x - xlow) / hx)
            jindex =  int(.5d0 + (gauges(ii)%y - ylow) / hy)
            if ((iindex < nghost .or. iindex > mitot-nghost) .or. &
                (jindex < nghost .or. jindex > mjtot-nghost)) then
                    print *, "ERROR in output of Gauge Data "
            end if
            xcent  = xlow + (iindex - 0.5d0) * hx
            ycent  = ylow + (jindex - 0.5d0) * hy
            xoff   = (gauges(ii)%x - xcent) / hx
            yoff   = (gauges(ii)%y - ycent) / hy

            ! Gauge interpolation seems to work, so error test is commented out.
            ! For debugging, use the code below...
            !   Note: we expect 0 <= xoff, yoff <= 1 but if gauge is exactly 
            !   at center of cell these might be off by rounding error

            !if (xoff .lt. -1.d-4 .or. xoff .gt. 1.0001d0 .or. &
            !    yoff .lt. -1.d-4 .or. yoff .gt. 1.0001d0) then
            !   write(6,*) "*** print_gauges: Interpolation problem at gauge ",&
            !               igauge(ii)
            !   write(6,*) "    xoff,yoff: ", xoff,yoff
            !endif

            ! Bilinear interpolation
            var_index = 0
            do n = 1, size(gauges(ii)%q_out_vars, 1)
                if (gauges(ii)%q_out_vars(n)) then
                    var_index = var_index + 1
                    var(var_index) = (1.d0 - xoff) * (1.d0 - yoff) * q(n, iindex, jindex) &
                                        + xoff * (1.d0 - yoff) * q(n, iindex + 1, jindex) &
                                        + (1.d0 - xoff) * yoff * q(n, iindex, jindex + 1) &
                                        + xoff * yoff * q(n, iindex + 1, jindex + 1)
                endif
            end do

            if (allocated(gauges(ii)%aux_out_vars)) then
                do n = 1, size(gauges(ii)%aux_out_vars, 1)
                    if (gauges(ii)%aux_out_vars(n)) then
                        var_index = var_index + 1
                        var(var_index) = (1.d0 - xoff) * (1.d0 - yoff) * aux(n, iindex, jindex) &
                                            + xoff * (1.d0 - yoff) * aux(n, iindex + 1, jindex) &
                                            + (1.d0 - xoff) * yoff * aux(n, iindex, jindex + 1) &
                                            + xoff * yoff * aux(n, iindex + 1, jindex + 1)
                    endif
                end do
            end if

            ! Check to make sure we grabbed all the values
            if (gauges(ii)%num_out_vars /= var_index) then
                print *, gauges(ii)%num_out_vars, var_index
                print *, gauges(ii)%q_out_vars
                print *, gauges(ii)%aux_out_vars
                stop "Somehow we did not grab all the values we wanted..."
            end if

            ! Zero out tiny values to prevent underflow problems
            do j = 1, gauges(ii)%num_out_vars
                if (abs(var(j)) < 1d-90) var(j) = 0.d0
            end do

           ! save info for this time
           index = gauges(ii)%buffer_index
     
            gauges(ii)%level(index) = level
            gauges(ii)%data(1,index) = tgrid
            do j = 1, gauges(ii)%num_out_vars
                gauges(ii)%data(1 + j, index) = var(j)
            end do
            
            gauges(ii)%buffer_index = index + 1
            if (gauges(ii)%buffer_index > MAX_BUFFER) then
                call print_gauges_and_reset_nextLoc(ii)  
            endif

            gauges(ii)%last_time = tgrid

        end do ! End of gauge loop =============================================

    end subroutine update_gauges
!
! -------------------------------------------------------------------------
!
      subroutine print_gauges_and_reset_nextLoc(gauge_num)
        ! Write out gauge data for the gauge specified

        implicit none

        ! Input
        integer, intent(in) :: gauge_num

        ! Locals
        integer :: j, k, myunit
        integer :: omp_get_thread_num, mythread
        character(len=32) :: out_format

        ! Open unit dependent on thread number
        mythread = 0
!$      mythread = omp_get_thread_num()
        myunit = OUTGAUGEUNIT + mythread

        ! ASCII output
        if (gauges(gauge_num)%file_format == 1) then
            ! Construct output format based on number of output variables and
            ! request format
            write(out_format, "(A7, i2, A6, A1)") "(i5.2,",         &
               gauges(gauge_num)%num_out_vars + 1, gauges(gauge_num)%display_format, ")"

            open(unit=myunit, file=gauges(gauge_num)%file_name, status='old', &
                              position='append', form='formatted')
          
            ! Loop through gauge's buffer writing out all available data.  Also
            ! reset buffer_index back to beginning of buffer since we are emptying
            ! the buffer here
            do j = 1, gauges(gauge_num)%buffer_index - 1
                write(myunit, out_format) gauges(gauge_num)%level(j),    &
                    (gauges(gauge_num)%data(k, j), k=1, gauges(gauge_num)%num_out_vars + 1)
            end do
            gauges(gauge_num)%buffer_index = 1                        

            ! close file
            close(myunit)
        else
            print *, "Unhandled file format ", gauges(gauge_num)%file_format
            stop
        end if

    end subroutine print_gauges_and_reset_nextLoc

end module gauges_module
