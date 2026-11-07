#include "Includes.h"
module ShockCapturing

   use SMConstants,                only: RP, PI, STD_OUT, LINE_LENGTH, NDIM, IX, IY, IZ
   use PhysicsStorage,             only: NCONS, NGRAD
   use FluidData,                  only: dimensionless
   use Utilities,                  only: toLower
   use DGSEMClass,                 only: ComputeTimeDerivative_f, DGSem
   use HexMeshClass,               only: HexMesh
   use ElementClass,               only: Element, HexElement_ProlongAviscToFaces
#if !defined(SPALARTALMARAS)
   use LESModels,                  only: Smagorinsky_t, Smagorinsky_ComputeViscosity
#endif
   use SpectralVanishingViscosity, only: SVV, InitializeSVV, SVVdev_filter, SVVdev_kind, SVVdev_lowPass, &
                                         SVVdev_W, SVVdev_mu, SVVdev_diss, SVV_PHYS_ENERGY,              &
                                         SVV_Hflux_0D, SVV_Flux_0D
   use DGIntegrals,                only: ScalarWeakIntegrals, ScalarStrongIntegrals
   use NodalStorageClass,          only: NodalStorage

   use ShockCapturingKeywords
   use SCsensorClass, only: SCsensor_t, Set_SCsensor, Destruct_SCsensor, GetSensedVariable_0D, &
                            GMMFeatures_0D

   implicit none

   public :: Initialize_ShockCapturing
   public :: ShockCapturingDriver

   type ArtificialViscosity_t

      integer,  private :: region           !< Sensor region where it acts (1 or 2)
      integer,  private :: updateMethod     !< Method to compute the viscosity coefficient
      real(RP), private :: mu1              !< First viscosity parameter (low)
      real(RP), private :: alpha1           !< Second viscosity parameter (low)
      real(RP), private :: mu2              !< First viscosity parameter (high)
      real(RP), private :: alpha2           !< Second viscosity parameter (high)
      real(RP), private :: mu2alpha         !< Ratio alpha/mu
      logical,  private :: alphaIsPropToMu  !< .true. if alpha/mu is defined
#if !defined (SPALARTALMARAS)
      type(Smagorinsky_t), private :: Smagorinsky  !< For automatic viscosity
#endif

      contains

         procedure :: Initialize => AV_initialize
         procedure :: Viscosity  => AV_viscosity
         procedure :: Describe   => AV_describe

   end type ArtificialViscosity_t

   type SCdriver_t

      logical  :: isActive = .false.  !< On/Off flag

      type(SCsensor_t),             private              :: sensor   !< Sensor
      class(ArtificialViscosity_t), private, allocatable :: method1  !< First SC method
      class(ArtificialViscosity_t), private, allocatable :: method2  !< Second SC method

      contains

         procedure :: Detect           => SC_detect
         procedure :: ComputeViscosity => SC_viscosity
         procedure :: Describe         => SC_describe

         final :: SC_destruct

   end type SCdriver_t

   type, extends(ArtificialViscosity_t) :: SC_NoSVV_t

      integer,                                 private :: fluxType
      procedure(Viscous_Int), nopass, pointer, private :: ViscousFlux => null()

      contains

         procedure :: Initialize => NoSVV_initialize
         procedure :: Viscosity  => NoSVV_viscosity
         procedure :: Describe   => NoSVV_describe

         final :: NoSVV_destruct

   end type SC_NoSVV_t

   type, extends(ArtificialViscosity_t) :: SC_SVV_t

      real(RP), private :: sqrt_mu1
      real(RP), private :: sqrt_alpha1
      real(RP), private :: sqrt_mu2
      real(RP), private :: sqrt_alpha2
      real(RP), private :: sqrt_mu2alpha

      contains

         procedure :: Initialize => SVV_initialize
         procedure :: Viscosity  => SVV_viscosity
         procedure :: Describe   => SVV_describe

   end type SC_SVV_t
