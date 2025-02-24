program main
    !ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    !c
    !c       main program for the 1&1/2 layer redu!ced gravity model
    !c
    !c
    !c
    !c
    !c
    !ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

    use size_mod, only : isc, iec, jsc, jec, isd, ied, jsd, jed, halo, i, iday_start, itimer2, &
        itimermax, itimerrate, j, k, loop, loop_start, lpd, lpm, month, month_start, month_wind, & 
        taum, taun, taup, taus, time_switch, tracer_switch, iday_wind, rkmh, rkmu, rkmv, rkmt, kclim, &
        imt, jmt, km, gdx, gdy, kmaxMYM, dz, nn, lm, gdxb, gdyb, t, eta, u, v, temp, h, pvort, salt, &
        dxu, dyv, omask, uvel, vvel, smcoeff, SHCoeff, diag_ext1, diag_ext2, diag_ext3, diag_ext4, &
        diag_ext5, diag_ext6, sphm, uwnd, vwnd, airt, ssw, cld, pme, chl, rvr, taux_force, tauy_force, &
        init_size, denss, rmld_misc, rdx, rdy, rkmt, we_upwel, wd, we, pme_corr, temp_read, salt_read, mask

    use param_mod, only : day2sec, dpm, dt, dtts, dyd, loop_day, loop_total, nmid, rnmid, sum_adv, deg2rad
    
    use momentum_mod, only : momentum
    use tracer_mod, only : tracer, rgm_zero_tracer_adv
    use couple_mod, only : couple_rgmld
    use presgrad_mod, only : pressure_integral
    use interp_extrap_initial_mod, only : interp_extrap_initial
    use filter_mod, only : filter
    
    use mpp_mod, only : mpp_npes, mpp_pe, mpp_error, stdout, FATAL, WARNING, NOTE, mpp_init, &
        mpp_exit, mpp_max, mpp_sum, mpp_sync, mpp_root_pe, mpp_clock_id, mpp_clock_begin, mpp_clock_end, &
        lowercase

    use fms_mod,  only : field_exist, field_size, read_data, fms_init, fms_end

    use fms_io_mod, only : register_restart_field, restart_file_type, save_restart, restore_state, &
        open_namelist_file, open_file, close_file, file_exist

    use mpp_domains_mod, only : domain2d, domain1d, mpp_define_layout, mpp_define_domains, &
        mpp_get_compute_domain, mpp_get_domain_components, mpp_update_domains, mpp_get_data_domain, &
        CGRID_SW, BITWISE_EXACT_SUM, mpp_global_sum

    use diag_manager_mod, only : diag_manager_init, register_diag_field, register_static_field, &
        diag_axis_init, send_data, diag_manager_end

    use diag_data_mod, only : FILL_VALUE

    use data_override_mod, only : data_override_init, data_override

    use time_manager_mod, only : set_calendar_type, NO_CALENDAR, JULIAN, NOLEAP, GREGORIAN, &
        THIRTY_DAY_MONTHS, date_to_string, get_calendar_type, time_type, set_time, set_date, &
        operator(+), assignment(=), print_date, print_time, set_ticks_per_second, increment_date, &
        operator(>=), operator(==), get_date, days_in_month, operator(-), operator(/)

    implicit none

    integer :: iday_month, ii
    real :: age_time, day_night, rlct, depth_mld
    type(time_type) :: time, time_step, time_restart, start_time
    integer :: months=0, days=0, hours=0, minutes=0, seconds=0

    integer :: domain_layout(2), used

    integer :: id_lon, id_lat, id_sst, id_depth_mld, id_depth, id_sss, id_airt
    integer :: id_lonb, id_latb
    integer :: id_h, id_eta, id_u, id_v, id_tx, id_ty, id_temp, id_salt
    integer :: id_we, id_dens, id_pvort, id_mask, id_dxu, id_dyv, id_rkmh, id_rkmu, id_rkmv
    integer :: id_temp_mld, id_salt_mld, id_u_mld, id_v_mld, id_diag, id_sh, id_sm
    integer :: id_mld, id_tke, id_rif, id_mlen, id_st_h, id_st_m, id_pme
    integer :: id_sphm, id_uwnd, id_vwnd, id_ssw, id_cld, id_chl, id_rvr

    integer :: init_clk, main_clk, clinic_clk, mld_clk, filter_clk, couple_clk

    type(domain2d) :: domain

    type(restart_file_type) :: restart_odtm

    real :: rdepth(km)
    real :: sumall, umax
    logical, allocatable :: lmask(:,:), lmask3(:,:,:), lmask3m(:,:,:)
    logical :: override
    integer :: restart_interval(6) = 0, layout(2)
    character (len=32) :: timestamp
    
    namelist /main_nml/ restart_interval, layout, rgm_zero_tracer_adv, dt, & 
        months, days, hours, minutes, seconds

    call mpp_init()
    call fms_init()

    init_clk = mpp_clock_id('Initialization')
    main_clk = mpp_clock_id('Main Loop')
    clinic_clk = mpp_clock_id('Clinic')
    mld_clk = mpp_clock_id('MLD')
    filter_clk = mpp_clock_id('Filter')
    couple_clk = mpp_clock_id('Couple')

    call mpp_clock_begin(init_clk)
    call init_odtm()
    call mpp_clock_end(init_clk)


    !c       do the integration

    month_start = 1
    loop_start = 1
    month = month_start
    lpm = dpm(month)*day2sec/dt
    lpd = day2sec/dt
    month_wind = month_start
    iday_month = month_start
    iday_wind = 1
    iday_start = iday_month !c-1
    
    if (mpp_root_pe()) call check
    
