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
	token   string
	ctx     context.Context
	client  sender
	refresh func(string)
}
type commandRouter struct {
	mu      sync.Mutex
	session *sendSession
	store   *archive.Store
	// presence is true while the app is in front; the session polls less when idle.
	presence *atomic.Bool
}

func (r *commandRouter) set(session *sendSession) { r.mu.Lock(); r.session = session; r.mu.Unlock() }
func (r *commandRouter) run(ctx context.Context, commands <-chan archive.SendCommand) {
	for {
		select {
		case <-ctx.Done():
			return
		case command, ok := <-commands:
			if !ok {
				return
			}
			r.mu.Lock()
			session := r.session
			r.mu.Unlock()
			_ = r.execute(command, session)
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
	if command.IsStart() {
		return r.start(command, session)
	}
	if command.Kind == "mark_read" {
		return r.markRead(command, session)
	}
	if command.Kind == "typing" {
		if command.Valid() && session != nil && session.ctx.Err() == nil && command.Connection == session.token {
			if client, ok := session.client.(typer); ok {
				_ = client.Typing(session.ctx, command.ConversationID)
			}
		}
		return nil
	}
	created, err := r.store.ReserveSend(command)
	if err != nil || !created {
		return err
	}
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
	if command.Kind == "react" {
		var target archive.Message
		target, err = r.store.MessageByID(command.MessageID)
		if reacting, ok := session.client.(reacter); err == nil && ok && target.ConversationID == command.ConversationID {
			send, err = reacting.PrepareReaction(ctx, command, target)
		}
	} else {
		send, err = session.client.PrepareText(ctx, command)
	}
	if err != nil || send == nil || ctx.Err() != nil {
		return state("failed", "preflight")
	}
	if err = state("sending", ""); err != nil {
		return err
	}
	accepted, err := send(ctx)
	if session.refresh != nil {
		session.refresh(command.ConversationID)
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
		session.refresh(conversation.ID)
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
	if err := client.MarkRead(session.ctx, command.ConversationID, command.MessageID); err != nil {
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
