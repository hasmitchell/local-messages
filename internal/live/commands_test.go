package live

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"local/GoogleMessagingAppMac/internal/archive"
	"strings"
	"testing"
	"time"
)

type fakeSender struct {
	prepares, sends int
	mode            string
	store           *archive.Store
	t               *testing.T
}

func (f *fakeSender) PrepareText(_ context.Context, c archive.SendCommand) (func(context.Context) (bool, error), error) {
	f.prepares++
	if f.mode == "preflight" {
		return nil, errors.New("private remote error")
	}
	return func(ctx context.Context) (bool, error) {
		f.sends++
		state, err := f.store.SendState(c.ID)
		if err != nil || state != "sending" {
			f.t.Fatal("send happened before durable reservation")
		}
		switch f.mode {
		case "timeout":
			return false, context.DeadlineExceeded
		case "reject":
			return false, nil
		case "echo":
			err := f.store.PutUpdates([]archive.Message{{ID: "remote", ClientID: c.ID, ConversationID: c.ConversationID, Body: c.Body, Timestamp: time.Now(), Outgoing: true, Status: "OUTGOING_COMPLETE"}})
			if err != nil {
				f.t.Fatal(err)
			}
		}
		return true, nil
	}, nil
}
func TestSendAttemptsAreDurableAndNeverAutomaticallyRepeated(t *testing.T) {
	for _, mode := range []string{"accepted", "timeout", "reject", "preflight", "echo", "offline", "stale_connection"} {
		t.Run(mode, func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			if err = store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now()}); err != nil {
				t.Fatal(err)
			}
			command := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", Body: "Synthetic test text"}
			fake := &fakeSender{mode: mode, store: store, t: t}
			session := &sendSession{token: "connection", ctx: context.Background(), client: fake}
			if mode == "offline" {
				session = nil
			}
			if mode == "stale_connection" {
				command.Connection = "old-connection"
			}
			router := &commandRouter{store: store}
			for range 2 {
				if err = router.execute(command, session); err != nil {
					t.Fatal(err)
				}
			}
			expected := map[string]string{"accepted": "accepted", "timeout": "unknown", "reject": "failed", "preflight": "failed", "echo": "confirmed", "offline": "failed", "stale_connection": "failed"}[mode]
			state, _ := store.SendState(command.ID)
			if state != expected {
				t.Fatalf("state %s; want %s", state, expected)
			}
			sends := 1
			if mode == "offline" || mode == "preflight" || mode == "stale_connection" {
				sends = 0
			}
			if fake.sends != sends {
				t.Fatal("incorrect number of wire sends", fake.sends)
			}
			if err = store.RecoverInterruptedSends(); err != nil {
				t.Fatal(err)
			}
			if err = router.execute(command, session); err != nil {
				t.Fatal(err)
			}
			if fake.sends != sends {
				t.Fatal("restart repeated an attempted send")
			}
		})
	}
}
func TestCrashRecoveryDistinguishesBeforeAndAfterSubmission(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.PutConversation(archive.Conversation{ID: "c", LastMessage: time.Now()})
	for _, stage := range []string{"preparing", "sending"} {
		c := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Saved before network"}
		_, err := store.ReserveSend(c)
		if err != nil {
			t.Fatal(err)
		}
		_ = store.SetSendState(c.ID, stage, "")
		if err = store.RecoverInterruptedSends(); err != nil {
			t.Fatal(err)
		}
		state, _ := store.SendState(c.ID)
		expected := "failed"
		if stage == "sending" {
			expected = "unknown"
		}
		if state != expected {
			t.Fatal("incorrect interrupted-send state")
		}
	}
}
func TestCommandParserRejectsMalformedOrOversizedInput(t *testing.T) {
	valid := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Line one\nLine two 😀"}
	encoded, _ := json.Marshal(valid)
	// The app's dismiss line must parse: one rejected line stops the reader.
	dismissLine := `{"kind":"dismiss","id":"` + uuid.NewString() + `","conversation_id":"c","body":"","connection":"x"}` + "\n"
	for _, test := range []struct {
		input string
		count int
	}{{string(encoded) + "\n", 1}, {string(encoded) + " {}\n", 0}, {`{"kind":"send_text","id":"bad"}` + "\n", 0}, {strings.Repeat("x", 129*1024), 0}, {strings.TrimSuffix(string(encoded), "}") + `,"unexpected":true}` + "\n", 0}, {dismissLine, 1}} {
		out := make(chan archive.SendCommand, 2)
		ReadCommands(context.Background(), strings.NewReader(test.input), out)
		count := 0
		for range out {
			count++
		}
		if count != test.count {
			t.Fatal("unsafe command accepted")
		}
	}
}

