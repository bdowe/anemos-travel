package main

import (
	"strings"
	"testing"
)

func strPtr(s string) *string { return &s }

func TestNormalizeNotes(t *testing.T) {
	long := strings.Repeat("a", maxProfileNotesLen+50)
	// Multibyte runes: truncation must count runes, not bytes.
	multibyte := strings.Repeat("é", maxProfileNotesLen+1)

	tests := []struct {
		name string
		in   *string
		want *string
	}{
		{"nil keeps existing", nil, nil},
		{"empty clears", strPtr(""), strPtr("")},
		{"whitespace-only clears", strPtr("  \n\t "), strPtr("")},
		{"trims surrounding whitespace", strPtr("  - likes food\n"), strPtr("- likes food")},
		{"under cap unchanged", strPtr("- vegetarian"), strPtr("- vegetarian")},
		{"over cap truncated", strPtr(long), strPtr(long[:maxProfileNotesLen])},
		{"multibyte truncated at rune boundary", strPtr(multibyte), strPtr(strings.Repeat("é", maxProfileNotesLen))},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeNotes(tt.in)
			if (got == nil) != (tt.want == nil) {
				t.Fatalf("normalizeNotes() = %v, want %v", got, tt.want)
			}
			if got != nil && *got != *tt.want {
				t.Fatalf("normalizeNotes() = %q (len %d), want %q (len %d)", *got, len(*got), *tt.want, len(*tt.want))
			}
		})
	}
}

func TestNormalizeWorkStyle(t *testing.T) {
	for _, v := range []string{"digital_nomad", "workation", "leisure_only"} {
		got, err := normalizeChoice(strPtr(v), allowedWorkStyles, "work_style")
		if err != nil || got == nil || *got != v {
			t.Fatalf("normalizeChoice(%q) = %v, %v; want accepted", v, got, err)
		}
	}
	if _, err := normalizeChoice(strPtr("nomad"), allowedWorkStyles, "work_style"); err == nil {
		t.Fatal("normalizeChoice(\"nomad\") should be rejected")
	}
	if got, err := normalizeChoice(nil, allowedWorkStyles, "work_style"); got != nil || err != nil {
		t.Fatalf("normalizeChoice(nil) = %v, %v; want nil, nil (keep existing)", got, err)
	}
}

// specs/active-profile. Each field goes through the same normalizeChoice
// boundary as budget/pace/work_style, so these pin the value sets rather than
// the mechanism.
func TestNormalizeActiveProfileChoices(t *testing.T) {
	cases := []struct {
		field   string
		allowed map[string]bool
		valid   []string
		invalid string
	}{
		{"fitness_routine", allowedFitnessRoutines, []string{"gym", "running", "both", "none"}, "lifting"},
		{"outdoor_intensity", allowedOutdoorIntensities, []string{"easy", "moderate", "challenging"}, "extreme"},
		{"companions", allowedCompanions, []string{"solo", "partner", "friends", "family_with_kids", "varies"}, "family with kids"},
	}
	for _, c := range cases {
		t.Run(c.field, func(t *testing.T) {
			for _, v := range c.valid {
				got, err := normalizeChoice(strPtr(v), c.allowed, c.field)
				if err != nil || got == nil || *got != v {
					t.Fatalf("normalizeChoice(%q) = %v, %v; want accepted", v, got, err)
				}
			}
			// The pre-00062 quiz sent companions as "family with kids"; the
			// column is snake_case, so the old spelling must NOT sneak through.
			if _, err := normalizeChoice(strPtr(c.invalid), c.allowed, c.field); err == nil {
				t.Fatalf("normalizeChoice(%q) should be rejected", c.invalid)
			}
			if got, err := normalizeChoice(nil, c.allowed, c.field); got != nil || err != nil {
				t.Fatalf("normalizeChoice(nil) = %v, %v; want nil, nil (keep existing)", got, err)
			}
			// Empty string means "omit", never "clear" — shared with every
			// other choice field on this profile.
			if got, err := normalizeChoice(strPtr(""), c.allowed, c.field); got != nil || err != nil {
				t.Fatalf("normalizeChoice(\"\") = %v, %v; want nil, nil", got, err)
			}
		})
	}
}
