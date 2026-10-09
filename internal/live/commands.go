package live

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/google"
)

// ReadCommands only runs on the explicitly enabled private stdin channel. EOF,
// malformed commands and oversized lines terminate it; input is never logged.
func ReadCommands(ctx context.Context, input io.Reader, output chan<- archive.SendCommand) {
	defer close(output)
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 128*1024)
	for scanner.Scan() {
		var command archive.SendCommand
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&command) != nil || !command.Valid() {
			return
		}
		var extra any
		if decoder.Decode(&extra) != io.EOF {
			return
		}
		select {
		case output <- command:
		case <-ctx.Done():
			return
		}
	}
}

type sender interface {
	PrepareText(context.Context, archive.SendCommand) (func(context.Context) (bool, error), error)
}
type reacter interface {
	PrepareReaction(context.Context, archive.SendCommand, archive.Message) (func(context.Context) (bool, error), error)
}
type starter interface {
	StartConversation(context.Context, string) (archive.Conversation, error)
}
type readMarker interface {
	MarkRead(context.Context, string, string) error
}
type typer interface {
	Typing(context.Context, string) error
}
type sendSession struct {
	token  string
	ctx    context.Context
	client sender
	// refresh re-reads a conversation from the phone, back to `since` when it is
	// set (a reaction can land on a message older than the usual catch-up window).
	refresh func(id string, since time.Time)
}
type commandRouter struct {
	mu      sync.Mutex
	session *sendSession
	store   *archive.Store
	// presence is true while the app is in front; the session polls less when idle.
	presence *atomic.Bool
}

func (r *commandRouter) set(session *sendSession) { r.mu.Lock(); r.session = session; r.mu.Unlock() }
func (r *commandRouter) current() *sendSession    { r.mu.Lock(); defer r.mu.Unlock(); return r.session }

// phoneRequestTimeout bounds best-effort requests (typing, mark read) so an
// unresponsive phone cannot hold up the sends queued behind them.
const phoneRequestTimeout = 15 * time.Second

type queuedCommand struct {
	command  archive.SendCommand
	reserved bool
}

// run records each send the moment it arrives, so the app sees it within
// milliseconds even while an earlier send, upload or phone request is still in
// progress. The phone work itself stays in arrival order on one goroutine.
func (r *commandRouter) run(ctx context.Context, commands <-chan archive.SendCommand) {
	work := make(chan queuedCommand, 256)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for item := range work {
			if item.reserved {
				_ = r.perform(item.command, r.current())
			} else {
				_ = r.execute(item.command, r.current())
			}
		}
	}()
	defer func() { close(work); <-done }()
	for {
		select {
		case <-ctx.Done():
			return
		case command, ok := <-commands:
			if !ok {
				return
			}
			item := queuedCommand{command: command}
			switch command.Kind {
			case "presence", "dismiss":
				_ = r.execute(command, nil)
				continue
			case "send_text", "react":
				created, err := r.store.ReserveSend(command)
				if err != nil || !created {
					continue
				}
				item.reserved = true
			}
			select {
			case work <- item:
			case <-ctx.Done():
				// Shutting down: a recorded attempt that will not run must not
				// sit as 'preparing' until the next start.
				if item.reserved {
					_ = r.store.SetSendState(command.ID, "failed", "offline")
				}
				return
			}
		}
	}
}
func (r *commandRouter) execute(command archive.SendCommand, session *sendSession) error {
	if command.Kind == "presence" {
		if command.Valid() && r.presence != nil {
			r.presence.Store(command.Body == "active")
		}
		return nil
	}
	if command.Kind == "dismiss" {
		if !command.Valid() {
			return nil
		}
		return r.store.DismissSend(command.ID, command.ConversationID)
	}
	if command.IsStart() {
		return r.start(command, session)
	}
	if command.Kind == "mark_read" {
		return r.markRead(command, session)
	}
	if command.Kind == "typing" {
		if command.Valid() && session != nil && session.ctx.Err() == nil && command.Connection == session.token {
			if client, ok := session.client.(typer); ok {
				ctx, cancel := context.WithTimeout(session.ctx, phoneRequestTimeout)
				_ = client.Typing(ctx, command.ConversationID)
				cancel()
			}
		}
		return nil
	}
	created, err := r.store.ReserveSend(command)
	if err != nil || !created {
		return err
	}
	return r.perform(command, session)
}

