package main

import (
	"strings"
	"testing"
)

func TestTruncateForImportPassthrough(t *testing.T) {
	s := strings.Repeat("a", importMaxChars)
	if got := truncateForImport(s); got != s {
		t.Fatal("text at the limit must pass through unchanged")
	}
}

func TestTruncateForImportKeepsHeadAndTail(t *testing.T) {
	head := strings.Repeat("H", importHeadChars)
	middle := strings.Repeat("M", importMaxChars) // guarantees over-limit
	tail := strings.Repeat("T", importMaxChars-importHeadChars)
	got := truncateForImport(head + middle + tail)

	if !strings.HasPrefix(got, head) {
		t.Error("head of the paste must survive truncation")
	}
	if !strings.HasSuffix(got, tail) {
		t.Error("tail of the paste must survive truncation")
	}
	if !strings.Contains(got, "truncated") {
		t.Error("truncation marker missing")
	}
	if strings.Contains(got, "M") {
		t.Error("middle must be cut")
	}
}

// Multi-byte runes at the cut boundaries must never be split — the result has
// to stay valid UTF-8 for the JSON request body.
func TestTruncateForImportRuneSafe(t *testing.T) {
	s := strings.Repeat("é", importMaxChars+1000)
	got := truncateForImport(s)
	if strings.ContainsRune(got, '�') {
		t.Fatal("truncation split a multi-byte rune")
	}
	r := []rune(got)
	if len(r) > importMaxChars+100 { // marker allowance
		t.Fatalf("truncated length = %d runes, want <= %d", len(r), importMaxChars+100)
	}
}

func TestPlausibleCoords(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	cases := []struct {
		name     string
		lat, lng *float64
		want     bool
	}{
		{"both nil", nil, nil, false},
		{"lat only", f(38.7), nil, false},
		{"lat out of range", f(91), f(0.5), false},
		{"lng out of range", f(38.7), f(181), false},
		{"null island filler", f(0), f(0), false},
		{"valid", f(38.7223), f(-9.1393), true},
		{"valid on equator", f(0), f(-9.1), true},
	}
	for _, c := range cases {
		if got := plausibleCoords(c.lat, c.lng); got != c.want {
			t.Errorf("%s: plausibleCoords = %v, want %v", c.name, got, c.want)
		}
	}
}