#ifdef trace
    tracer_switch = 1
#else
    tracer_switch = 0
#endif

    call mpp_clock_begin(main_clk)
 
    do loop = loop_start, loop_total

        loop_day = loop*dt/day2sec

#ifdef monthly_wind

        if ( loop .gt. lpm) then 
            month = month + 1
            month_wind = month_wind + 1
            lpm = lpm + dpm(month)*day2sec/dt

#ifdef monthly_climatology
            if ( month .eq. 13) then 
                month = 1
                month_wind = 1
            endif
#endif
            if ( month .eq. 13) month = 1
        endif
#endif
    
        sum_adv=0.0
    
        call data_override('OCN','sphm',sphm,time,override)
        if (.not.override) call mpp_error(WARNING, 'sphm not overriden')
        used = send_data(id_sphm, sphm, time)

        call data_override('OCN','uwnd',uwnd,time,override)
        if (.not.override) call mpp_error(WARNING, 'uwnd not overriden')
        used = send_data(id_uwnd, uwnd, time)

        call data_override('OCN','vwnd',vwnd,time,override)
        if (.not.override) call mpp_error(WARNING, 'vwnd not overriden')
        used = send_data(id_vwnd, vwnd, time)

        call data_override('OCN','airt',airt,time,override)
        if (.not.override) call mpp_error(WARNING, 'airt not overriden')
        used = send_data(id_airt, airt, time)

        call data_override('OCN','ssw',ssw,time,override)
        if (.not.override) call mpp_error(WARNING, 'ssw not overriden')
        used = send_data(id_ssw, ssw, time)

        call data_override('OCN','cld',cld,time,override)
        if (.not.override) call mpp_error(WARNING, 'cld not overriden')
        used = send_data(id_cld, cld, time)

        call data_override('OCN','pme',pme,time,override)
        if (.not.override) call mpp_error(WARNING, 'pme not overriden')
        used = send_data(id_pme, pme, time)

        call data_override('OCN','chl',chl,time,override)
        if (.not.override) call mpp_error(WARNING, 'chl not overriden')
        used = send_data(id_chl, chl, time)

        call data_override('OCN','rvr',rvr,time,override)
        if (.not.override) call mpp_error(WARNING, 'rvr not overriden')
        used = send_data(id_rvr, rvr, time)

        call data_override('OCN','taux_force',taux_force,time,override)

        call data_override('OCN','tauy_force',tauy_force,time,override)

#ifdef entrain
        call entrain_detrain
        call mpp_update_domains(wd,domain)
        call mpp_update_domains(we,domain)
