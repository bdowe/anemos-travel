// Part of the trip detail screen library — see trip_detail_screen.dart.
// Verbatim move (zero behavior change): the members below are the
// bookings tab's rows, lens bodies, and booking actions, lifted out
// of the god-screen so wave 2 can redesign them in isolation.
part of '../../screens/trip_detail_screen.dart';

extension on _TripDetailScreenState {

  /// The one "Booked" writer: flips the todo and (when the slot has one) the
  /// matched confirmed record in lockstep, so every reader of either flag —
  /// checklist rows, calendar/.ics export, print packet — agrees with the
  /// single visible checkbox. Optimistic on all touched lists; any failure
  /// rolls every list back (a partial server success self-heals on the next
  /// toggle or sync).
  Future<void> _setRowBooked(bool booked,
      {BookingTodo? todo, Accommodation? stay, TripSegment? segment}) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final prevTodos = _bookingTodos;
    final prevStays = _stays;
    final prevSegments = _segments;
    _rebuild(() {
      if (todo != null) {
        _bookingTodos = [
          for (final t in _bookingTodos)
            if (t.id == todo.id) t.copyWith(booked: booked) else t,
        ];
      }
      if (stay != null) {
        _stays = [
          for (final a in _stays)
            if (a.id == stay.id) a.copyWith(booked: booked) else a,
        ];
      }
      if (segment != null) {
        _segments = [
          for (final s in _segments)
            if (s.id == segment.id) s.copyWith(booked: booked) else s,
        ];
      }
    });
    try {
      await Future.wait<void>([
        if (todo != null)
          ref
              .read(bookingTodosApiServiceProvider)
              .setBooked(widget.tripId, todo.id, booked),
        if (stay != null)
          ref
              .read(accommodationsApiServiceProvider)
              .update(widget.tripId, stay.id, {'booked': booked}),
        if (segment != null)
          ref
              .read(transportApiServiceProvider)
              .updateSegment(widget.tripId, segment.id, {'booked': booked}),
      ]);
    } catch (e) {
      if (mounted) {
        _rebuild(() {
          _bookingTodos = prevTodos;
          _stays = prevStays;
          _segments = prevSegments;
        });
      }
      _showSnack(l10n.tripUpdateFailed(friendlyError(l10n, e)));
      return;
    }
    // The booked flip IS the Next Step card's advance signal: phase 3 walks
    // the booking slots and phase 5 aggregates them, so both read the flag
    // this call just wrote (specs/next-step-cta). Only after the server
    // accepted it — a rolled-back optimistic flip must not move the card.
    if (mounted) _invalidateReview();