!
!  Interfaces
!  ----------
   abstract interface
      pure subroutine Viscous_Int(nEqn, nGradEqn, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
         import RP, NDIM
         integer,       intent(in)  :: nEqn
         integer,       intent(in)  :: nGradEqn
         real(kind=RP), intent(in)  :: Q   (1:nEqn    )
         real(kind=RP), intent(in)  :: Q_x (1:nGradEqn)
         real(kind=RP), intent(in)  :: Q_y (1:nGradEqn)
         real(kind=RP), intent(in)  :: Q_z (1:nGradEqn)
         real(kind=RP), intent(in)  :: mu
         real(kind=RP), intent(in)  :: beta
         real(kind=RP), intent(in)  :: kappa
         real(kind=RP), intent(out) :: F(1:nEqn, 1:NDIM)
      end subroutine Viscous_Int
   end interface

   type(SCdriver_t), allocatable :: ShockCapturingDriver
!
!  Flat copy of the configuration for the device kernels, indexed by region
!  (1: first method, 2: second method): polymorphic components and procedure
!  pointers cannot be used in OpenACC compute regions.
!
   logical  :: SCdev_isActive        = .false.
   logical  :: SCdev_hasMethod(2)    = .false.
   integer  :: SCdev_update(2)       = SC_CONST_ID
   integer  :: SCdev_fluxType(2)     = SC_PHYS_ID
   real(RP) :: SCdev_mu1(2)          = 0.0_RP
   real(RP) :: SCdev_mu2(2)          = 0.0_RP
   real(RP) :: SCdev_smagC(2)        = 0.0_RP
   integer  :: SCdev_smagWallModel(2) = 0
!
!  SVV only (the filter itself is in SpectralVanishingViscosity)
   logical  :: SCdev_isSVV(2)        = .false.
   logical  :: SCdev_alphaPropMu(2)  = .false.
   real(RP) :: SCdev_sqrtMu1(2)      = 0.0_RP
   real(RP) :: SCdev_sqrtMu2(2)      = 0.0_RP
   real(RP) :: SCdev_sqrtAlpha1(2)   = 0.0_RP
   real(RP) :: SCdev_sqrtAlpha2(2)   = 0.0_RP
   real(RP) :: SCdev_sqrtMu2Alpha(2) = 0.0_RP
!
!  Sensor: the parameters of the sensors computed on the device, and the sensor of
!  every element in one array, so that it moves between host and device at once
   integer  :: SCdev_sensType = 0
   integer  :: SCdev_sVar     = 0
   real(RP) :: SCdev_s0       = 0.0_RP
   real(RP) :: SCdev_ds       = 1.0_RP
   real(RP) :: SCdev_ds2      = 0.5_RP
   real(RP), allocatable :: SCdev_sensor(:)
!
!  GMM sensor: the features of every node, in the order of Sensor_GMM, and
!  the index of the first node of every element in them
   real(RP), allocatable :: SCdev_gmmx(:,:)
   integer,  allocatable :: SCdev_first(:)
!
!  copyin, so that the defaults reach the device also when
!  Initialize_ShockCapturing is not called (Euler)
!
   !$acc declare copyin(SCdev_isActive)
   !$acc declare copyin(SCdev_hasMethod, SCdev_update, SCdev_fluxType)
   !$acc declare copyin(SCdev_mu1, SCdev_mu2, SCdev_smagC, SCdev_smagWallModel)
   !$acc declare copyin(SCdev_isSVV, SCdev_alphaPropMu, SCdev_sqrtMu1, SCdev_sqrtMu2)
   !$acc declare copyin(SCdev_sqrtAlpha1, SCdev_sqrtAlpha2, SCdev_sqrtMu2Alpha)
   !$acc declare copyin(SCdev_sensType, SCdev_sVar, SCdev_s0, SCdev_ds, SCdev_ds2)
   !$acc declare create(SCdev_sensor, SCdev_gmmx, SCdev_first)

   public :: SCdev_isActive
   public :: SC_ComputeElementAviscFlux, SC_ProlongAviscFluxToFaces
   public :: SC_UpdateSensorOnDevice, SC_UpdateHostArtificialDiss
!
!  ========
   contains
!  ========
!
!
!///////////////////////////////////////////////////////////////////////////////
!
!     Initializer
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine Initialize_ShockCapturing(self, controlVariables, sem, &
                                        TimeDerivative, TimeDerivativeIsolated)
!
!     -------
!     Modules
!     -------
      use FTValueDictionaryClass
!
!     ---------
!     Interface
!     ---------
      implicit none
      type(SCdriver_t), allocatable, intent(inout) :: self
      class(FTValueDictionary),      intent(in)    :: controlVariables
      class(DGSem),                  intent(inout) :: sem
      procedure(ComputeTimeDerivative_f)           :: TimeDerivative
      procedure(ComputeTimeDerivative_f)           :: TimeDerivativeIsolated
!
!     ---------------
!     Local variables
!     ---------------
      character(len=:), allocatable :: method
      integer                       :: minSteps
      integer                       :: eID, ip

!
!     Check if shock-capturing is requested
!     -------------------------------------
      allocate(self)

      if (controlVariables % containsKey(SC_KEY)) then
         self % isActive = controlVariables % logicalValueForKey(SC_KEY)
      else
         self % isActive = .false.
      end if

      if (.not. self % isActive) then
!
!        Push the defaults to the device
!        -------------------------------
         call SC_SyncDeviceConfig(self)
         return
      end if
!
!     Shock-capturing methods
!     -----------------------
      if (controlVariables % containsKey(SC_METHOD1_KEY)) then
         method = controlVariables % stringValueForKey(SC_METHOD1_KEY, LINE_LENGTH)
      else
         method = SC_NO_VAL
      end if
      call toLower(method)

      select case (trim(method))
      case (SC_NOSVV_VAL)
         allocate(SC_NoSVV_t :: self % method1)

      case (SC_SVV_VAL)
         allocate(SC_SVV_t :: self % method1)

      case (SC_NO_VAL)
         safedeallocate(self % method1)

      case default
         write(STD_OUT,*) 'ERROR. Unavailable first shock-capturing method. Options are:'
         write(STD_OUT,*) '   * ', SC_NO_VAL
         write(STD_OUT,*) '   * ', SC_NOSVV_VAL
         write(STD_OUT,*) '   * ', SC_SVV_VAL
         error stop

      end select

      if (controlVariables % containsKey(SC_METHOD2_KEY)) then
         method = controlVariables % stringValueForKey(SC_METHOD2_KEY, LINE_LENGTH)
      else
         method = SC_NO_VAL
      end if
      call toLower(method)

      select case (trim(method))
      case (SC_NOSVV_VAL)
         allocate(SC_NoSVV_t :: self % method2)

      case (SC_SVV_VAL)
         allocate(SC_SVV_t :: self % method2)

      case (SC_NO_VAL)
         safedeallocate(self % method2)

      case default
         write(STD_OUT,*) 'ERROR. Unavailable second shock-capturing method. Options are:'
         write(STD_OUT,*) '   * ', SC_NO_VAL
         write(STD_OUT,*) '   * ', SC_NOSVV_VAL
         write(STD_OUT,*) '   * ', SC_SVV_VAL
         error stop

      end select
!
!     Initialize viscous and hyperbolic terms
!     ---------------------------------------
      if (allocated(self % method1)) call self % method1 % Initialize(controlVariables, sem % mesh, 1)
      if (allocated(self % method2)) call self % method2 % Initialize(controlVariables, sem % mesh, 2)
!
!     Sensor 'inertia'
!     ----------------
      if (controlVariables % containsKey(SC_SENSOR_INERTIA_KEY)) then
         minSteps = controlVariables % realValueForKey(SC_SENSOR_INERTIA_KEY)
         if (minSteps < 1) then
            write(STD_OUT,*) 'ERROR. Sensor inertia must be at least 1.'
            error stop
         end if
      else
         minSteps = 1
      end if
!
!     Construct sensor
!     ----------------
      call Set_SCsensor(self % sensor, controlVariables, sem, minSteps, &
                        TimeDerivative, TimeDerivativeIsolated)
      allocate(SCdev_sensor(sem % mesh % no_of_elements))
      if (self % sensor % sens_type == SC_GMM_ID) then
         allocate(SCdev_gmmx(2, sem % NDOF), SCdev_first(sem % mesh % no_of_elements))
         ip = 1
         do eID = 1, sem % mesh % no_of_elements
            SCdev_first(eID) = ip
            ip = ip + product(sem % mesh % elements(eID) % Nxyz + 1)
         end do
         !$acc update device(SCdev_first)
      end if
!
!     Flatten the configuration for the device
!     ----------------------------------------
      call SC_SyncDeviceConfig(self)

   end subroutine Initialize_ShockCapturing
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_SyncDeviceConfig(self)
!
!     Push the flat configuration, filled by the methods' initializers, to
!     the device
!
      implicit none
      type(SCdriver_t), intent(in) :: self

      SCdev_isActive = self % isActive
      if (self % isActive) then
         SCdev_sensType = self % sensor % sens_type
         if (SCdev_sensType == SC_INTEGRAL_ID .or. SCdev_sensType == SC_INTEGRAL_SQRT_ID) then
            SCdev_sVar = self % sensor % sVar
            SCdev_s0   = self % sensor % s0
            SCdev_ds   = self % sensor % ds
            SCdev_ds2  = self % sensor % ds2
         end if
      end if

      !$acc update device(SCdev_isActive)
      !$acc update device(SCdev_hasMethod, SCdev_update, SCdev_fluxType)
      !$acc update device(SCdev_mu1, SCdev_mu2, SCdev_smagC, SCdev_smagWallModel)
      !$acc update device(SCdev_isSVV, SCdev_alphaPropMu, SCdev_sqrtMu1, SCdev_sqrtMu2)
      !$acc update device(SCdev_sqrtAlpha1, SCdev_sqrtAlpha2, SCdev_sqrtMu2Alpha)
      !$acc update device(SCdev_sensType, SCdev_sVar, SCdev_s0, SCdev_ds, SCdev_ds2)

   end subroutine SC_SyncDeviceConfig
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_UpdateSensorOnDevice(mesh)
!
!     The host sensor goes to the device in one transfer
!
      implicit none
      type(HexMesh), intent(inout) :: mesh
      integer :: eID

      if (.not. SCdev_isActive) return

      do eID = 1, size(mesh % elements)
         SCdev_sensor(eID) = mesh % elements(eID) % storage % sensor
      end do
      !$acc update device(SCdev_sensor)

      !$acc parallel loop present(mesh) async(1)
      do eID = 1, size(mesh % elements)
         mesh % elements(eID) % storage % sensor = SCdev_sensor(eID)
      end do
      !$acc end parallel loop
      !$acc wait(1)

   end subroutine SC_UpdateSensorOnDevice
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_ComputeSensorOnDevice(mesh)
!
!     Integral sensors (with or without sqrt), as Sensor_integral and
!     Sensor_integral_sqrt, on the device; the result is copied to the host
!
      implicit none
      type(HexMesh), intent(inout) :: mesh
      integer  :: eID, i, j, k
      real(RP) :: val, dev, s

      !$acc wait
      !$acc parallel loop gang present(mesh) private(val, dev, s) async(1)
      do eID = 1, size(mesh % elements)
         val = 0.0_RP
         !$acc loop vector collapse(3) reduction(+:val)
         do k = 0, mesh % elements(eID) % Nxyz(3) ; do j = 0, mesh % elements(eID) % Nxyz(2) ; do i = 0, mesh % elements(eID) % Nxyz(1)
            val = val + NodalStorage(mesh % elements(eID) % Nxyz(1)) % w(i) &
                      * NodalStorage(mesh % elements(eID) % Nxyz(2)) % w(j) &
                      * NodalStorage(mesh % elements(eID) % Nxyz(3)) % w(k) &
                      * mesh % elements(eID) % geom % jacobian(i,j,k)       &
                      * GetSensedVariable_0D(SCdev_sVar,                    &
                                             mesh % elements(eID) % storage % Q(:,i,j,k),   &
                                             mesh % elements(eID) % storage % U_x(:,i,j,k), &
                                             mesh % elements(eID) % storage % U_y(:,i,j,k), &
                                             mesh % elements(eID) % storage % U_z(:,i,j,k))
         end do                ; end do                ; end do
         if (SCdev_sensType == SC_INTEGRAL_SQRT_ID) val = sqrt(val)
!
!        SinRamp
         dev = val - SCdev_s0
         if (dev <= -SCdev_ds2) then
            s = 0.0_RP
         elseif (dev >= SCdev_ds2) then
            s = 1.0_RP
         else
            s = ( 1.0_RP + sin(PI * dev / SCdev_ds) ) / 2.0_RP
         end if
         mesh % elements(eID) % storage % sensor = s
         SCdev_sensor(eID) = s
      end do
      !$acc end parallel loop
      !$acc wait(1)
      !$acc update self(SCdev_sensor)

      do eID = 1, size(mesh % elements)
         mesh % elements(eID) % storage % sensor = SCdev_sensor(eID)
      end do

   end subroutine SC_ComputeSensorOnDevice
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_GMMFeaturesOnDevice(mesh)
!
!     The features of the GMM sensor on the device, copied to the host
!     for the clustering
!
      implicit none
      type(HexMesh), intent(inout) :: mesh
      integer :: eID, i, j, k, ip

      !$acc wait
      !$acc parallel loop gang present(mesh) async(1)
      do eID = 1, size(mesh % elements)
         !$acc loop vector collapse(3) private(ip)
         do k = 0, mesh % elements(eID) % Nxyz(3) ; do j = 0, mesh % elements(eID) % Nxyz(2) ; do i = 0, mesh % elements(eID) % Nxyz(1)
            ip = SCdev_first(eID) + i + (mesh % elements(eID) % Nxyz(1) + 1) &
                                 * (j + (mesh % elements(eID) % Nxyz(2) + 1) * k)
            call GMMFeatures_0D(mesh % elements(eID) % storage % Q(:,i,j,k),   &
                                mesh % elements(eID) % storage % U_x(:,i,j,k), &
                                mesh % elements(eID) % storage % U_y(:,i,j,k), &
                                mesh % elements(eID) % storage % U_z(:,i,j,k), &
                                SCdev_gmmx(1,ip), SCdev_gmmx(2,ip))
         end do                ; end do                ; end do
      end do
      !$acc end parallel loop
      !$acc wait(1)
      !$acc update self(SCdev_gmmx)

   end subroutine SC_GMMFeaturesOnDevice
!
!///////////////////////////////////////////////////////////////////////////////
!
!     Base class
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_detect(self, sem, t)
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SCdriver_t), intent(inout) :: self
      type(DGSem),       intent(inout) :: sem
      real(RP),          intent(in)    :: t

      select case (self % sensor % sens_type)
      case (SC_ZERO_ID, SC_ONE_ID)