#endif

        call mpp_update_domains(u(:,:,:,taun),domain)
        call mpp_update_domains(u(:,:,:,taum),domain)
        call mpp_update_domains(v(:,:,:,taun),domain)
        call mpp_update_domains(v(:,:,:,taum),domain)
        call mpp_update_domains(h(:,:,:,taun),domain)
        call mpp_update_domains(h(:,:,:,taum),domain)
        call mpp_update_domains(t(:,:,:,1,taun),domain)
        call mpp_update_domains(t(:,:,:,2,taun),domain)
        call mpp_update_domains(t(:,:,:,1,taum),domain)
        call mpp_update_domains(t(:,:,:,2,taum),domain)

        call mpp_update_domains(temp(:,:,:,1),domain)
        call mpp_update_domains(temp(:,:,:,2),domain)
        call mpp_update_domains(salt(:,:,:,1),domain)
        call mpp_update_domains(salt(:,:,:,2),domain)
        call mpp_update_domains(uvel(:,:,:,1),domain)
        call mpp_update_domains(uvel(:,:,:,2),domain)
        call mpp_update_domains(vvel(:,:,:,1),domain)
        call mpp_update_domains(vvel(:,:,:,2),domain)

        call mpp_clock_begin(clinic_clk)
        call clinic(domain)
        call mpp_update_domains(h(:,:,:,taup),domain)
        call mpp_clock_end(clinic_clk)

        day_night = cos(loop*(2*3.14/(day2sec/dt))) + 1.0
        
        do i=isc,iec
            do j=jsc,jec
                do k=1,km-1
                    nmid = (jmt/2)+1
    
                    call stability_check ()

                    call pressure_integral ()
    
                    rlct = rkmu(i,j) + rkmv(i,j)
                    if (rlct .ne. 0.0) then
                        call momentum
                    endif

#ifdef trace
                    call tracer 
#endif
                enddo
            enddo
        enddo


        call mpp_clock_begin(mld_clk)
        call mixed_layer_physics
        call mpp_update_domains(uvel(:,:,:,2),domain)
        call mpp_update_domains(vvel(:,:,:,2),domain)
        call mpp_clock_end(mld_clk)

        call balance_pme()

        call mpp_clock_begin(couple_clk)
        call couple_rgmld
        call mpp_clock_end(couple_clk)

        call mpp_clock_begin(filter_clk) 
        call filter(domain)
        call mpp_clock_end(filter_clk) 
    
        call print_date(time)
        call send_data_diag(time)

        time = time + time_step
   
        ! save intermediate restarts
        if ( time >= time_restart ) then
            timestamp = date_to_string(time)
            call write_restart(timestamp)
            time_restart = increment_date(time, restart_interval(1), restart_interval(2), &
                restart_interval(3), restart_interval(4), restart_interval(5), restart_interval(6) )
        endif

        sumall = sum(u(isc:iec,jsc:jec,:,taun) + &
                         t(isc:iec,jsc:jec,:,1,taun))

        call mpp_sum(sumall)

        umax = maxval(abs(u(isc:iec,jsc:jec,:,taun)))
        call mpp_max(umax)

        if ( umax > 10. .or. sumall/=sumall ) then
            call save_restart(restart_odtm, 'crash')
            call diag_manager_end(time)
            print *, 'blow-up :', umax, sumall
            call mpp_error(WARNING, 'stop=>blow-up')
            call mpp_sync()
            call mpp_error(FATAL, 'stop=>blow-up')
        endif

    enddo

    call mpp_clock_end(main_clk)
    
    call mpp_error(NOTE,'Integration finished')

    call write_restart() 
    
    call diag_manager_end(time)
    call fms_end()
    
    contains


    subroutine init_odtm()

        integer :: ii, used, unit
        character(len=32) :: calendar
        integer :: start_date(6) = 0, m
        integer :: current_date(6) = 0, date(6) = 0
        type(time_type):: Time_end, Run_length

        unit = open_namelist_file()
        rewind(unit)
        read(unit,nml=main_nml)
        dtts = 2.0 * dt

        ! Read calendar type and start time 
        unit = open_file(file='INPUT/odtm.res',action='read')
        rewind(unit)
        read(unit,*) calendar
        read(unit,*) start_date
        read(unit,*) current_date
        call close_file(unit)

        select case (lowercase(calendar))
        case('gregorian')
            call set_calendar_type(GREGORIAN)
        case('noleap')
            call set_calendar_type(NOLEAP)
        case('julian')
            call set_calendar_type(JULIAN)
        case('thirty_day_months')
            call set_calendar_type(THIRTY_DAY_MONTHS)
        case('no_calendar')
            call set_calendar_type(NO_CALENDAR)
        case default
            call mpp_error(fatal, &
            'Wrong calendar type! Available calendar types are: GREGORIAN, NOLEAP, JULIAN, THIRTY_DAY_MONTHS, NO_CALENDAR')
        end select
         
        unit = open_file(file='RESTART/._tmp_',action='write')
        call close_file(unit,'delete')

        time_step = set_time(seconds=int(dt))

        start_time = set_date(start_date(1), start_date(2), start_date(3), &
                        start_date(4), start_date(5), start_date(6))

        time = set_date(current_date(1), current_date(2), current_date(3), &
                        current_date(4), current_date(5), current_date(6))

        Time_end = Time
        do m=1,months
           Time_end = Time_end + set_time(0,days_in_month(Time_end))
        end do
        Time_end   = Time_end + set_time(hours*3600+minutes*60+seconds, days)
        Run_length = Time_end - Time
        loop_total = Run_length / time_step

