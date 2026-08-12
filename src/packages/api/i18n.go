package main

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Server-side localization (specs/i18n-spanish).
//
// The client resolves the locale (explicit override, else device language) and
// states it on every request via Accept-Language; the server never re-derives
// it. users.locale is consulted only where there is no request at all —
// background email jobs and token-gated exports.
//
// Scope is the text the API itself renders: emails, trip-review findings, the
// print/share export pages and .ics labels. The writeJSONError strings are
// deliberately NOT localized — they are developer- and edge-case-facing, and
// the right fix there is machine-readable error codes mapped client-side.
// Exception: the import.* error/warning strings, which the import screen
// displays verbatim to end users (specs/import-trip-from-ai-chat) — those go
// through tr() like any other user-facing copy.
//
// The catalog is a plain map rather than golang.org/x/text/message: the
// server-side surface is a few dozen strings across a handful of locales, so a
// literal map stays greppable, dependency-free, and testable. TestCatalogIsComplete
// fails if any key is missing a translation, which is what keeps the fallback
// path from silently becoming the normal path.

const defaultLocale = "en"

const localeContextKey contextKey = "locale"

// supportedLocales is the source of truth for both negotiation and validation,
// most-preferred first. Adding a locale means: append here, add a languageNames
// entry, and fill in the catalog (the completeness test enforces the last one).
var supportedLocales = []string{"en", "es"}

// languageNames are English names for each locale, used to build the AI
// response-language instruction.
var languageNames = map[string]string{
	"en": "English",
	"es": "Spanish (español)",
}

// normalizeLocale folds a user- or header-supplied tag to a supported base
// language: "es-MX", "ES", "es-419" all become "es". Returns ok=false for
// anything unsupported, so callers can reject rather than silently defaulting.
func normalizeLocale(tag string) (string, bool) {
	base := strings.ToLower(strings.TrimSpace(tag))
	if i := strings.IndexAny(base, "-_"); i >= 0 {
		base = base[:i]
	}
	for _, l := range supportedLocales {
		if l == base {
			return l, true
		}
	}
	return "", false
}

// languageName returns the English name of a locale, for prompt text.
func languageName(locale string) string {
	if name, ok := languageNames[locale]; ok {
		return name
	}
	return languageNames[defaultLocale]
}

// matchLocale picks the best supported locale from an Accept-Language header,
// honoring q-values ("fr,es;q=0.9,en;q=0.8" => es, even though fr comes first).
// Unparseable, empty, and all-unsupported headers yield the default locale.
func matchLocale(header string) string {
	type candidate struct {
		tag string
		q   float64
		pos int
	}
	var candidates []candidate
	for i, part := range strings.Split(header, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		tag, q := part, 1.0
		if semi := strings.Index(part, ";"); semi >= 0 {
			tag = strings.TrimSpace(part[:semi])
			for _, param := range strings.Split(part[semi+1:], ";") {
				k, v, found := strings.Cut(param, "=")
				if !found || strings.ToLower(strings.TrimSpace(k)) != "q" {
					continue
				}
				if parsed, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
					q = parsed
				}
			}
		}
		// q=0 means "explicitly not acceptable".
		if q <= 0 {
			continue
		}
		if locale, ok := normalizeLocale(tag); ok {
			candidates = append(candidates, candidate{tag: locale, q: q, pos: i})
		}
	}
	if len(candidates) == 0 {
		return defaultLocale
	}
	// Highest q wins; ties break on header order, which is where browsers put
	// their real preference.
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].q != candidates[j].q {
			return candidates[i].q > candidates[j].q
		}
		return candidates[i].pos < candidates[j].pos
	})
	return candidates[0].tag
}

// localeMiddleware stamps the negotiated locale onto the request context. It
// runs for every route — including the public token-gated export routes, which
// have no session to read a stored locale from.
func localeMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		locale := matchLocale(r.Header.Get("Accept-Language"))
		// An explicit ?lang= wins: export links are opened by a browser or a
		// calendar app whose own language says nothing about the traveler's.
		if q := r.URL.Query().Get("lang"); q != "" {
			if override, ok := normalizeLocale(q); ok {
				locale = override
			}
		}
		ctx := context.WithValue(r.Context(), localeContextKey, locale)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// requestLocale returns the locale negotiated for this request, or the default