!
!        These read nothing from the solution
!        ------------------------------------
         call self % sensor % Compute(sem, t)
         call SC_UpdateSensorOnDevice(sem % mesh)

      case (SC_INTEGRAL_ID, SC_INTEGRAL_SQRT_ID)
!
!        Computed on the device; the host gets a copy (inertia, monitors, output)
!        ------------------------------------------------------------------------
         call SC_ComputeSensorOnDevice(sem % mesh)
         if (self % sensor % min_steps > 1) then
            call self % sensor % ApplyInertia(sem)
            call SC_UpdateSensorOnDevice(sem % mesh)
         end if

      case (SC_GMM_ID)
!
!        Features on the device, clustering on the host
!        ----------------------------------------------
         call SC_GMMFeaturesOnDevice(sem % mesh)
         call self % sensor % SensorFromFeatures(sem, SCdev_gmmx)
         call self % sensor % ApplyInertia(sem)
         call SC_UpdateSensorOnDevice(sem % mesh)

      case default
!
!        The other sensors run on the host
!        ---------------------------------
         call sem % mesh % UpdateHostData()
         call self % sensor % Compute(sem, t)
         call SC_UpdateSensorOnDevice(sem % mesh)
      end select

   end subroutine SC_detect
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_viscosity(self, mesh, e, SCflux)
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SCdriver_t), intent(in)    :: self
      type(HexMesh),     intent(inout) :: mesh
      type(Element),     intent(inout) :: e
      real(RP),          intent(out)   :: SCflux(1:NCONS,       &
                                                 0:e % Nxyz(1), &
                                                 0:e % Nxyz(2), &
                                                 0:e % Nxyz(3), &
                                                 1:NDIM)
