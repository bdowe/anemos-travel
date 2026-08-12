// Shared money formatting so every quoted price is rendered with its currency
// visible and consistent — no bare "$412" that silently mixes USD/CAD/AUD, and
// no amount printed without the currency it's quoted in.
//
// This is a currency-CODE → SYMBOL map: static and universal (a currency's
// symbol never changes), NOT a country→currency mapping. It exists purely to
// present the `currency` field each priced object already carries.

import 'package:intl/intl.dart';

/// Symbols for the codes our providers (Duffel flights, Ferryhopper)
/// actually return. Deliberately short: a distinct, unambiguous symbol only.
/// Anything not listed falls back to showing the ISO code itself.
const Map<String, String> _currencySymbols = {
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'JPY': '¥',
  'CNY': '¥',
  'AUD': r'A$',
  'CAD': r'C$',
  'NZD': r'NZ$',
  'HKD': r'HK$',
  'SGD': r'S$',
  'MXN': r'MX$',
  'BRL': r'R$',
  'INR': '₹',
  'KRW': '₩',
  'THB': '฿',
  'TRY': '₺',
};

/// Renders [amount] with its [currencyCode] visible: `"€412"` / `"C$412"` when
/// the code maps to a known symbol, else `"USD 412"` (code prefix) so the
/// amount is never shown bare. An empty/whitespace code degrades to just the
/// number. Amounts are rounded to whole units (prices are quoted that way),
/// and a negative amount keeps a leading minus: `"-$5"`.
///
/// Only the digits are localized — grouping separators follow the app's
/// language via Intl.defaultLocale ("1,234" in English, "1.234" in Spanish).
/// Symbol choice stays currency-driven and symbol placement stays prefixed:
/// which symbol a currency uses is a property of the currency, not of the
/// reader's language (specs/i18n-spanish).
String formatMoney(num amount, String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  final negative = amount < 0;
  final sign = negative ? '-' : '';
  final rounded = NumberFormat.decimalPattern().format(amount.abs().round());
  final symbol = _currencySymbols[code];
  if (symbol == null) {
    return code.isEmpty ? '$sign$rounded' : '$sign$code $rounded';
  }
  return '$sign$symbol$rounded';
}