// outside one. Never returns "", so every call site is safe without a guard.
func requestLocale(ctx context.Context) string {
	if locale, ok := ctx.Value(localeContextKey).(string); ok && locale != "" {
		return locale
	}
	return defaultLocale
}

// localeOrDefault resolves a stored (nullable) users.locale for the
// request-less callers: background email jobs and export fallbacks.
func localeOrDefault(stored *string) string {
	if stored == nil {
		return defaultLocale
	}
	if locale, ok := normalizeLocale(*stored); ok {
		return locale
	}
	return defaultLocale
}

// messages maps a stable key to its per-locale template. Templates are Sprintf
// format strings; argument order must match across locales, which is why
// multi-argument entries keep their placeholders in the same sequence.
var messages = map[string]map[string]string{
	"common.day":         {"en": "Day %d", "es": "Día %d"},
	"common.unscheduled": {"en": "Unscheduled", "es": "Sin programar"},

	"email.invite.body":            {"en": "%s invited you to co-plan \"%s\" on Golden Tempo Travel.\n\nOpen this link to see the trip and join as a co-planner:\n\n%s\n\nThe link works once and expires in 7 days. If you weren't expecting this, you can ignore this email.", "es": "%s te ha invitado a planificar «%s» juntos en Golden Tempo Travel.\n\nAbre este enlace para ver el viaje y unirte como coplanificador:\n\n%s\n\nEl enlace funciona una sola vez y caduca en 7 días. Si no esperabas este correo, puedes ignorarlo."},
	"email.invite.default_sender":  {"en": "A traveler", "es": "Alguien"},
	"email.invite.subject":         {"en": "%s invited you to co-plan \"%s\"", "es": "%s te ha invitado a planificar «%s» juntos"},
	"email.nudge.body":             {"en": "You started planning a trip but haven't been back in a while — your work is saved right where you left it.", "es": "Empezaste a planificar un viaje, pero hace tiempo que no vuelves: tu trabajo sigue guardado justo donde lo dejaste."},
	"email.nudge.greeting":         {"en": "Hi %s,", "es": "Hola, %s:"},
	"email.nudge.greeting_generic": {"en": "Hi there,", "es": "¡Hola!"},
	"email.nudge.resume":           {"en": "Jump back in: %s", "es": "Vuelve a entrar aquí: %s"},
	"email.nudge.subject":          {"en": "Pick up where you left off", "es": "Retoma donde lo dejaste"},
	"email.nudge.unsubscribe":      {"en": "Not planning anything right now? Unsubscribe from these nudges: %s", "es": "¿No estás planificando nada ahora mismo? Cancela la suscripción a estos recordatorios: %s"},
	"email.reminder.departure":     {"en": "Departure: %s", "es": "Salida: %s"},
	"email.reminder.lead_soon":     {"en": "Your trip \"%s\" is coming up in %d days.", "es": "Tu viaje «%s» comienza dentro de %d días."},
	"email.reminder.lead_today":    {"en": "Today's the day — \"%s\" begins.", "es": "Hoy es el día: «%s» comienza."},
	"email.reminder.open":          {"en": "Open your itinerary: %s", "es": "Abre tu itinerario: %s"},
	"email.reminder.signoff":       {"en": "Safe travels!", "es": "¡Buen viaje!"},
	"email.reminder.subject_soon":  {"en": "Your trip \"%s\" starts in %d days", "es": "Tu viaje «%s» empieza dentro de %d días"},
	"email.reminder.subject_today": {"en": "Your trip \"%s\" starts today", "es": "Tu viaje «%s» empieza hoy"},
	"email.reminder.unsubscribe":   {"en": "To stop trip reminders, unsubscribe here: %s", "es": "Para dejar de recibir recordatorios de viaje, cancela la suscripción aquí: %s"},
	"email.reset.body":             {"en": "Someone (hopefully you) asked to reset your Golden Tempo Travel password.\n\nReset your password: %s\n\nIf the link doesn't open, use this reset code instead:\n\n    %s\n\nIn the app, choose \"Forgot password?\", paste the code, and pick a new password. The link and code are valid for 1 hour and work once. If this wasn't you, ignore this email — your password is unchanged.", "es": "Alguien (esperamos que tú) pidió restablecer tu contraseña de Golden Tempo Travel.\n\nRestablece tu contraseña: %s\n\nSi el enlace no se abre, usa este código de restablecimiento:\n\n    %s\n\nEn la app, elige «¿Olvidaste tu contraseña?», pega el código y elige una contraseña nueva. El enlace y el código son válidos durante 1 hora y funcionan una sola vez. Si no fuiste tú, ignora este correo: tu contraseña no ha cambiado."},
	"email.reset.subject":          {"en": "Reset your password — Golden Tempo Travel", "es": "Restablece tu contraseña — Golden Tempo Travel"},
	"email.verify.body":            {"en": "Welcome to Golden Tempo Travel!\n\nConfirm your email address by opening this link:\n\n%s\n\nThe link expires in 24 hours. If you didn't create an account, you can ignore this email.", "es": "¡Te damos la bienvenida a Golden Tempo Travel!\n\nConfirma tu dirección de correo abriendo este enlace:\n\n%s\n\nEl enlace caduca en 24 horas. Si no creaste una cuenta, puedes ignorar este correo."},
	"email.verify.subject":         {"en": "Confirm your email — Golden Tempo Travel", "es": "Confirma tu correo — Golden Tempo Travel"},

	"ics.booked":        {"en": "Booked", "es": "Reservado"},
	"ics.mode.bus":      {"en": "Bus", "es": "Autobús"},
	"ics.mode.car":      {"en": "Car", "es": "Coche"},
	"ics.mode.ferry":    {"en": "Ferry", "es": "Ferri"},
	"ics.mode.flight":   {"en": "Flight", "es": "Vuelo"},
	"ics.mode.other":    {"en": "Other", "es": "Otro"},
	"ics.mode.train":    {"en": "Train", "es": "Tren"},
	"ics.recommendedBy": {"en": "Recommended by %s", "es": "Recomendado por %s"},
	"ics.segmentTitle":  {"en": "%s: %s", "es": "%s: %s"},
	"ics.stayTitle":     {"en": "Stay: %s", "es": "Alojamiento: %s"},

	"import.error.daily_limit":        {"en": "You've reached today's import limit — try again tomorrow.", "es": "Alcanzaste el límite de importaciones de hoy — inténtalo de nuevo mañana."},
	"import.error.no_trip":            {"en": "We couldn't find a trip in that text — paste the conversation or its final summary.", "es": "No encontramos un viaje en ese texto — pega la conversación o su resumen final."},
	"import.error.nothing_located":    {"en": "We couldn't locate any of the places in that text on the map.", "es": "No pudimos ubicar en el mapa ninguno de los lugares de ese texto."},
	"import.error.places_unavailable": {"en": "Place lookups are temporarily unavailable — please try again in a few minutes.", "es": "La búsqueda de lugares no está disponible temporalmente — inténtalo de nuevo en unos minutos."},
	"import.error.trip_limit":         {"en": "You've reached your trip limit — delete an old trip first.", "es": "Alcanzaste tu límite de viajes — elimina primero un viaje antiguo."},
	"import.warning.approximate":      {"en": "%s: location is approximate — check it on the map", "es": "%s: la ubicación es aproximada — revísala en el mapa"},
	"import.warning.capped":           {"en": "Only the first %d places were imported — %d more were left out.", "es": "Solo se importaron los primeros %d lugares — %d más quedaron fuera."},
	"import.warning.dropped":          {"en": "%s couldn't be located and was left out — add it manually", "es": "%s no se pudo ubicar y quedó fuera — agrégalo manualmente"},
	"import.warning.unverified":       {"en": "Place verification is unavailable right now — imported locations are approximate.", "es": "La verificación de lugares no está disponible ahora — las ubicaciones importadas son aproximadas."},

	"notif.aTraveler": {"en": "A traveler", "es": "Un viajero"},

	"page.verify.expired.body":  {"en": "Request a new verification email from your account.", "es": "Pide un nuevo correo de verificación desde tu cuenta."},
	"page.verify.expired.title": {"en": "Link expired or already used", "es": "El enlace caducó o ya se usó"},
	"page.verify.ok.body":       {"en": "You're all set — head back to %s.", "es": "Todo listo: vuelve a %s."},
	"page.verify.ok.title":      {"en": "Email verified ✓", "es": "Correo verificado ✓"},

	"print.accommodations":       {"en": "Accommodations", "es": "Alojamientos"},
	"print.arrives":              {"en": "Arrives %s", "es": "Llega el %s"},
	"print.booked":               {"en": "(booked)", "es": "(reservado)"},
	"print.bookingChecklist":     {"en": "Booking checklist", "es": "Lista de reservas"},
	"print.budget":               {"en": "Budget", "es": "Presupuesto"},
	"print.checkIn":              {"en": "Check-in %s", "es": "Entrada %s"},
	"print.checkInToday":         {"en": "Check in today", "es": "Entrada hoy"},
	"print.checkOut":             {"en": "Check-out %s", "es": "Salida %s"},
	"print.checkOutOn":           {"en": "Check out %s", "es": "Salida el %s"},
	"print.dateWithYear":         {"en": "%s, %d", "es": "%s de %d"},
	"print.dayTripFrom":          {"en": "Day trip from %s", "es": "Excursión de un día desde %s"},
	"print.departs":              {"en": "Departs %s", "es": "Sale el %s"},
	"print.emptyExport":          {"en": "This trip has nothing to export yet.", "es": "Este viaje aún no tiene nada que exportar."},
	"print.footer":               {"en": "Exported from Golden Tempo Travel", "es": "Exportado desde Golden Tempo Travel"},
	"print.itinerary":            {"en": "Itinerary", "es": "Itinerario"},
	"print.linkUnavailableBody":  {"en": "It may have expired.", "es": "Puede que haya caducado."},
	"print.linkUnavailableTitle": {"en": "This export link isn't available", "es": "Este enlace de exportación no está disponible"},
	"print.noPlans":              {"en": "No plans yet for this day.", "es": "Aún no hay planes para este día."},
	"print.otherTransport":       {"en": "Other transport", "es": "Otros transportes"},
	"print.packingChecklist":     {"en": "Packing checklist", "es": "Lista de equipaje"},
	"print.recommendedBy":        {"en": "Recommended by", "es": "Recomendado por"},
	"print.remaining":            {"en": "Remaining:", "es": "Restante:"},
	"print.target":               {"en": "Target:", "es": "Objetivo:"},
	"print.tonight":              {"en": "Tonight:", "es": "Esta noche:"},
	"print.totalSpent":           {"en": "Total spent:", "es": "Total gastado:"},
	"print.untitledTrip":         {"en": "Untitled trip", "es": "Viaje sin título"},
	"print.weather":              {"en": "Weather", "es": "Tiempo"},
	"print.weatherRainChance":    {"en": ", %d%% chance of rain", "es": ", %d%% de probabilidad de lluvia"},
	"print.weatherRainMm":        {"en": ", %.0fmm rain", "es": ", %.0f mm de lluvia"},
	"print.weatherTypical":       {"en": "Typical: %s", "es": "Típico: %s"},

	"review.confirmBooking":       {"en": "Confirm your booking for %s.", "es": "Confirma tu reserva de %s."},
	"review.emptyDay":             {"en": "Day %d has nothing planned.", "es": "El día %d no tiene nada planificado."},
	"review.emptyDayRange":        {"en": "Days %d–%d have nothing planned.", "es": "Los días %d–%d no tienen nada planificado."},
	"review.fix.addBus":           {"en": "Add bus", "es": "Añadir autobús"},
	"review.fix.addDrive":         {"en": "Add drive", "es": "Añadir trayecto en coche"},
	"review.fix.addFerry":         {"en": "Add ferry", "es": "Añadir ferri"},
	"review.fix.addStay":          {"en": "Add a stay", "es": "Añadir alojamiento"},
	"review.fix.addSunProtection": {"en": "+ sun protection", "es": "+ protección solar"},
	"review.fix.addTrain":         {"en": "Add train", "es": "Añadir tren"},
	"review.fix.addTransport":     {"en": "Add transport", "es": "Añadir transporte"},
	"review.fix.addUmbrella":      {"en": "+ umbrella", "es": "+ paraguas"},
	"review.fix.addWarmLayers":    {"en": "+ warm layers", "es": "+ ropa de abrigo"},
	"review.fix.adjustBudget":     {"en": "Adjust budget", "es": "Ajustar el presupuesto"},
	"review.fix.markBooked":       {"en": "Mark booked", "es": "Marcar como reservado"},
	"review.fix.moveToDay":        {"en": "Move to Day %d", "es": "Mover al día %d"},
	"review.fix.reschedule":       {"en": "Reschedule", "es": "Reprogramar"},
	"review.fix.setDates":         {"en": "Set dates", "es": "Añadir fechas"},
	"review.itemBeyondSpan":       {"en": "%q is on day %d, past the trip's %d-day span.", "es": "%q está en el día %d, más allá de la duración de %d días del viaje."},
	"review.mayBeClosed":          {"en": "%s may be closed on %s (Day %d).", "es": "%s puede estar cerrado el %s (día %d)."},
	"review.noDates":              {"en": "Add trip dates to unlock day-by-day checks.", "es": "Añade las fechas del viaje para desbloquear las comprobaciones día a día."},
	"review.noLodging":            {"en": "No lodging booked for the night of %s.", "es": "No hay alojamiento reservado para la noche del %s."},
	"review.noLodgingRange":       {"en": "No lodging booked for the nights of %s – %s (%d nights).", "es": "No hay alojamiento reservado para las noches del %s al %s (%d noches)."},
	"review.noTransport":          {"en": "No transport booked from %s to %s.", "es": "No hay transporte reservado de %s a %s."},
	"review.overBudget":           {"en": "Over budget by %.2f %s.", "es": "Te has pasado del presupuesto por %.2f %s."},
	"review.packedDay":            {"en": "Day %d has %d items planned — that may be too packed.", "es": "El día %d tiene %d actividades planificadas — puede que sea demasiado."},
	"review.rainLikely":           {"en": "Rain likely on Day %d (%s) — pack an umbrella.", "es": "Es probable que llueva el día %d (%s) — lleva paraguas."},
	"review.timeOfDayCollision":   {"en": "Day %d has %d things scheduled for the %s.", "es": "El día %d tiene %d cosas programadas para %s."},
	"review.tod.afternoon":        {"en": "afternoon", "es": "la tarde"},
	"review.tod.evening":          {"en": "evening", "es": "la noche"},
	"review.tod.morning":          {"en": "morning", "es": "la mañana"},
	"review.unscheduledMany":      {"en": "%d items have no day assigned — schedule them to see them on the day plan.", "es": "%d actividades no tienen día asignado — prográmalas para verlas en el plan diario."},
	"review.unscheduledOne":       {"en": "1 item has no day assigned — schedule it to see it on the day plan.", "es": "1 actividad no tiene día asignado — prográmala para verla en el plan diario."},
	"review.veryCold":             {"en": "Day %d (%s) could be very cold (%.0f°C) — pack warm layers.", "es": "El día %d (%s) puede hacer mucho frío (%.0f °C) — lleva ropa de abrigo."},
	"review.veryHot":              {"en": "Day %d (%s) could be very hot (%.0f°C) — plan for the heat.", "es": "El día %d (%s) puede hacer mucho calor (%.0f °C) — prepárate para el calor."},

	"share.aTraveler":              {"en": "a traveler", "es": "un viajero"},
	"share.dateWithYear":           {"en": "%s, %d", "es": "%s de %d"},
	"share.plannedBy":              {"en": "Planned by %s", "es": "Planificado por %s"},
	"share.temporarilyUnavailable": {"en": "Temporarily unavailable", "es": "No disponible temporalmente"},
	"share.unavailableBody":        {"en": "The link may have been turned off.", "es": "Puede que el enlace se haya desactivado."},
	"share.unavailableTitle":       {"en": "This trip isn't available", "es": "Este viaje no está disponible"},

	"timeofday.afternoon": {"en": "Afternoon", "es": "Tarde"},
	"timeofday.evening":   {"en": "Evening", "es": "Noche"},
	"timeofday.morning":   {"en": "Morning", "es": "Mañana"},

	"weekday.friday":    {"en": "Friday", "es": "viernes"},
	"weekday.monday":    {"en": "Monday", "es": "lunes"},
	"weekday.saturday":  {"en": "Saturday", "es": "sábado"},
	"weekday.sunday":    {"en": "Sunday", "es": "domingo"},
	"weekday.thursday":  {"en": "Thursday", "es": "jueves"},
	"weekday.tuesday":   {"en": "Tuesday", "es": "martes"},
	"weekday.wednesday": {"en": "Wednesday", "es": "miércoles"},
}

