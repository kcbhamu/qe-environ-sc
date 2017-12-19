!
! Copyright (C) 2007-2008 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
! original version by O. Andreussi and N. Marzari
!
!--------------------------------------------------------------------
MODULE extcharge
!--------------------------------------------------------------------

  USE kinds,          ONLY: DP
  USE constants,      ONLY: pi, e2
  USE io_global,      ONLY: stdout
  USE mp,             ONLY: mp_sum
  USE mp_bands,       ONLY: intra_bgrp_comm
  USE environ_cell,   ONLY: domega, omega
  USE environ_ions,   ONLY: avg_pos, rhoions, tau
  USE environ_base,   ONLY: verbose, environ_unit,                   &
                            env_external_charges, extcharge_dim,     &
                            extcharge_axis, extcharge_pos,           &
                            extcharge_spread, extcharge_charge,      &
                            rhoexternal, semiconductor_region,       &
                            electrode_charge 
  USE environ_debug,  ONLY: write_cube
  USE semiconductor,  ONLY: slab_dir, max_atomic_pos
  !
  IMPLICIT NONE
  ! 
  LOGICAL :: first = .TRUE.
  !
  REAL(DP) :: eextself = 0.D0, eextzero = 0.D0
  !
  SAVE
  !
  PRIVATE
  !
  PUBLIC :: generate_extcharge, calc_vextcharge, calc_eextcharge, calc_fextcharge
  !
CONTAINS
  !
!--------------------------------------------------------------------
  SUBROUTINE generate_extcharge( nnr, alat,tot_charge )
!--------------------------------------------------------------------
    !
    USE generate_function, ONLY : generate_gaussian
    USE semiconductor,     ONLY : generate_sc_extcharge
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN) :: nnr
    REAL(DP) :: alat
    REAL(DP), INTENT(IN) :: tot_charge
    !
    INTEGER :: iextcharge
    INTEGER :: axis, dim
    REAL(DP) :: charge, spread, pos(3), pos0(3), slab_z
    !
    rhoexternal = 0.D0
    !

    IF ( env_external_charges .LE. 0 ) RETURN

    ! Insert semiconductor external charge
    IF (semiconductor_region) THEN
        CALL generate_sc_extcharge(tot_charge)

    END IF 

    !
    first = .TRUE.
    !
    ! Use the origin of the cell as default origin, removed other options
    !
    pos0 = 0.D0
    !
    ! Generate gaussian densities (planar,lines or points, depending on dim)
    !
    DO iextcharge = 1, env_external_charges
      ! 
      pos(:) = extcharge_pos(:,iextcharge)/alat + pos0(:)
      charge = extcharge_charge(iextcharge)
      spread = extcharge_spread(iextcharge)
      dim = extcharge_dim(iextcharge)
      axis = extcharge_axis(iextcharge)
      !
      ! Extcharge densities only for points, lines or planes (DIM = 0, 1 or 2)
      !
      IF ( dim .GE. 3 .OR. dim .LT. 0 ) THEN
        WRITE(stdout,*)'Warning: wrong extcharge_dim, doing nothing'
        CYCLE  
      END IF
      !
      CALL generate_gaussian( nnr, dim, axis, charge, spread, pos, rhoexternal ) 
      !
    ENDDO
    !
    IF ( verbose .GE. 2 ) CALL write_cube( nnr, rhoexternal, 'rhoexternal.cube' )
    !
    RETURN
    !
!--------------------------------------------------------------------
  END SUBROUTINE generate_extcharge
!--------------------------------------------------------------------
!--------------------------------------------------------------------
  SUBROUTINE calc_vextcharge(  nnr, nspin, vextcharge )
!--------------------------------------------------------------------
    !
    USE environ_base,  ONLY : atomicspread
    USE environ_ions,  ONLY : nat, ityp, zv
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN) :: nnr, nspin
    REAL( DP ), INTENT(OUT) :: vextcharge(nnr)
    !
    INTEGER :: ia
    REAL( DP ) :: ehart, charge
    REAL( DP ), ALLOCATABLE :: vaux(:,:), rhoaux(:,:)

    CALL start_clock( 'get_extcharge' ) 

    IF ( .NOT. first ) RETURN
    first = .FALSE.
    vextcharge = 0.D0

    ALLOCATE( rhoaux( nnr, nspin ) )
    ALLOCATE( vaux( nnr, nspin ) )
    rhoaux( :, 1 ) = rhoexternal(:)
    IF ( nspin .EQ. 2 ) rhoaux( :, 2 ) = 0.D0
    vaux = 0.D0
    CALL v_h_of_rho_r( rhoaux, ehart, charge, vaux )
    vextcharge(:) = vaux( :, 1 )
    DEALLOCATE( rhoaux )
    IF ( verbose .GE. 2 ) CALL write_cube( nnr, vextcharge, 'vextcharge.cube' )
    DEALLOCATE( vaux )

    eextself = 0.5 * SUM( vextcharge( : ) * rhoexternal( : ) ) * domega
    CALL mp_sum( eextself, intra_bgrp_comm )
    IF ( verbose .GE. 1 ) WRITE(environ_unit,*)&
      & 'External charge self energy',eextself

    eextzero = 0.D0
    DO ia = 1, nat
       eextzero = eextzero + zv( ityp( ia ) ) * atomicspread( ityp( ia ) ) ** 2
    ENDDO
    eextzero = eextzero * pi / omega * charge * e2
    IF ( verbose .GE. 1 ) WRITE(environ_unit,*)&
      & 'External charge G=0 correction',eextzero
    
    CALL stop_clock( 'get_extcharge' ) 

    RETURN

!--------------------------------------------------------------------
  END SUBROUTINE calc_vextcharge
!--------------------------------------------------------------------
!--------------------------------------------------------------------
  SUBROUTINE calc_eextcharge(  nnr, rho, eextcharge )
!--------------------------------------------------------------------
    !
    USE environ_base,  ONLY : vextcharge
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN) :: nnr
    REAL( DP ), INTENT(IN) :: rho(nnr)
    REAL( DP ), INTENT(OUT) :: eextcharge
    !
    REAL( DP ), ALLOCATABLE :: rhotot(:)
    !
    ALLOCATE(rhotot(nnr))
    rhotot = rhoions + rho
    !
    eextcharge = SUM( vextcharge(:) * rhotot( : ) ) * domega
    !
    DEALLOCATE(rhotot)
    !
    CALL mp_sum( eextcharge, intra_bgrp_comm )
    !
    eextcharge = eextcharge + eextself + eextzero
    !
    RETURN
    !
!--------------------------------------------------------------------
  END SUBROUTINE calc_eextcharge
!--------------------------------------------------------------------
!--------------------------------------------------------------------
  SUBROUTINE calc_fextcharge(  nnr, nspin, nat, f )
!--------------------------------------------------------------------
    !
    USE generate_function, ONLY : generate_gradgaussian
    USE environ_cell,      ONLY : alat
    USE environ_base,      ONLY : env_static_permittivity, rhopol
    USE environ_ions,      ONLY : ntyp, ityp, zv, tau, avg_pos, zvtot, rhoions
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN)       :: nnr, nspin, nat
    REAL(DP), INTENT(INOUT)   :: f( 3, nat )
    !
    ! Since the external charges can only be placed independently of 
    ! atomic positions there is no explicit contributions to the
    ! inter-atomic forces
    !
    RETURN
    !
!--------------------------------------------------------------------
  END SUBROUTINE calc_fextcharge
!--------------------------------------------------------------------
!--------------------------------------------------------------------
END MODULE extcharge
!--------------------------------------------------------------------