!
!     ---------------
!     Local variables
!     ---------------
      real(RP) :: switch
      logical  :: updated


      switch = e % storage % sensor
      updated = .false.

      if (switch >= 1.0_RP) then
         if (allocated(self % method2)) then
            call self % method2 % Viscosity(mesh, e, switch, SCflux)
            updated = .true.
         end if

      elseif (switch > 0.0_RP) then
         if (allocated(self % method1)) then
            call self % method1 % Viscosity(mesh, e, switch, SCflux)
            updated = .true.
         end if

      end if

      if (.not. updated) then
         SCflux = 0.0_RP
         e % storage % artificialDiss = 0.0_RP
      end if

   end subroutine SC_viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   pure subroutine SC_ArtificialViscousFlux_0D(region, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
!
!     Device version of the ViscousFlux procedure pointer of SC_NoSVV_t
!
      !$acc routine seq
      use Physics,        only: GuermondPopovFlux_ENTROPY, ViscousFlux_STATE, &
                                ViscousFlux_ENTROPY, ViscousFlux_ENERGY
      use PhysicsStorage, only: grad_vars, GRADVARS_ENTROPY, GRADVARS_ENERGY
      implicit none
      integer,       intent(in)  :: region
      real(kind=RP), intent(in)  :: Q   (1:NCONS)
      real(kind=RP), intent(in)  :: Q_x (1:NGRAD)
      real(kind=RP), intent(in)  :: Q_y (1:NGRAD)
      real(kind=RP), intent(in)  :: Q_z (1:NGRAD)
      real(kind=RP), intent(in)  :: mu, beta, kappa
      real(kind=RP), intent(out) :: F   (1:NCONS, 1:NDIM)

      select case (SCdev_fluxType(region))
      case (SC_GP_ID)
         call GuermondPopovFlux_ENTROPY(NCONS, NGRAD, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
      case default
         select case (grad_vars)
         case (GRADVARS_ENTROPY)
            call ViscousFlux_ENTROPY(NCONS, NGRAD, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
         case (GRADVARS_ENERGY)
            call ViscousFlux_ENERGY(NCONS, NGRAD, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
         case default
            call ViscousFlux_STATE(NCONS, NGRAD, Q, Q_x, Q_y, Q_z, mu, beta, kappa, F)
         end select
      end select

   end subroutine SC_ArtificialViscousFlux_0D
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_ComputeElementAviscFlux(e, eID)
!
!     Device version of SC_viscosity and NoSVV_viscosity for one element. The
!     flux is prolonged to the faces by SC_ProlongAviscFluxToFaces.
!
      !$acc routine vector
#if !defined (SPALARTALMARAS)
      use LESModels, only: Smagorinsky_ComputeViscosity
#endif
      implicit none
      type(Element), intent(inout) :: e
      integer,       intent(in)    :: eID
!
!     ---------------
!     Local variables
!     ---------------
      integer       :: i, j, k, eq, region
      real(kind=RP) :: switch, mu, kappa, delta
      real(kind=RP) :: covariantFlux(1:NCONS, 1:NDIM)

      switch = e % storage % sensor
!
!     Pick the region exactly as SC_viscosity does
!     --------------------------------------------
      region = 0
      if (switch >= 1.0_RP) then
         if (SCdev_hasMethod(2)) region = 2
      elseif (switch > 0.0_RP) then
         if (SCdev_hasMethod(1)) region = 1
      end if

      if (region /= 0) then
         if (SCdev_isSVV(region)) then
            call SC_ComputeElementSVVFlux(e, eID, region, switch)
            return
         end if
      end if

      if (region == 0) then

         !$acc loop vector collapse(3)
         do k = 0, e % Nxyz(3) ; do j = 0, e % Nxyz(2) ; do i = 0, e % Nxyz(1)
            !$acc loop seq
            do eq = 1, NCONS
               e % storage % AviscContravariantFlux(eq,i,j,k,IX) = 0.0_RP
               e % storage % AviscContravariantFlux(eq,i,j,k,IY) = 0.0_RP
               e % storage % AviscContravariantFlux(eq,i,j,k,IZ) = 0.0_RP
            end do
         end do                ; end do                ; end do
         e % storage % artificialDiss = 0.0_RP
         if (SCdev_isSVV(1)) SVVdev_diss(eID) = 0.0_RP

      else

         delta = ( e % geom % Volume                                            &
                 / real((e % Nxyz(1)+1)*(e % Nxyz(2)+1)*(e % Nxyz(3)+1), RP) )  &
                 ** (1.0_RP / 3.0_RP)
!
!     Viscosity and flux, node by node
!     --------------------------------
      !$acc loop vector collapse(3) private(covariantFlux, mu, kappa)
      do k = 0, e % Nxyz(3) ; do j = 0, e % Nxyz(2) ; do i = 0, e % Nxyz(1)

         select case (SCdev_update(region))
         case (SC_SENSOR_ID)
            mu = (SCdev_mu1(region) * (1.0_RP-switch) + SCdev_mu2(region) * switch) * e % hn

#if !defined (SPALARTALMARAS)
         case (SC_SMAG_ID)
            call Smagorinsky_ComputeViscosity(delta, e % geom % dWall(i,j,k), &
                                              e % storage % Q(:,i,j,k),       &
                                              e % storage % U_x(:,i,j,k),     &
                                              e % storage % U_y(:,i,j,k),     &
                                              e % storage % U_z(:,i,j,k),     &
                                              mu,                             &
                                              SCdev_smagC(region),            &
                                              SCdev_smagWallModel(region))
#endif

         case default   ! SC_CONST_ID
            if (switch >= 1.0_RP) then
               mu = SCdev_mu2(region) * e % hn
            else
               mu = SCdev_mu1(region) * e % hn
            end if

         end select

         kappa = dimensionless % mu_to_kappa * mu

         call SC_ArtificialViscousFlux_0D(region, e % storage % Q(:,i,j,k),   &
                                          e % storage % U_x(:,i,j,k),         &
                                          e % storage % U_y(:,i,j,k),         &
                                          e % storage % U_z(:,i,j,k),         &
                                          mu, 0.0_RP, kappa, covariantFlux)

         !$acc loop seq
         do eq = 1, NCONS
            e % storage % AviscContravariantFlux(eq,i,j,k,IX) =                       &
                 covariantFlux(eq,IX) * e % geom % jGradXi(IX,i,j,k)                  &
               + covariantFlux(eq,IY) * e % geom % jGradXi(IY,i,j,k)                  &
               + covariantFlux(eq,IZ) * e % geom % jGradXi(IZ,i,j,k)

            e % storage % AviscContravariantFlux(eq,i,j,k,IY) =                       &
                 covariantFlux(eq,IX) * e % geom % jGradEta(IX,i,j,k)                 &
               + covariantFlux(eq,IY) * e % geom % jGradEta(IY,i,j,k)                 &
               + covariantFlux(eq,IZ) * e % geom % jGradEta(IZ,i,j,k)

            e % storage % AviscContravariantFlux(eq,i,j,k,IZ) =                       &
                 covariantFlux(eq,IX) * e % geom % jGradZeta(IX,i,j,k)                &
               + covariantFlux(eq,IY) * e % geom % jGradZeta(IY,i,j,k)                &
               + covariantFlux(eq,IZ) * e % geom % jGradZeta(IZ,i,j,k)
         end do

      end do                ; end do                ; end do

      end if

   end subroutine SC_ComputeElementAviscFlux

!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_ComputeElementSVVFlux(e, eID, region, switch)
!
!     Device version of SVV_viscosity for one element: H = sqrt(J) Hflux is
!     filtered in xi, eta and zeta, with SVVdev_W and AviscContravariantFlux
!     taking turns as scratch. Q and its gradients are copied to local arrays,
!     and there is no USE here: otherwise gfortran makes a temporary, or saves
!     the FP state, at every call.
!
      !$acc routine vector
      implicit none
      type(Element), intent(inout) :: e
      integer,       intent(in)    :: eID
      integer,       intent(in)    :: region
      real(kind=RP), intent(in)    :: switch
!
!     ---------------
!     Local variables
!     ---------------
      integer       :: i, j, k, l, eq, dir, Nx, Ny, Nz, eqMin, eqMax
      real(kind=RP) :: delta, sqrt_mu, sqrt_alpha, sqrtJ, f, dissNode, SVV_diss
      real(kind=RP) :: Qn(1:NCONS), Uxn(1:NGRAD), Uyn(1:NGRAD), Uzn(1:NGRAD)
      real(kind=RP) :: H(1:NCONS, 1:NDIM)
      real(kind=RP) :: Hf(1:NCONS, 1:NDIM)
      real(kind=RP) :: cartesianFlux(1:NCONS, 1:NDIM)

      Nx = e % Nxyz(1) ; Ny = e % Nxyz(2) ; Nz = e % Nxyz(3)

      delta = ( e % geom % Volume / real((Nx+1)*(Ny+1)*(Nz+1), RP) ) ** (1.0_RP / 3.0_RP)
!
!     Variables entering the dissipation estimate (SVV % entropy_indexes)
!     -------------------------------------------------------------------
      if (SVVdev_kind == SVV_PHYS_ENERGY) then
         eqMin = 2 ; eqMax = 4
      else
         eqMin = 1 ; eqMax = 5
      end if
!
!     Unfiltered H, scaled with sqrt(J)
!     ---------------------------------
      !$acc loop vector collapse(3) private(Qn, Uxn, Uyn, Uzn, H, sqrt_mu, sqrt_alpha, sqrtJ)
      do k = 0, Nz ; do j = 0, Ny ; do i = 0, Nx
         call SC_SVVGetNode(e, i, j, k, Qn, Uxn, Uyn, Uzn)
         call SC_SVVViscosity_0D(region, switch, e % hn, delta, e % geom % dWall(i,j,k), &
                                 Qn, Uxn, Uyn, Uzn, sqrt_mu, sqrt_alpha)
         SVVdev_mu(1,i,j,k,eID) = sqrt_mu
         SVVdev_mu(2,i,j,k,eID) = sqrt_alpha
         call SVV_Hflux_0D(Qn, Uxn, Uyn, Uzn, sqrt_mu, sqrt_alpha, H(:,IX), H(:,IY), H(:,IZ))
         sqrtJ = sqrt(e % geom % jacobian(i,j,k))
         !$acc loop seq
         do dir = 1, NDIM
            !$acc loop seq
            do eq = 1, NCONS
               SVVdev_W(eq,i,j,k,dir,eID) = sqrtJ * H(eq,dir)
            end do
         end do
      end do       ; end do       ; end do
!
!     Filter in xi
!     ------------
      !$acc loop vector collapse(3) private(Hf, f)
      do k = 0, Nz ; do j = 0, Ny ; do i = 0, Nx
         Hf = 0.0_RP
         !$acc loop seq
         do l = 0, Nx
            f = SVVdev_filter(i,l,Nx)
            !$acc loop seq
            do dir = 1, NDIM
               !$acc loop seq
               do eq = 1, NCONS
                  Hf(eq,dir) = Hf(eq,dir) + f * SVVdev_W(eq,l,j,k,dir,eID)
               end do
            end do
         end do
         !$acc loop seq
         do dir = 1, NDIM
            !$acc loop seq
            do eq = 1, NCONS
               e % storage % AviscContravariantFlux(eq,i,j,k,dir) = Hf(eq,dir)
            end do
         end do
      end do       ; end do       ; end do
!
!     Filter in eta
!     -------------
      !$acc loop vector collapse(3) private(Hf, f)
      do k = 0, Nz ; do j = 0, Ny ; do i = 0, Nx
         Hf = 0.0_RP
         !$acc loop seq
         do l = 0, Ny
            f = SVVdev_filter(j,l,Ny)
            !$acc loop seq
            do dir = 1, NDIM
               !$acc loop seq
               do eq = 1, NCONS
                  Hf(eq,dir) = Hf(eq,dir) + f * e % storage % AviscContravariantFlux(eq,i,l,k,dir)
               end do
            end do
         end do
         !$acc loop seq
         do dir = 1, NDIM
            !$acc loop seq
            do eq = 1, NCONS
               SVVdev_W(eq,i,j,k,dir,eID) = Hf(eq,dir)
            end do
         end do
      end do       ; end do       ; end do
!
!     Filter in zeta, then the SVV flux
!     ---------------------------------
      SVV_diss = 0.0_RP
      !$acc loop vector collapse(3) reduction(+:SVV_diss) &
      !$acc private(Qn, Uxn, Uyn, Uzn, H, Hf, cartesianFlux, sqrt_mu, sqrt_alpha, sqrtJ, f, dissNode)
      do k = 0, Nz ; do j = 0, Ny ; do i = 0, Nx
         Hf = 0.0_RP
         !$acc loop seq
         do l = 0, Nz
            f = SVVdev_filter(k,l,Nz)
            !$acc loop seq
            do dir = 1, NDIM
               !$acc loop seq
               do eq = 1, NCONS
                  Hf(eq,dir) = Hf(eq,dir) + f * SVVdev_W(eq,i,j,l,dir,eID)
               end do
            end do
         end do

         call SC_SVVGetNode(e, i, j, k, Qn, Uxn, Uyn, Uzn)
         sqrt_mu    = SVVdev_mu(1,i,j,k,eID)
         sqrt_alpha = SVVdev_mu(2,i,j,k,eID)

         if (SVVdev_lowPass) then
            call SVV_Hflux_0D(Qn, Uxn, Uyn, Uzn, sqrt_mu, sqrt_alpha, H(:,IX), H(:,IY), H(:,IZ))
            sqrtJ = sqrt(e % geom % jacobian(i,j,k))
            !$acc loop seq
            do dir = 1, NDIM
               !$acc loop seq
               do eq = 1, NCONS
                  Hf(eq,dir) = sqrtJ * H(eq,dir) - Hf(eq,dir)
               end do
            end do
         end if

         call SVV_Flux_0D(Qn, Hf(:,IX), Hf(:,IY), Hf(:,IZ), sqrt_mu, sqrt_alpha, cartesianFlux)

         sqrtJ = sqrt(e % geom % invJacobian(i,j,k))
         !$acc loop seq
         do dir = 1, NDIM
            !$acc loop seq
            do eq = 1, NCONS
               cartesianFlux(eq,dir) = sqrtJ * cartesianFlux(eq,dir)
            end do
         end do
!
!        Dissipation estimate
!        --------------------
         dissNode = 0.0_RP
         !$acc loop seq
         do eq = eqMin, eqMax
            dissNode = dissNode + ( Uxn(eq) * cartesianFlux(eq,IX) &
                                  + Uyn(eq) * cartesianFlux(eq,IY) &
                                  + Uzn(eq) * cartesianFlux(eq,IZ) )
         end do
         SVV_diss = SVV_diss + NodalStorage(Nx) % w(i) * NodalStorage(Ny) % w(j) * NodalStorage(Nz) % w(k) &
                             * dissNode * e % geom % jacobian(i,j,k)
!
!        Contravariant flux
!        ------------------
         !$acc loop seq
         do eq = 1, NCONS
            e % storage % AviscContravariantFlux(eq,i,j,k,IX) =                       &
                 cartesianFlux(eq,IX) * e % geom % jGradXi(IX,i,j,k)                  &
               + cartesianFlux(eq,IY) * e % geom % jGradXi(IY,i,j,k)                  &
               + cartesianFlux(eq,IZ) * e % geom % jGradXi(IZ,i,j,k)

            e % storage % AviscContravariantFlux(eq,i,j,k,IY) =                       &
                 cartesianFlux(eq,IX) * e % geom % jGradEta(IX,i,j,k)                 &
               + cartesianFlux(eq,IY) * e % geom % jGradEta(IY,i,j,k)                 &
               + cartesianFlux(eq,IZ) * e % geom % jGradEta(IZ,i,j,k)

            e % storage % AviscContravariantFlux(eq,i,j,k,IZ) =                       &
                 cartesianFlux(eq,IX) * e % geom % jGradZeta(IX,i,j,k)                &
               + cartesianFlux(eq,IY) * e % geom % jGradZeta(IY,i,j,k)                &
               + cartesianFlux(eq,IZ) * e % geom % jGradZeta(IZ,i,j,k)
         end do

      end do       ; end do       ; end do

      e % storage % artificialDiss = SVV_diss
      SVVdev_diss(eID)             = SVV_diss

   end subroutine SC_ComputeElementSVVFlux
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_SVVViscosity_0D(region, switch, hn, delta, dWall, Q, Ux, Uy, Uz, sqrt_mu, sqrt_alpha)
!
!     sqrt(mu) and sqrt(alpha) at one node, as in SVV_viscosity (alpha is zero
!     where SVV_viscosity leaves it undefined)
!
      !$acc routine seq
      implicit none
      integer,       intent(in)  :: region
      real(kind=RP), intent(in)  :: switch, hn, delta, dWall
      real(kind=RP), intent(in)  :: Q(1:NCONS), Ux(1:NGRAD), Uy(1:NGRAD), Uz(1:NGRAD)
      real(kind=RP), intent(out) :: sqrt_mu, sqrt_alpha
!
!     ---------------
!     Local variables
!     ---------------
      real(kind=RP) :: salpha

      sqrt_mu = 0.0_RP
      salpha  = 0.0_RP

      select case (SCdev_update(region))
      case (SC_CONST_ID)
         if (switch >= 1.0_RP) then
            sqrt_mu = SCdev_sqrtMu2(region)    * hn
            salpha  = SCdev_sqrtAlpha2(region) * hn
         else
            sqrt_mu = SCdev_sqrtMu1(region)    * hn
            salpha  = SCdev_sqrtAlpha1(region) * hn
         end if

      case (SC_SENSOR_ID)
         sqrt_mu = (SCdev_sqrtMu1(region)    * (1.0_RP-switch) + SCdev_sqrtMu2(region)    * switch) * hn
         salpha  = (SCdev_sqrtAlpha1(region) * (1.0_RP-switch) + SCdev_sqrtAlpha2(region) * switch) * hn

#if !defined (SPALARTALMARAS)
      case (SC_SMAG_ID)
         call Smagorinsky_ComputeViscosity(delta, dWall, Q, Ux, Uy, Uz, sqrt_mu, &
                                           SCdev_smagC(region), SCdev_smagWallModel(region))
         sqrt_mu = sqrt(sqrt_mu)
#endif

      end select

      if (SCdev_alphaPropMu(region)) then
         sqrt_alpha = SCdev_sqrtMu2Alpha(region) * sqrt_mu
      else
         sqrt_alpha = salpha
      end if

   end subroutine SC_SVVViscosity_0D
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_SVVGetNode(e, i, j, k, Q, Ux, Uy, Uz)
!
!     Q and the gradients of node (i,j,k) as contiguous arrays
!
      !$acc routine seq
      implicit none
      type(Element), intent(in)  :: e
      integer,       intent(in)  :: i, j, k
      real(kind=RP), intent(out) :: Q(1:NCONS), Ux(1:NGRAD), Uy(1:NGRAD), Uz(1:NGRAD)
      integer :: eq

      do eq = 1, NCONS
         Q(eq) = e % storage % Q(eq,i,j,k)
      end do
      do eq = 1, NGRAD
         Ux(eq) = e % storage % U_x(eq,i,j,k)
         Uy(eq) = e % storage % U_y(eq,i,j,k)
         Uz(eq) = e % storage % U_z(eq,i,j,k)
      end do

   end subroutine SC_SVVGetNode
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_UpdateHostArtificialDiss(mesh)
!
!     SVV dissipation of each element back to the host, for the monitors
!
      implicit none
      type(HexMesh), intent(inout) :: mesh
      integer :: eID

      if (.not. SCdev_isSVV(1)) return

      !$acc wait(1)
      !$acc update self(SVVdev_diss)
      do eID = 1, size(mesh % elements)
         mesh % elements(eID) % storage % artificialDiss = SVVdev_diss(eID)
      end do

   end subroutine SC_UpdateHostArtificialDiss
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_ProlongAviscFluxToFaces(mesh)
!
!     Element AV flux to the faces, on the device. As HexMesh_ProlongSolToFaces,
!     it handles rotated faces but not p-nonconforming ones.
!
      implicit none
      type(HexMesh), intent(inout) :: mesh
      integer :: eID, fID

!$acc parallel loop gang collapse(2) present(mesh) num_gangs(size(mesh % elements)) vector_length(32) async(1)
      do eID = 1, size(mesh % elements)
         do fID = 1, 6
            call HexElement_ProlongAviscToFaces(mesh % elements(eID), NCONS,                        &
                                                mesh % faces(mesh % elements(eID) % faceIDs(fID)),  &
                                                mesh % elements(eID) % storage % AviscContravariantFlux, fID)
      end do ; end do
!$acc end parallel loop

   end subroutine SC_ProlongAviscFluxToFaces
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_describe(self)
!
!     -------
!     Modules
!     -------
      use MPI_Process_Info, only: MPI_Process
      use Headers,          only: Subsection_Header
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SCdriver_t), intent(in) :: self


      if (.not. MPI_Process % isRoot .or. .not. self % isActive) return

      write(STD_OUT, "(/)")
      call Subsection_Header("Shock-Capturing")

      call self % sensor % Describe()

      if (allocated(self % method1)) then
         write(STD_OUT,*) ""
         write(STD_OUT,"(30X,A,A30)") "=>", "First method"
         call self % method1 % Describe()
      end if

      if (allocated(self % method2)) then
         write(STD_OUT,*) ""
         write(STD_OUT,"(30X,A,A30)") "=>", "Second method"
         call self % method2 % Describe()
      end if

   end subroutine SC_describe
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SC_destruct(self)
!
!     ---------
!     Interface
!     ---------
      implicit none
      type(SCdriver_t), intent(inout) :: self


      self%isActive = .false.

      call Destruct_SCsensor(self % sensor)
      if (allocated(SCdev_sensor)) deallocate(SCdev_sensor)
      if (allocated(SCdev_gmmx))   deallocate(SCdev_gmmx)
      if (allocated(SCdev_first))  deallocate(SCdev_first)

      if (allocated(self % method1)) deallocate(self % method1)
      if (allocated(self % method2)) deallocate(self % method2)

   end subroutine SC_destruct
!
!///////////////////////////////////////////////////////////////////////////////
!
!     Shock-capturing methods base class
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine AV_initialize(self, controlVariables, mesh, region)
!
!     -------
!     Modules
!     -------
      use FTValueDictionaryClass
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(ArtificialViscosity_t), intent(inout) :: self
      type(FTValueDictionary),      intent(in)    :: controlVariables
      type(HexMesh),                intent(inout) :: mesh
      integer,                      intent(in)    :: region
!
!     ---------------
!     Local variables
!     ---------------
      character(len=:), allocatable :: update

!
!     Viscosity values (mu and alpha)
!     -------------------------------
      if (region == 1) then

         if (controlVariables % containsKey(SC_MU1_KEY)) then
            self % mu1 = controlVariables % doublePrecisionValueForKey(SC_MU1_KEY)
         else
            self % mu1 = 0.0_RP
         end if

         if (controlVariables % containsKey(SC_MU2_KEY)) then
            self % mu2 = controlVariables % doublePrecisionValueForKey(SC_MU2_KEY)
         else
            self % mu2 = self % mu1
         end if

      else

         if (controlVariables % containsKey(SC_MU2_KEY)) then
            self % mu2 = controlVariables % doublePrecisionValueForKey(SC_MU2_KEY)
         else
            self % mu2 = 0.0_RP
         end if
         self % mu1 = self % mu2

      end if

      if (controlVariables % containsKey(SC_ALPHA_MU_KEY)) then

         self % alphaIsPropToMu = .true.
         self % mu2alpha        = controlVariables % doublePrecisionValueForKey(SC_ALPHA_MU_KEY)
         self % alpha1          = self % mu2alpha * self % mu1
         self % alpha2          = self % mu2alpha * self % mu2

      else

         self % alphaIsPropToMu = .false.

         if (region == 1) then

            if (controlVariables % containsKey(SC_ALPHA1_KEY)) then
               self % alpha1 = controlVariables % doublePrecisionValueForKey(SC_ALPHA1_KEY)
            else
               self % alpha1 = 0.0_RP
            end if

            if (controlVariables % containsKey(SC_ALPHA2_KEY)) then
               self % alpha2 = controlVariables % doublePrecisionValueForKey(SC_ALPHA2_KEY)
            else
               self % alpha2 = self % alpha1
            end if

         else

            if (controlVariables % containsKey(SC_ALPHA2_KEY)) then
               self % alpha2 = controlVariables % doublePrecisionValueForKey(SC_ALPHA2_KEY)
            else
               self % alpha2 = 0.0_RP
            end if
            self % alpha1 = self % alpha2

         end if

      end if
!
!     Viscosity update method
!     -----------------------
      if (region == 1) then

         if (controlVariables % containsKey(SC_UPDATE_KEY)) then
            update = controlVariables % StringValueForKey(SC_UPDATE_KEY, LINE_LENGTH)
            call toLower(update)

            select case (trim(update))
            case (SC_CONST_VAL)
               self % updateMethod = SC_CONST_ID

            case (SC_SENSOR_VAL)
               self % updateMethod = SC_SENSOR_ID

#if !defined (SPALARTALMARAS)
            case (SC_SMAG_VAL)

               self % updateMethod = SC_SMAG_ID
               if (.not. self % alphaIsPropToMu) then
                  write(STD_OUT,*) 'ERROR. Alpha must be proportional to mu when using shock-capturing with LES.'
                  error stop
               end if

               ! TODO: Use the default constructor
               self % Smagorinsky % active = .true.
               self % Smagorinsky % requiresWallDistances = .false.
               self % Smagorinsky % WallModel = 0  ! No wall model
               self % Smagorinsky % C = self % mu1
#endif

            case default
               write(STD_OUT,*) 'ERROR. Unavailable shock-capturing update strategy. Options are:'
               write(STD_OUT,*) '   * ', SC_CONST_VAL
               write(STD_OUT,*) '   * ', SC_SENSOR_VAL
#if !defined (SPALARTALMARAS)
               write(STD_OUT,*) '   * ', SC_SMAG_VAL
#endif
               error stop

            end select

         else
            self % updateMethod = SC_CONST_ID

         end if

      else

         self % updateMethod = SC_CONST_ID

      end if

   end subroutine AV_initialize
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine AV_viscosity(self, mesh, e, switch, SCflux)
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(ArtificialViscosity_t), intent(in)    :: self
      type(HexMesh),                intent(inout) :: mesh
      type(Element),                intent(inout) :: e
      real(RP),                     intent(in)    :: switch
      real(RP),                     intent(out)   :: SCflux(1:NCONS,       &
                                                            0:e % Nxyz(1), &
                                                            0:e % Nxyz(2), &
                                                            0:e % Nxyz(3), &
                                                            1:NDIM)


      SCflux = 0.0_RP

   end subroutine AV_viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine AV_describe(self)
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(ArtificialViscosity_t), intent(in) :: self

   end subroutine AV_describe
!
!///////////////////////////////////////////////////////////////////////////////
!
!     Simple artificial viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine NoSVV_initialize(self, controlVariables, mesh, region)
!
!     -------
!     Modules
!     -------
      use FTValueDictionaryClass
      use PhysicsStorage, only: grad_vars, GRADVARS_STATE, &
                                GRADVARS_ENTROPY, GRADVARS_ENERGY
      use Physics,        only: ViscousFlux_STATE, ViscousFlux_ENTROPY, &
                                ViscousFlux_ENERGY, GuermondPopovFlux_ENTROPY
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_NoSVV_t),       intent(inout) :: self
      type(FTValueDictionary), intent(in)    :: controlVariables
      type(HexMesh),           intent(inout) :: mesh
      integer,                 intent(in)    :: region
!
!     ---------------
!     Local variables
!     ---------------
      character(len=:), allocatable :: flux

!
!     Parent initializer
!     ------------------
      call self % ArtificialViscosity_t % Initialize(controlVariables, mesh, region)
      self % region = region
!
!     Set the flux type
!     -----------------
      if (region == 1 .and. controlVariables % containsKey(SC_VISC_FLUX1_KEY)) then
         flux = controlVariables % stringValueForKey(SC_VISC_FLUX1_KEY, LINE_LENGTH)
      elseif (region == 2 .and. controlVariables % containsKey(SC_VISC_FLUX2_KEY)) then
         flux = controlVariables % stringValueForKey(SC_VISC_FLUX2_KEY, LINE_LENGTH)
      else
         flux = SC_PHYS_VAL
      end if

      call toLower(flux)

      select case (trim(flux))
      case (SC_PHYS_VAL); self % fluxType = SC_PHYS_ID
      case (SC_GP_VAL);   self % fluxType = SC_GP_ID
      case default
         write(STD_OUT,'(A,I1,A)') 'ERROR. Artificial viscosity ', region, &
                                   ' not recognized. Options are:'
         write(STD_OUT,*) '   * ', SC_PHYS_VAL
         write(STD_OUT,*) '   * ', SC_GP_VAL
         error stop
      end select

      select case (self % fluxType)
      case (SC_PHYS_ID)
         select case (grad_vars)
         case (GRADVARS_STATE);   self % ViscousFlux => ViscousFlux_STATE
         case (GRADVARS_ENTROPY); self % ViscousFlux => ViscousFlux_ENTROPY
         case (GRADVARS_ENERGY);  self % ViscousFlux => ViscousFlux_ENERGY
         end select

      case (SC_GP_ID)
         select case (grad_vars)
         case (GRADVARS_ENTROPY); self % ViscousFlux => GuermondPopovFlux_ENTROPY
         case default
            write(STD_OUT,*) "ERROR. Guermond-Popov (2014) artificial ",  &
                              "viscosity is only configured for Entropy ", &
                              "gradient variables"
            error stop
         end select

      end select
!
!     Flat copy for the device kernels (pushed by SC_SyncDeviceConfig)
!     ---------------------------------------------------------------
      SCdev_hasMethod(region) = .true.
      SCdev_update(region)    = self % updateMethod
      SCdev_fluxType(region)  = self % fluxType
      SCdev_mu1(region)       = self % mu1
      SCdev_mu2(region)       = self % mu2
#if !defined (SPALARTALMARAS)
      SCdev_smagC(region)         = self % Smagorinsky % C
      SCdev_smagWallModel(region) = self % Smagorinsky % WallModel
#endif

   end subroutine NoSVV_initialize
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine NoSVV_viscosity(self, mesh, e, switch, SCflux)
!
!     --------------------------------------------------------------------------
!     TODO: Introduce alpha viscosity, which probably means reimplementing here
!           all the viscous fluxes of `Physics_NS`...
!     --------------------------------------------------------------------------
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_NoSVV_t), intent(in)    :: self
      type(HexMesh),     intent(inout) :: mesh
      type(Element),     intent(inout) :: e
      real(RP),          intent(in)    :: switch
      real(RP),          intent(out)   :: SCflux(1:NCONS,       &
                                                 0:e % Nxyz(1), &
                                                 0:e % Nxyz(2), &
                                                 0:e % Nxyz(3), &
                                                 1:NDIM)
!
!     ---------------
!     Local variables
!     ---------------
      integer  :: i
      integer  :: j
      integer  :: k
      integer  :: fIDs(6)
      real(RP) :: delta
      real(RP) :: kappa
      real(RP) :: mu(0:e % Nxyz(1), 0:e % Nxyz(2), 0:e % Nxyz(3))
      real(RP) :: covariantFlux(1:NCONS, 1:NDIM)


      if (switch > 0.0_RP) then
!
!        Compute viscosity
!        -----------------
         select case (self % updateMethod)
         case (SC_CONST_ID)
            mu = merge(self % mu2, self % mu1, switch >= 1.0_RP) * e % hn

         case (SC_SENSOR_ID)
            mu = (self % mu1 * (1.0_RP-switch) + self % mu2 * switch) * e % hn

#if !defined (SPALARTALMARAS)
         case (SC_SMAG_ID)

            delta = (e % geom % Volume / product(e % Nxyz + 1)) ** (1.0_RP / 3.0_RP)
            do k = 0, e % Nxyz(3) ; do j = 0, e % Nxyz(2) ; do i = 0, e % Nxyz(1)
               call Smagorinsky_ComputeViscosity(delta, e % geom % dWall(i,j,k), &
                                                 e % storage % Q(:,i,j,k),       &
                                                 e % storage % U_x(:,i,j,k),     &
                                                 e % storage % U_y(:,i,j,k),     &
                                                 e % storage % U_z(:,i,j,k),     &
                                                 mu(i,j,k),                      &
                                                 self % smagorinsky % C,            &
                                                 self % smagorinsky % WallModel)
            end do                ; end do                ; end do
#endif

         end select
!
!        Compute the viscous flux
!        ------------------------
         do k = 0, e % Nxyz(3) ; do j = 0, e % Nxyz(2) ; do i = 0, e % Nxyz(1)

            kappa = dimensionless % mu_to_kappa * mu(i,j,k)
            call self % ViscousFlux(NCONS, NGRAD, e % storage % Q(:,i,j,k), &
                                    e % storage % U_x(:,i,j,k),             &
                                    e % storage % U_y(:,i,j,k),             &
                                    e % storage % U_z(:,i,j,k),             &
                                    mu(i,j,k), 0.0_RP, kappa,               &
                                    covariantflux)

            SCflux(:,i,j,k,IX) = covariantFlux(:,IX) * e % geom % jGradXi(IX,i,j,k) &
                               + covariantFlux(:,IY) * e % geom % jGradXi(IY,i,j,k) &
                               + covariantFlux(:,IZ) * e % geom % jGradXi(IZ,i,j,k)


            SCflux(:,i,j,k,IY) = covariantFlux(:,IX) * e % geom % jGradEta(IX,i,j,k) &
                               + covariantFlux(:,IY) * e % geom % jGradEta(IY,i,j,k) &
                               + covariantFlux(:,IZ) * e % geom % jGradEta(IZ,i,j,k)


            SCflux(:,i,j,k,IZ) = covariantFlux(:,IX) * e % geom % jGradZeta(IX,i,j,k) &
                               + covariantFlux(:,IY) * e % geom % jGradZeta(IY,i,j,k) &
                               + covariantFlux(:,IZ) * e % geom % jGradZeta(IZ,i,j,k)

         end do                ; end do                ; end do

      else

         e % storage % artificialDiss = 0.0_RP
         SCflux = 0.0_RP

      end if
!
!     Project to faces
!     ----------------
      fIDs = e % faceIDs
      call e % ProlongAviscFluxToFaces(NCONS, SCflux, mesh % faces(fIDs(1)), &
                                                      mesh % faces(fIDs(2)), &
                                                      mesh % faces(fIDs(3)), &
                                                      mesh % faces(fIDs(4)), &
                                                      mesh % faces(fIDs(5)), &
                                                      mesh % faces(fIDs(6))  )

   end subroutine NoSVV_viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine NoSVV_describe(self)
!
!     -------
!     Modules
!     -------
      use MPI_Process_Info, only: MPI_Process
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_NoSVV_t), intent(in) :: self


      if (.not. MPI_Process % isRoot) return

      write(STD_OUT,"(30X,A,A30)", advance="no") "->", "Viscosity update method: "
      select case (self % updateMethod)
         case (SC_CONST_ID);  write(STD_OUT,"(A)") SC_CONST_VAL
         case (SC_SENSOR_ID); write(STD_OUT,"(A)") SC_SENSOR_VAL
         case (SC_SMAG_ID);   write(STD_OUT,"(A)") SC_SMAG_VAL
      end select

      if (self % updateMethod == SC_SMAG_ID) then
