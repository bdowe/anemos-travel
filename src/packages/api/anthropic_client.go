package main

import (
	"os"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// newAnthropicClient builds the Anthropic client used by the /plan agent and
// the admin local-content ingest. An optional ANTHROPIC_BASE_URL env var
// redirects API traffic — the seam a fake-Anthropic test harness needs (the
// free-cap integration test drives real /plan sessions through it). Unset
// means production behavior, byte-identical to before. The SDK's default
// option chain also reads ANTHROPIC_BASE_URL, but pinning it explicitly here
// keeps the seam independent of SDK-version behavior and documents it at the
// one place clients are constructed.
func newAnthropicClient(apiKey string) anthropic.Client {
	opts := []option.RequestOption{option.WithAPIKey(apiKey)}
	if base := os.Getenv("ANTHROPIC_BASE_URL"); base != "" {
		opts = append(opts, option.WithBaseURL(base))
		// Anthropic-compatible providers (e.g. Moonshot/Kimi at
		// https://api.moonshot.ai/anthropic) may authenticate via
		// `Authorization: Bearer` rather than `x-api-key`, so send the key on
		// both headers. The real Anthropic API rejects requests carrying both,
		// but a set base URL means we are not talking to it; the fake test
		// harness ignores auth entirely.
		opts = append(opts, option.WithAuthToken(apiKey))
	}
	return anthropic.NewClient(opts...)
}

// aiModel / aiModelLight pick the models for every Claude-API call in the
// process. Unset env means the production Anthropic defaults; setting them
// (with ANTHROPIC_BASE_URL) points the whole AI surface at an
// Anthropic-compatible provider, e.g. ANTHROPIC_MODEL=kimi-k3.
//
// aiModel serves the /plan agent loop, trip import, profile distillation, and
// local-content extraction; aiModelLight serves the conversation compactor.
func aiModel() anthropic.Model {
	if m := os.Getenv("ANTHROPIC_MODEL"); m != "" {
		return anthropic.Model(m)
	}
	return anthropic.ModelClaudeSonnet4_6
}

func aiModelLight() anthropic.Model {
	if m := os.Getenv("ANTHROPIC_MODEL_LIGHT"); m != "" {
		return anthropic.Model(m)
	}
	return anthropic.ModelClaudeHaiku4_5
}

// forcedToolThinking is the Thinking param for calls that pin ToolChoice to a
// single tool (compactor, extractor, distiller, importer). Providers whose
// models think by default (kimi-k3) reject forced tool_choice while thinking
// is enabled, so an active model override explicitly disables thinking on
// those calls. With no override the zero value is returned, which the SDK
// omits — the default Anthropic requests stay byte-identical to before.
func forcedToolThinking() anthropic.ThinkingConfigParamUnion {
	if os.Getenv("ANTHROPIC_MODEL") != "" || os.Getenv("ANTHROPIC_MODEL_LIGHT") != "" {
		disabled := anthropic.NewThinkingConfigDisabledParam()
		return anthropic.ThinkingConfigParamUnion{OfDisabled: &disabled}
	}
	return anthropic.ThinkingConfigParamUnion{}
}