    // Budget autopopulate rides the flip only AFTER the server accepted it
    // (a rolled-back optimistic flip must never create or delete money).
    if (!mounted) return;
    if (booked) {
      await _maybePromptBudgetExpense(todo: todo, stay: stay, segment: segment);
    } else {
      await _removeLinkedAutoExpense([
        if (todo != null) todo.id,
        if (stay != null) stay.id,
        if (segment != null) segment.id,
      ]);
    }
  }


  /// Booked-flip budget autopopulate (specs/budget-v2): right after a
  /// false→true flip lands, offer to record the price — the moment the
  /// traveler actually has it in hand. Dedupe first: a linked expense for
  /// ANY of the flip's row ids (todo + matched stay/segment flip together)
  /// means this booking is already in the budget — a re-book after a manual
  /// takeover stays silent; the server's upsert-by-source is the backstop
  /// when the read fails. The link rides the most durable row
  /// (stay ?? segment ?? todo). Undo on the confirmation snackbar deletes
  /// the expense it just created — the booked state itself stays (the
  /// checkbox is one tap away; Undo here is about the money).
  Future<void> _maybePromptBudgetExpense(
      {BookingTodo? todo, Accommodation? stay, TripSegment? segment}) async {
    if (!mounted || _readOnly) return;
    final l10n = context.l10n;
    var currency = 'USD';
    try {
      currency =
          (await ref.read(budgetProvider(widget.tripId).future)).currency;
    } catch (_) {} // prompt still works; USD is the budget default
    final ids = {
      if (todo != null) todo.id,
      if (stay != null) stay.id,
      if (segment != null) segment.id,
    };
    try {
      final expenses = await ref.read(expensesProvider(widget.tripId).future);
      if (expenses.any((e) => ids.contains(e.sourceId))) return;
    } catch (_) {}
    if (!mounted) return;
    final draft = await showBookedExpensePrompt(
      context,
      currency: currency,
      prefill:
          deriveBookedExpensePrefill(todo: todo, stay: stay, segment: segment),
    );
    if (draft == null || !mounted) return;
    final source = stay != null
        ? (kind: 'accommodation', id: stay.id)
        : segment != null
            ? (kind: 'segment', id: segment.id)
            : (kind: 'booking_todo', id: todo!.id);
    try {
      final added = await ref.read(budgetApiServiceProvider).addExpense(
            widget.tripId,
            category: draft.category,
            label: draft.label,
            amount: draft.amount,
            sourceKind: source.kind,
            sourceId: source.id,
          );
      _invalidateBudget();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(l10n.budgetPromptAdded(formatMoney(draft.amount, currency))),
        action: SnackBarAction(
          label: l10n.tripUndo,
          onPressed: () async {
            try {
              await ref
                  .read(budgetApiServiceProvider)
                  .deleteExpense(widget.tripId, added.id);
              _invalidateBudget();
            } catch (e) {
              _showSnack(l10n.tripUndoFailed(friendlyError(l10n, e)));
            }
          },
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.statusCode == 422) {
        _showSnack(l10n.budgetPromptLimitReached);
      } else {
        _showSnack(friendlyError(l10n, e));
      }
    }
  }


  /// Unbook cleanup: delete the auto (system-managed) expense linked to any
  /// of [ids]. Best-effort — never rolls back a successful unbook; a
  /// taken-over (auto=false) expense is the traveler's and stays
  /// (migration 00061's contract).
  Future<void> _removeLinkedAutoExpense(List<String> ids) async {
    try {
      final expenses = await ref.read(expensesProvider(widget.tripId).future);
      var removed = false;
      for (final e in expenses) {
        if (e.auto && e.sourceId != null && ids.contains(e.sourceId)) {
          await ref
              .read(budgetApiServiceProvider)
              .deleteExpense(widget.tripId, e.id);
          removed = true;
        }
      }
      if (removed) _invalidateBudget();
    } catch (_) {}
  }


  void _invalidateBudget() {
    ref.invalidate(budgetProvider(widget.tripId));
    ref.invalidate(expensesProvider(widget.tripId));
  }


  /// Persists a drag-reorder of the Bookings section's residual "Other" cards.
  /// Optimistic: residual display order derives from _bookingTodos list order
  /// (see _groupedBookings), so move the residual entries to the tail in their
  /// new order — grouped todos are slot-matched by key, so nothing else shifts.
  Future<void> _reorderResidual(
      List<BookingTodo> residual, int oldIndex, int newIndex) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final newOrder = List.of(residual);
    newOrder.insert(newIndex, newOrder.removeAt(oldIndex));
    final residualIds = {for (final t in residual) t.id};
    final prev = _bookingTodos;
    _rebuild(() {
      _bookingTodos = [
        for (final t in _bookingTodos)
          if (!residualIds.contains(t.id)) t,
        ...newOrder,
      ];
    });
    try {
      await ref
          .read(bookingTodosApiServiceProvider)
          .reorderTodos(widget.tripId, [for (final t in newOrder) t.id]);
    } catch (e) {
      if (mounted) _rebuild(() => _bookingTodos = prev);
      _showSnack(l10n.tripReorderFailed(friendlyError(l10n, e)));
    }
  }


  /// The residual booking-todo cards (the Bookings section's "Other"
  /// sub-group): todos that didn't match a city group. City-matched todos
  /// render embedded inside their city groups instead. Only called with a
  /// non-empty [residual] — the section hides the sub-group otherwise.
  Widget _residualBookingsList(List<BookingTodo> residual, ThemeData theme) {
    final l10n = context.l10n;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: residual.length,
      onReorder: (oldIndex, newIndex) =>
          _reorderResidual(residual, oldIndex, newIndex),
      itemBuilder: (context, i) {
        final todo = residual[i];
        // Drag stays on all widths here: for residual custom bookings the
        // handle is the ONLY reorder mechanism (no kebab move entries).
        final canDrag = !_readOnly && !_isOffline && residual.length > 1;
        return Padding(
          key: ValueKey(todo.id),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: BookingTodoCard(
            todo: todo,
            onBookedChanged: (v) => _setRowBooked(v, todo: todo),
            onOpen: _openCallbackFor(todo),
            openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                ? l10n.tripFindFlights
                : null,
            onEdit: todo.auto ? null : () => _editTodo(todo),
            onDelete: todo.auto ? null : () => _deleteTodo(todo),
            dragHandle: canDrag
                ? ReorderableDragStartListener(
                    index: i,
                    child: Icon(
                      Icons.drag_indicator,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }


  /// "Add details…" on an inline booking row: promotes the todo to a
  /// confirmed accommodation/segment via the existing add-sheets, prefilled
  /// from the todo. Confirmed records are what viewers see and what calendar
  /// export, the Tonight caption, and map stay pins read — this is the
  /// one-tap replacement for the retired Suggested-draft "Keep" flow. The
  /// next drafts sync sees the leg covered by a confirmed row and prunes its
  /// shadow draft server-side. Deliberately does NOT mark the todo booked —
  /// booking state stays a separate, explicit action.
  Future<void> _addDetailsFromTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    if (todo.kind == 'stay') {
      final body = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => AddStaySheet(
          initialName: todo.title,
          initialCheckIn: todo.departDate,
          initialCheckOut: todo.returnDate,
        ),
      );
      if (body == null) return;
      try {
        await ref
            .read(accommodationsApiServiceProvider)
            .add(widget.tripId, body);
        await _load();
      } catch (e) {
        _showSnack(l10n.tripAddStayFailed(friendlyError(l10n, e)));
      }
      return;
    }
    // Transport: the todo model carries no origin/destination fields, but
    // _deriveTodos always titles a leg 'A → B' — split it back apart. Mode
    // prefers the row's per-leg override, else follows the provider the leg
    // was derived with.
    final parts = todo.title.split(' → ');
    final trip = _trip;
    // Set by the "Change airport" link, which closes this sheet; the airports
    // sheet opens after the await rather than from the callback, so the two
    // modals never overlap.
    var changeAirport = false;
    // Prefill what the app actually KNOWS, not the wire's best-effort search
    // seed. On a leg with no recorded flight the departure opens BLANK rather
    // than pre-filled with the arrival day, so the sheet never asks the
    // traveler to confirm a departure date the app invented. A row with no
    // entry here (a custom or agent-added one) keeps the stored value.
    final known = _legDates[todo.todoKey];
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AddSegmentSheet(
        initialOrigin: parts.isNotEmpty ? parts.first : null,
        initialDestination: parts.length > 1 ? parts[1] : null,
        initialMode: todo.mode ??
            switch (todo.provider) {
              'ferry' => 'ferry',
              'rome2rio' => trip == null ? null : _TripDetailScreenState._groundModeOf(trip),
              _ => 'flight',
            },
        initialDepartDate: known == null
            ? todo.departDate
            : (known.depart == null ? null : _fmt(known.depart!)),
        initialArriveDate: known?.arrive == null ? null : _fmt(known!.arrive!),
        // A derived leg's endpoints are the trip's (its airports) or the
        // itinerary's (its cities) — this form's job is the booking detail.
        // Typing over them here used to post a second row that contradicted
        // the one above it.
        endpointsLocked: todo.auto,
        onChangeAirport: todo.auto && todo.isHomeLeg && !_readOnly
            ? () {
                changeAirport = true;
                Navigator.of(sheetContext).pop();
              }
            : null,
      ),
    );
    if (changeAirport) {
      await _openTripAirports();
      return;
    }
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .addSegment(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddTransportFailed(friendlyError(l10n, e)));
    }
  }


  /// Opens the trip's own departure/return airports (specs/trip-endpoint-
  /// airports) and saves what comes back. The server renames the two derived
  /// legs in the same transaction — in place, so their booked state, per-leg
  /// mode and any linked expense survive — which is why this reloads the trip
  /// rather than patching a title locally.
  ///
  /// This exists because the page had no such control: the only affordance on
  /// a derived "EWR → Amsterdam" row was "Add details…", which posts a segment,
  /// so correcting the airport there produced a second, contradicting row.
  Future<void> _openTripAirports() async {
    if (_guardOffline()) return;
    final trip = _trip;
    if (trip == null) return;
    final l10n = context.l10n;
    // What the legs read today when the trip states no airport of its own —
    // shown as context, never seeded into the fields, so opening the sheet and
    // pressing Save can't quietly promote a fallback into a fixed choice.
    final fallback = (trip.origin?.trim().isNotEmpty ?? false)
        ? trip.origin!.trim()
        : _homeAirport;
    final choice = await showModalBottomSheet<TripAirportsChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TripAirportsSheet(
        originAirport: trip.originAirport,
        returnAirport: trip.returnAirport,
        fallbackLabel: fallback,
      ),
    );
    if (choice == null) return;
    try {
      final result = await ref.read(tripsApiServiceProvider).updateTripEndpoints(
            widget.tripId,
            originAirport: choice.originAirport,
            returnAirport: choice.returnAirport,
          );
      await _load();
      if (!mounted) return;
      _showSnack(l10n.tripAirportsSaved(result.legsRenamed.length));
    } on TripEndpointsException catch (e) {
      // The 422s are written for travelers and name what went wrong — an
      // airport that matches nothing, or a trip that plainly travels by car.
      // Flattening them into "something went wrong" throws away the answer.
      _showSnack(e.statusCode == 422 && e.message.isNotEmpty
          ? e.message
          : l10n.tripAirportsFailed(friendlyError(l10n, e)));
    } catch (e) {
      _showSnack(l10n.tripAirportsFailed(friendlyError(l10n, e)));
    }
  }


  /// The per-leg mode writer: PATCHes the transport row's override (the
  /// server stores it and rebuilds the row's provider + search link to
  /// match), then re-derives the checklist so [_flightLegs]/[_ferryLegs] and
  /// the row's open action agree with the new mode. Origin/destination come
  /// from the derived 'A → B' title, exactly like [_addDetailsFromTodo].
  Future<void> _setRowMode(BookingTodo todo, String mode) async {
    if (_guardOffline()) return;
    if (mode == todo.mode) return;
    final l10n = context.l10n;
    final parts = todo.title.split(' → ');
    if (parts.length < 2) return;
    try {
      final updated = await ref.read(bookingTodosApiServiceProvider).setMode(
            widget.tripId,
            todo.id,
            mode: mode,
            origin: parts.first,
            destination: parts[1],
            departDate: todo.departDate,
          );
      if (!mounted) return;
      _rebuild(() => _bookingTodos = [
            for (final t in _bookingTodos) t.id == updated.id ? updated : t
          ]);
      // A walk-derived Next Step reads this row's mode for its copy and its
      // action label (specs/next-step-cta), and the sync below only
      // invalidates when the DERIVED set changed — which a mode-only edit
      // does not. Re-read the review explicitly so card and row agree.
      _invalidateReview();
      final trip = _trip;
      if (trip != null) await _syncBookingTodos(trip);
    } catch (e) {
      _showSnack(l10n.tripUpdateFailed(friendlyError(l10n, e)));
    }
  }


  Future<void> _deleteTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(bookingTodosApiServiceProvider)
          .delete(widget.tripId, todo.id);
      if (mounted) {
        _rebuild(() => _bookingTodos =
            _bookingTodos.where((t) => t.id != todo.id).toList());
      }
    } catch (e) {
      _showSnack(l10n.tripDeleteFailed(friendlyError(l10n, e)));
    }
  }


  Future<void> _addBooking() async {
    if (_guardOffline()) return;
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddBookingTodoDialog(
        tripId: widget.tripId,
        groundMode: _trip == null ? null : _TripDetailScreenState._groundModeOf(_trip!),
      ),
    );
    if (added == true) await _load();
  }


  Future<void> _editTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _AddBookingTodoDialog(tripId: widget.tripId, existing: todo),
    );
    if (changed == true) await _load();
  }


  Future<void> _addStay() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const AddStaySheet(),
    );
    if (body == null) return;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .add(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddStayFailed(friendlyError(l10n, e)));
    }
  }


  Future<void> _deleteStay(Accommodation a) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .delete(widget.tripId, a.id);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripRemoveStayFailed(friendlyError(l10n, e)));
    }
  }


  /// Opens the stay sheet prefilled; a save PATCHes the row, which also
  /// confirms it if it was a Suggested draft.
  Future<void> _editStay(Accommodation a) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddStaySheet(initial: a),
    );
    if (body == null) return;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .update(widget.tripId, a.id, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripUpdateStayFailed(friendlyError(l10n, e)));
    }
  }


  Future<void> _addSegment() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    // A stated travel mode prefills the form ('mixed' doesn't pick a side).
    final tm = _trip?.travelMode;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddSegmentSheet(initialMode: tm == 'mixed' ? null : tm),
    );
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .addSegment(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddTransportFailed(friendlyError(l10n, e)));
    }
  }


  Future<void> _deleteSegment(TripSegment s) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(transportApiServiceProvider)
          .deleteSegment(widget.tripId, s.id);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripRemoveTransportFailed(friendlyError(l10n, e)));
    }
  }


  /// Opens the transport sheet prefilled; a save PATCHes the row, which also
  /// confirms it if it was a Suggested draft.
  Future<void> _editSegment(TripSegment s) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddSegmentSheet(initial: s),
    );
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .updateSegment(widget.tripId, s.id, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripUpdateTransportFailed(friendlyError(l10n, e)));
    }
  }


  /// The saved-details line under a slot's todo row (or standalone when the
  /// slot has no todo — viewers get none from the server). Carries the
  /// confirmed record's edit/delete/calendar affordances; the checkbox shows
  /// only in detail-only mode, where there's no todo row above to drive it.
  Widget _detailRowFor({Accommodation? stay, TripSegment? segment,
      required bool detailOnly}) {
    final editable = !_readOnly && !_isOffline;
    if (stay != null) {
      return BookingDetailRow.stay(
        tripId: widget.tripId,
        stay: stay,
        onEdit: editable ? () => _editStay(stay) : null,
        onDelete: editable ? () => _deleteStay(stay) : null,
        showCheckbox: detailOnly,
        onBookedChanged:
            detailOnly && !_readOnly ? (v) => _setRowBooked(v, stay: stay) : null,
        appleCalendarEnabled: !_readOnly && !_isOffline,
      );
    }
    final s = segment!;
    return BookingDetailRow.segment(
      tripId: widget.tripId,
      segment: s,
      onEdit: editable ? () => _editSegment(s) : null,
      onDelete: editable ? () => _deleteSegment(s) : null,
      showCheckbox: detailOnly,
      onBookedChanged:
          detailOnly && !_readOnly ? (v) => _setRowBooked(v, segment: s) : null,
      appleCalendarEnabled: !_readOnly && !_isOffline,
    );
  }


  /// Compact booking rows for a city group's slot: arrival flight + stay when
  /// [departureOnly] is false, the return-home flight when true. Each todo
  /// row is followed by its matched confirmed record's details; a match
  /// without a todo (viewers) renders as a standalone detail row.
  /// [unbookedOnly] keeps only rows whose visible checkbox is unchecked — the
  /// "Not booked yet" lens.
  ///
  /// The slot's entries and their checkbox state both come from the
  /// derivation ([bookingSlotEntries] / [bookingEntryBooked]) rather than
  /// being spelled out here, because the filter-strip counts iterate the same
  /// two functions: a chip's count and the rows it reveals cannot disagree
  /// about what a slot holds or about what "booked" means.
  List<Widget> _bookingRowWidgets(
    BookingSlot slot, {
    required bool departureOnly,
    bool unbookedOnly = false,
  }) {
    final l10n = context.l10n;
    var entries = bookingSlotEntries(slot, departureOnly: departureOnly);
    if (unbookedOnly) {
      entries = entries.where((e) => !bookingEntryBooked(e)).toList();
    }
    return [
      for (final e in entries) ...[
        if (e.todo case final todo?)
          BookingTodoRow(
            todo: todo,
            tripTravelMode: _trip?.travelMode,
            compact: _narrow,
            onBookedChanged: (v) => _setRowBooked(v,
                todo: todo, stay: e.stay, segment: e.segment),
            onOpen: _openCallbackFor(todo),
            openLabelOverride: _ferryLegs.containsKey(todo.todoKey)
                ? (_narrow ? l10n.tripFindFerriesShort : l10n.tripFindFerries)
                : _flightLegs.containsKey(todo.todoKey)
                    ? (_narrow
                        ? l10n.tripFindFlightsShort
                        : l10n.tripFindFlights)
                    : null,
            // No "Add details…" once a confirmed segment fills the slot —
            // the same rule as the mode picker below: that row's truth is the
            // segment, edited via its own sheet. Without this the sheet would
            // open pre-filled with the segment's own dates and Save would
            // create a SECOND segment for the same leg. (Locking the sheet's
            // endpoints stops a segment that CONTRADICTS the row; this stops a
            // duplicate of it — the two guards cover different halves.)
            onAddDetails: (_readOnly ||
                    _isOffline ||
                    todo.kind == 'other' ||
                    e.segment != null)
                ? null
                : () => _addDetailsFromTodo(todo),
            // Only the two journey endpoints: those are the rows the trip's
            // own airports title, so they are the only ones this moves. The
            // role comes from the server, which stores it as identity —
            // guessing it here would be wrong on a row it demoted.
            onChangeAirport: (_readOnly || _isOffline || !todo.isHomeLeg)
                ? null
                : () => _openTripAirports(),
            // No picker when a confirmed segment fills the slot — that row's
            // mode truth is the segment, edited via its own sheet.
            onModeChanged: (_readOnly ||
                    _isOffline ||
                    e.segment != null ||
                    todo.kind != 'transport')
                ? null
                : (m) => _setRowMode(todo, m),
          ),
        if (e.stay != null || e.segment != null)
          _detailRowFor(
              stay: e.stay, segment: e.segment, detailOnly: e.todo == null),
      ],
    ];
  }


  /// Flat "left to book" rows for the 'unbooked' lens: every city slot's
  /// unbooked rows in trip order, then the residual todos and detail-only
  /// records that matched no city. Reuses the same row widgets (and the
  /// _setRowBooked writer) as the inline city view, so checking a box here
  /// behaves identically and the row leaves the lens on the rebuild.
  ///
  /// [destination] narrows to one leg label exactly as [_allBookingRows] does
  /// — the destination strip renders in BOTH scopes, so a chosen city has to
  /// mean the same thing in both. Same discipline too: this filters the OUTPUT
  /// of the one full-label partition, never a re-partition on a label subset.
  List<Widget> _unbookedRows(
    GroupedBookings grouped,
    List<String> labels, {
    String? destination,
  }) {
    final l10n = context.l10n;
    bool slotShown(int i) =>
        destination == null ||
        (i < labels.length && labels[i] == destination);
    final showResiduals =
        destination == null || destination == _kOtherPlaces;
    return [
      for (final (i, slot) in grouped.slots.indexed)
        if (slotShown(i)) ...[
          ..._bookingRowWidgets(slot, departureOnly: false, unbookedOnly: true),
          if (i == grouped.slots.length - 1)
            ..._bookingRowWidgets(slot,
                departureOnly: true, unbookedOnly: true),
        ],
      if (showResiduals) ...[
        for (final todo in grouped.residual.where((t) => !t.booked))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: BookingTodoCard(
              todo: todo,
              onBookedChanged: (v) => _setRowBooked(v, todo: todo),
              onOpen: _openCallbackFor(todo),
              openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                  ? l10n.tripFindFlights
                  : null,
              onEdit: todo.auto ? null : () => _editTodo(todo),
              onDelete: todo.auto ? null : () => _deleteTodo(todo),
            ),
          ),
        for (final a in grouped.residualStays.where((a) => !a.booked))
          _detailRowFor(stay: a, segment: null, detailOnly: true),
        for (final s in grouped.residualSegments.where((s) => !s.booked))
          _detailRowFor(stay: null, segment: s, detailOnly: true),
      ],
    ];
  }


  /// The 'bookings' lens rows: every city slot's rows — booked and unbooked —
  /// in trip order, then the residual todos and detail-only records that
  /// matched no city. Reuses the same row widgets (and the _setRowBooked
  /// writer) as the inline city view, so checking a box here behaves
  /// identically; the row stays put, struck through.
  ///
  /// [destination] narrows to one leg label (null = all): slot i is included
  /// when labels[i] matches; residuals only under All or the 'Other places'
  /// chip (they matched no destination by definition). This filters the
  /// OUTPUT of the one full-label groupedBookings partition — never re-run
  /// the partition on a label subset: its claim-once matching is
  /// order-dependent, so a subset call would assign rows differently than
  /// the inline city view (docs/zen.md).
  List<Widget> _allBookingRows(
    GroupedBookings grouped,
    List<String> labels, {
    String? destination,
  }) {
    final l10n = context.l10n;
    bool slotShown(int i) =>
        destination == null ||
        (i < labels.length && labels[i] == destination);
    final showResiduals =
        destination == null || destination == _kOtherPlaces;
    return [
      for (final (i, slot) in grouped.slots.indexed)
        if (slotShown(i)) ...[
          ..._bookingRowWidgets(slot, departureOnly: false),
          if (i == grouped.slots.length - 1)
            ..._bookingRowWidgets(slot, departureOnly: true),
        ],
      if (showResiduals) ...[
        for (final todo in grouped.residual)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: BookingTodoCard(
              todo: todo,
              onBookedChanged: (v) => _setRowBooked(v, todo: todo),
              onOpen: _openCallbackFor(todo),
              openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                  ? l10n.tripFindFlights
                  : null,
              onEdit: todo.auto ? null : () => _editTodo(todo),
              onDelete: todo.auto ? null : () => _deleteTodo(todo),
            ),
          ),
        for (final a in grouped.residualStays)
          _detailRowFor(stay: a, segment: null, detailOnly: true),
        for (final s in grouped.residualSegments)
          _detailRowFor(stay: null, segment: s, detailOnly: true),
      ],
    ];
  }


  /// Chips for the Bookings destination filter: the leg labels deduped in trip
  /// order (a revisited city gets ONE chip covering both its runs — chips
  /// select by label equality, and run-suffixed chips would leak the internal
  /// `#2` key grammar), plus the canonical 'Other places' value when residual
  /// bookings exist and no real 'Other places' leg already supplied it. Each
  /// carries its own booked count from [bookingDestinationCounts].
  ///
  /// A stale selection (leg labels change when the itinerary is edited) is
  /// clamped HERE rather than in either view body, because both scopes render
  /// the strip and both need the same clamp before they filter their rows.
  /// We're already in build, so this frame renders the clamped value (the
  /// _focusedLegKey clamp idiom).
  List<BookingDestination> _bookingsLensDestinations(
    GroupedBookings grouped,
    List<String> labels,
  ) {
    final l10n = context.l10n;
    final hasResiduals = grouped.residual.isNotEmpty ||
        grouped.residualStays.isNotEmpty ||
        grouped.residualSegments.isNotEmpty;
    final values = <String>[];
    for (final l in labels) {
      if (!values.contains(l)) values.add(l);
    }
    if (hasResiduals && !values.contains(_kOtherPlaces)) {
      values.add(_kOtherPlaces);
    }
    if (_bookingsLensDestination != null &&
        !values.contains(_bookingsLensDestination)) {
      _bookingsLensDestination = null;
    }
    final counts =
        bookingDestinationCounts(grouped, labels, otherKey: _kOtherPlaces);
    return [
      for (final v in values)
        (
          value: v,
          label: v == _kOtherPlaces ? l10n.tripOtherBookings : v,
          booked: counts[v]?.booked ?? 0,
          total: counts[v]?.total ?? 0,
        ),
    ];
  }


  /// The Bookings view's one filter row — scope chip + destination strip —
  /// rendered by BOTH scopes so toggling "Not booked yet" doesn't change the
  /// shape of the chrome above the rows. The destination deliberately SURVIVES
  /// that toggle: it is a different question ("where"), and clearing it would
  /// silently widen what the traveler is looking at.
  Widget _bookingsFilterBar(List<BookingDestination> destinations) =>
      BookingFilterBar(
        unbookedOnly: _itemFilter == 'unbooked',
        onUnbookedOnlyChanged: (v) =>
            _rebuild(() => _itemFilter = v ? 'unbooked' : 'bookings'),
        destinations: destinations,
        selected: _bookingsLensDestination,
        onSelected: (v) => _rebuild(() => _bookingsLensDestination = v),
      );


  /// The 'unbooked' scope body: the same filter row as the all-bookings lens
  /// above the flat left-to-book list. Never returns [] — the filter row is
  /// the way out of an empty state, so it renders above both arms.
  ///
  /// The two empty arms say different true things. With no destination
  /// chosen, an empty list means the TRIP is fully booked (the celebration).
  /// With one chosen it means only that city is, so it gets its own line —
  /// the trip-wide copy would be a claim this list cannot support.
  List<Widget> _unbookedViewBody(
    GroupedBookings grouped,
    List<String> labels,
  ) {
    final l10n = context.l10n;
    final destinations = _bookingsLensDestinations(grouped, labels);
    final rows = _unbookedRows(grouped, labels,
        destination: _bookingsLensDestination);
    return [
      _bookingsFilterBar(destinations),
      if (rows.isEmpty && _bookingsLensDestination == null)
        SizedBox(
          height: 260,
          child: EmptyState(
            icon: Icons.celebration_outlined,
            title: l10n.tripFilterAllBooked,
            message: l10n.tripFilterAllBookedMessage,
          ),
        )
      else if (rows.isEmpty)
        SizedBox(
          height: 120,
          child: EmptyState(
            icon: Icons.celebration_outlined,
            title: l10n.tripBookingsAllBookedForDestination,
            compact: true,
          ),
        )
      else
        ...rows,
    ];
  }


  /// The 'bookings' lens body: the filter row above the flat all-bookings
  /// list. Returns [] when the trip has no bookings at all so build can swap
  /// in the lens empty state.
  List<Widget> _bookingsLensBody(
    GroupedBookings grouped,
    List<String> labels,
  ) {
    final l10n = context.l10n;
    final all = _allBookingRows(grouped, labels);
    if (all.isEmpty) return const [];
    // Builds the chips AND clamps a stale selection — so it runs before the
    // rows below are filtered by that selection.
    final destinations = _bookingsLensDestinations(grouped, labels);
    final rows = _bookingsLensDestination == null
        ? all
        : _allBookingRows(grouped, labels,
            destination: _bookingsLensDestination);
    return [
      _bookingsFilterBar(destinations),
      if (rows.isEmpty)
        SizedBox(
          height: 120,
          child: EmptyState(
            icon: Icons.search_off,
            title: l10n.tripBookingsLensNoneForDestination,
            compact: true,
          ),
        )
      else
        ...rows,
    ];
  }


  /// "+ Add booking" — the Bookings view's one add CTA (its "Add place").
  /// A single menu fans out to the three record kinds so the itinerary tail
  /// no longer needs a button trio. One MenuAnchor for both widths; only the
  /// anchor swaps (labeled wide, icon-only narrow — same precedent and
  /// reason as Add place below). Offline disables the anchor; each handler
  /// re-guards via _guardOffline() for a menu left open across the flip.
  Widget _addBookingMenu() {
    final l10n = context.l10n;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.hotel_outlined, size: 18),
          onPressed: _addStay,
          child: Text(l10n.bookingsMenuStay),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.route_outlined, size: 18),
          onPressed: _addSegment,
          child: Text(l10n.bookingsMenuTransport),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.check_circle_outline, size: 18),
          onPressed: _addBooking,
          child: Text(l10n.bookingsMenuOther),
        ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        return _narrow
            ? IconButton(
                onPressed: _isOffline ? null : toggle,
                tooltip: l10n.bookingsAddBooking,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add, size: 20),
              )
            : TextButton.icon(
                onPressed: _isOffline ? null : toggle,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.bookingsAddBooking),
              );
      },
    );
  }


  /// The itinerary's trailing "Other bookings" area — the home for
  /// everything the retired Bookings section held that has no city slot:
  /// residual todos (custom bookings, stale autos) and confirmed records
  /// that matched no city. Content-only — the add actions live in the
  /// Bookings view's header button (_addBookingMenu).
  Widget? _otherBookingsArea(
      ThemeData theme,
      ({
        List<BookingTodo> residual,
        List<Accommodation> residualStays,
        List<TripSegment> residualSegments,
      }) other) {
    final l10n = context.l10n;
    final hasContent = other.residual.isNotEmpty ||
        other.residualStays.isNotEmpty ||
        other.residualSegments.isNotEmpty;
    if (!hasContent) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding:
              const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
          child: Text(
            l10n.tripOtherBookings,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (other.residual.isNotEmpty)
          _residualBookingsList(other.residual, theme),
        for (final a in other.residualStays)
          _detailRowFor(stay: a, segment: null, detailOnly: true),
        for (final s in other.residualSegments)
          _detailRowFor(stay: null, segment: s, detailOnly: true),
      ],
    );
  }

}