#if !defined (SPALARTALMARAS)
         write(STD_OUT,"(30X,A,A30,1pG10.3)") "->", "LES intensity (CS): ", self % Smagorinsky % C
#endif
      else
         if (self % region == 1) then
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity 1: ", self % mu1
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity 2: ", self % mu2
         else ! self % region == 2
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity: ", self % mu2
         end if
      end if

      if (self % alphaIsPropToMu) then
         write(STD_OUT,"(30X,A,A30,1pG10.3,A)") "->", "Alpha viscosity: ", self % mu2alpha, "x mu"
      else
         if (self % region == 1) then
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity 1: ", self % alpha1
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity 2: ", self % alpha2
         else ! self % region == 2
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity: ", self % alpha2
         end if
      end if

      write(STD_OUT,"(30X,A,A30)", advance="no") "->", "Dissipation type: "
      select case (self % fluxType)
         case (SC_PHYS_ID); write(STD_OUT,"(A)") SC_PHYS_VAL
         case (SC_GP_ID);   write(STD_OUT,"(A)") SC_GP_VAL
      end select

   end subroutine NoSVV_describe
!
!///////////////////////////////////////////////////////////////////////////////
!
   pure subroutine NoSVV_destruct(self)
!
!     ---------
!     Interface
!     ---------
      implicit none
      type(SC_NoSVV_t), intent(inout) :: self


      if (associated(self % ViscousFlux)) nullify(self % ViscousFlux)

   end subroutine NoSVV_destruct
