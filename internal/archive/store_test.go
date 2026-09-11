package archive

import (
	"path/filepath"
	"testing"
	"time"
)

func TestArchivePersistsAndSearchTracksEditsWithoutDuplicates(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "archive with spaces?#")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	p := Progress{ConversationID: "chat", Since: now.AddDate(-1, 0, 0), State: "in_progress"}
	m := Message{ID: "1", ConversationID: "chat", Timestamp: now, Body: "Original booking", Sender: "Chloé"}
	for range 2 {
		if err = s.PutPage([]Message{m}, p); err != nil {
			t.Fatal(err)
		}
	}
	found, err := s.Search("booking", "", 10)
	if err != nil || len(found) != 1 {
		t.Fatalf("search %v %v", found, err)
	}
	m.Body = "Updated itinerary"
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	found, err = s.Search("booking", "", 10)
	if err != nil || len(found) != 0 {
		t.Fatalf("old text remains indexed: %v %v", found, err)
	}
	found, err = s.Search("chloe itinerary", "chat", 10)
	if err != nil || len(found) != 1 {
		t.Fatalf("offline search %v %v", found, err)
	}
	if !found[0].Timestamp.Equal(now) {
		t.Fatal("microsecond timestamp changed")
	}
	stats, err := s.Stats()
	if err != nil || stats.Messages != 1 {
		t.Fatalf("duplicates: %+v %v", stats, err)
	}
}

func TestSearchTreatsOperatorsAndPunctuationAsLiteralInput(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	m := Message{ID: "1", ConversationID: "chat", Timestamp: time.Now(), Body: `hello "world" OR booking`}
	if err = s.PutPage([]Message{m}, Progress{ConversationID: "chat"}); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{`"world"`, `booking OR missing`, `') ; DROP TABLE messages; --`, `*`, `:`, `AND`, `  `} {
		if _, err = s.Search(query, "", 10); err != nil {
			t.Fatalf("query %q failed: %v", query, err)
		}
	}
	found, err := s.Search("booking OR missing", "", 10)
	if err != nil || len(found) != 0 {
		t.Fatal("FTS operators changed query meaning")
	}
	stats, err := s.Stats()
	if err != nil || stats.Messages != 1 {
		t.Fatalf("unsafe search changed database: %v", err)
	}
}

func TestPageAndCursorRollbackTogether(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	good := Message{ID: "1", ConversationID: "chat", Timestamp: time.Now(), Body: "should roll back"}
	bad := Message{ID: "2", ConversationID: "chat"}
	if err = s.PutPage([]Message{good, bad}, Progress{ConversationID: "chat", Pages: 1}); err == nil {
		t.Fatal("bad page succeeded")
	}
	p, err := s.Progress("chat")
	if err != nil || p.Pages != 0 {
		t.Fatalf("cursor was committed: %+v %v", p, err)
	}
	stats, err := s.Stats()
	if err != nil || stats.Messages != 0 {
		t.Fatal("partial page committed")
	}
}

func TestOverlappingPagePreservesDownloadedMedia(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	m := Message{ID: "1", ConversationID: "chat", Timestamp: time.Now(), Attachments: []Attachment{{ID: "a", MediaID: "remote-a", State: "downloaded_original", Path: "media/a.jpg"}, {ID: "b", MediaID: "remote-b", State: "pending"}}}
	p := Progress{ConversationID: "chat"}
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	m.Attachments[0].State = "pending"
	m.Attachments[0].Path = ""
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	messages, err := s.PendingMedia(time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || len(messages[0].Attachments) != 2 || messages[0].Attachments[0].Path != "media/a.jpg" {
		t.Fatalf("lost original: %+v", messages)
	}
}

func TestSparseHistoryPreservesResolvedOriginal(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	m := Message{ID: "1", ConversationID: "chat", Timestamp: time.Now(), Attachments: []Attachment{{ID: "a", ActionID: "a", MediaID: "original-a", Key: []byte("synthetic-key"), Size: 123, MIME: "image/jpeg", State: "downloaded_original", Path: "media/a.jpg"}}}
	p := Progress{ConversationID: "chat"}
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	m.Attachments = []Attachment{{ID: "a", MIME: "image/unknown", State: "original_unavailable"}}
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	messages, err := s.PendingMedia(time.Unix(0, 0))
	if err != nil || len(messages) != 1 || len(messages[0].Attachments) != 1 {
		t.Fatalf("reading refreshed attachment: %v", err)
	}
	a := messages[0].Attachments[0]
	if a.Path != "media/a.jpg" || a.State != "downloaded_original" || a.MediaID != "original-a" || string(a.Key) != "synthetic-key" || a.Size != 123 || a.MIME != "image/jpeg" || a.ActionID != "a" {
		t.Fatalf("lost resolved original: %+v", a)
	}
	// An explicit replacement must not reuse the old bytes or their key.
	m.Attachments = []Attachment{{ID: "a", MediaID: "replacement-a", MIME: "image/jpeg", State: "pending"}}
	if err = s.PutPage([]Message{m}, p); err != nil {
		t.Fatal(err)
	}
	messages, err = s.PendingMedia(time.Unix(0, 0))
	if err != nil || len(messages) != 1 || len(messages[0].Attachments) != 1 {
		t.Fatalf("reading replacement attachment: %v", err)
	}
	a = messages[0].Attachments[0]
	if a.Path != "" || a.State == "downloaded_original" || len(a.Key) != 0 {
		t.Fatalf("retained stale original: %+v", a)
	}
}

func TestMediaCompletionPreservesLiveEditsAndDoesNotResurrectAttachments(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m := Message{ID: "m", ConversationID: "c", Timestamp: time.Now().UTC(), Body: "initial", Attachments: []Attachment{{ID: "a", MediaID: "remote", MIME: "image/png", State: "pending"}}}
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	downloaded := m
	downloaded.Attachments = append([]Attachment(nil), m.Attachments...)
	downloaded.Attachments[0].State = "downloaded_original"
	downloaded.Attachments[0].Path = "media/saved.png"
	m.Body = "edited"
	m.Reactions = []Reaction{{Emoji: "👍"}}
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	if err = store.UpdateMedia(downloaded); err != nil {
		t.Fatal(err)
	}
	found, err := store.Search("edited", "", 10)
	if err != nil || len(found) != 1 || len(found[0].Reactions) != 1 || found[0].Attachments[0].Path == "" {
		t.Fatal("download overwrote a concurrent edit")
	}
	m.Attachments = nil
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	if err = store.UpdateMedia(downloaded); err != nil {
		t.Fatal(err)
	}
	found, _ = store.Search("edited", "", 10)
	if len(found[0].Attachments) != 0 {
		t.Fatal("download resurrected removed attachment")
	}
}

func TestArrivalJournalIgnoresEditsReplayAndOutgoingMessages(t *testing.T) {
	store, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	m := Message{ID: "incoming", ConversationID: "c", Timestamp: time.Now().UTC(), Status: "INCOMING_COMPLETE", Body: "hello"}
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	m.Body = "edited"
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	m.ID = "outgoing"
	m.Outgoing = true
	m.Status = "OUTGOING_COMPLETE"
	if err = store.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = store.db.QueryRow(`SELECT count(*) FROM arrivals`).Scan(&count); err != nil || count != 1 {
		t.Fatal("duplicate or outgoing arrival", err, count)
	}
}
