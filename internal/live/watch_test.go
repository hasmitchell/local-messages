package live

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"io"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/google"
	"local/GoogleMessagingAppMac/internal/history"
	"strings"
	"testing"
	"time"
)

type fakeSource struct {
	closed   bool
	observer func(any)
}

func (s *fakeSource) Fetch(context.Context, string, json.RawMessage) (history.Page, error) {
	return history.Page{}, nil
}
func (s *fakeSource) Conversations(context.Context, gmproto.ListConversationsRequest_Folder, int) ([]archive.Conversation, error) {
	return nil, nil
}
func (s *fakeSource) Lookup(context.Context, string) (archive.Conversation, bool, error) {
	return archive.Conversation{}, false, nil
}
func (s *fakeSource) Save(context.Context) error { return nil }
func (s *fakeSource) Download(ctx context.Context, _ *archive.Store, _ time.Time, _ string, _ int64) error {
	<-ctx.Done()
	return ctx.Err()
}
func (s *fakeSource) Close() { s.closed = true }

type statusWriter struct {
	bytes.Buffer
	onStatus func(Status)
}

func (w *statusWriter) Write(data []byte) (int, error) {
	var s Status
	if json.Unmarshal(data, &s) == nil && w.onStatus != nil {
		w.onStatus(s)
	}
	return w.Buffer.Write(data)
}
func TestWorkerRetriesAndStopsItsSession(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	calls := 0
	var client *fakeSource
	output := &statusWriter{onStatus: func(s Status) {
		if s.State == "connected" {
			cancel()
		}
	}}
	err = watch(ctx, store, Options{Since: time.Now().AddDate(-1, 0, 0), MaxPages: 100, Media: "photos"}, output, func(_ context.Context, _ string, observe func(any)) (source, error) {
		calls++
		if calls == 1 {
			return nil, errors.New("private body and secret must never reach IPC")
		}
		client = &fakeSource{observer: observe}
		return client, nil
	})
	if err != nil || calls != 2 || client == nil || !client.closed {
		t.Fatal("retry/cancellation did not clean up", err, calls)
	}
	if strings.Contains(output.String(), "secret") || !strings.Contains(output.String(), "reconnecting") || !strings.Contains(output.String(), "stopped") {
		t.Fatal("incorrect or unsafe status stream")
	}
	decoder := json.NewDecoder(strings.NewReader(output.String()))
	for {
		var fields map[string]any
		err := decoder.Decode(&fields)
		if err == io.EOF {
			break
		}
		if err != nil || len(fields) != 2 || fields["state"] == nil || fields["time"] == nil {
			t.Fatal("unexpected IPC fields")
		}
	}
}
func TestWorkerReportsOnlyStatusChanges(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	// The session loop runs every two seconds; this spans at least two passes.
	ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
	defer cancel()
	connected := 0
	output := &statusWriter{onStatus: func(s Status) {
		if s.State == "connected" {
			connected++
		}
	}}
	_ = watch(ctx, store, Options{Since: time.Now().AddDate(-1, 0, 0), MaxPages: 100, Media: "none"}, output, func(_ context.Context, _ string, observe func(any)) (source, error) {
		return &fakeSource{observer: observe}, nil
	})
	if connected != 1 {
		t.Fatalf("connected reported %d times; repeats wake the app for nothing", connected)
	}
}
func TestUnavailablePairingAndLogoutDoNotReconnectForever(t *testing.T) {
	for _, logout := range []bool{false, true} {
		t.Run(map[bool]string{false: "keychain", true: "logged_out"}[logout], func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			var output bytes.Buffer
			calls := 0
			err = watch(context.Background(), store, Options{}, &output, func(_ context.Context, _ string, observe func(any)) (source, error) {
				calls++
				if logout {
					observe(&events.GaiaLoggedOut{})
					return nil, errors.New("signed out")
				}
				return nil, google.ErrPairingUnavailable
			})
			if err != nil || calls != 1 || !strings.Contains(output.String(), "pairing_required") {
				t.Fatal("terminal pairing state was lost")
			}
		})
	}
}

func TestIdentityFailureNeedsPairingWithoutRetrying(t *testing.T) {
	for _, failure := range []error{google.ErrOriginalIdentityMissing, archive.ErrIdentityMismatch} {
		store, err := archive.Open(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		calls := 0
		err = watch(context.Background(), store, Options{}, &output, func(context.Context, string, func(any)) (source, error) { calls++; return nil, failure })
		store.Close()
		if err != nil || calls != 1 || !strings.Contains(output.String(), "pairing_required") {
			t.Fatal("identity failure retried or was not shown")
		}
	}
}