!
!///////////////////////////////////////////////////////////////////////////////
!
!     SVV filtered viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SVV_initialize(self, controlVariables, mesh, region)
!
!     -------
!     Modules
!     -------
      use FTValueDictionaryClass
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_SVV_t),         intent(inout) :: self
      type(FTValueDictionary), intent(in)    :: controlVariables
      type(HexMesh),           intent(inout) :: mesh
      integer,                 intent(in)    :: region


      ! TODO: Implement it also for region 2, but SVV does not seem very useful there...
      if (region == 2) then
         write(STD_OUT,*) "ERROR. SVV viscosity can be used only in the first region of the sensor."
         error stop
      end if
!
!     Parent initializer
!     ------------------
      call self % ArtificialViscosity_t % Initialize(controlVariables, mesh, region)
      self % region = region
!
!     Set the square root of the viscosities
!     --------------------------------------
      self % sqrt_mu1 = sqrt(self % mu1)
      self % sqrt_mu2 = sqrt(self % mu2)

      if (self % alphaIsPropToMu) then
         self % sqrt_mu2alpha = sqrt(self % mu2alpha)
      else
         self % sqrt_alpha1 = sqrt(self % alpha1)
         self % sqrt_alpha2 = sqrt(self % alpha2)
      end if
!
!     Start the SVV module
!     --------------------
      call InitializeSVV(SVV, controlVariables, mesh)