type blockingSender struct{ release chan struct{} }

func (b *blockingSender) PrepareText(ctx context.Context, _ archive.SendCommand) (func(context.Context) (bool, error), error) {
	return func(ctx context.Context) (bool, error) {
		select {
		case <-b.release:
		case <-ctx.Done():
		}
		return true, nil
	}, nil
}

func TestSendsAreRecordedWhileEarlierPhoneWorkIsInProgress(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err = store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now()}); err != nil {
		t.Fatal(err)
	}
	sender := &blockingSender{release: make(chan struct{})}
	router := &commandRouter{store: store}
	router.set(&sendSession{token: "connection", ctx: context.Background(), client: sender})
	commands := make(chan archive.SendCommand)
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	go func() { defer close(finished); router.run(ctx, commands) }()
	first := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", Body: "First"}
	second := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", Body: "Second"}
	put := func(c archive.SendCommand) {
		t.Helper()
		select {
		case commands <- c:
		case <-time.After(5 * time.Second):
			t.Fatal("router stopped reading commands")
		}
	}
	put(first)
	waitForState := func(id, want string) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for {
			state, _ := store.SendState(id)
			if state == want {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("state %q; want %q", state, want)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	waitForState(first.ID, "sending")
	// The first send is still waiting on the phone; the second is on record at once.
	put(second)
	waitForState(second.ID, "preparing")
	close(sender.release)
	waitForState(first.ID, "accepted")
	waitForState(second.ID, "accepted")
	cancel()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("router did not stop")
	}
}

type fakeReacter struct {
	fakeSender
	reactions int
}

func (f *fakeReacter) PrepareReaction(_ context.Context, c archive.SendCommand, target archive.Message) (func(context.Context) (bool, error), error) {
	return func(context.Context) (bool, error) { f.reactions++; return true, nil }, nil
}

func TestReactionIsAppliedAndRereadsBackToItsMessage(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	old := time.Now().Add(-72 * time.Hour).UTC().Truncate(time.Microsecond)
	if err = store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err = store.PutUpdates([]archive.Message{{ID: "m", ConversationID: "c", Body: "Older message", Timestamp: old, Status: "INCOMING_COMPLETE"}}); err != nil {
		t.Fatal(err)
	}
	fake := &fakeReacter{}
	var refreshed []time.Time
	session := &sendSession{token: "connection", ctx: context.Background(), client: fake, refresh: func(_ string, since time.Time) { refreshed = append(refreshed, since) }}
	command := archive.SendCommand{Kind: "react", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", MessageID: "m", Emoji: "👍"}
	if err = (&commandRouter{store: store}).execute(command, session); err != nil {
		t.Fatal(err)
	}
	if state, _ := store.SendState(command.ID); state != "applied" || fake.reactions != 1 {
		t.Fatalf("reaction state %q after %d sends", state, fake.reactions)
	}
	// The re-read reaches back to the reacted message, beyond the usual catch-up window.
	if len(refreshed) != 1 || !refreshed[0].Equal(old) {
		t.Fatalf("refresh since %v; want %v", refreshed, old)
	}
}

func TestDismissHidesOnlyFailedOrUnconfirmedAttempts(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err = store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now()}); err != nil {
		t.Fatal(err)
	}
	router := &commandRouter{store: store}
	states := map[string]string{"failed": "dismissed", "unknown": "dismissed", "accepted": "accepted", "sending": "sending"}
	for from, want := range states {
		c := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Text"}
		if _, err = store.ReserveSend(c); err != nil {
			t.Fatal(err)
		}
		_ = store.SetSendState(c.ID, from, "")
		if err = router.execute(archive.SendCommand{Kind: "dismiss", ID: c.ID, ConversationID: "c"}, nil); err != nil {
			t.Fatal(err)
		}
		if got, _ := store.SendState(c.ID); got != want {
			t.Fatalf("%s became %s; want %s", from, got, want)
		}
	}
	// The wrong conversation cannot dismiss another thread's attempt.
	c := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Text"}
	_, _ = store.ReserveSend(c)
	_ = store.SetSendState(c.ID, "failed", "offline")
	_ = router.execute(archive.SendCommand{Kind: "dismiss", ID: c.ID, ConversationID: "other"}, nil)
	if got, _ := store.SendState(c.ID); got != "failed" {
		t.Fatal("dismiss crossed conversations")
	}
}
