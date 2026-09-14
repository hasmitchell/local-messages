package live

import (
	"testing"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

func TestPhoneReadStateAppliesImmediatelyButNeverFromStaleEvents(t *testing.T) {
	buffer := &eventBuffer{cancel: func() {}, wake: make(chan struct{}, 1)}
	buffer.observe(&gmproto.Conversation{ConversationID: "c", Unread: false, LastMessageTimestamp: 2_000_000})
	buffer.observe(&gmproto.Conversation{})
	p := buffer.take()
	update, ok := p.unread["c"]
	if !ok || update.unread || update.lastMessage.UnixMicro() != 2_000_000 || len(p.unread) != 1 {
		t.Fatalf("unexpected unread updates %+v", p.unread)
	}
	if !p.inventory || p.dirty["c"].IsZero() == false {
		t.Fatalf("conversation events must still invalidate the thread: %+v", p)
	}

	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.UnixMicro(2_000_000), Unread: true}); err != nil {
		t.Fatal(err)
	}
	unread := func() bool {
		var value bool
		if err := store.DB().QueryRow(`SELECT unread FROM conversations WHERE id='c'`).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	// A replayed event about older activity must not clear a newer unread state.
	if err := store.UpdateUnread("c", false, time.UnixMicro(1_000_000)); err != nil || !unread() {
		t.Fatalf("stale event changed read state: %v %v", err, unread())
	}
	// The current event clears it, and a later one can set it again.
	if err := store.UpdateUnread("c", false, time.UnixMicro(2_000_000)); err != nil || unread() {
		t.Fatalf("current event did not clear unread: %v %v", err, unread())
	}
	if err := store.UpdateUnread("c", true, time.UnixMicro(3_000_000)); err != nil || !unread() {
		t.Fatalf("newer event did not set unread: %v %v", err, unread())
	}
}