!
!     Flat copy for the device kernels (pushed by SC_SyncDeviceConfig)
!     ---------------------------------------------------------------
      SCdev_hasMethod(region)   = .true.
      SCdev_isSVV(region)       = .true.
      SCdev_update(region)      = self % updateMethod
      SCdev_sqrtMu1(region)     = self % sqrt_mu1
      SCdev_sqrtMu2(region)     = self % sqrt_mu2
      SCdev_alphaPropMu(region) = self % alphaIsPropToMu
      if (self % alphaIsPropToMu) then
         SCdev_sqrtMu2Alpha(region) = self % sqrt_mu2alpha
      else
         SCdev_sqrtAlpha1(region) = self % sqrt_alpha1
         SCdev_sqrtAlpha2(region) = self % sqrt_alpha2
      end if
#if !defined (SPALARTALMARAS)
      SCdev_smagC(region)         = self % Smagorinsky % C
      SCdev_smagWallModel(region) = self % Smagorinsky % WallModel
#endif

   end subroutine SVV_initialize
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SVV_viscosity(self, mesh, e, switch, SCflux)
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_SVV_t), intent(in)    :: self
      type(HexMesh),   intent(inout) :: mesh
      type(Element),   intent(inout) :: e
      real(RP),        intent(in)    :: switch
      real(RP),        intent(out)   :: SCflux(1:NCONS,       &
                                               0:e % Nxyz(1), &
                                               0:e % Nxyz(2), &
                                               0:e % Nxyz(3), &
                                               1:NDIM)