// tr renders a catalog entry in the given locale, falling back to English and
// then to the key itself, so a missing translation degrades to readable text
// rather than a blank. Args are applied with Sprintf when present.
func tr(locale, key string, args ...any) string {
	template, ok := lookupMessage(locale, key)
	if !ok {
		return key
	}
	if len(args) == 0 {
		return template
	}
	return fmt.Sprintf(template, args...)
}

func lookupMessage(locale, key string) (string, bool) {
	entry, ok := messages[key]
	if !ok {
		return "", false
	}
	if template, ok := entry[locale]; ok && template != "" {
		return template, true
	}
	template, ok := entry[defaultLocale]
	return template, ok
}

// Date formatting. Go's time.Format hardcodes English month and weekday names,
// so localized dates need their own tables rather than a layout string.

const (
	dateStyleMonthDay        = "monthDay"        // Jan 2      / 2 ene
	dateStyleWeekdayMonthDay = "weekdayMonthDay" // Mon, Jan 2 / lun, 2 ene
	dateStyleLong            = "long"            // January 2, 2026 / 2 de enero de 2026
)

var esMonthsShort = [...]string{"ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"}

var esMonthsLong = [...]string{
	"enero", "febrero", "marzo", "abril", "mayo", "junio",
	"julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
}

// Indexed by time.Weekday (Sunday = 0).
var esWeekdaysShort = [...]string{"dom", "lun", "mar", "mié", "jue", "vie", "sáb"}