/// Adds or edits a custom booking TODO. A destination (and optional dates)
/// lets the server build the search link; a pasted link overrides it.
class _AddBookingTodoDialog extends ConsumerStatefulWidget {
  final String tripId;

  /// When set, the dialog edits this todo (PATCH) instead of adding one.
  /// Destination/origin aren't persisted server-side, so they open blank:
  /// re-entering a destination makes the server rebuild the search link,
  /// otherwise the existing link is kept.
  final BookingTodo? existing;

  /// The trip's stated non-flight travel mode ('car'|'train'|'bus'|'ferry'):
  /// new transport todos then prefer the Rome2Rio link over Google Flights.
  final String? groundMode;

  const _AddBookingTodoDialog(
      {required this.tripId, this.existing, this.groundMode});

  @override
  ConsumerState<_AddBookingTodoDialog> createState() =>
      _AddBookingTodoDialogState();
}


class _AddBookingTodoDialogState extends ConsumerState<_AddBookingTodoDialog> {
  String _kind = 'stay';
  final _title = TextEditingController();
  final _destination = TextEditingController();
  final _origin = TextEditingController();
  DateTime? _departDate;
  DateTime? _returnDate;
  final _url = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _kind = e.kind;
      _title.text = e.title;
      _url.text = e.searchUrl ?? '';
      _departDate = DateTime.tryParse(e.departDate ?? '');
      _returnDate = DateTime.tryParse(e.returnDate ?? '');
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _destination.dispose();
    _origin.dispose();
    _url.dispose();
    super.dispose();
  }

  String? _nn(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate(bool isDepart) async {
    final now = DateTime.now();
    final first = now.subtract(const Duration(days: 365));
    final last = now.add(const Duration(days: 365 * 2));
    var initial = (isDepart ? _departDate : _returnDate) ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) {
      setState(() => isDepart ? _departDate = picked : _returnDate = picked);
    }
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = l10n.tripTitleRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final isTransport = _kind == 'transport';
      final isEdit = widget.existing != null;
      // Note: PATCH is a COALESCE partial update, so an omitted date can't
      // clear a previously saved one — it just keeps the old value.
      final body = <String, dynamic>{
        'kind': _kind,
        'title': _title.text.trim(),
        if (_nn(_destination.text) != null)
          'destination': _nn(_destination.text),
        if (isTransport && _nn(_origin.text) != null)
          'origin': _nn(_origin.text),
        if (_departDate != null) 'depart_date': _fmt(_departDate!),
        if (!isTransport && _returnDate != null)
          'return_date': _fmt(_returnDate!),
        // On edit the field is prefilled with the stored link; sending it
        // back unchanged would override a destination-driven rebuild (an
        // explicit search_url wins server-side), so omit it unless the user
        // actually changed it — COALESCE keeps the stored one.
        if (_nn(_url.text) != null &&
            (!isEdit || _nn(_url.text) != widget.existing!.searchUrl))
          'search_url': _nn(_url.text),
        // The provider is only a preference for the server's link builder; on
        // edit, sending it without a destination would overwrite the stored
        // provider while the old link stays — so only send it when a link is
        // (re)built from a destination.
        if (!isEdit || _nn(_destination.text) != null) ...{
          if (_kind == 'stay') 'provider': 'airbnb',
          if (isTransport)
            'provider':
                widget.groundMode != null ? 'rome2rio' : 'google_flights',
        },
        'guests': 1,
        'passengers': 1,
      };
      final svc = ref.read(bookingTodosApiServiceProvider);
      if (isEdit) {
        await svc.update(widget.tripId, widget.existing!.id, body);
      } else {
        await svc.addTodo(widget.tripId, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = l10n.tripSaveFailed(friendlyError(l10n, e));
      });
    }
  }

  /// A picker-backed date row: tap to pick, with a clear button when set
  /// (both dates are optional).
  Widget _dateField(String label, bool isDepart) {
    final value = isDepart ? _departDate : _returnDate;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(value == null ? label : '$label: ${_fmt(value)}'),
            ),
            onPressed: () => _pickDate(isDepart),
          ),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: context.l10n.tripClearDate,
            onPressed: () => setState(() =>
                isDepart ? _departDate = null : _returnDate = null),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isTransport = _kind == 'transport';
    return AlertDialog(
      title: Text(widget.existing == null
          ? l10n.tripAddBooking
          : l10n.tripEditBooking),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.tripFieldType),
              items: [
                DropdownMenuItem(
                    value: 'stay', child: Text(l10n.tripKindStay)),
                DropdownMenuItem(
                    value: 'transport', child: Text(l10n.tripKindTransport)),
                DropdownMenuItem(
                    value: 'other', child: Text(l10n.tripKindOther)),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'stay'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _title,
                decoration: InputDecoration(labelText: l10n.tripFieldTitle)),
            const SizedBox(height: AppSpacing.md),
            if (isTransport) ...[
              TextField(
                  controller: _origin,
                  decoration:
                      InputDecoration(labelText: l10n.tripFieldOrigin)),
              const SizedBox(height: AppSpacing.md),
            ],
            TextField(
                controller: _destination,
                decoration:
                    InputDecoration(labelText: l10n.tripFieldDestination)),
            const SizedBox(height: AppSpacing.md),
            _dateField(
                isTransport
                    ? l10n.tripFieldDepartDate
                    : l10n.tripFieldCheckIn,
                true),
            if (!isTransport) ...[
              const SizedBox(height: AppSpacing.sm),
              _dateField(l10n.tripFieldCheckOut, false),
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _url,
                decoration: InputDecoration(labelText: l10n.tripFieldLink)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.commonSave),
        ),
      ],
    );
  }
}
