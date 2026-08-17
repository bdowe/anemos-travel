// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Anemos';

  @override
  String get languageSectionTitle => 'Idioma';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageChangeNote =>
      'Los viajes y las notas que ya guardaste se mantienen en el idioma en que se escribieron.';

  @override
  String get languageMenuTooltip => 'Cambiar idioma';

  @override
  String get appearanceLanguageSectionTitle => 'Apariencia e idioma';

  @override
  String get appearanceSectionTitle => 'Apariencia';

  @override
  String get appearanceSystem => 'Usar la configuración del dispositivo';

  @override
  String get appearanceLight => 'Claro';

  @override
  String get appearanceDark => 'Oscuro';

  @override
  String get commonSave => 'Guardar';

  @override
  String get commonCancel => 'Cancelar';

  @override
  String get commonDelete => 'Eliminar';

  @override
  String get commonRetry => 'Reintentar';

  @override
  String get commonClose => 'Cerrar';

  @override
  String get commonBack => 'Atrás';

  @override
  String get commonNext => 'Siguiente';

  @override
  String get commonDone => 'Listo';

  @override
  String get commonSeeAll => 'Ver todo';

  @override
  String citiesTwo(String first, String second) {
    return '$first y $second';
  }

  @override
  String citiesMore(String first, String second, int count) {
    return '$first y $second +$count más';
  }

  @override
  String get prefsTitle => 'Perfil de viaje';

  @override
  String get prefsBudget => 'Presupuesto';

  @override
  String get prefsPace => 'Ritmo';

  @override
  String get prefsInterests => 'Intereses';

  @override
  String get prefsAddInterest => 'Añadir un interés';

  @override
  String get prefsHomeAirport => 'Aeropuerto de origen';

  @override
  String get prefsHomeAirportHelp =>
      'Se usa como origen predeterminado al planificar vuelos.';

  @override
  String get prefsHomeAirportPickOne =>
      'Elige un aeropuerto de la lista o vacía el campo.';

  @override
  String get prefsProfileNotes => 'Notas del perfil';

  @override
  String get prefsProfileNotesHelp =>
      'Tu agente de IA mantiene estas notas a medida que te conoce. Puedes editarlas o borrarlas cuando quieras.';

  @override
  String get prefsProfileNotesHint =>
      'Todavía no hay notas: el agente las va añadiendo mientras planificas viajes.';

  @override
  String get prefsSaved => 'Preferencias guardadas';

  @override
  String get prefsSaveFailed => 'No se pudieron guardar las preferencias';

  @override
  String get prefsLoadErrorTitle => 'No se pudo cargar tu perfil de viaje';

  @override
  String get prefsLoadErrorMessage =>
      'Revisa tu conexión e inténtalo de nuevo.';

  @override
  String get prefsBudgetLow => 'económico';

  @override
  String get prefsBudgetMid => 'medio';

  @override
  String get prefsBudgetLuxury => 'lujo';

  @override
  String get prefsWorkStyle => 'Trabajo y viajes';

  @override
  String get prefsWorkStyleNomad => 'sí, trabajo mientras viajo';

  @override
  String get prefsWorkStyleWorkation => 'a veces';

  @override
  String get prefsWorkStyleLeisure => 'no, los viajes son para desconectar';

  @override
  String get prefsCompanions => 'Con quién viajas';

  @override
  String get prefsFitnessRoutine => 'Ejercicio';

  @override
  String get prefsFitnessRoutineHelp =>
      'Sirve para elegir alojamientos cerca de un gimnasio o de un sitio para correr, y para dejarte el tiempo.';

  @override
  String get prefsFitnessGym => 'acceso a gimnasio';

  @override
  String get prefsFitnessRunning => 'rutas para correr';

  @override
  String get prefsFitnessBoth => 'ambos';

  @override
  String get prefsFitnessNone => 'no es un factor';

  @override
  String get prefsOutdoorIntensity => 'Días al aire libre';

  @override
  String get prefsOutdoorIntensityHelp =>
      'Qué tan exigentes quieres que sean las rutas y otras salidas activas.';

  @override
  String get prefsOutdoorEasy => 'fácil: paseos y miradores';

  @override
  String get prefsOutdoorModerate => 'moderado: rutas de medio día';

  @override
  String get prefsOutdoorChallenging => 'exigente: largo y con desnivel';

  @override
  String get prefsBaggage => 'Con qué equipaje vuelas';

  @override
  String get prefsBaggageHelp =>
      'Los precios de los vuelos se calculan con este equipaje incluido, para que la opción más barata lo sea de verdad.';

  @override
  String get prefsPaceRelaxed => 'relajado';

  @override
  String get prefsPaceBalanced => 'equilibrado';

  @override
  String get prefsPacePacked => 'intenso';

  @override
  String get prefsInterestMuseums => 'museos';

  @override
  String get prefsInterestFood => 'gastronomía';

  @override
  String get prefsInterestNightlife => 'vida nocturna';

  @override
  String get prefsInterestNature => 'naturaleza';

  @override
  String get prefsInterestHistory => 'historia';

  @override
  String get prefsInterestArt => 'arte';

  @override
  String get prefsInterestShopping => 'compras';

  @override
  String get prefsInterestOutdoors => 'aire libre';

  @override
  String get prefsInterestBeaches => 'playas';

  @override
  String get prefsInterestArchitecture => 'arquitectura';

  @override
  String get prefsInterestLiveMusic => 'música en vivo';

  @override
  String get prefsInterestBars => 'bares';

  @override
  String get prefsInterestTheater => 'teatro';

  @override
  String get prefsInterestFestivals => 'festivales';

  @override
  String get prefsInterestLocalMarkets => 'mercados locales';

  @override
  String get prefsInterestStreetFood => 'comida callejera';

  @override
  String get prefsInterestCoffee => 'café';

  @override
  String get prefsInterestWine => 'vino';

  @override
  String get prefsInterestCraftBeer => 'cerveza artesanal';

  @override
  String get prefsInterestFineDining => 'alta cocina';

  @override
  String get prefsInterestHiking => 'senderismo';

  @override
  String get prefsInterestWildlife => 'vida silvestre';

  @override
  String get prefsInterestWaterSports => 'deportes acuáticos';

  @override
  String get prefsInterestSkiing => 'esquí';

  @override
  String get prefsInterestCycling => 'ciclismo';

  @override
  String get prefsInterestClimbing => 'escalada';

  @override
  String get prefsInterestNationalParks => 'parques nacionales';

  @override
  String get prefsInterestRoadTrips => 'viajes por carretera';

  @override
  String get prefsInterestPhotography => 'fotografía';

  @override
  String get prefsInterestStreetArt => 'arte urbano';

  @override
  String get prefsInterestWellness => 'bienestar';

  @override
  String get prefsInterestSpas => 'spas';

  @override
  String get prefsInterestSportsEvents => 'eventos deportivos';

  @override
  String get ssoContinueWithGoogle => 'Continuar con Google';

  @override
  String get ssoContinueWithApple => 'Continuar con Apple';

  @override
  String get ssoDividerOr => 'o';

  @override
  String get authWelcomeBack => 'Bienvenido de nuevo';

  @override
  String get authCreateAccountTitle => 'Crea tu cuenta';

  @override
  String get authEmailLabel => 'Correo electrónico';

  @override
  String get authEmailRequired => 'El correo electrónico es obligatorio';

  @override
  String get authEmailInvalid => 'Introduce un correo electrónico válido';

  @override
  String get authPasswordLabel => 'Contraseña';

  @override
  String get authPasswordRequired => 'La contraseña es obligatoria';

  @override
  String get authPasswordTooShort =>
      'La contraseña debe tener al menos 8 caracteres';

  @override
  String get authDisplayNameLabel => 'Nombre visible (opcional)';

  @override
  String get authSignIn => 'Iniciar sesión';

  @override
  String get authCreateAccount => 'Crear cuenta';

  @override
  String get authNoAccountPrompt => '¿No tienes cuenta? Regístrate';

  @override
  String get authHaveAccountPrompt => '¿Ya tienes cuenta? Inicia sesión';

  @override
  String get authForgotPassword => '¿Olvidaste tu contraseña?';

  @override
  String get authPasswordUpdatedSnack =>
      'Contraseña actualizada — inicia sesión con tu nueva contraseña';

  @override
  String get authResetDialogTitle => 'Restablece tu contraseña';

  @override
  String get authResetDialogBody =>
      'Te enviaremos por correo un código de restablecimiento si esta dirección tiene una cuenta.';

  @override
  String get authSending => 'Enviando…';

  @override
  String get authSendCode => 'Enviar código';

  @override
  String get authEnterCodeTitle => 'Introduce tu código de restablecimiento';

  @override
  String get authEnterCodeBody =>
      'Revisa tu bandeja de entrada para ver el código que acabamos de enviarte.';

  @override
  String get authResetCodeLabel => 'Código de restablecimiento';

  @override
  String get authNewPasswordLabel => 'Nueva contraseña';

  @override
  String get authCodeRequired => 'Pega el código del correo';

  @override
  String get authSaving => 'Guardando…';

  @override
  String get authSetNewPassword => 'Guardar nueva contraseña';

  @override
  String get authErrorInvalidCredentials => 'Correo o contraseña incorrectos.';

  @override
  String get authErrorEmailTaken =>
      'Ese correo ya tiene una cuenta: prueba a iniciar sesión.';

  @override
  String get authErrorBadResetCode =>
      'El código no coincide: revísalo o solicita uno nuevo.';

  @override
  String get resetAppBarTitle => 'Restablecer contraseña';

  @override
  String get resetSuccessTitle => 'Contraseña actualizada';

  @override
  String get resetSuccessBody =>
      'Inicia sesión con tu nueva contraseña. Se cerraron las demás sesiones.';

  @override
  String get resetSignInButton => 'Iniciar sesión';

  @override
  String get resetChooseTitle => 'Elige una nueva contraseña';

  @override
  String get resetNewPasswordLabel => 'Nueva contraseña';

  @override
  String get resetPasswordRequired => 'La contraseña es obligatoria';

  @override
  String get resetPasswordTooShort =>
      'La contraseña debe tener al menos 8 caracteres';

  @override
  String get resetConfirmLabel => 'Confirma la nueva contraseña';

  @override
  String get resetConfirmRequired => 'Confirma tu nueva contraseña';

  @override
  String get resetPasswordsMismatch => 'Las contraseñas no coinciden';

  @override
  String get resetSetNewPassword => 'Guardar nueva contraseña';

  @override
  String get landingSignIn => 'Iniciar sesión';

  @override
  String get landingHeroTagline => 'Planifica menos. Viaja más.';

  @override
  String get landingHeroSubtitle =>
      'Tu compañero de viaje con IA: describe el viaje que quieres y recibe un itinerario completo, día a día, con rutas, lugares y vuelos.';

  @override
  String get landingHaveAccount => 'Ya tengo una cuenta';

  @override
  String get landingGetStarted => 'Empezar';

  @override
  String get landingFeaturesTitle =>
      'Todo lo que necesitas para planificar el viaje';

  @override
  String get landingFeatureAgentTitle => 'Agente de viajes con IA';

  @override
  String get landingFeatureAgentDescription =>
      'Describe el viaje de tus sueños y recibe un itinerario completo en segundos.';

  @override
  String get landingCopyright => '© 2026 Golden Tempo LLC';

  @override
  String get verifyTitle => 'Verificar correo';

  @override
  String get verifyChecking => 'Confirmando tu correo…';

  @override
  String get verifySuccessTitle => 'Correo verificado ✓';

  @override
  String get verifySuccessBody =>
      'Todo listo: gracias por confirmar tu dirección.';

  @override
  String get verifyLinkExpiredTitle => 'El enlace caducó o ya se usó';

  @override
  String get verifyLinkExpiredBody =>
      'Solicita un nuevo correo de verificación desde tu cuenta.';

  @override
  String get verifyContinue => 'Continuar';

  @override
  String get ssoTitle => 'Iniciando tu sesión';

  @override
  String get ssoFailedTitle => 'No se completó el inicio de sesión';

  @override
  String get ssoErrorCancelled =>
      'El inicio de sesión se canceló o falló. Inténtalo de nuevo.';

  @override
  String get ssoErrorExpired =>
      'Este enlace de inicio de sesión caducó. Inténtalo de nuevo.';

  @override
  String get ssoBackToSignIn => 'Volver a iniciar sesión';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsProfileSection => 'Perfil';

  @override
  String get settingsDisplayName => 'Nombre visible';

  @override
  String get settingsSaveName => 'Guardar nombre';

  @override
  String get settingsNameUpdated => 'Nombre actualizado';

  @override
  String get settingsPasswordSection => 'Contraseña';

  @override
  String get settingsCurrentPassword => 'Contraseña actual';

  @override
  String get settingsNewPassword => 'Contraseña nueva (8 caracteres o más)';

  @override
  String get settingsChangePassword => 'Cambiar contraseña';

  @override
  String get settingsPasswordChanged =>
      'Contraseña cambiada: se cerró la sesión en los demás dispositivos';

  @override
  String get settingsSessionsSection => 'Sesiones';

  @override
  String get settingsSessionsHelp =>
      'Cierra tu sesión en todos los dispositivos, incluido este.';

  @override
  String get settingsSignOutEverywhere =>
      'Cerrar sesión en todos los dispositivos';

  @override
  String get settingsSignOutEverywhereTitle =>
      '¿Cerrar sesión en todos los dispositivos?';

  @override
  String get settingsSignOutEverywhereBody =>
      'Esto cierra tu sesión en todos los dispositivos, incluido este.';

  @override
  String get settingsEmailPrefsSection => 'Preferencias de correo';

  @override
  String get settingsTripReminders => 'Recordatorios de viaje';

  @override
  String get settingsTripRemindersSubtitle =>
      'Avisos sobre viajes próximos y cosas que te faltan por reservar.';

  @override
  String get settingsWeeklyIdeas => 'Ideas semanales para planificar';

  @override
  String get settingsWeeklyIdeasSubtitle =>
      'Un correo semanal con ideas de destinos e inspiración.';

  @override
  String get settingsEmailPrefsUpdated => 'Preferencias de correo actualizadas';

  @override
  String get settingsLegalSection => 'Legal';

  @override
  String get settingsPrivacyPolicy => 'Política de privacidad';

  @override
  String get settingsTermsOfService => 'Términos del servicio';

  @override
  String get settingsDangerZoneSection => 'Zona de peligro';

  @override
  String get settingsDeleteAccount => 'Eliminar cuenta';

  @override
  String get settingsDeleteAccountTitle => '¿Eliminar tu cuenta?';

  @override
  String get settingsDeleteAccountBody =>
      'Esto elimina de forma permanente tu cuenta, tus viajes y tus preferencias. No se puede deshacer.';

  @override
  String get settingsConfirmPassword => 'Confirma tu contraseña';

  @override
  String get settingsDeleteForever => 'Eliminar para siempre';

  @override
  String get quizTitle => 'Configura tu perfil de viaje';

  @override
  String get quizSkip => 'Omitir';

  @override
  String get quizFinish => 'Finalizar';

  @override
  String get quizStyleTitle => '¿Cuál es tu estilo de viaje?';

  @override
  String get quizStyleSubtitle =>
      'Ayuda al planificador a ajustar los alojamientos y las actividades a ti.';

  @override
  String get quizWorkStyleTitle => '¿Trabajas mientras viajas?';

  @override
  String get quizWorkStyleSubtitle =>
      'Así el planificador equilibra alojamientos con buen wifi y tiempo de trabajo con la exploración.';

  @override
  String get quizInterestsTitle => '¿Qué te encanta hacer en un viaje?';

  @override
  String get quizInterestsSubtitle => 'Elige todas las que quieras.';

  @override
  String get quizActiveTitle => '¿Qué tan activos son tus viajes?';

  @override
  String get quizActiveSubtitle =>
      'Ambas son opcionales: definen dónde te alojas y qué tan exigentes son los días al aire libre.';

  @override
  String get quizCompanionsTitle => '¿Con quién sueles viajar?';

  @override
  String get quizCompanionSolo => 'en solitario';

  @override
  String get quizCompanionPartner => 'en pareja';

  @override
  String get quizCompanionFriends => 'con amigos';

  @override
  String get quizCompanionFamily => 'en familia con niños';

  @override
  String get quizCompanionVaries => 'depende';

  @override
  String get quizHomeAirportTitle => '¿Desde dónde vuelas?';

  @override
  String get quizBaggageTitle => '¿Con qué equipaje vuelas?';

  @override
  String get quizBaggageSubtitle =>
      'Así las tarifas que te mostremos ya incluirán el coste de tu equipaje.';

  @override
  String get quizTripsTitle => '¿Sueñas con algún viaje?';

  @override
  String get quizTripsSubtitle =>
      'Lugares, épocas del año, ocasiones: el planificador los tendrá en cuenta.';

  @override
  String get quizTripsHint =>
      'p. ej. Japón en temporada de cerezos en flor, saltar de isla en isla por Grecia el próximo verano…';

  @override
  String get quizSaveFailed =>
      'No se pudieron guardar tus respuestas: inténtalo de nuevo u omítelo por ahora.';

  @override
  String get quizProfileUpdated => 'Perfil de viaje actualizado';

  @override
  String quizStepOf(int n, int total) {
    return 'Paso $n de $total';
  }

  @override
  String get quizLoadErrorTitle => 'No se pudo cargar tu perfil de viaje';

  @override
  String get quizLoadErrorBody =>
      'No se pudieron cargar tus respuestas guardadas, así que el cuestionario aún no puede empezar. Comprueba tu conexión e inténtalo de nuevo.';

  @override
  String get bookingCardEdit => 'Editar';

  @override
  String get bookingCardRemove => 'Quitar';

  @override
  String get bookingCardBooked => 'Reservado';

  @override
  String bookingCardOpenIn(String provider) {
    return 'Abrir en $provider';
  }

  @override
  String get bookingCardOpenSearch => 'Abrir búsqueda';

  @override
  String get bookingCardOpenSearchShort => 'Buscar';

  @override
  String get calendarAddTo => 'Añadir al calendario';

  @override
  String get calendarGoogle => 'Google Calendar';

  @override
  String get calendarApple => 'Apple Calendar (.ics)';

  @override
  String calendarExportFailed(String error) {
    return 'No se pudo exportar el evento: $error';
  }

  @override
  String get bookingsAddStay => 'Añadir alojamiento';

  @override
  String get bookingsAddTransport => 'Añadir transporte';

  @override
  String get bookingsAddBooking => 'Añadir reserva';

  @override
  String get bookingsMenuStay => 'Alojamiento';

  @override
  String get bookingsMenuTransport => 'Transporte';

  @override
  String get bookingsMenuOther => 'Otro';

  @override
  String get tripOtherBookings => 'Otras reservas';

  @override
  String get bookingRowAddDetails => 'Añadir detalles…';

  @override
  String get bookingRowOptions => 'Opciones de la reserva';

  @override
  String get bookingRowModeTooltip => 'Cambiar el modo de transporte';

  @override
  String bookingRowDepartArrive(String depart, String arrive) {
    return '$depart → $arrive';
  }

  @override
  String bookingRowArrivesOn(String date) {
    return 'Llega el $date';
  }

  @override
  String get bookingsOpenListing => 'Abrir anuncio';

  @override
  String get bookingsEditStay => 'Editar alojamiento';

  @override
  String get bookingsRemoveStay => 'Eliminar alojamiento';

  @override
  String get bookingsOpenBooking => 'Abrir reserva';

  @override
  String get bookingsEditTransport => 'Editar transporte';

  @override
  String get bookingsRemoveTransport => 'Eliminar transporte';

  @override
  String get bookingsAddAStay => 'Añadir un alojamiento';

  @override
  String get bookingsStayNameLabel => 'Nombre *';

  @override
  String get bookingsStayProviderLabel => 'Proveedor (Airbnb, Booking.com, …)';

  @override
  String get bookingsStayUrlLabel => 'URL del anuncio';

  @override
  String get bookingsStayAddressLabel => 'Dirección';

  @override
  String get bookingsCheckInOut => 'Entrada / salida';

  @override
  String get bookingsPriceNoteLabel => 'Nota de precio (p. ej. 120 €/noche)';

  @override
  String get bookingsSegmentFromLabel => 'Desde *';

  @override
  String get bookingsSegmentToLabel => 'Hasta *';

  @override
  String get bookingsSegmentEndpointsFromTrip => 'Lo define el viaje.';

  @override
  String get bookingsDepartureDate => 'Fecha de salida';

  @override
  String get bookingsArrivalDate =>
      'Fecha de llegada (si llega al día siguiente)';

  @override
  String get bookingsSegmentProviderLabel => 'Proveedor / compañía';

  @override
  String get bookingsSegmentUrlLabel => 'URL de la reserva';

  @override
  String get bookingsNotesLabel => 'Notas';

  @override
  String get bookingsModeFlight => 'vuelo';

  @override
  String get bookingsModeTrain => 'tren';

  @override
  String get bookingsModeBus => 'autobús';

  @override
  String get bookingsModeCar => 'coche';

  @override
  String get bookingsModeFerry => 'ferri';

  @override
  String get bookingsModeOther => 'otro';

  @override
  String get budgetTitle => 'Presupuesto';

  @override
  String budgetSummarySpent(String amount) {
    return '$amount gastado';
  }

  @override
  String get budgetSummaryNoTarget => 'sin objetivo';

  @override
  String get budgetPromptTitle => '¿Añadir al presupuesto?';

  @override
  String get budgetPromptSkip => 'Omitir';

  @override
  String budgetPromptAmountLabel(String currency) {
    return 'Importe ($currency)';
  }

  @override
  String budgetPromptAdded(String amount) {
    return '$amount añadido al presupuesto';
  }

  @override
  String get budgetPromptLimitReached =>
      'Límite de gastos alcanzado — elimina uno en Presupuesto primero';

  @override
  String get budgetEmptyTitle => 'Aún no hay presupuesto';

  @override
  String get budgetEmptyMessage =>
      'Fija un objetivo arriba o añade gastos abajo para controlar lo que gastas.';

  @override
  String budgetTargetSet(String amount, String currency) {
    return 'Objetivo: $amount ($currency)';
  }

  @override
  String get budgetNoTarget => 'Sin objetivo — solo se registra el gasto';

  @override
  String get budgetEditExpenseTitle => 'Editar gasto';

  @override
  String get budgetSetTargetTitle => 'Fijar objetivo de presupuesto';

  @override
  String get budgetCategoryLabel => 'Categoría';

  @override
  String get budgetLabelField => 'Etiqueta';

  @override
  String get budgetAmount => 'Importe';

  @override
  String get budgetCurrencyLabel => 'Moneda';

  @override
  String get budgetTargetLabel => 'Objetivo';

  @override
  String get budgetTargetHint => 'Déjalo en blanco para no fijar ninguno';

  @override
  String get budgetTargetHelp =>
      'Deja el objetivo en blanco para solo registrar tus gastos.';

  @override
  String get budgetExpenseOptions => 'Opciones del gasto';

  @override
  String get budgetMenuEdit => 'Editar';

  @override
  String get budgetTotalSpent => 'Total gastado';

  @override
  String get budgetRemaining => 'Restante';

  @override
  String get budgetAddHint => 'Añade un gasto…';

  @override
  String get budgetAddExpenseTooltip => 'Añadir gasto';

  @override
  String get budgetCategoryFlights => 'Vuelos';

  @override
  String get budgetCategoryLodging => 'Alojamiento';

  @override
  String get budgetCategoryFood => 'Comida';

  @override
  String get budgetCategoryActivities => 'Actividades';

  @override
  String get budgetCategoryTransport => 'Transporte';

  @override
  String get budgetCategoryShopping => 'Compras';

  @override
  String get budgetCategoryGeneral => 'General';

  @override
  String get budgetPlanStatePlanned => 'Previsto';

  @override
  String get budgetPlanStatePaid => 'Pagado';

  @override
  String budgetPlanRowBothSemantics(String planned, String paid) {
    return 'Previsto $planned, pagado $paid';
  }

  @override
  String get budgetPlanTotalPlanned => 'Total previsto';

  @override
  String budgetPlanProjected(String amount) {
    return 'Proyectado $amount';
  }

  @override
  String budgetPlanOverTargetBy(String amount) {
    return '$amount por encima del objetivo';
  }

  @override
  String get budgetPlanVsPlan => 'Frente al plan';

  @override
  String budgetPlanDeltaOver(String amount) {
    return '$amount de más';
  }

  @override
  String budgetPlanDeltaUnder(String amount) {
    return '$amount de menos';
  }

  @override
  String get budgetPlanDeltaOnPlan => 'Según lo previsto';

  @override
  String get budgetPlanMarkPaid => 'Marcar como pagado';

  @override
  String get budgetPlanMarkPlanned => 'Marcar como previsto';

  @override
  String budgetPlanPaidAmountLabel(String currency) {
    return 'Pagado ($currency)';
  }

  @override
  String budgetPlanPlannedAmountLabel(String currency) {
    return 'Previsto ($currency)';
  }

  @override
  String budgetPlanPlannedHelper(String amount) {
    return 'Previsto $amount';
  }

  @override
  String get budgetPlanAmountsHelp =>
      'Indica lo que piensas gastar, lo que pagaste o ambos.';

  @override
  String budgetPlanMovedBack(String label) {
    return '$label vuelve a previsto';
  }

  @override
  String get budgetPlanGroupHasPlanned => 'Incluye importes previstos';

  @override
  String get budgetPlanAutoLocked => 'De una reserva: desmárcala para quitarla';

  @override
  String get budgetDailyTitle => 'Comida y bebida al día';

  @override
  String get budgetDailySubtitle =>
      'Precios locales típicos, por persona: es una estimación, no un precio.';

  @override
  String budgetDailyRate(String amount) {
    return '$amount/persona/día';
  }

  @override
  String budgetDailyNights(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count noches',
      one: '1 noche',
    );
    return '$_temp0';
  }

  @override
  String get budgetDailyAdd => 'Añadir al plan';

  @override
  String budgetDailyInPlan(String amount) {
    return 'En tu plan · $amount';
  }

  @override
  String budgetDailyAdded(String city) {
    return 'Comida y bebida de $city añadida a tu plan';
  }

  @override
  String budgetDailyExpenseLabel(String city) {
    return 'Comida y bebida · $city';
  }

  @override
  String budgetDailyTravelers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count viajeros',
      one: '1 viajero',
    );
    return '$_temp0';
  }

  @override
  String get budgetDailyTravelersAdd => 'Un viajero más';

  @override
  String get budgetDailyTravelersRemove => 'Un viajero menos';

  @override
  String get budgetDailyTierLabel => 'Nivel de gasto';

  @override
  String get budgetDailyTierBudget => 'Económico';

  @override
  String get budgetDailyTierMid => 'Intermedio';

  @override
  String get budgetDailyTierLuxury => 'Sin mirar el precio';

  @override
  String get budgetDailyTierFromProfile =>
      'Según tu nivel de presupuesto guardado';

  @override
  String get checklistTitle => 'Equipaje y preparativos';

  @override
  String checklistSummary(int checked, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$checked de $total preparados',
      zero: 'Aún no hay elementos',
    );
    return '$_temp0';
  }

  @override
  String get checklistEmptyTitle => 'Aún no has preparado nada';

  @override
  String get checklistEmptyMessage =>
      'Añade elementos abajo o pídele al asistente de IA que te ayude a crear la lista.';

  @override
  String get checklistEditItemTitle => 'Editar elemento';

  @override
  String get checklistItemLabel => 'Elemento';

  @override
  String get checklistItemOptions => 'Opciones del elemento';

  @override
  String get checklistMenuEdit => 'Editar';

  @override
  String get checklistAddHint => 'Añade un elemento…';

  @override
  String get checklistAddItemTooltip => 'Añadir elemento';

  @override
  String get checklistCategoryDocuments => 'Documentos';

  @override
  String get checklistCategoryClothing => 'Ropa';

  @override
  String get checklistCategoryElectronics => 'Electrónica';

  @override
  String get checklistCategoryHealth => 'Salud';

  @override
  String get checklistCategoryGeneral => 'General';

  @override
  String get itemDialogTitle => 'Añadir lugar';

  @override
  String get itemDialogSearchLabel => 'Busca un lugar';

  @override
  String get itemDialogSearchHint => 'p. ej. Pastéis de Belém, Lisboa';

  @override
  String get itemDialogPickDifferent => 'Elegir otro lugar';

  @override
  String get itemDialogAddManually => '¿No lo encuentras? Añádelo manualmente';

  @override
  String get itemDialogPlaceNameLabel => 'Nombre del lugar';

  @override
  String get itemDialogSearchInstead => 'Mejor buscar lugares';

  @override
  String get itemDialogDayLabel => 'Día';

  @override
  String get itemDialogUnscheduled => 'Sin programar';

  @override
  String itemDialogDayN(int day) {
    return 'Día $day';
  }

  @override
  String itemDialogNewDay(int day) {
    return 'Nuevo día ($day)';
  }

  @override
  String get itemDialogTimeOfDayLabel => 'Momento del día';

  @override
  String get itemDialogTimeAny => 'Cualquiera';

  @override
  String get itemDialogTimeMorning => 'Mañana';

  @override
  String get itemDialogTimeAfternoon => 'Tarde';

  @override
  String get itemDialogTimeEvening => 'Noche';

  @override
  String get itemDialogCategoryAttraction => 'Atracción';

  @override
  String get itemDialogCategoryRestaurant => 'Restaurante';

  @override
  String get itemDialogAdd => 'Añadir';

  @override
  String get itemDialogNoResults =>
      'No se encontró ningún lugar — prueba con otra búsqueda o añade el lugar manualmente.';

  @override
  String get itemDialogSearchUnavailable =>
      'La búsqueda no está disponible — añade el lugar manualmente abajo.';

  @override
  String get itemDialogErrorEnterName => 'Escribe un nombre para el lugar.';

  @override
  String get itemDialogErrorPickPlace => 'Elige un lugar primero.';

  @override
  String itemDialogErrorAddFailed(String error) {
    return 'No se pudo añadir el lugar: $error';
  }

  @override
  String get commonOffline =>
      'Estás sin conexión — vuelve a conectarte para hacer cambios.';

  @override
  String get commonGenericError => 'Algo salió mal. Inténtalo de nuevo.';

  @override
  String get tripTitleFallback => 'Viaje';

  @override
  String get tripOtherPlaces => 'Otros lugares';

  @override
  String get tripOfflineGuard =>
      'Estás sin conexión — vuelve a conectarte para hacer cambios.';

  @override
  String tripUpdateFailed(String error) {
    return 'Error al actualizar: $error';
  }

  @override
  String tripDeleteFailed(String error) {
    return 'Error al eliminar: $error';
  }

  @override
  String tripReorderFailed(String error) {
    return 'No se pudo reordenar: $error';
  }

  @override
  String tripLeaveFailed(String error) {
    return 'No se pudo quitar el viaje: $error';
  }

  @override
  String tripAddStayFailed(String error) {
    return 'No se pudo añadir el alojamiento: $error';
  }

  @override
  String tripRemoveStayFailed(String error) {
    return 'No se pudo quitar el alojamiento: $error';
  }

  @override
  String tripUpdateStayFailed(String error) {
    return 'No se pudo actualizar el alojamiento: $error';
  }

  @override
  String tripAddTransportFailed(String error) {
    return 'No se pudo añadir el transporte: $error';
  }

  @override
  String tripRemoveTransportFailed(String error) {
    return 'No se pudo quitar el transporte: $error';
  }

  @override
  String tripUpdateTransportFailed(String error) {
    return 'No se pudo actualizar el transporte: $error';
  }

  @override
  String tripShareLinkFailed(String error) {
    return 'No se pudo crear el enlace para compartir: $error';
  }

  @override
  String tripPrintExportFailed(String error) {
    return 'No se pudo abrir la vista para imprimir: $error';
  }

  @override
  String tripCalendarExportFailed(String error) {
    return 'No se pudo exportar el calendario: $error';
  }

  @override
  String tripEventExportFailed(String error) {
    return 'No se pudo exportar el evento: $error';
  }

  @override
  String tripSharingOffFailed(String error) {
    return 'No se pudo desactivar el uso compartido: $error';
  }

  @override
  String tripInviteFailed(String error) {
    return 'No se pudo crear la invitación: $error';
  }

  @override
  String tripRemoveItemFailed(String name, String error) {
    return 'No se pudo quitar $name: $error';
  }

  @override
  String tripRestoreItemFailed(String name, String error) {
    return 'No se pudo restaurar $name: $error';
  }

  @override
  String tripUpdateItemFailed(String name, String error) {
    return 'No se pudo actualizar $name: $error';
  }

  @override
  String tripMoveItemFailed(String error) {
    return 'No se pudo mover el elemento: $error';
  }

  @override
  String tripUpdateBookingFailed(String error) {
    return 'No se pudo actualizar la reserva: $error';
  }

  @override
  String tripUndoFailed(String error) {
    return 'No se pudo deshacer: $error';
  }

  @override
  String tripAddPackingFailed(String error) {
    return 'No se pudo añadir el artículo de equipaje: $error';
  }

  @override
  String tripLoadBudgetFailed(String error) {
    return 'No se pudo cargar el presupuesto: $error';
  }

  @override
  String tripUpdateBudgetFailed(String error) {
    return 'No se pudo actualizar el presupuesto: $error';
  }

  @override
  String tripSaveFailed(String error) {
    return 'Error al guardar: $error';
  }

  @override
  String get tripOpenLinkFailed => 'No se pudo abrir el enlace';

  @override
  String get tripFerrySearchFailed => 'No se pudo abrir la búsqueda de ferris';

  @override
  String get tripLoadFailed => 'No se pudo cargar este viaje';

  @override
  String get tripEditTitle => 'Editar título';

  @override
  String get tripDeleteTitle => '¿Eliminar el viaje?';

  @override
  String get tripDeleteBody => 'Esta acción no se puede deshacer.';

  @override
  String get tripLeaveTitle => '¿Quitar de mis viajes?';

  @override
  String get tripLeaveBody =>
      'Perderás el acceso hasta que vuelvan a invitarte. El viaje en sí no se elimina.';

  @override
  String get tripRemove => 'Quitar';

  @override
  String get tripUndo => 'Deshacer';

  @override
  String get tripAddPlacesBeforeRefine =>
      'Añade algunos lugares antes de refinar con IA.';

  @override
  String get tripAssistantLabel => 'Asistente de viaje';

  @override
  String tripRefiningSection(String section) {
    return 'Refinando $section';
  }

  @override
  String tripRefineCity(String city) {
    return 'Refinar $city';
  }

  @override
  String get tripRefineThisDay => 'Refinar este día';

  @override
  String get tripRefineWithAI => 'Refinar con IA';

  @override
  String get tripAskAI => 'Pregunta a la IA sobre este viaje';

  @override
  String get tripShareLinkCopied =>
      'Enlace para compartir copiado al portapapeles';

  @override
  String get tripSharingTurnedOff =>
      'Uso compartido desactivado — los enlaces ya no funcionan (los coplanificadores y seguidores actuales conservan el acceso)';

  @override
  String tripCoPlanInviteMessage(String summary) {
    return 'Planifica conmigo: $summary';
  }

  @override
  String get tripInviteCopied =>
      'Invitación de coplanificador copiada — cualquiera que la tenga puede editar';

  @override
  String get tripCoPlannerRemoved => 'Coplanificador eliminado';

  @override
  String tripInviteSent(String email) {
    return 'Invitación enviada a $email';
  }

  @override
  String get tripShareTrip => 'Compartir viaje';

  @override
  String get tripShareLinkAction => 'Compartir enlace…';

  @override
  String get tripCopyShareLink => 'Copiar enlace para compartir';

  @override
  String get tripShareInviteAction => 'Compartir invitación de coplanificador…';

  @override
  String get tripCopyInviteLink => 'Copiar enlace de invitación (puede editar)';

  @override
  String get tripManageAccess => 'Gestionar acceso';

  @override
  String get tripPrintSavePdf => 'Imprimir / Guardar como PDF';

  @override
  String get tripAddToCalendar => 'Añadir al calendario';

  @override
  String get tripTurnOffSharing => 'Desactivar el uso compartido';

  @override
  String get tripDeleteTrip => 'Eliminar viaje';

  @override
  String get tripRemoveFromMyTrips => 'Quitar de mis viajes';

  @override
  String get tripMoreActions => 'Más opciones';

  @override
  String get tripAirportsTitle => 'Aeropuertos del viaje';

  @override
  String get tripAirportsHelp =>
      'Desde qué aeropuerto sale este viaje y a cuál vuelve. Tu aeropuerto habitual no cambia.';

  @override
  String get tripAirportsDepartsFrom => 'Sale desde';

  @override
  String get tripAirportsReturnsInto => 'Vuelve a';

  @override
  String get tripAirportsSameBothWays => 'Vuelve al mismo aeropuerto';

  @override
  String get tripAirportsUseHomeAirport => 'Usar mi aeropuerto habitual';

  @override
  String get tripAirportsPickOne => 'Elige un aeropuerto de la lista.';

  @override
  String get tripAirportsBothNeeded =>
      'Elige un aeropuerto para los dos extremos, o bórralos.';

  @override
  String tripAirportsCurrentFallback(String label) {
    return 'Ahora mismo estos trayectos usan $label.';
  }

  @override
  String get tripAirportsMenuLabel => 'Aeropuertos del viaje…';

  @override
  String get tripAirportsChangeDeparture => 'Cambiar aeropuerto de salida…';

  @override
  String get tripAirportsChangeReturn => 'Cambiar aeropuerto de vuelta…';

  @override
  String get tripAirportsChangeLink => 'Cambiar aeropuerto';

  @override
  String tripAirportsSaved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Guardado. $count trayectos renombrados.',
      one: 'Guardado. 1 trayecto renombrado.',
      zero:
          'Guardado. Aún no hay trayecto de ida ni de vuelta: usarán estos aeropuertos cuando aparezcan.',
    );
    return '$_temp0';
  }

  @override
  String tripAirportsFailed(String error) {
    return 'No se pudieron guardar los aeropuertos del viaje: $error';
  }

  @override
  String get tripLocalIntel => 'Información local';

  @override
  String tripLocalGuideTitle(String title) {
    return 'Guía local: $title';
  }

  @override
  String tripGuideBy(String name) {
    return 'Por $name';
  }

  @override
  String tripEventsWhileHereCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos mientras estás aquí',
      one: '1 evento mientras estás aquí',
    );
    return '$_temp0';
  }

  @override
  String tripEventsWhileHereCountCapped(int count) {
    return '$count+ eventos mientras estás aquí';
  }

  @override
  String tripEventsInCity(String city) {
    return 'Eventos en $city';
  }

  @override
  String get tripEventsSource => 'Listados de Ticketmaster';

  @override
  String tripFindingEvents(String city) {
    return 'Buscando eventos en $city…';
  }

  @override
  String tripFindEventsIn(String city) {
    return 'Buscar eventos en $city';
  }

  @override
  String tripRecommendedBy(String name) {
    return 'Recomendado por $name';
  }

  @override
  String get tripFindFlights => 'Buscar vuelos';

  @override
  String get tripFindFlightsShort => 'Vuelos';

  @override
  String get tripFindFerries => 'Buscar ferris';

  @override
  String get tripFindFerriesShort => 'Ferris';

  @override
  String get tripAddBooking => 'Añadir una reserva';

  @override
  String get tripEditBooking => 'Editar reserva';

  @override
  String get tripFieldType => 'Tipo';

  @override
  String get tripKindStay => 'Alojamiento';

  @override
  String get tripKindTransport => 'Transporte';

  @override
  String get tripKindOther => 'Otro';

  @override
  String get tripFieldTitle => 'Título';

  @override
  String get tripFieldOrigin => 'Origen (opcional)';

  @override
  String get tripFieldDestination => 'Destino (opcional)';

  @override
  String get tripFieldDepartDate => 'Fecha de salida (opcional)';

  @override
  String get tripFieldCheckIn => 'Entrada (opcional)';

  @override
  String get tripFieldCheckOut => 'Salida (opcional)';

  @override
  String get tripFieldLink => 'Enlace (opcional, sustituye a la búsqueda)';

  @override
  String get tripTitleRequired => 'El título es obligatorio';

  @override
  String get tripClearDate => 'Borrar fecha';

  @override
  String get tripItinerary => 'Itinerario';

  @override
  String get tripToday => 'Hoy';

  @override
  String get tripAddPlace => 'Añadir lugar';

  @override
  String get tripCollapseAll => 'Contraer todo';

  @override
  String get tripExpandAll => 'Expandir todo';

  @override
  String get tripFilterUnbooked => 'Sin reservar';

  @override
  String get tripFilterAllBooked => 'Todo reservado';

  @override
  String get tripFilterAllBookedMessage =>
      'No queda nada por reservar en este viaje — todo listo.';

  @override
  String get tripTabBookings => 'Reservas';

  @override
  String get tripBookingsLensEmptyTitle => 'Aún no hay reservas';

  @override
  String get tripBookingsLensEmptyMessage =>
      'Los vuelos, alojamientos y reservas de este viaje aparecerán aquí.';

  @override
  String get tripBookingsLensNoneForDestination =>
      'No hay reservas para este destino.';

  @override
  String get tripNoPlacesYet => 'Aún no hay lugares';

  @override
  String get tripNoPlacesYetMessage =>
      'Refina con IA o añade un lugar para empezar tu itinerario.';

  @override
  String get tripNoMappedPlaces => 'No hay lugares en el mapa';

  @override
  String tripNoPlacesInLeg(String city) {
    return 'No hay lugares marcados en $city';
  }

  @override
  String get tripAddPlaceMapHint => 'Añade un lugar para verlo en el mapa.';

  @override
  String get tripExpandMap => 'Ampliar mapa';

  @override
  String tripDayN(int n) {
    return 'Día $n';
  }

  @override
  String tripDayTripTo(String town) {
    return 'Excursión · $town';
  }

  @override
  String get tripDayTripFallback => 'Excursión';

  @override
  String tripTonight(String stays) {
    return 'Esta noche: $stays';
  }

  @override
  String tripLegNights(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count noches',
      one: '1 noche',
    );
    return '· $_temp0';
  }

  @override
  String tripTravelMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String tripTravelHours(int hours) {
    return '$hours h';
  }

  @override
  String tripTravelHoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String tripTravelFromHub(String duration, String hub) {
    return '$duration desde $hub';
  }

  @override
  String tripTravelTotal(String duration) {
    return '$duration de trayecto';
  }

  @override
  String tripRainChance(int percent) {
    return '$percent% de lluvia';
  }

  @override
  String get tripTypicalForDates => 'lo habitual en estas fechas';

  @override
  String get tripPlaceActions => 'Acciones del lugar';

  @override
  String get tripOpenInGoogleMaps => 'Abrir en Google Maps';

  @override
  String get tripEdit => 'Editar';

  @override
  String get tripMoveUp => 'Subir';

  @override
  String get tripMoveDown => 'Bajar';

  @override
  String get tripReorderSection => 'Reordenar sección';

  @override
  String get tripAddToGoogleCalendar => 'Añadir a Google Calendar';

  @override
  String get tripAddToAppleCalendar => 'Añadir a Apple Calendar (.ics)';

  @override
  String tripRemovedItem(String name) {
    return '$name eliminado';
  }

  @override
  String tripMovedToDay(int day) {
    return 'Movido al día $day';
  }

  @override
  String get tripMarkedAsBooked => 'Marcado como reservado';

  @override
  String tripAddedToPacking(String item) {
    return '\"$item\" añadido al equipaje';
  }

  @override
  String get tripRename => 'Cambiar nombre';

  @override
  String get tripAddDates => 'Añadir fechas';

  @override
  String tripCoPlanningWith(String name) {
    return 'Planificando con $name — tus cambios se guardan para todos.';
  }

  @override
  String get tripCoPlanningShared =>
      'Planificando un viaje compartido — tus cambios se guardan para todos.';

  @override
  String tripSharedBy(String name) {
    return 'Compartido por $name — solo lectura.';
  }

  @override
  String get tripSharedViewOnly => 'Viaje compartido — solo lectura.';

  @override
  String tripUpdatedBy(String name, String time) {
    return 'Actualizado por $name · $time';
  }

  @override
  String get tripOverview => 'Resumen';

  @override
  String get tripShowMore => 'Mostrar más';

  @override
  String get tripShowLess => 'Mostrar menos';

  @override
  String get tripTimeRecently => 'hace poco';

  @override
  String get tripTimeJustNow => 'ahora mismo';

  @override
  String tripTimeMinutesAgo(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String tripTimeHoursAgo(int hours) {
    return 'hace $hours h';
  }

  @override
  String tripTimeDaysAgo(int days) {
    return 'hace $days d';
  }

  @override
  String get tripFriendEmail => 'Correo de tu amigo';

  @override
  String get tripInvite => 'Invitar';

  @override
  String get tripNoCoPlanners =>
      'Aún no hay coplanificadores. Invita a un amigo por correo arriba o copia un enlace de invitación desde el menú de compartir.';

  @override
  String get tripRoleViewer => 'Lector';

  @override
  String get tripRoleCanEdit => 'Puede editar';

  @override
  String get tripRemoveAccess => 'Quitar acceso';

  @override
  String get tripPendingInvites => 'Invitaciones pendientes';

  @override
  String tripInvited(String expires) {
    return 'Invitado — $expires';
  }

  @override
  String get tripRevokeInvite => 'Revocar invitación';

  @override
  String tripExpiresInDays(int days) {
    return 'caduca en $days d';
  }

  @override
  String tripExpiresInHours(int hours) {
    return 'caduca en $hours h';
  }

  @override
  String get tripExpiresSoon => 'caduca pronto';

  @override
  String get tripEditPlace => 'Editar lugar';

  @override
  String get tripFieldName => 'Nombre';

  @override
  String get tripFieldCity => 'Ciudad';

  @override
  String get tripFieldDay => 'Día';

  @override
  String get tripCategoryAttraction => 'Atracción';

  @override
  String get tripCategoryRestaurant => 'Restaurante';

  @override
  String get tripTimeMorning => 'Mañana';

  @override
  String get tripTimeAfternoon => 'Tarde';

  @override
  String get tripTimeEvening => 'Noche';

  @override
  String get tripReorderPlaces => 'Reordenar lugares';

  @override
  String get tripReorderHint =>
      'Arrastra para cambiar el orden de visita dentro de esta sección.';

  @override
  String get tripSaveOrder => 'Guardar orden';

  @override
  String get tripsListTitle => 'Mis viajes';

  @override
  String get tripsListErrorTitle => 'No se pudieron cargar los viajes';

  @override
  String get tripsListErrorMessage =>
      'Revisa tu conexión e inténtalo de nuevo.';

  @override
  String get tripsListEmptyTitle => 'Aún no tienes viajes';

  @override
  String get tripsListEmptyMessage =>
      'Habla con el agente de IA para crear tu primer viaje.';

  @override
  String get tripsListPlanTrip => 'Planear un viaje';

  @override
  String get tripsListSharedWithYou => 'Compartidos contigo';

  @override
  String get tripsListPastTrips => 'Viajes pasados';

  @override
  String tripsListPastTripsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count viajes',
      one: '1 viaje',
    );
    return '$_temp0';
  }

  @override
  String get tripsListUpcoming => 'Próximos';

  @override
  String get tripsListNewTrip => 'Nuevo viaje';

  @override
  String get tripsListYourTravels => 'Tus viajes';

  @override
  String get tripsListTravelMap => 'Tu mapa de viajes';

  @override
  String get tripsListStatsTraveled => 'Viajado';

  @override
  String get tripsListStatsPlanned => 'Planeado';

  @override
  String tripsListStatTrips(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Viajes',
      one: 'Viaje',
    );
    return '$_temp0';
  }

  @override
  String tripsListStatTravelDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Días de viaje',
      one: 'Día de viaje',
    );
    return '$_temp0';
  }

  @override
  String tripsListStatCities(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ciudades',
      one: 'Ciudad',
    );
    return '$_temp0';
  }

  @override
  String tripsListStaysCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alojamientos',
      one: '1 alojamiento',
    );
    return '$_temp0';
  }

  @override
  String tripsListPackedCount(int checked, int total) {
    return '$checked/$total en la maleta';
  }

  @override
  String tripsListBudgetSpentOfTarget(String spent, String target) {
    return '$spent de $target';
  }

  @override
  String tripsListBookTransportNudge(String date) {
    return 'Reserva el transporte: el primer tramo sale el $date';
  }

  @override
  String tripDurationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count días',
      one: '1 día',
    );
    return '$_temp0';
  }

  @override
  String tripCitiesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ciudades',
      one: '1 ciudad',
    );
    return '$_temp0';
  }

  @override
  String tripsListPlaces(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lugares',
      one: '1 lugar',
    );
    return '$_temp0';
  }

  @override
  String tripsListBookedCount(int booked, int total) {
    return '$booked/$total reservados';
  }

  @override
  String get tripsListShared => 'Compartido';

  @override
  String get upNextEyebrow => 'PRÓXIMO VIAJE';

  @override
  String upNextStartsIn(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Empieza en $days días',
      one: 'Empieza mañana',
      zero: 'Empieza hoy',
    );
    return '$_temp0';
  }

  @override
  String tripsListCreated(String date) {
    return 'Creado el $date';
  }

  @override
  String tripsListPlannedWith(String name) {
    return 'Planeado con $name';
  }

  @override
  String tripsListSharedBy(String name) {
    return 'Compartido por $name';
  }

  @override
  String get tripsListVersionsError => 'No se pudieron cargar las versiones';

  @override
  String tripsListVersionLatest(String date) {
    return 'más reciente · $date';
  }

  @override
  String tripsListVersionNumbered(int version, String date) {
    return 'v$version · $date';
  }

  @override
  String get settingsConnectedAppsSection => 'Apps conectadas';

  @override
  String get settingsConnectedAppsHelp =>
      'Asistentes de IA a los que permitiste crear viajes en tu cuenta.';

  @override
  String get settingsConnectedAppsEmpty => 'No hay apps conectadas.';

  @override
  String get settingsConnectedAppsError =>
      'No se pudieron cargar las apps conectadas';

  @override
  String settingsConnectedLastUsed(String date) {
    return 'Último uso: $date';
  }

  @override
  String get settingsConnectedNeverUsed => 'Aún sin usar';

  @override
  String get settingsRevokeAction => 'Revocar';

  @override
  String settingsRevokeConfirmTitle(String app) {
    return '¿Revocar $app?';
  }

  @override
  String get settingsRevokeConfirmBody =>
      'Dejará de poder crear viajes en tu cuenta de inmediato. Puedes volver a conectarla más tarde.';

  @override
  String settingsRevokedToast(String app) {
    return '$app desconectada';
  }

  @override
  String get connectAppBarTitle => 'Conectar app';

  @override
  String connectTitle(String app) {
    return '¿Conectar $app a Anemos?';
  }

  @override
  String get connectUnverifiedCaution =>
      'Este nombre lo proporcionó la propia app y no lo hemos verificado. Continúa solo si iniciaste esto desde una app en la que confías.';

  @override
  String get connectWillBeAbleTo => 'Podrá:';

  @override
  String get connectScopeTripsWrite =>
      'Crear viajes en tu cuenta y ver tu lista de viajes';

  @override
  String get connectScopeRecsRead =>
      'Buscar las recomendaciones locales de Anemos';

  @override
  String get connectSignInPrompt =>
      'Inicia sesión en tu cuenta de Anemos para continuar.';

  @override
  String get connectSignInCta => 'Iniciar sesión';

  @override
  String get connectApprove => 'Conectar';

  @override
  String get connectDeny => 'Cancelar';

  @override
  String get connectExpiredTitle => 'Esta solicitud caducó';

  @override
  String get connectExpiredMessage =>
      'Vuelve a iniciar la conexión desde tu asistente de IA.';

  @override
  String get importFromAi => 'Importar de un chat de IA';

  @override
  String get importExplainer =>
      '¿Planeaste un viaje en ChatGPT o Claude? Pega la conversación — o su resumen final — y la convertiremos en un viaje que puedes editar.';

  @override
  String get importCopyPrompt => 'Copiar prompt de planificación';

  @override
  String get importPromptCopied =>
      'Prompt copiado — pégalo en ChatGPT o Claude para empezar a planear.';

  @override
  String get importPasteButton => 'Pegar';

  @override
  String get importPasteHint =>
      'Pega aquí tu conversación o el resumen del viaje…';

  @override
  String get importButton => 'Importar viaje';

  @override
  String get importProgressReading => 'Leyendo tu conversación…';

  @override
  String get importProgressLocating => 'Ubicando lugares en el mapa…';

  @override
  String get importWarningsTitle => 'Algunos lugares necesitan atención';

  @override
  String get importViewTrip => 'Ver viaje';

  @override
  String get logTripTitle => 'Registrar un viaje pasado';

  @override
  String get logTripAction => 'Añadir viaje pasado';

  @override
  String get logTripExplainer =>
      '¿Estuviste en un lugar que no planeamos aquí? Añádelo y contará en Tus viajes.';

  @override
  String get logTripDestinationsLabel => '¿Adónde fuiste?';

  @override
  String get logTripDestinationsHint => 'Busca una ciudad o un país';

  @override
  String logTripAddByName(String name) {
    return 'Añadir \"$name\" por nombre';
  }

  @override
  String get logTripNoCoordsNote =>
      'Los destinos sin ubicación en el mapa siguen contando como ciudades, pero no tendrán un punto en tu mapa de viajes.';

  @override
  String get logTripDatesLabel => '¿Cuándo?';

  @override
  String get logTripPickDates => 'Elige las fechas del viaje';

  @override
  String get logTripDatesRequired =>
      'Las fechas son obligatorias: son lo que hace que este viaje cuente como algo que ya viviste.';

  @override
  String get logTripNameLabel => 'Nombra este viaje (opcional)';

  @override
  String get logTripSave => 'Guardar viaje';

  @override
  String get importPlanningPrompt =>
      'Ayúdame a planear un viaje. Pregúntame por el destino, las fechas, mis intereses, el ritmo y el presupuesto, y luego arma un itinerario día por día. Al terminar, cierra con una sección titulada TRIP SUMMARY que incluya: el o los destinos y las fechas exactas del viaje; cada día como \"Día N — Ciudad\" con entradas de Mañana / Tarde / Noche, cada una escrita como \"Nombre del lugar — Ciudad\" usando nombres reales que se puedan ubicar en el mapa; las excursiones marcadas como \"excursión desde [ciudad]\"; y cómo me traslado entre ciudades (avión, coche, tren, autobús o ferry).';

  @override
  String get homeGreetingMorning => 'Buenos días';

  @override
  String get homeGreetingAfternoon => 'Buenas tardes';

  @override
  String get homeGreetingEvening => 'Buenas noches';

  @override
  String homeGreetingNamed(String greeting, String name) {
    return '$greeting, $name';
  }

  @override
  String get homeGreetingSubtitle => '¿Adónde vamos ahora?';

  @override
  String get homeHeroTitle => 'Planea menos. Viaja más.';

  @override
  String get homeHeroSubtitle =>
      'Cuéntame el viaje que sueñas y armaré el itinerario completo — lugares, días y rutas.';

  @override
  String get homeHeroCta => 'Vamos';

  @override
  String get suggestionParis => '2 días en París';

  @override
  String get suggestionRome => 'Museos en Roma';

  @override
  String get suggestionTokyo => 'Fin de semana en Tokio';

  @override
  String get suggestionGreece => 'De isla en isla por Grecia';

  @override
  String get suggestionLisbon => '3 días en Lisboa';

  @override
  String get suggestionBarcelona => 'De tapas por Barcelona';

  @override
  String get suggestionBangkok => 'Comida callejera en Bangkok';

  @override
  String get suggestionAmalfi => 'Ruta por la Costa Amalfitana';

  @override
  String get suggestionNewYork => 'Una semana en Nueva York';

  @override
  String get suggestionBali => 'Playas de Bali';

  @override
  String get suggestionPatagonia => 'Senderismo en la Patagonia';

  @override
  String get suggestionKenya => 'Safari en Kenia';

  @override
  String get homeLocalGuidesTitle => 'Guías locales';

  @override
  String homeGuideByline(String name) {
    return 'Por $name';
  }

  @override
  String get shellNavHome => 'Inicio';

  @override
  String get shellNavPlan => 'Planear';

  @override
  String get shellNavTrips => 'Viajes';

  @override
  String get healthMetricsErrorTitle => 'No se pudieron cargar las métricas';

  @override
  String get healthHealthErrorTitle => 'No se pudo cargar el estado';

  @override
  String get healthProcessSection => 'Proceso';

  @override
  String get healthRoutesSection => 'Rutas';

  @override
  String get healthProcessUptime => 'Proceso activo';

  @override
  String get healthRequests => 'Solicitudes';

  @override
  String get healthErrorRate => 'Tasa de errores';

  @override
  String get healthGoroutines => 'Goroutines';

  @override
  String get healthMemory => 'Memoria';

  @override
  String get healthPlacesCalls => 'Llamadas a Places';

  @override
  String healthCacheHits(int count) {
    return '$count aciertos de caché';
  }

  @override
  String get healthColRoute => 'Ruta';

  @override
  String get healthColMethod => 'Método';

  @override
  String get healthColCount => 'Cantidad';

  @override
  String get healthColErrorPct => '% de errores';

  @override
  String get healthDependenciesSection => 'Dependencias';

  @override
  String get healthDatabase => 'Base de datos';

  @override
  String healthPing(int ms) {
    return 'ping de $ms ms';
  }

  @override
  String get healthPillOk => 'ok';

  @override
  String get healthPillUnreachable => 'inaccesible';

  @override
  String get healthPillConfigured => 'configurado';

  @override
  String get healthPillNotConfigured => 'sin configurar';

  @override
  String get healthPillUnknown => 'desconocido';

  @override
  String get healthPillStale => 'desactualizada';

  @override
  String get healthPillFresh => 'reciente';

  @override
  String get healthBackupsSection => 'Copias de seguridad';

  @override
  String get healthLastBackup => 'Última copia de seguridad';

  @override
  String healthBackupAge(String age) {
    return 'hace $age';
  }

  @override
  String get healthNoBackupRecorded => 'sin copias registradas';

  @override
  String get healthBuildSection => 'Compilación';

  @override
  String healthRelease(String release) {
    return 'versión $release';
  }

  @override
  String get healthDegradedTitle => 'Sistema degradado';

  @override
  String get healthRecoveredTitle => 'Sistema recuperado';

  @override
  String get notifOpsOpenHealth => 'Ver el estado del sistema';

  @override
  String get healthUptimeSection => 'Disponibilidad';

  @override
  String get healthUptimeSelfCheckNote =>
      'Autodiagnóstico — no detecta caídas del edge ni del gateway';

  @override
  String get healthUptimeComponentApi => 'API';

  @override
  String get healthUptimeComponentAi => 'Proveedor de IA';

  @override
  String get healthUptimePillDown => 'caído';

  @override
  String healthUptimeDaysAgo(int days) {
    return 'hace $days días';
  }

  @override
  String get healthUptimeToday => 'Hoy';

  @override
  String healthUptimeSummary(String pct) {
    return '$pct % de disponibilidad';
  }

  @override
  String healthUptimeSummaryPartial(String pct, int days) {
    return '$pct % · $days días observados';
  }

  @override
  String get healthUptimeNoHistory => 'Aún no hay historial';

  @override
  String healthUptimeMonitoringSince(String date) {
    return 'Monitorizando desde $date';
  }

  @override
  String healthUptimeDayNoData(String date) {
    return '$date · sin datos';
  }

  @override
  String get healthUptimeNoIncidents => 'sin incidencias';

  @override
  String healthUptimeDown(String duration) {
    return '$duration caído';
  }

  @override
  String get healthUptimeReasonDbUnreachable => 'base de datos inaccesible';

  @override
  String get healthUptimeReasonProcessDown => 'proceso caído';

  @override
  String get healthUptimeReasonAiFailing => 'proveedor de IA fallando';

  @override
  String get healthUptimeReasonBackupsStale =>
      'copias de seguridad desactualizadas';

  @override
  String get healthUptimeKeyboardHint =>
      'Usa las flechas izquierda y derecha para revisar un día';

  @override
  String get healthUptimeErrorTitle => 'No se pudo cargar la disponibilidad';

  @override
  String get reviewSectionTitle => 'Estado del viaje';

  @override
  String reviewHeaderAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Casi listo — $count por resolver',
      one: 'Casi listo — 1 por resolver',
    );
    return '$_temp0';
  }

  @override
  String reviewHeaderSuggestionsOnly(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'En buen estado — $count sugerencias',
      one: 'En buen estado — 1 sugerencia',
    );
    return '$_temp0';
  }

  @override
  String get reviewNeedsAttentionHeader => 'Necesita atención';

  @override
  String get reviewSuggestionsHeader => 'Sugerencias';

  @override
  String reviewBadgeAttentionSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos necesitan atención',
      one: '1 elemento necesita atención',
    );
    return '$_temp0';
  }

  @override
  String reviewBadgeSuggestionsSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sugerencias disponibles',
      one: '1 sugerencia disponible',
    );
    return '$_temp0';
  }

  @override
  String get reviewEmptyTitle => 'Todo en orden';

  @override
  String get reviewEmptyMessage =>
      'No encontramos problemas — tu viaje va bien.';

  @override
  String get reviewSeverityCritical => 'Crítico';

  @override
  String get reviewSeverityWarning => 'Advertencia';

  @override
  String get reviewSeverityInfo => 'Información';

  @override
  String get reviewOfflineSnack =>
      'Estás sin conexión — vuelve a conectarte para hacer más comprobaciones.';

  @override
  String get reviewHoursChecked => 'Horarios comprobados';

  @override
  String get reviewCheckHours => 'Comprobar también los horarios';

  @override
  String get reviewHoursCheckFailed =>
      'No se pudieron comprobar los horarios — inténtalo de nuevo.';

  @override
  String get liveTripEyebrow => 'SUCEDIENDO AHORA';

  @override
  String get liveTripStatusLive => 'En curso';

  @override
  String liveTripDay(int day) {
    return 'Día $day';
  }

  @override
  String liveTripDayOfTotal(int day, int total) {
    return 'Día $day de $total';
  }

  @override
  String get continueChatsTitle => 'Continúa donde lo dejaste';

  @override
  String get continueChatsReopenError => 'No se pudo reabrir esa conversación.';

  @override
  String get continueChatsDismissError =>
      'No se pudo descartar esa conversación.';

  @override
  String get continueChatsDismiss => 'Descartar';

  @override
  String get mapNoMappedPlaces => 'No hay lugares en el mapa';

  @override
  String get mapZoomIn => 'Acercar';

  @override
  String get mapZoomOut => 'Alejar';

  @override
  String get mapResetMap => 'Restablecer mapa';

  @override
  String mapLegVisitNumber(int n) {
    return 'Visita $n';
  }

  @override
  String get mapShowAllPlaces => 'Mostrar todos los lugares';

  @override
  String mapDepartureAirport(String code) {
    return 'Aeropuerto de salida ($code)';
  }

  @override
  String mapReturnAirport(String code) {
    return 'Aeropuerto de regreso ($code)';
  }

  @override
  String mapHomeAirport(String code) {
    return 'Aeropuerto de origen ($code)';
  }

  @override
  String get accountMenuTooltip => 'Cuenta';

  @override
  String get accountMenuTravelProfile => 'Perfil de viaje';

  @override
  String get accountMenuNotifications => 'Notificaciones';

  @override
  String get accountMenuRetakeQuiz => 'Repetir el cuestionario de viaje';

  @override
  String get accountMenuAccountSettings => 'Ajustes';

  @override
  String get accountMenuLocalIntelAdmin => 'Administración de info local';

  @override
  String get accountMenuMetrics => 'Métricas';

  @override
  String get accountMenuSignOut => 'Cerrar sesión';

  @override
  String get nextStepEyebrow => 'Siguiente paso';

  @override
  String nextStepProgress(int n, int total) {
    return '$n de $total';
  }

  @override
  String get nextStepViewAll => 'Ver todo';

  @override
  String get nextStepSetDatesAction => 'Elegir fechas';

  @override
  String get nextStepPlanAction => 'Planificar en el chat';

  @override
  String get nextStepLodgingAction => 'Buscar alojamiento';

  @override
  String get nextStepTransportAction => 'Ver opciones';

  @override
  String get nextStepScheduleAction => 'Completar los huecos';

  @override
  String get nextStepBookAction => 'Revisar reservas';

  @override
  String get nextStepPackingAction => 'Abrir lista de equipaje';

  @override
  String get nextStepAllSetDismiss => 'Descartar';

  @override
  String get nextStepViewProgress => 'Ver todos los pasos';

  @override
  String get planProgressTitle => 'Progreso del plan';

  @override
  String get planProgressHint =>
      'Los pasos se desbloquean en orden: termina este y se abrirá el siguiente.';

  @override
  String get planProgressStateDone => 'Hecho';

  @override
  String get planProgressStateCurrent => 'Paso actual';

  @override
  String get planProgressStateLater => 'Más adelante';

  @override
  String get notifTitle => 'Notificaciones';

  @override
  String get notifMoreActions => 'Más opciones';

  @override
  String get notifClearAll => 'Borrar todo';

  @override
  String get notifClearAllTitle => '¿Borrar todas las notificaciones?';

  @override
  String get notifClearAllBody =>
      'Se eliminarán todas las notificaciones, incluidas las no leídas. Esta acción no se puede deshacer.';

  @override
  String notifClearAllFailed(String error) {
    return 'No se pudieron borrar las notificaciones: $error';
  }

  @override
  String get notifLoadErrorTitle => 'No se pudieron cargar las notificaciones';

  @override
  String get notifEmptyTitle => 'Aún no tienes notificaciones';

  @override
  String get notifEmptyMessage =>
      'Aquí aparecerán los recordatorios de viaje y las novedades de planificación compartida.';

  @override
  String get notifUnreadSemantic => 'No leída';

  @override
  String notifDownFrom(String price, String previous) {
    return '$price, bajó desde $previous';
  }

  @override
  String get notifBestInWindow => '(el mejor del periodo)';

  @override
  String get notifGenericFallback => 'Notificación';

  @override
  String get notifSomeTrip => 'un viaje';

  @override
  String get notifSomeone => 'Alguien';

  @override
  String get notifACollaborator => 'Un colaborador';

  @override
  String notifJoinedTrip(String who, String trip) {
    return '$who se unió a «$trip»';
  }

  @override
  String notifFollowedTrip(String who, String trip) {
    return '$who ahora sigue «$trip»';
  }

  @override
  String notifEditedTrip(String who, String trip) {
    return '$who editó «$trip»';
  }

  @override
  String get sharedTitle => 'Viaje compartido';

  @override
  String get sharedUnavailableTitle => 'Este enlace no está disponible';

  @override
  String get sharedInviteUnavailableMessage =>
      'Puede que la invitación haya caducado, se haya revocado o ya se haya usado.';

  @override
  String get sharedLinkUnavailableMessage =>
      'Puede que el viaje ya no esté compartido o que el enlace sea incorrecto.';

  @override
  String get sharedPlacesGroup => 'Lugares';

  @override
  String sharedSaveCopyError(String error) {
    return 'No se pudo guardar una copia: $error';
  }

  @override
  String sharedJoinError(String error) {
    return 'No se pudo unir al viaje: $error';
  }

  @override
  String sharedBy(String name) {
    return 'Compartido por $name';
  }

  @override
  String get sharedNoMappedPlaces => 'No hay lugares en el mapa';

  @override
  String sharedNoPlacesIn(String city) {
    return 'No hay lugares fijados en $city';
  }

  @override
  String get sharedEmptyTitle => 'Aún no hay lugares';

  @override
  String get sharedEmptyMessage => 'Este viaje todavía no tiene itinerario.';

  @override
  String sharedDayN(int day) {
    return 'Día $day';
  }

  @override
  String get sharedStays => 'Alojamientos';

  @override
  String get sharedJoinCoPlanner => 'Unirme como coplanificador';

  @override
  String get sharedSaveSeparateCopy => 'O guardar una copia aparte';

  @override
  String get sharedKeepInTrips => 'Guardar en mis viajes';

  @override
  String get legalAgreementPrefix => 'Al registrarte aceptas los ';

  @override
  String get legalConsentCheckboxPrefix => 'Acepto los ';

  @override
  String get legalTermsOfService => 'Términos del servicio';

  @override
  String get legalAgreementConjunction => ' y la ';

  @override
  String get legalPrivacyPolicy => 'Política de privacidad';

  @override
  String get offlineJustNow => 'ahora mismo';

  @override
  String offlineMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count minutos',
      one: 'hace 1 minuto',
    );
    return '$_temp0';
  }

  @override
  String offlineHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count horas',
      one: 'hace 1 hora',
    );
    return '$_temp0';
  }

  @override
  String offlineDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count días',
      one: 'hace 1 día',
    );
    return '$_temp0';
  }

  @override
  String offlineBannerMessage(String when) {
    return 'Sin conexión: mostrando la copia guardada $when';
  }

  @override
  String get chatInputHint => '¿A dónde quieres ir?';

  @override
  String get chatFollowUpHint => 'Haz una pregunta de seguimiento…';

  @override
  String get chatSend => 'Enviar';

  @override
  String get chatStopGenerating => 'Detener la generación';

  @override
  String get chatAttachImages => 'Adjuntar imágenes';

  @override
  String get chatStopDictating => 'Dejar de dictar';

  @override
  String get chatDictate => 'Dictar';

  @override
  String get chatDropImages => 'Suelta imágenes para adjuntarlas';

  @override
  String get chatRemoveImage => 'Quitar imagen';

  @override
  String get chatImagePlaceholder => 'Imagen';

  @override
  String get chatStillPreparingImage =>
      'Todavía se está preparando una imagen — un momento.';

  @override
  String chatAttachLimit(int count) {
    return 'Puedes adjuntar hasta $count imágenes.';
  }

  @override
  String get chatImageUnreadable =>
      'No se pudo leer esa imagen — prueba con un JPEG, PNG, GIF o WebP de menos de 10 MB.';

  @override
  String get chatOnlyImages => 'Solo se pueden adjuntar archivos de imagen.';

  @override
  String get chatToolSearchPlaces => 'Buscando lugares...';

  @override
  String get chatToolCreateItinerary => 'Creando itinerario...';

  @override
  String get chatToolUpdateItinerary => 'Actualizando itinerario...';

  @override
  String get chatToolSearchFlights => 'Buscando vuelos...';

  @override
  String get chatToolCheckConnectivity =>
      'Comprobando la conectividad de la ruta...';

  @override
  String get chatToolSearchEvents => 'Buscando eventos...';

  @override
  String get chatToolSuggestFerries => 'Buscando ferris...';

  @override
  String get chatToolLocalRecs => 'Buscando recomendaciones locales...';

  @override
  String get chatToolReviewTrip => 'Revisando tu viaje...';

  @override
  String get chatToolWeather => 'Consultando el tiempo...';

  @override
  String get chatToolSearchNearby => 'Buscando cerca...';

  @override
  String get chatToolWorking => 'Procesando...';

  @override
  String get chatSummarizing => 'Resumiendo la conversación anterior…';

  @override
  String get chatProfileUpdatedTooltip => 'Perfil de viaje actualizado';

  @override
  String get chatProfileUpdated => 'Anotado — perfil de viaje actualizado';

  @override
  String get chatTripUpdated => 'Viaje actualizado';

  @override
  String chatChipFlightOptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count opciones de vuelo',
      one: '$count opción de vuelo',
    );
    return '$_temp0';
  }

  @override
  String chatChipLocalPicks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count recomendaciones locales',
      one: '$count recomendación local',
    );
    return '$_temp0';
  }

  @override
  String chatStripPlaces(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lugares',
      one: '$count lugar',
    );
    return '$_temp0';
  }

  @override
  String chatStripParking(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count opciones de aparcamiento',
      one: '$count opción de aparcamiento',
    );
    return '$_temp0';
  }

  @override
  String get chatToolFindParking => 'Buscando aparcamiento...';

  @override
  String get chatCardFreeListed => 'Gratis (según el listado)';

  @override
  String chatStripHotels(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alojamientos',
      one: '$count alojamiento',
    );
    return '$_temp0';
  }

  @override
  String get chatStripHotelsNoRates => 'sin precios en directo';

  @override
  String chatCardPerNight(String price) {
    return '$price/noche';
  }

  @override
  String get chatToolSearchHotels => 'Buscando alojamientos...';

  @override
  String get chatLinksStays => 'Ver alojamientos';

  @override
  String get chatLinksTransport => 'Ver transporte';

  @override
  String chatChipEvents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos',
      one: '$count evento',
    );
    return '$_temp0';
  }

  @override
  String chatChipFerryOptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count opciones de ferri',
      one: '$count opción de ferri',
    );
    return '$_temp0';
  }

  @override
  String chatChipEventSources(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fuentes de eventos',
      one: '$count fuente de eventos',
    );
    return '$_temp0';
  }

  @override
  String get chatTryAgain => 'Intentar de nuevo';

  @override
  String get chatQueued => 'En cola';

  @override
  String get chatRemoveQueued => 'Quitar mensaje en cola';

  @override
  String get agentScreenTitle => 'Planea tu viaje';

  @override
  String get agentScreenStartOver => 'Empezar de nuevo';

  @override
  String get agentScreenEmptyTitle => 'Cuéntame sobre el viaje de tus sueños';

  @override
  String get agentScreenEmptyMessage =>
      'Buscaré lugares reales y crearé un itinerario día a día para ti.';

  @override
  String agentScreenItineraryReady(int count) {
    return 'Itinerario listo — $count lugares';
  }

  @override
  String get agentScreenViewTrip => 'Ver viaje';

  @override
  String get agentScreenSignInToSave => 'Inicia sesión para guardar tus viajes';

  @override
  String get resultChipViewInTrip => 'Ver en el viaje';

  @override
  String refineTargetDay(int day) {
    return 'Día $day';
  }

  @override
  String refineTargetDayCity(int day, String city) {
    return 'Día $day — $city';
  }

  @override
  String get refineTargetWholeTrip => 'Todo el viaje';

  @override
  String get refineAssistantTitle => 'Asistente de viaje';

  @override
  String refineHeader(String target) {
    return 'Ajustando · $target';
  }

  @override
  String get refineAssistantHint => 'Pregunta lo que quieras sobre este viaje…';

  @override
  String get refineHint => 'Pide cambios...';

  @override
  String get refineNewChat => 'Chat nuevo';

  @override
  String get refineNewChatConfirmTitle => '¿Empezar un chat nuevo?';

  @override
  String get refineNewChatConfirmBody =>
      'Se borrará esta conversación. Tu viaje no se ve afectado.';

  @override
  String get refineResumeLoading => 'Restaurando tu conversación…';

  @override
  String get refineResumeGone => 'Esta conversación ha caducado.';

  @override
  String get refineResumeGoneDetail =>
      'Se borró o se eliminó junto con su viaje. Puedes empezar una nueva.';

  @override
  String get refineResumeFailed => 'No se pudo reabrir esta conversación.';

  @override
  String get tripContinueChat => 'Continuar chat';

  @override
  String tripContinueChatMeta(int count, String age) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count mensajes',
      one: '1 mensaje',
    );
    return '$_temp0 · $age';
  }

  @override
  String get chatDictationPermission =>
      'Se bloqueó el acceso al micrófono. Revisa la configuración de tu navegador.';

  @override
  String get chatDictationUnsupported =>
      'La entrada por voz no está disponible en este navegador.';

  @override
  String get chatDictationUnavailable =>
      'La entrada por voz no está disponible en este momento.';

  @override
  String get chatDictationFailed =>
      'No se pudo transcribir el audio. Puedes escribir en su lugar.';

  @override
  String get placeSearchAddTitle => 'Añadir ubicación';

  @override
  String get placeSearchEditTitle => 'Editar ubicación';

  @override
  String get placeSearchManualCoords => 'Usar coordenadas manuales';

  @override
  String get placeSearchManualCoordsSubtitle =>
      'Introduce la latitud y la longitud manualmente en lugar de buscar lugares';

  @override
  String get placeSearchNameLabel => 'Nombre de la ubicación *';

  @override
  String get placeSearchNameRequired =>
      'El nombre de la ubicación es obligatorio';

  @override
  String get placeSearchCategoryLabel => 'Categoría (opcional)';

  @override
  String get placeSearchCategoryHint =>
      'p. ej., restaurant, museum, coffee_shop';

  @override
  String get placeSearchVisitDurationLabel =>
      'Duración de la visita (minutos, opcional)';

  @override
  String get placeSearchDurationInvalid =>
      'Introduce una duración válida en minutos';

  @override
  String get placeSearchSearchLabel => 'Buscar un lugar';

  @override
  String get placeSearchSearchHint =>
      'Escribe para buscar restaurantes, atracciones, etc.';

  @override
  String get placeSearchLatitude => 'Latitud';

  @override
  String get placeSearchLongitude => 'Longitud';

  @override
  String get placeSearchLatitudeRequired => 'Latitud *';

  @override
  String get placeSearchLongitudeRequired => 'Longitud *';

  @override
  String get placeSearchLatitudeRequiredError => 'La latitud es obligatoria';

  @override
  String get placeSearchLongitudeRequiredError => 'La longitud es obligatoria';

  @override
  String get placeSearchLatitudeInvalid =>
      'Introduce una latitud válida (-90 a 90)';

  @override
  String get placeSearchLongitudeInvalid =>
      'Introduce una longitud válida (-180 a 180)';

  @override
  String get placeSearchNoResults =>
      'No se encontraron lugares. Prueba con otro término de búsqueda.';

  @override
  String placeSearchError(String error) {
    return 'Error: $error';
  }

  @override
  String addToTripAddedTo(String title) {
    return 'Añadido a $title';
  }

  @override
  String get addToTripViewTrip => 'Ver viaje';

  @override
  String get addToTripTitle => 'Añadir al viaje';

  @override
  String get addToTripDuplicate => 'Ya está en este viaje.';

  @override
  String get addToTripAddAnyway => 'Añadir de todos modos';

  @override
  String addToTripLoadTripError(String error) {
    return 'No se pudo cargar ese viaje: $error';
  }

  @override
  String addToTripAddPlaceError(String error) {
    return 'No se pudo añadir el lugar: $error';
  }

  @override
  String get addToTripLoadTripsError => 'No se pudieron cargar tus viajes.';

  @override
  String get addToTripNoTrips =>
      'Aún no tienes viajes — planifica un viaje primero y luego añade lugares.';

  @override
  String get addToTripUnscheduled => 'Sin programar';

  @override
  String addToTripDay(int day) {
    return 'Día $day';
  }

  @override
  String get flightSearchTitle => 'Buscar vuelos';

  @override
  String get flightSearchFrom => 'Desde';

  @override
  String get flightSearchTo => 'Hasta';

  @override
  String get flightSearchDepartDate => 'Fecha de ida';

  @override
  String get flightSearchReturnOptional => 'Vuelta (opcional)';

  @override
  String get flightSearchClearReturnTooltip => 'Borrar fecha de vuelta';

  @override
  String get flightSearchCabinEconomy => 'Económica';

  @override
  String get flightSearchCabinPremiumEconomy => 'Económica premium';

  @override
  String get flightSearchCabinBusiness => 'Business';

  @override
  String get flightSearchCabinFirst => 'Primera';

  @override
  String get flightSearchBaggagePersonalItem => 'Artículo personal';

  @override
  String get flightSearchBaggageCarryOn => 'Equipaje de mano';

  @override
  String get flightSearchBaggageChecked => 'Maleta facturada';

  @override
  String get flightSearchPresetCheapest => 'Más barato';

  @override
  String get flightSearchPresetFastest => 'Más rápido';

  @override
  String get flightSearchPresetBalanced => 'Equilibrado';

  @override
  String get flightSearchSearching => 'Buscando…';

  @override
  String get flightSearchSubmit => 'Buscar vuelos';

  @override
  String get flightSearchErrorTitle => 'No se pudieron cargar los vuelos';

  @override
  String get flightSearchHintInitial =>
      'Elige un origen, un destino y una fecha para buscar vuelos.';

  @override
  String get flightSearchHintEmpty =>
      'No se encontraron vuelos para esta ruta y fecha.';

  @override
  String get flightSearchHintInitialTitle => 'Encuentra tu vuelo';

  @override
  String get flightSearchNoResultsTitle => 'No se encontraron vuelos';

  @override
  String get flightSearchFormTitle => 'Búsqueda';

  @override
  String get flightSearchEditSearch => 'Editar búsqueda';

  @override
  String flightSearchSummaryTravelers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count viajeros',
      one: '1 viajero',
    );
    return '$_temp0';
  }

  @override
  String get flightSearchCabinLabel => 'Cabina';

  @override
  String get flightSearchBaggageLabel => 'Equipaje';

  @override
  String get flightSearchCheckedNotPriced =>
      'Estos precios incluyen la tarifa de equipaje de mano, pero no la de maleta facturada: consúltala con la aerolínea.';

  @override
  String get flightSearchOptimizeLabel => 'Ordenar resultados por';

  @override
  String get flightSearchAdults => 'Adultos';

  @override
  String get flightSearchChildren => 'Niños';

  @override
  String get flightSearchAddAdult => 'Añadir adulto';

  @override
  String get flightSearchRemoveAdult => 'Quitar adulto';

  @override
  String get flightSearchAddChild => 'Añadir niño';

  @override
  String get flightSearchRemoveChild => 'Quitar niño';

  @override
  String flightSearchChildN(int n) {
    return 'Niño $n';
  }

  @override
  String flightSearchResultsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count vuelos encontrados',
      one: '1 vuelo encontrado',
    );
    return '$_temp0';
  }

  @override
  String flightCardSavings(String amount) {
    return 'Ahorras $amount frente a la siguiente opción';
  }

  @override
  String get flightCardBagIncluded => 'Maleta incluida';

  @override
  String flightCardBagPaid(String fee) {
    return 'maleta incl. +$fee';
  }

  @override
  String get flightCardBagInPrice => 'tarifa de equipaje incluida';

  @override
  String get flightCardBagUnknown => 'Tarifa de maleta desconocida';

  @override
  String get flightCardOpenLinkError => 'No se pudo abrir el enlace';

  @override
  String get flightCardBestMatch => 'MEJOR OPCIÓN';

  @override
  String get flightCardFlight => 'Vuelo';

  @override
  String flightCardScore(String score) {
    return 'puntuación $score';
  }

  @override
  String get flightCardBook => 'Reservar';

  @override
  String get flightSheetOutbound => 'Ida';

  @override
  String get flightSheetReturn => 'Vuelta';

  @override
  String get flightSheetRoundTrip => 'Ida y vuelta';

  @override
  String get flightSheetBookThisFlight => 'Reservar este vuelo';

  @override
  String flightSheetBookWith(String airline) {
    return 'Reservar con $airline';
  }

  @override
  String get flightSheetBagPersonalItem => 'Artículo personal';

  @override
  String flightSheetBagCarryOnCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count equipajes de mano',
      one: 'equipaje de mano',
    );
    return '$_temp0';
  }

  @override
  String flightSheetBagCheckedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count maletas facturadas',
      one: 'maleta facturada',
    );
    return '$_temp0';
  }

  @override
  String flightSheetIncluded(String list) {
    return 'Incluye: $list';
  }

  @override
  String flightSheetBagFeeNote(String fee) {
    return '+$fee de tarifa de maleta incluida en el precio';
  }

  @override
  String get flightSheetBagInPriceNote =>
      'La tarifa del equipaje ya está incluida en este precio';

  @override
  String get flightSheetBagUnknownNote =>
      'Tu maleta no está incluida — consulta la tarifa con la aerolínea';

  @override
  String flightSheetLayover(String airport) {
    return 'Escala en $airport';
  }

  @override
  String flightSheetLayoverWithDuration(String airport, String duration) {
    return 'Escala en $airport · $duration';
  }

  @override
  String get airportFieldHint => 'Ciudad o aeropuerto';

  @override
  String get airportFieldClearTooltip => 'Borrar selección';

  @override
  String get airportFieldNoMatches => 'No hay aeropuertos que coincidan';

  @override
  String get guidesTitle => 'Guías locales';

  @override
  String get guidesErrorTitle => 'No se pudieron cargar las guías';

  @override
  String get guidesErrorMessage =>
      'Comprueba tu conexión e inténtalo de nuevo.';

  @override
  String get guidesEmptyTitle => 'Aún no hay guías';

  @override
  String get guidesEmptyMessage =>
      'Las guías de locales de verdad aparecerán aquí a medida que se publiquen.';

  @override
  String get guidesElsewhere => 'En otros lugares';

  @override
  String guidesByline(String name) {
    return 'por $name';
  }

  @override
  String get guideDetailTitle => 'Guía local';

  @override
  String get guideDetailErrorTitle => 'No se pudo cargar esta guía';

  @override
  String get guideDetailErrorMessage =>
      'Comprueba tu conexión e inténtalo de nuevo.';

  @override
  String guideDetailByline(String name) {
    return 'Por $name';
  }

  @override
  String get guideDetailPlacesTitle => 'Lugares de esta guía';

  @override
  String get guideDetailNoPinsTitle => 'Aún no hay lugares marcados';

  @override
  String get guideDetailNoPinsMessage =>
      'Por ahora esta guía es solo narrativa.';

  @override
  String get appMapCredits => 'Créditos del mapa';

  @override
  String flightStops(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count escalas',
      one: '1 escala',
      zero: 'Sin escalas',
    );
    return '$_temp0';
  }

  @override
  String flightStopsEachWay(String stops) {
    return '$stops por trayecto';
  }

  @override
  String flightStopsSplit(String outbound, String inbound) {
    return '$outbound / $inbound';
  }

  @override
  String calendarStayTitle(String name) {
    return 'Alojamiento: $name';
  }

  @override
  String calendarSegmentTitle(String mode, String route) {
    return '$mode: $route';
  }

  @override
  String get calendarModeFlight => 'Vuelo';

  @override
  String get calendarModeTrain => 'Tren';

  @override
  String get calendarModeBus => 'Autobús';

  @override
  String get calendarModeCar => 'Coche';

  @override
  String get calendarModeFerry => 'Ferri';

  @override
  String get calendarModeOther => 'Otro';

  @override
  String get errorNetwork =>
      'Comprueba tu conexión a internet e inténtalo de nuevo.';

  @override
  String get errorTooManyRequests =>
      'Vas un poco demasiado rápido: espera un momento e inténtalo de nuevo.';

  @override
  String get errorSession => 'Tu sesión ha caducado. Vuelve a iniciar sesión.';

  @override
  String get errorServer =>
      'Algo salió mal de nuestro lado. Inténtalo de nuevo en un momento.';

  @override
  String get errorGeneric => 'Algo salió mal. Inténtalo de nuevo.';

  @override
  String get nearMeChipLabel => '¿Qué hay cerca de mí?';

  @override
  String get nearMeSeedLabel => 'Cerca de mi ubicación actual';

  @override
  String nearMeSeedMessage(String lat, String lng, String accuracy) {
    return 'Mi ubicación actual es latitud $lat, longitud $lng (precisión de unos $accuracy m). ¿Qué hay bueno para ver, hacer o comer cerca de mí ahora mismo?';
  }

  @override
  String nearMeManualMessage(String place) {
    return 'Estoy en $place. ¿Qué hay bueno para ver, hacer o comer por la zona ahora mismo?';
  }

  @override
  String get nearMeDialogTitle => '¿Dónde estás?';

  @override
  String get nearMeDialogMessage =>
      'No pudimos obtener tu ubicación. Escribe una ciudad o un barrio, o activa el acceso a la ubicación e inténtalo de nuevo.';

  @override
  String get nearMeDialogHint => 'p. ej. Atenas, Plaka';

  @override
  String get nearMeDialogCta => 'Preguntar';

  @override
  String get wearSectionTitle => 'Qué ponerte y qué llevar';

  @override
  String get wearBandFreezing => 'Bajo cero — ropa térmica y abrigo aislante';

  @override
  String get wearBandCold => 'Frío — abrigo, gorro y guantes';

  @override
  String get wearBandCool => 'Fresco — chaqueta y varias capas';

  @override
  String get wearBandMild => 'Templado — capas ligeras';

  @override
  String get wearBandWarm =>
      'Cálido — ropa de verano y una capa ligera para la noche';

  @override
  String get wearBandHot => 'Calor — ropa ligera y protección solar';

  @override
  String get wearRainLikely => 'lluvia probable, lleva paraguas';

  @override
  String get wearBigSwing => 'gran variación día-noche, lleva capas';

  @override
  String get wearExtremeHeat => 'días muy calurosos, protección solar extra';

  @override
  String get wearFreezingNights => 'noches bajo cero, capas de abrigo';

  @override
  String get wearSummaryRain => 'lluvia probable';

  @override
  String get wearHistoricalFootnote =>
      'Más allá del pronóstico de 16 días, los rangos muestran el tiempo habitual en estas fechas.';

  @override
  String get wearPackTitle => 'Qué llevar en este viaje';

  @override
  String get wearByCityTitle => 'Ciudad por ciudad';

  @override
  String get wearEveryStop => 'todas las paradas';

  @override
  String get wearPackThermals => 'Ropa térmica';

  @override
  String get wearPackWarmCoat => 'Abrigo, gorro y guantes';

  @override
  String get wearPackJacket => 'Una chaqueta o capa de abrigo';

  @override
  String get wearPackLightLayer => 'Una capa ligera para la noche';

  @override
  String get wearPackSummerClothes => 'Ropa de verano';

  @override
  String get wearPackRainGear => 'Un paraguas o chubasquero';

  @override
  String get wearPackSunProtection => 'Protección solar';

  @override
  String get rickRollCaption => 'Never gonna give you up';

  @override
  String get rickRollDismissHint => 'toca donde sea para salir';
}