// perform does the phone work for a send or reaction already reserved in the outbox.
func (r *commandRouter) perform(command archive.SendCommand, session *sendSession) error {
	var err error
	state := func(value, reason string) error { return r.store.SetSendState(command.ID, value, reason) }
	if session == nil || session.ctx.Err() != nil || command.Connection != session.token {
		return state("failed", "offline")
	}
	deadline := 60 * time.Second
	if len(command.Files) > 0 {
		deadline = 5 * time.Minute
	}
	ctx, cancel := context.WithTimeout(session.ctx, deadline)
	defer cancel()
	var send func(context.Context) (bool, error)
	var target archive.Message
	if command.Kind == "react" {
		target, err = r.store.MessageByID(command.MessageID)
		if reacting, ok := session.client.(reacter); err == nil && ok && target.ConversationID == command.ConversationID {
			send, err = reacting.PrepareReaction(ctx, command, target)
		}
	} else {
		send, err = session.client.PrepareText(ctx, command)
	}
	if err != nil || send == nil || ctx.Err() != nil {
		// A phone that does not answer is a connection problem, not a problem
		// with the conversation, SIM or files.
		if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) || errors.Is(err, libgm.ErrPhoneNotResponding) || errors.Is(err, libgm.ErrConnectionClosed) {
			return state("failed", "offline")
		}
		return state("failed", "preflight")
	}
	if err = state("sending", ""); err != nil {
		return err
	}
	accepted, err := send(ctx)
	if session.refresh != nil {
		session.refresh(command.ConversationID, target.Timestamp)
	}
	if err != nil {
		if errors.Is(err, google.ErrNotSubmitted) {
			return state("failed", "attachment_preparation")
		}
		return state("unknown", "response_lost")
	}
	if !accepted {
		return state("failed", "phone_rejected")
	}
	if command.Kind == "react" {
		return state("applied", "")
	}
	return state("accepted", "")
}

// start asks the phone for the conversation belonging to a number. The phone
// returns an existing thread when there is one, so repeating a start is safe.
func (r *commandRouter) start(command archive.SendCommand, session *sendSession) error {
	created, err := r.store.ReserveStart(command)
	if err != nil || !created {
		return err
	}
	state := func(value, reason string) error { return r.store.SetSendState(command.ID, value, reason) }
	if session == nil || session.ctx.Err() != nil || command.Connection != session.token {
		return state("failed", "offline")
	}
	client, ok := session.client.(starter)
	if !ok {
		return state("failed", "preflight")
	}
	if err = state("resolving", ""); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(session.ctx, 45*time.Second)
	defer cancel()
	conversation, err := client.StartConversation(ctx, command.Number)
	if err != nil || conversation.ID == "" {
		if ctx.Err() != nil {
			return state("failed", "offline")
		}
		return state("failed", "phone_rejected")
	}
	if err = r.store.PutConversation(conversation); err != nil {
		return err
	}
	if session.refresh != nil {
		session.refresh(conversation.ID, time.Time{})
	}
	return r.store.SetStartResult(command.ID, conversation.ID)
}

// markRead is best effort and idempotent: it needs no outbox row, and a
// failure only means the phone keeps showing the thread as unread.
func (r *commandRouter) markRead(command archive.SendCommand, session *sendSession) error {
	if !command.Valid() || session == nil || session.ctx.Err() != nil || command.Connection != session.token {
		return nil
	}
	client, ok := session.client.(readMarker)
	if !ok {
		return nil
	}
	ctx, cancel := context.WithTimeout(session.ctx, phoneRequestTimeout)
	defer cancel()
	if err := client.MarkRead(ctx, command.ConversationID, command.MessageID); err != nil {
		return nil
	}
	return r.store.SetUnread(command.ConversationID, false)
}

func (r *commandRouter) token() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.session == nil || r.session.ctx.Err() != nil {
		return ""
	}
	return r.session.token
}
