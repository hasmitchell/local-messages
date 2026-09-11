package live

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
)

type avatarFake struct {
	fakeSource
	requests [][]string
	photos   map[string][]byte
}

func (f *avatarFake) ParticipantThumbnails(_ context.Context, ids []string) (map[string][]byte, error) {
	f.requests = append(f.requests, append([]string(nil), ids...))
	return f.photos, nil
}

func TestRefreshAvatarsSavesContactPhotosOnce(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	conv := archive.Conversation{ID: "c1", Name: "Alex", Folder: "INBOX", LastMessage: time.Now(), Participants: []archive.Participant{
		{ID: "p-alex", Name: "Alex", Number: "+61400000001", ContactID: "contact-1"},
		{ID: "p-unknown", Name: "", Number: "+61400000009"},
		{ID: "p-me", Name: "Me", IsMe: true, ContactID: "contact-me"},
	}}
	if err := store.PutConversation(conv); err != nil {
		t.Fatal(err)
	}
	jpeg := append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, []byte("synthetic")...)
	src := &avatarFake{photos: map[string][]byte{"p-alex": jpeg}}
	if err := refreshAvatars(context.Background(), store, src, avatarBatchLimit); err != nil {
		t.Fatal(err)
	}
	if len(src.requests) != 1 || len(src.requests[0]) != 1 || src.requests[0][0] != "p-alex" {
		t.Fatalf("expected one lookup for the contact-linked participant only, got %v", src.requests)
	}
	records, err := store.Avatars()
	if err != nil {
		t.Fatal(err)
	}
	record := records["p-alex"]
	if record.Path == "" || filepath.Dir(record.Path) != filepath.Join("media", "avatars") || filepath.Ext(record.Path) != ".jpg" {
		t.Fatalf("unexpected avatar path %q", record.Path)
	}
	info, err := os.Stat(filepath.Join(store.Dir, record.Path))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("avatar file permissions %v", info.Mode().Perm())
	}
	// A fresh record is not fetched again until the refresh period passes.
	if err := refreshAvatars(context.Background(), store, src, avatarBatchLimit); err != nil {
		t.Fatal(err)
	}
	if len(src.requests) != 1 {
		t.Fatalf("expected no repeated lookup, got %d requests", len(src.requests))
	}
	// A participant without a photo is remembered as a miss, not retried.
	src.photos = map[string][]byte{}
	if err := store.PutAvatar(archive.AvatarRecord{ParticipantID: "p-alex", Path: record.Path, Hash: record.Hash, Updated: time.Now().Add(-8 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := refreshAvatars(context.Background(), store, src, avatarBatchLimit); err != nil {
		t.Fatal(err)
	}
	records, _ = store.Avatars()
	if records["p-alex"].Path != "" {
		t.Fatalf("expected the removed photo to clear the record, got %q", records["p-alex"].Path)
	}
	if _, err := os.Stat(filepath.Join(store.Dir, record.Path)); !os.IsNotExist(err) {
		t.Fatalf("expected the stale avatar file to be removed")
	}
	// Sources without thumbnail support are skipped silently.
	if err := refreshAvatars(context.Background(), store, &fakeSource{}, avatarBatchLimit); err != nil {
		t.Fatal(err)
	}
	if imageExtension([]byte("not an image")) != "" {
		t.Fatal("non-image bytes must not be saved")
	}
}
