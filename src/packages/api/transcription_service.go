package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"time"
)

// TranscriptionService transcribes short audio clips via an OpenAI-compatible
// /audio/transcriptions endpoint (Groq by default; OpenAI works by swapping
// TRANSCRIPTION_BASE_URL). It backs the voice-dictation fallback path for
// browsers without built-in speech recognition — see specs/voice-dictation.
// Like Duffel/Ticketmaster, the provider is isolated to this one file so it
// can be swapped without touching the handler or the Flutter app.
type TranscriptionService struct {
	APIKey  string
	BaseURL string
	Model   string
	Client  *http.Client
}

// transcribeMimeExtensions is the allowlist of inbound audio content types,
// mapped to the filename extension the upstream provider keys the container
// format off. MediaRecorder emits audio/webm on Chromium and audio/ogg on
// Firefox; mp4/wav cover native mobile recorders later.
var transcribeMimeExtensions = map[string]string{
	"audio/webm": "webm",
	"audio/ogg":  "ogg",
	"audio/mp4":  "mp4",
	"audio/wav":  "wav",
}

// NewTranscriptionService reads provider config from the environment. A
// missing key is a soft failure (a warning, like Duffel) — the mic still
// works in browsers with built-in speech recognition; only the server
// fallback is disabled.
func NewTranscriptionService() *TranscriptionService {
	key := os.Getenv("TRANSCRIPTION_API_KEY")
	if key == "" {
		fmt.Println("Warning: TRANSCRIPTION_API_KEY not set; voice dictation fallback disabled")
	}

	baseURL := os.Getenv("TRANSCRIPTION_BASE_URL")
	if baseURL == "" {
		baseURL = "https://api.groq.com/openai/v1"
	}
	model := os.Getenv("TRANSCRIPTION_MODEL")
	if model == "" {
		model = "whisper-large-v3-turbo"
	}

	return &TranscriptionService{
		APIKey:  key,
		BaseURL: strings.TrimRight(baseURL, "/"),
		Model:   model,
		Client:  newUpstreamClient(60 * time.Second),
	}
}

// Configured reports whether the provider key is present (drives the
// /transcribe/availability capability check and the 503 degraded mode).
func (t *TranscriptionService) Configured() bool {
	return t.APIKey != ""
}

// Transcribe sends the audio clip upstream as multipart form data and returns
// the transcribed text. mimeType must be one of transcribeMimeExtensions
// (the handler validates before calling).
func (t *TranscriptionService) Transcribe(ctx context.Context, audio []byte, mimeType string) (string, error) {
	if !t.Configured() {
		return "", fmt.Errorf("transcription API key not configured")
	}
	ext, ok := transcribeMimeExtensions[mimeType]
	if !ok {
		return "", fmt.Errorf("unsupported audio type %q", mimeType)
	}

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("file", "audio."+ext)
	if err != nil {
		return "", fmt.Errorf("failed to build multipart body: %w", err)
	}
	if _, err := part.Write(audio); err != nil {
		return "", fmt.Errorf("failed to write audio part: %w", err)
	}
	if err := mw.WriteField("model", t.Model); err != nil {
		return "", fmt.Errorf("failed to write model field: %w", err)
	}
	if err := mw.Close(); err != nil {
		return "", fmt.Errorf("failed to finalize multipart body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.BaseURL+"/audio/transcriptions", &body)
	if err != nil {
		return "", fmt.Errorf("failed to build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+t.APIKey)
	req.Header.Set("Content-Type", mw.FormDataContentType())

	resp, err := t.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("transcription request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("failed to read transcription response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("transcription API returned %d: %s", resp.StatusCode, truncateForLog(respBody))
	}

	var parsed struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", fmt.Errorf("failed to parse transcription response: %w", err)
	}
	return strings.TrimSpace(parsed.Text), nil
}

// truncateForLog keeps upstream error payloads readable in logs.
func truncateForLog(b []byte) string {
	const max = 500
	s := string(b)
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

// transcriptionService is the process-wide singleton, matching the Duffel /
// Ticketmaster convention.
var transcriptionService = NewTranscriptionService()
