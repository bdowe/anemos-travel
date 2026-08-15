import 'package:json_annotation/json_annotation.dart';

import '../utils/place_links.dart';

part 'hotel_stay.g.dart';

/// One property in the /plan stream's `hotels` SSE event (specs/hotel-search),
/// matching the Go API's HotelStay.
///
/// Both server tiers produce this one shape. What differs is whether the price
/// group is filled — and you must never read that difference off an individual
/// stay. Ask [HotelStayResults.ratesLive] instead: a rates-tier result whose
/// top property happened to lack a rate would otherwise mislabel the set.
@JsonSerializable()
class HotelStay {
  final String name;

  /// 'hotel' or 'vacation_rental'. Not cosmetic — an apartment and a hotel are
  /// different propositions to someone choosing where to sleep.
  @JsonKey(defaultValue: 'hotel')
  final String kind;

  @JsonKey(name: 'star_class')
  final int? starClass;
  final double? rating;
  final int? reviews;

  /// Nightly rate, total for the stay, and the currency all three are in.
  /// Present or absent TOGETHER — this app does no currency conversion
  /// anywhere, so a number without its currency is one nobody can compare.
  @JsonKey(name: 'rate_per_night')
  final double? ratePerNight;
  @JsonKey(name: 'total_rate')
  final double? totalRate;
  final String? currency;

  final double? latitude;
  final double? longitude;
  @JsonKey(defaultValue: '')
  final String address;

  /// An absolute, directly-loadable image URL (rates tier — CORS-open
  /// googleusercontent, not a billed Place Photo).
  @JsonKey(name: 'image_url', defaultValue: '')
  final String imageUrl;

  /// A Google photo reference (discovery tier) that must be exchanged through
  /// the API's own /places/photo gate.
  @JsonKey(name: 'photo_ref', defaultValue: '')
  final String photoRef;

  @JsonKey(name: 'booking_url', defaultValue: '')
  final String bookingUrl;
  @JsonKey(defaultValue: <String>[])
  final List<String> amenities;
  @JsonKey(name: 'check_in_time', defaultValue: '')
  final String checkInTime;
  @JsonKey(name: 'check_out_time', defaultValue: '')
  final String checkOutTime;

  const HotelStay({
    required this.name,
    this.kind = 'hotel',
    this.starClass,
    this.rating,
    this.reviews,
    this.ratePerNight,
    this.totalRate,
    this.currency,
    this.latitude,
    this.longitude,
    this.address = '',
    this.imageUrl = '',
    this.photoRef = '',
    this.bookingUrl = '',
    this.amenities = const [],
    this.checkInTime = '',
    this.checkOutTime = '',
  });

  /// The one image accessor the card uses, so no renderer has to know which
  /// tier a stay came from. The server sets exactly one of the two handles;
  /// an absolute URL loads as-is, a photo ref resolves through the API.
  String? resolvedPhotoUrl(String apiBaseUrl) {
    if (imageUrl.isNotEmpty) return imageUrl;
    if (photoRef.isNotEmpty) return placePhotoUrl(apiBaseUrl, photoRef);
    return null;
  }

  factory HotelStay.fromJson(Map<String, dynamic> json) =>
      _$HotelStayFromJson(json);
  Map<String, dynamic> toJson() => _$HotelStayToJson(this);
}

/// The `hotels` SSE event as a whole. Deliberately one object rather than five
/// parallel fields on PlanState: the values are correlated — a tier without its
/// list, or a list without its dates, is a bug — and holding them together
/// makes the "replaced whole, never mutated" rule true by construction.
class HotelStayResults {
  final String city;
  final String checkIn;
  final String checkOut;
  final List<HotelStay> stays;

  /// Whether these carry live rates. Read this, never "does stay 0 have a
  /// price": it is a property of the lookup, not of any one property in it.
  final bool ratesLive;

  /// Stable reason code when [ratesLive] is false — 'no_dates' | 'quota' |
  /// 'unavailable' | 'not_configured'. Localized client-side.
  final String ratesNote;

  const HotelStayResults({
    required this.city,
    this.checkIn = '',
    this.checkOut = '',
    this.stays = const [],
    this.ratesLive = false,
    this.ratesNote = '',
  });

  factory HotelStayResults.fromEvent(Map<String, dynamic> data) {
    final raw = data['stays'];
    return HotelStayResults(
      city: (data['city'] as String?) ?? '',
      checkIn: (data['check_in'] as String?) ?? '',
      checkOut: (data['check_out'] as String?) ?? '',
      stays: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(HotelStay.fromJson)
              .toList()
          : const [],
      ratesLive: data['rates_live'] == true,
      ratesNote: (data['rates_note'] as String?) ?? '',
    );
  }
}