!
!     ---------------
!     Local variables
!     ---------------
      integer  :: i
      integer  :: j
      integer  :: k
      integer  :: fIDs(6)
      real(RP) :: delta
      real(RP) :: salpha
      real(RP) :: sqrt_mu(0:e % Nxyz(1), 0:e % Nxyz(2), 0:e % Nxyz(3))
      real(RP) :: sqrt_alpha(0:e % Nxyz(1), 0:e % Nxyz(2), 0:e % Nxyz(3))


      if (switch > 0.0_RP) then
!
!        Compute viscosities
!        -------------------
         select case (self % updateMethod)
         case (SC_CONST_ID)
            sqrt_mu = merge(self % sqrt_mu2,    self % sqrt_mu1,    switch >= 1.0_RP) * e % hn
            salpha  = merge(self % sqrt_alpha2, self % sqrt_alpha1, switch >= 1.0_RP) * e % hn

         case (SC_SENSOR_ID)
            sqrt_mu = (self % sqrt_mu1 * (1.0_RP-switch) + self % sqrt_mu2 * switch) * e % hn
            salpha  = (self % sqrt_alpha1 * (1.0_RP-switch) + self % sqrt_alpha2 * switch) * e % hn

#if !defined (SPALARTALMARAS)
         case (SC_SMAG_ID)

            delta = (e % geom % Volume / product(e % Nxyz + 1)) ** (1.0_RP / 3.0_RP)
            do k = 0, e % Nxyz(3) ; do j = 0, e % Nxyz(2) ; do i = 0, e % Nxyz(1)
               call Smagorinsky_ComputeViscosity(delta, e % geom % dWall(i,j,k), &
                                                 e % storage % Q(:,i,j,k),       &
                                                 e % storage % U_x(:,i,j,k),     &
                                                 e % storage % U_y(:,i,j,k),     &
                                                 e % storage % U_z(:,i,j,k),     &
                                                 sqrt_mu(i,j,k),                 &
                                                 self % smagorinsky % C,         &
                                                 self % smagorinsky % WallModel)
               sqrt_mu(i,j,k) = sqrt(sqrt_mu(i,j,k))
            end do                ; end do                ; end do
#endif

         end select

         if (self % alphaIsPropToMu) then
            sqrt_alpha = self % sqrt_mu2alpha * sqrt_mu
         else
            sqrt_alpha = salpha
         end if
!
!        Compute the viscous flux
!        ------------------------
         call SVV % ComputeInnerFluxes(e, sqrt_mu, sqrt_alpha, SCflux)

      else

         e % storage % artificialDiss = 0.0_RP
         SCflux = 0.0_RP

      end if
!
!     Project to faces
!     ----------------
      fIDs = e % faceIDs
      call e % ProlongAviscFluxToFaces(NCONS, SCflux, mesh % faces(fIDs(1)), &
                                                      mesh % faces(fIDs(2)), &
                                                      mesh % faces(fIDs(3)), &
                                                      mesh % faces(fIDs(4)), &
                                                      mesh % faces(fIDs(5)), &
                                                      mesh % faces(fIDs(6))  )

   end subroutine SVV_viscosity
!
!///////////////////////////////////////////////////////////////////////////////
!
   subroutine SVV_describe(self)
!
!     -------
!     Modules
!     -------
      use MPI_Process_Info, only: MPI_Process
!
!     ---------
!     Interface
!     ---------
      implicit none
      class(SC_SVV_t), intent(in) :: self


      if (.not. MPI_Process % isRoot) return

      write(STD_OUT,"(30X,A,A30)", advance="no") "->", "Viscosity update method: "
      select case (self % updateMethod)
         case (SC_CONST_ID);  write(STD_OUT,"(A)") SC_CONST_VAL
         case (SC_SENSOR_ID); write(STD_OUT,"(A)") SC_SENSOR_VAL
         case (SC_SMAG_ID);   write(STD_OUT,"(A)") SC_SMAG_VAL
      end select

      if (self % updateMethod == SC_SMAG_ID) then
#if !defined (SPALARTALMARAS)
         write(STD_OUT,"(30X,A,A30,1pG10.3)") "->", "LES intensity (CS): ", self % Smagorinsky % C
#endif
      else
         if (self % region == 1) then
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity 1: ", self % mu1
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity 2: ", self % mu2
         else ! self % region == 2
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Mu viscosity: ", self % mu2
         end if
      end if

      if (self % alphaIsPropToMu) then
         write(STD_OUT,"(30X,A,A30,1pG10.3,A)") "->", "Alpha viscosity: ", self % mu2alpha, "x mu"
      else
         if (self % region == 1) then
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity 1: ", self % alpha1
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity 2: ", self % alpha2
         else ! self % region == 2
            write(STD_OUT,"(30X,A,A30,1pG10.3)") "->","Alpha viscosity: ", self % alpha2
         end if
      end if

      call SVV % Describe()

   end subroutine SVV_describe

end module ShockCapturing
