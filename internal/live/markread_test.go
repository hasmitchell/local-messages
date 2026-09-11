package live

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"local/GoogleMessagingAppMac/internal/archive"
)

type fakeReadMarker struct {
	fakeSender
	calls [][2]string
	fail  bool
}

func (f *fakeReadMarker) MarkRead(_ context.Context, conversationID, messageID string) error {
	f.calls = append(f.calls, [2]string{conversationID, messageID})
	if f.fail {
		return errors.New("private remote error")
	}
	return nil
}

func TestMarkReadCommandClearsUnreadWithoutOutboxRows(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now(), Unread: true}); err != nil {
		t.Fatal(err)
	}
	unread := func() bool {
		var value bool
		if err := store.DB().QueryRow(`SELECT unread FROM conversations WHERE id='c'`).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	fake := &fakeReadMarker{}
	session := &sendSession{token: "connection", ctx: context.Background(), client: fake}
	router := &commandRouter{store: store}
	command := archive.SendCommand{Kind: "mark_read", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", MessageID: "m1"}
	if err := router.execute(command, session); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) != 1 || fake.calls[0] != [2]string{"c", "m1"} || unread() {
		t.Fatalf("calls %v unread %v", fake.calls, unread())
	}
	var rows int
	if err := store.DB().QueryRow(`SELECT count(*) FROM outbox`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("mark_read must not create outbox rows: %d %v", rows, err)
	}
	// A failed request leaves the phone's state untouched locally.
	if err := store.SetUnread("c", true); err != nil {
		t.Fatal(err)
	}
	fake.fail = true
	if err := router.execute(command, session); err != nil || !unread() {
		t.Fatalf("failure should keep unread: %v %v", err, unread())
	}
	// Stale connections and sources without support are ignored.
	stale := archive.SendCommand{Kind: "mark_read", ID: uuid.NewString(), Connection: "old", ConversationID: "c", MessageID: "m1"}
	if err := router.execute(stale, session); err != nil || len(fake.calls) != 2 {
		t.Fatalf("stale connection should be ignored: %v %v", err, fake.calls)
	}
	if err := router.execute(command, &sendSession{token: "connection", ctx: context.Background(), client: &fakeSender{}}); err != nil {
		t.Fatal(err)
	}
	if (archive.SendCommand{Kind: "mark_read", ID: uuid.NewString(), ConversationID: "c"}).Valid() {
		t.Fatal("mark_read needs a message id")
	}
}
