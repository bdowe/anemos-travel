package main

import (
	"os"
	"strconv"
)

// envInt reads a positive integer from the environment, falling back when the
// variable is unset, non-numeric, or non-positive. The shared knob-reading
// helper for background-checker cadences and abuse/free-cap tuning.
func envInt(name string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return fallback
}