!--------------write time stamps-----------------------------------------------
        unit = open_file(file='time_stamp.out',action='write')
        call get_date (Time_end, date(1), date(2), date(3), date(4), date(5), date(6))
        write(unit,*) lowercase(trim(calendar))
        write(unit,*) start_date
        write(unit,*) date
        write(unit,*) dt
        call close_file(unit)
      
        if (all(restart_interval==0)) restart_interval(1) = 10
 
        time_restart = increment_date(time, restart_interval(1), restart_interval(2), &
        restart_interval(3), restart_interval(4), restart_interval(5), restart_interval(6) )

        call init_grid()

        call diag_manager_init()

        call data_override_init(Ocean_domain_in=domain)

        allocate ( lmask(isc:iec,jsc:jec) ) 
        allocate ( lmask3(isc:iec,jsc:jec,km) )
        allocate ( lmask3m(isc:iec,jsc:jec,kmaxMYM) )

        lmask=.false.; lmask3 = .false.; lmask3m = .false.

        lmask(isc:iec,jsc:jec)=omask(isc:iec,jsc:jec)

        do ii = 1, km
            lmask3(isc:iec, jsc:jec, ii) = omask(isc:iec,jsc:jec)
        enddo

        do ii = 1,kmaxMYM
            lmask3m(isc:iec,jsc:jec, ii) = omask(isc:iec,jsc:jec) 
        enddo

        id_lon = diag_axis_init('lon', gdx(1:imt), 'degrees_east', cart_name='X', &
            long_name='longitude', domain2=domain)

        id_lat = diag_axis_init('lat', gdy(1:jmt), 'degrees_north', cart_name='Y', &
            long_name='latitude', domain2=domain) 

        id_lonb = diag_axis_init('lonb', gdxb(1:imt+1), 'degrees_east', cart_name='X', &
            long_name='longitude', domain2=domain)

        id_latb = diag_axis_init('latb', gdyb(1:jmt+1), 'degrees_north', cart_name='Y', &
            long_name='latitude', domain2=domain) 

        id_depth_mld = diag_axis_init('depth_mld', (/(real(ii)*5.0,ii=1,kmaxMYM)/), 'meters', &
            cart_name='Z', long_name='depth')

        rdepth(1) = dz(1)

        do ii=2,km
            rdepth(ii)=rdepth(ii-1) + dz(ii)
        enddo

        id_depth = diag_axis_init('depth', rdepth, 'meters', &
            cart_name='Z', long_name='depth')

        id_airt = register_diag_field('odtm', 'airt', (/id_lon,id_lat/), init_time=Time, &
                 long_name='Air Temperature', units='deg-C',missing_value=FILL_VALUE)

        id_sphm = register_diag_field('odtm', 'sphm', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_uwnd = register_diag_field('odtm', 'uwnd', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_vwnd = register_diag_field('odtm', 'vwnd', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_ssw = register_diag_field('odtm', 'ssw', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_cld = register_diag_field('odtm', 'cld', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_pme = register_diag_field('odtm', 'pme', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_rvr = register_diag_field('odtm', 'rvr', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_chl = register_diag_field('odtm', 'chl', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_sst = register_diag_field('odtm', 'sst', (/id_lon,id_lat/), init_time=Time, &
                 long_name='Sea Surface Temperature', units='deg-C',missing_value=FILL_VALUE)

        id_sss = register_diag_field('odtm', 'sss', (/id_lon,id_lat/), init_time=Time, &
                 long_name='Sea Surface Salinity', units='psu',missing_value=FILL_VALUE)

        id_temp = register_diag_field('odtm', 'temp', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='Temperature', units='deg-C',missing_value=FILL_VALUE)

        id_salt = register_diag_field('odtm', 'salt', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='Salinity', units='deg-C',missing_value=FILL_VALUE)

        id_h = register_diag_field('odtm', 'h', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='Hieght', units='meters',missing_value=FILL_VALUE)

        id_eta = register_diag_field('odtm', 'eta', (/id_lon,id_lat/), init_time=Time, &
                 long_name='eta', units='meters',missing_value=FILL_VALUE)

        id_u = register_diag_field('odtm', 'u', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='U-velocity', units='ms-1',missing_value=FILL_VALUE)

        id_v = register_diag_field('odtm', 'v', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='V-velocity', units='ms-1',missing_value=FILL_VALUE)

        id_tx = register_diag_field('odtm', 'tx', (/id_lon,id_lat/), init_time=Time, &
                 long_name='taux', units='?',missing_value=FILL_VALUE)

        id_ty = register_diag_field('odtm', 'ty', (/id_lon,id_lat/), init_time=Time, &
                 long_name='tauy', units='?',missing_value=FILL_VALUE)

        id_we = register_diag_field('odtm', 'we', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)
       
        id_dens = register_diag_field('odtm', 'dens', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='Density', units='?',missing_value=FILL_VALUE)

        id_pvort = register_diag_field('odtm', 'pvort', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_rkmh = register_diag_field('odtm', 'rkmh', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_rkmu = register_diag_field('odtm', 'rkmu', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_rkmv = register_diag_field('odtm', 'rkmv', (/id_lon,id_lat,id_depth/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_mask = register_static_field('odtm', 'mask', (/id_lon,id_lat/), long_name='?', units='?', &
                    missing_value=FILL_VALUE )

        id_dxu = register_static_field('odtm', 'dxu', (/id_lon,id_lat/), long_name='?', units='?', &
                    missing_value=FILL_VALUE)

        id_dyv = register_static_field('odtm', 'dyv', (/id_lon,id_lat/), long_name='?', units='?', &
                    missing_value=FILL_VALUE)

        id_temp_mld = register_diag_field('odtm', 'temp_mld', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='Temperature', units='deg-C',missing_value=FILL_VALUE)
        
        id_salt_mld = register_diag_field('odtm', 'salt_mld', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='Salinity', units='psu',missing_value=FILL_VALUE)

        id_u_mld = register_diag_field('odtm', 'u_mld', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='U-velocity', units='ms-1',missing_value=FILL_VALUE)

        id_v_mld = register_diag_field('odtm', 'v_mld', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='V-velocity', units='ms-1',missing_value=FILL_VALUE)

        id_diag = register_diag_field('odtm', 'diag', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_sh = register_diag_field('odtm', 'sh', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_sm = register_diag_field('odtm', 'sm', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)
        
        id_mld = register_diag_field('odtm', 'mld', (/id_lon,id_lat/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_tke = register_diag_field('odtm', 'tke', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)
        
        id_rif = register_diag_field('odtm', 'rif', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_mlen = register_diag_field('odtm', 'mlen', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_st_h = register_diag_field('odtm', 'st_h', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        id_st_m = register_diag_field('odtm', 'st_m', (/id_lon,id_lat,id_depth_mld/), init_time=Time, &
                 long_name='?', units='?',missing_value=FILL_VALUE)

        used = send_data(id_mask, rkmh(isc:iec,jsc:jec), time)
        used = send_data(id_dxu, dxu(isc:iec,jsc:jec), time)
        used = send_data(id_dyv, dyv(isc:iec,jsc:jec), time)

    end subroutine init_odtm


    subroutine send_data_diag(time)

        type(time_type) :: time
        integer :: used

       
        used = send_data(id_rkmh,rkmh(isc:iec,jsc:jec), time)

        used = send_data(id_rkmu,rkmu(isc:iec,jsc:jec), time)

        used = send_data(id_rkmv,rkmv(isc:iec,jsc:jec), time)

        used = send_data(id_sst,t(isc:iec,jsc:jec,1,1,taun), time, mask=lmask)

        used = send_data(id_sss,t(isc:iec,jsc:jec,1,2,taun), time, mask=lmask)

        used = send_data(id_temp,t(isc:iec,jsc:jec,:,1,taun),time, mask=lmask3)

        used = send_data(id_salt,t(isc:iec,jsc:jec,:,2,taun),time, mask=lmask3)

        used = send_data(id_h,h(isc:iec,jsc:jec,:,taun),time, mask=lmask3)

        used = send_data(id_eta, eta(isc:iec,jsc:jec,1,1), time, mask=lmask)

        used = send_data(id_u, u(isc:iec,jsc:jec,:,taun), time, mask=lmask3)

        used = send_data(id_v, v(isc:iec,jsc:jec,:,taun), time, mask=lmask3)

        used = send_data(id_we, we(isc:iec,jsc:jec,:), time, mask=lmask3)

        used = send_data(id_dens, denss, time, mask=lmask3)

        used = send_data(id_pvort, pvort, time, mask=lmask3)
        
        used = send_data(id_temp_mld,temp(isc:iec,jsc:jec,:,1),time, mask=lmask3m)

        used = send_data(id_salt_mld,salt(isc:iec,jsc:jec,:,1),time, mask=lmask3m)

        used = send_data(id_u_mld,uvel(isc:iec,jsc:jec,:,taun),time, mask=lmask3m)

        used = send_data(id_v_mld,vvel(isc:iec,jsc:jec,:,taun),time, mask=lmask3m)

        used = send_data(id_diag,rmld_misc,time, mask=lmask3m)

        used = send_data(id_sh,SHCoeff,time, mask=lmask3m)

        used = send_data(id_sm,SMCoeff,time, mask=lmask3m)

        used = send_data(id_tke,diag_ext1,time, mask=lmask3m)

        used = send_data(id_rif,diag_ext2,time, mask=lmask3m)

        used = send_data(id_mlen,diag_ext3,time, mask=lmask3m)

        used = send_data(id_st_h,diag_ext4,time, mask=lmask3m)

        used = send_data(id_st_m,diag_ext5,time, mask=lmask3m)

    end subroutine send_data_diag
    


    subroutine init_grid

        !c initialze model grid.
    
        implicit none
    
        integer :: ii, jj, kk, kmax, l, ll, nt
        integer :: dimz(4)
        real, allocatable :: tmp2(:,:)
        integer :: id_restart
        real :: tempin(kclim), saltin(kclim)
        real :: saltout, tempout
        character (len=32) :: grid_file='INPUT/grid_spec.nc'
        character (len=32) :: temp_clim_file='INPUT/temp_clim.nc'
        character (len=32) :: salt_clim_file='INPUT/salt_clim.nc'
        character (len=32) :: restart_file='odtm_restart.nc'

  
        if (.not.field_exist(grid_file, "geolon_t"))  &
            call mpp_error(FATAL,'geolon_t not present in '//trim(grid_file))

        if (.not.field_exist(grid_file, "geolat_t"))  &
            call mpp_error(FATAL,'geolat_t not present in '//trim(grid_file))

        if (.not.field_exist(grid_file, "geolon_vert_t"))  &
            call mpp_error(FATAL,'geolon_vert_t not present in '//trim(grid_file))

        if (.not.field_exist(grid_file, "geolat_vert_t"))  &
            call mpp_error(FATAL,'geolat_vert_t not present in '//trim(grid_file))

        if (.not.field_exist(grid_file, "rkmt"))  &
            call mpp_error(FATAL,'rkmt not present in '//trim(grid_file))
       
        call field_size(grid_file, "geolon_t", dimz)
        
        imt = dimz(1); jmt = dimz(2)
       
        if (sum(layout)<=0) then 
            call mpp_define_layout((/1,imt,1,jmt/),mpp_npes(),domain_layout)
        else
            domain_layout = layout
        endif

        call mpp_define_domains((/1,imt,1,jmt/), domain_layout, domain, xhalo=halo, yhalo=halo )

        call mpp_get_compute_domain(domain, isc, iec, jsc, jec)

        call mpp_get_data_domain(domain, isd, ied, jsd, jed)

        print *, '-----------------------Domain Decomposition-----------------------------'
        print *, 'Compute Domain: PE, isc, iec, jsc, jec = ', mpp_pe(), isc, iec, jsc, jec
        print *, 'Data Domain:    PE, isd, ied, jsd, jed = ', mpp_pe(), isd, ied, jsd, jed
        print *, '------------------------------------------------------------------------'

        call init_size()

        allocate(tmp2(imt+1,jmt+1))
        
        call read_data(grid_file, 'geolon_t', tmp2(1:imt,1:jmt), no_domain=.true.)
   
        gdx = 0.
        gdx(1:imt) = tmp2(1:imt,1)

        call read_data(grid_file, 'geolat_t', tmp2(1:imt,1:jmt), no_domain=.true.)
    
        gdy = 0.
        gdy(1:jmt) = tmp2(1,1:jmt)

        call read_data(grid_file, 'geolon_vert_t', tmp2, no_domain=.true.)
   
        gdxb = 0.
        gdxb(1:imt+1) = tmp2(1:imt+1,1)

        call read_data(grid_file, 'geolat_vert_t', tmp2, no_domain=.true.)
    
        gdyb = 0.
        gdyb(1:jmt+1) = tmp2(1,1:jmt+1)

        do ii=1,imt
           rdx(ii) = (gdxb(ii+1) - gdxb(ii))*deg2rad
        enddo

        do ii=1,jmt
           rdy(ii) = (gdyb(ii+1) - gdyb(ii))*deg2rad
        enddo

        deallocate(tmp2)

        call read_data(grid_file, 'rkmt', rkmt(1:imt,1:jmt), no_domain=.true.)

        ! since a C grid is being used, u,v, h are defined at 3 different points, hence
        ! each has a dfferent mask.    u--------h
        !                                       |
        !                                       |       
        !                                       |
        !                                       v

        omask(:,:) = .false.
        where(rkmt(1:imt,1:jmt) > 0.5) omask(1:imt,1:jmt) = .true.
        
        rkmu(:,:) = 0.
        rkmv(:,:) = 0.
        rkmh(:,:) = 0.
        mask(:,:) = 1.
         
        where(omask(isd:ied,jsd:jed)) rkmh(isd:ied,jsd:jed) = 1.

        do ii=isd, ied
            if (ii<1) cycle
            do jj=jsd, jed
                if (omask(ii,jj) .and. omask(ii-1,jj)) rkmu(ii,jj) = 1.0
            enddo
        enddo
    
        do ii=isd, ied
            do jj=jsd, jed
                if (jj<1) cycle
                if (omask(ii,jj) .and. omask(ii,jj-1)) rkmv(ii,jj) = 1.0
            enddo
        enddo
    
        call polar_coord

        id_restart = register_restart_field(restart_odtm, restart_file, 'u', u(:,:,:,1), u(:,:,:,2),domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'v', v(:,:,:,1), v(:,:,:,2),domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'temp', t(:,:,:,1,1), t(:,:,:,1,2), &
                     mandatory=.true.,domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'salt', t(:,:,:,2,1), t(:,:,:,2,2), &
                     mandatory=.true.,domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'h', h(:,:,:,1), h(:,:,:,2),domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'temp_mld', temp(:,:,:,1), temp(:,:,:,2), &
                     mandatory=.true.,domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'salt_mld', salt(:,:,:,1), salt(:,:,:,2), &
                     mandatory=.true.,domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'uvel', uvel(:,:,:,1), uvel(:,:,:,2),domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'vvel', vvel(:,:,:,1), vvel(:,:,:,2),domain=domain)
        id_restart = register_restart_field(restart_odtm, restart_file, 'pme_corr', pme_corr(:,:),domain=domain)

        we_upwel(:,:,:) = 0.0
        
        do kk=1,km
            h(:,:,kk,taum)=dz(kk)
            h(:,:,kk,taun)=dz(kk)
            h(:,:,kk,taup)=dz(kk)
        enddo

        u(:,:,:,:) = 0.0
        v(:,:,:,:) = 0.0

        we(:,:,:) = 0.0
        wd(:,:,:) = 0.0
        eta(:,:,:,:) = 0.0

        t(:,:,:,:,:) = 0.0
        t(:,:,:,:,:) = 0.0
       
        uvel(:,:,:,:) = 0.0
        vvel(:,:,:,:) = 0.0
        temp(:,:,:,:) = 0.0
        salt(:,:,:,:) = 0.0
 
        if (.not. field_exist(temp_clim_file, 'temp')) &
            call mpp_error(FATAL, 'field temp not found in '//trim(temp_clim_file))

        if (.not. field_exist(salt_clim_file, 'salt')) &
            call mpp_error(FATAL, 'field salt not found in '//trim(salt_clim_file))

        call field_size(temp_clim_file, 'temp', dimz)

        do nt = 1, lm-1
            call read_data(temp_clim_file, 'temp', temp_read(:,:,:,nt), timelevel=nt, domain=domain)
            call read_data(salt_clim_file, 'salt', salt_read(:,:,:,nt), timelevel=nt, domain=domain)
        enddo

        temp_read(:,:,:,lm) = temp_read(:,:,:,1)
        salt_read(:,:,:,lm) = salt_read(:,:,:,1)

        if (start_time == time) then
            call mpp_error(NOTE,'Model starting from initial state')
            do i=isc,iec
                do j=jsc,jec
                    if (rkmh(i,j)/=1.) cycle 
                    do k=1,kclim
                        tempin(k) = temp_read(i,j,k,1)  
                        saltin(k) = salt_read(i,j,k,1) 
                    enddo
                    do k=1,kmaxMYM
                        temp(i,j,k,1) = temp_read(i,j,k,1)
                        salt(i,j,k,1) = salt_read(i,j,k,1)
                        temp(i,j,k,2) = temp_read(i,j,k,1)
                        salt(i,j,k,2) = salt_read(i,j,k,1)
                    enddo
                    kmax = kclim
                    do k=1,km-1   
                        call interp_extrap_initial (i,j,k,kmax,tempin, &
                            saltin,tempout,saltout)
                        t(i,j,k,1,taun) = tempout
                        t(i,j,k,2,taun) = saltout
                        t(i,j,k,1,taum) = tempout
                        t(i,j,k,2,taum) = saltout
                    enddo

                    t(i,j,km,1,taun) = 10.0
                    t(i,j,km,2,taun) = 35
                    t(i,j,km,1,taum) = 10.0
                    t(i,j,km,2,taum) = 35.0

                enddo
            enddo
        else 
            call restore_state(restart_odtm)
        endif 

        call save_restart(restart_odtm,'initial') 

    end subroutine init_grid


    subroutine balance_pme()

        implicit none

        integer :: ievap, iprecip
        real :: revap

        revap = mpp_global_sum(domain,rmld_misc(:,:,3),BITWISE_EXACT_SUM)

        ievap = count(rmld_misc(isc:iec,jsc:jec,3)>0.)
        call mpp_sum(ievap)

        iprecip = count(rmld_misc(isc:iec,jsc:jec,3)<0.)
        call mpp_sum(iprecip)

        do i=isc, iec
            do j=jsc, jec
                if (revap .gt. 0.0) then
                    if (rmld_misc(i,j,3) .gt. 0.0) pme_corr(i,j) =  1.0*revap/ievap
                endif
                if (revap .lt. 0.0) then
                    if (rmld_misc(i,j,3) .lt. 0.0) pme_corr(i,j) =  1.0*revap/iprecip
                endif
            enddo
        enddo

    end subroutine balance_pme


    subroutine write_restart(timestmp)
        character (len=32), intent(in), optional :: timestmp
        integer :: unit, calendar_type_int
        character(len=32) :: odtm_res_file, calendar_type_str
        integer :: c_date(6), s_date(6)

        calendar_type_int = get_calendar_type()
        select case (calendar_type_int)
        case(NOLEAP)
            calendar_type_str = 'NOLEAP'
        case(GREGORIAN)
            calendar_type_str = 'GREGORIAN'
        case(THIRTY_DAY_MONTHS)
            calendar_type_str = 'THIRTY_DAY_MONTHS'
        case(JULIAN)
            calendar_type_str = 'JULIAN'
        case(NO_CALENDAR)
            calendar_type_str = 'NO_CALENDAR'
        case default
            calendar_type_str = 'INVALID CALENDAR'
        end select

        call get_date(time,c_date(1),c_date(2),c_date(3),&
                           c_date(4),c_date(5),c_date(6))
        call get_date(start_time,s_date(1),s_date(2),s_date(3),&
                           s_date(4),s_date(5),s_date(6))

        odtm_res_file = 'odtm.res'

        if (present(timestmp)) then
            call save_restart(restart_odtm,timestmp)
            odtm_res_file = trim(timestmp)//'.'//trim(odtm_res_file)
        else
            call save_restart(restart_odtm)
        endif

        if (mpp_pe() == mpp_root_pe()) then
            unit = open_file(file='RESTART/'//trim(odtm_res_file),action='write')
            rewind(unit)
            write(unit,*)calendar_type_str
            write(unit,*)s_date
            write(unit,*)c_date
            call close_file(unit)
        endif 

    end subroutine write_restart



end program main