// weekdayKeys maps a time.Weekday to its catalog key. time.Weekday.String() is
// hardcoded English, the same reason localizedDate exists — anything that names
// a day of the week to a user goes through the catalog.
// Indexed by time.Weekday (Sunday = 0).
var weekdayKeys = [...]string{
	"weekday.sunday",
	"weekday.monday",
	"weekday.tuesday",
	"weekday.wednesday",
	"weekday.thursday",
	"weekday.friday",
	"weekday.saturday",
}

// localizedWeekday names a day of the week in the given locale.
func localizedWeekday(locale string, w time.Weekday) string {
	return tr(locale, weekdayKeys[w])
}

// localizedDate renders t in the given style and locale. Spanish uses
// day-before-month ordering, which is why this switches on locale rather than
// swapping a layout string.
func localizedDate(locale string, t time.Time, style string) string {
	if locale != "es" {
		switch style {
		case dateStyleWeekdayMonthDay:
			return t.Format("Mon, Jan 2")
		case dateStyleLong:
			return t.Format("January 2, 2006")
		default:
			return t.Format("Jan 2")
		}
	}
	month := int(t.Month()) - 1
	switch style {
	case dateStyleWeekdayMonthDay:
		return fmt.Sprintf("%s, %d %s", esWeekdaysShort[t.Weekday()], t.Day(), esMonthsShort[month])
	case dateStyleLong:
		return fmt.Sprintf("%d de %s de %d", t.Day(), esMonthsLong[month], t.Year())
	default:
		return fmt.Sprintf("%d %s", t.Day(), esMonthsShort[month])
	}
}
