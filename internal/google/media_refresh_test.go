package google

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

type mediaHistory struct {
	pages []history.Page
	calls int
}

func (s *mediaHistory) Fetch(_ context.Context, _ string, _ json.RawMessage) (history.Page, error) {
	i := s.calls
	s.calls++
	if i >= len(s.pages) {
		return history.Page{}, fmt.Errorf("unexpected additional fetch")
	}
	return s.pages[i], nil
}

func TestRefreshRecoversStaleReferencesWithoutChangingSnapshot(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Microsecond)
	messages := []archive.Message{{ID: "message", ConversationID: "chat", Timestamp: now, Body: "saved text", Attachments: []archive.Attachment{
		{ID: "missing", MIME: "image/png", State: "original_request_failed"},
		{ID: "saved", MIME: "image/jpeg", MediaID: "original-saved", State: "downloaded_original", Path: "media/saved.jpg"},
		{ID: "audio", MIME: "audio/amr", State: "original_unavailable"},
	}}}
	checkpoint := archive.Progress{ConversationID: "chat", Pages: 7, State: "boundary_reached", Since: now.AddDate(-1, 0, 0)}
	if err := store.PutPage(messages, checkpoint); err != nil {
		t.Fatal(err)
	}
	source := &mediaHistory{pages: []history.Page{
		{Messages: []archive.Message{{ID: "unrelated", ConversationID: "chat", Timestamp: now}}, Cursor: json.RawMessage(`{"next":1}`)},
		{Messages: []archive.Message{{ID: "message", ConversationID: "chat", Timestamp: now, Body: "new remote text", Attachments: []archive.Attachment{
			{ID: "missing", ActionID: "missing", MIME: "image/png", MediaID: "recovered", Key: []byte{1}, Size: 123},
			{ID: "saved", MediaID: "changed-remote", Key: []byte{2}},
			{ID: "audio", MediaID: "audio-original", Key: []byte{3}},
		}}}},
	}}
	count, err := refreshMedia(context.Background(), store, source, messages, "photos", 1<<20)
	if err != nil || count != 1 || source.calls != 2 {
		t.Fatalf("refresh: %d %d %v", count, source.calls, err)
	}
	saved, err := store.PendingMedia(now.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 1 || saved[0].Body != "saved text" {
		t.Fatal("changed the message snapshot")
	}
	a := saved[0].Attachments
	if a[0].MediaID != "recovered" || a[0].State != "pending" || a[0].Size != 123 || len(a[0].Key) != 1 {
		t.Fatal("reference was not persisted")
	}
	if a[1].Path != "media/saved.jpg" || a[1].MediaID != "original-saved" || a[2].MediaID != "" {
		t.Fatal("changed saved original or excluded media")
	}
	p, err := store.Progress("chat")
	if err != nil || p.Pages != 7 || p.State != "boundary_reached" {
		t.Fatal("modified history checkpoint")
	}
}

func TestRefreshStopsAfterFindingMessageWithoutOriginal(t *testing.T) {
	messages := []archive.Message{{ID: "m", ConversationID: "c", Attachments: []archive.Attachment{{ID: "a", MIME: "image/jpeg"}}}}
	source := &mediaHistory{pages: []history.Page{{Messages: []archive.Message{{ID: "m", ConversationID: "c"}}, Cursor: json.RawMessage(`{"next":1}`)}}}
	n, err := refreshMedia(context.Background(), nil, source, messages, "photos", 1024)
	if err != nil || n != 0 || source.calls != 1 {
		t.Fatalf("unnecessary scan: %d %v", source.calls, err)
	}
}

func TestRefreshHonoursBudgetAndMediaFilter(t *testing.T) {
	for _, test := range []struct {
		mode       string
		budget     int64
		attachment archive.Attachment
	}{
		{"photos", 1024, archive.Attachment{MIME: "audio/amr"}},
		{"photos", 0, archive.Attachment{MIME: "image/jpeg"}},
		{"photos", 1024, archive.Attachment{MIME: "image/jpeg", Size: 2048}},
		{"none", 1024, archive.Attachment{MIME: "image/jpeg"}},
	} {
		source := &mediaHistory{}
		_, err := refreshMedia(context.Background(), nil, source, []archive.Message{{ID: "m", ConversationID: "c", Attachments: []archive.Attachment{test.attachment}}}, test.mode, test.budget)
		if err != nil || source.calls != 0 {
			t.Fatal("fetched excluded media")
		}
	}
}
