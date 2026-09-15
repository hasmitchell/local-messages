package live

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

type fakeTyper struct {
	fakeSender
	calls []string
}

func (f *fakeTyper) Typing(_ context.Context, id string) error {
	f.calls = append(f.calls, id)
	return nil
}

type fakeContacts struct {
	fakeSource
	calls int
}

func (f *fakeContacts) Contacts(context.Context) ([]archive.Contact, error) {
	f.calls++
	return []archive.Contact{{ParticipantID: "p1", Name: "Alex", Number: "+61 400 000 001", ContactID: "c1"}, {ParticipantID: "", Name: "dropped"}}, nil
}

func TestTypingEventsAndCommands(t *testing.T) {
	var notices []string
	buffer := &eventBuffer{cancel: func() {}, wake: make(chan struct{}, 1), onTyping: func(id string, active bool) {
		notices = append(notices, id+":"+map[bool]string{true: "on", false: "off"}[active])
	}}
	buffer.observe(&gmproto.TypingData{ConversationID: "c", Type: gmproto.TypingTypes_STARTED_TYPING})
	buffer.observe(&gmproto.TypingData{ConversationID: "c", Type: gmproto.TypingTypes_STOPPED_TYPING})
	buffer.observe(&gmproto.TypingData{})
	if len(notices) != 2 || notices[0] != "c:on" || notices[1] != "c:off" {
		t.Fatalf("typing notices %v", notices)
	}
	if conversationDigest("c") == "c" || len(conversationDigest("c")) != 16 {
		t.Fatal("typing lines must not carry the raw conversation id")
	}
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	fake := &fakeTyper{}
	session := &sendSession{token: "connection", ctx: context.Background(), client: fake}
	router := &commandRouter{store: store}
	command := archive.SendCommand{Kind: "typing", ID: uuid.NewString(), Connection: "connection", ConversationID: "c"}
	if err := router.execute(command, session); err != nil || len(fake.calls) != 1 || fake.calls[0] != "c" {
		t.Fatalf("typing command: %v %v", err, fake.calls)
	}
	stale := archive.SendCommand{Kind: "typing", ID: uuid.NewString(), Connection: "old", ConversationID: "c"}
	if err := router.execute(stale, session); err != nil || len(fake.calls) != 1 {
		t.Fatalf("stale typing command must be ignored: %v %v", err, fake.calls)
	}
	var rows int
	if err := store.DB().QueryRow(`SELECT count(*) FROM outbox`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("typing must not create outbox rows: %d %v", rows, err)
	}
	reply := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "hi", ReplyTo: "m1"}
	if !reply.Valid() {
		t.Fatal("reply_to should be accepted on text sends")
	}
}

func TestContactsRefreshOncePerDay(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	src := &fakeContacts{}
	for i := 0; i < 2; i++ {
		if err := refreshContacts(context.Background(), store, src); err != nil {
			t.Fatal(err)
		}
	}
	if src.calls != 1 {
		t.Fatalf("expected one listing per day, got %d", src.calls)
	}
	var name, number string
	if err := store.DB().QueryRow(`SELECT name,number FROM contacts WHERE participant_id='p1'`).Scan(&name, &number); err != nil || name != "Alex" || number != "+61 400 000 001" {
		t.Fatalf("contact not saved: %v %q %q", err, name, number)
	}
	var count int
	if err := store.DB().QueryRow(`SELECT count(*) FROM contacts`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("entries without a participant id must be dropped: %d", count)
	}
	if err := store.SetMeta("contacts_refreshed", time.Now().Add(-25*time.Hour).UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if err := refreshContacts(context.Background(), store, src); err != nil || src.calls != 2 {
		t.Fatalf("expected a refresh after a day: %v %d", err, src.calls)
	}
	if err := refreshContacts(context.Background(), store, &fakeSource{}); err != nil {
		t.Fatal(err)
	}
}
