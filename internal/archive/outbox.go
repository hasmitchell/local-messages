package archive

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

type SendCommand struct {
	Connection     string         `json:"connection"`
	Kind           string         `json:"kind"`
	ID             string         `json:"id"`
	ConversationID string         `json:"conversation_id"`
	Body           string         `json:"body"`
	Files          []OutgoingFile `json:"files,omitempty"`
	MessageID      string         `json:"message_id,omitempty"`
	Emoji          string         `json:"emoji,omitempty"`
	// Number starts a conversation with a phone number; the phone resolves it
	// to an existing or new conversation ID.
	Number string `json:"number,omitempty"`
	// ReplyTo quotes an earlier message of the same conversation (RCS).
	ReplyTo string `json:"reply_to,omitempty"`
}

var phoneNumberPattern = regexp.MustCompile(`^\+?[0-9]{6,15}$`)

func (c SendCommand) IsStart() bool { return c.Kind == "start" }

type OutgoingFile struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	MIME   string `json:"mime"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

const MaxUploadBytes = 25 << 20

func (c SendCommand) Valid() bool {
	_, err := uuid.Parse(c.ID)
	if err != nil || len(c.ID) != 36 {
		return false
	}
	if c.Kind == "start" {
		return c.ConversationID == "" && c.Body == "" && len(c.Files) == 0 && c.MessageID == "" && c.Emoji == "" && phoneNumberPattern.MatchString(c.Number)
	}
	if c.Kind == "presence" {
		return c.ConversationID == "" && (c.Body == "active" || c.Body == "idle") && len(c.Files) == 0 && c.MessageID == "" && c.Emoji == "" && c.Number == ""
	}
	if c.Kind == "typing" {
		return c.ConversationID != "" && len(c.ConversationID) <= 512 && c.Body == "" && len(c.Files) == 0 && c.MessageID == "" && c.Emoji == "" && c.Number == "" && c.ReplyTo == ""
	}
	if c.Kind == "mark_read" {
		return c.ConversationID != "" && len(c.ConversationID) <= 512 && c.MessageID != "" && len(c.MessageID) <= 512 && c.Body == "" && len(c.Files) == 0 && c.Emoji == "" && c.Number == ""
	}
	if c.ConversationID == "" || len(c.ConversationID) > 512 || c.Number != "" {
		return false
	}
	if c.Kind == "react" {
		return c.MessageID != "" && len(c.MessageID) <= 512 && len(c.Files) == 0 && c.Body == "" && (c.Emoji == "" || strings.Contains("|👍|❤️|😂|😮|😢|👎|", "|"+c.Emoji+"|"))
	}
	if c.Kind != "send_text" || !utf8.ValidString(c.Body) || len(c.Body) > 16000 || utf8.RuneCountInString(c.Body) > 4000 || len(c.Files) > 10 || (strings.TrimSpace(c.Body) == "" && len(c.Files) == 0) || len(c.ReplyTo) > 512 {
		return false
	}
	var total int64
	seen := map[string]bool{}
	for _, f := range c.Files {
		if _, err := uuid.Parse(f.ID); err != nil || len(f.ID) != 36 || seen[f.ID] || f.Size <= 0 || f.Size > MaxUploadBytes || len(f.SHA256) != 64 || f.Name == "" || len(f.Name) > 255 || strings.ContainsAny(f.Name, "/\\\x00\r\n") || !strings.Contains(f.MIME, "/") || len(f.MIME) > 128 {
			return false
		}
		seen[f.ID] = true
		total += f.Size
	}
	return total <= MaxUploadBytes
}

// Reserve commits the intent before any network operation. A duplicate command
// ID never results in another send, including after restart or a lost response.
func (s *Store) ReserveSend(c SendCommand) (bool, error) {
	if !c.Valid() {
		return false, fmt.Errorf("invalid send command")
	}
	now := time.Now().UnixMicro()
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.Exec(`INSERT INTO outbox(id,conversation_id,body,state,reason,created,updated,remote_id)
        SELECT ?,?,?,'preparing','',?,? ,'' WHERE EXISTS(SELECT 1 FROM conversations WHERE id=?)
        ON CONFLICT(id) DO NOTHING`, c.ID, c.ConversationID, c.Body, now, now, c.ConversationID)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	if err != nil || n == 0 {
		return false, err
	}
	data, err := json.Marshal(c)
	if err != nil {
		return false, err
	}
	if _, err = tx.Exec(`INSERT INTO outbox_commands VALUES(?,?)`, c.ID, data); err != nil {
		return false, err
	}
	return true, tx.Commit()
}
// ReserveStart records the intent to open a conversation with a number. The
// row has no conversation until the phone answers; the result lands in remote_id.
func (s *Store) ReserveStart(c SendCommand) (bool, error) {
	if !c.Valid() || !c.IsStart() {
		return false, fmt.Errorf("invalid start command")
	}
	now := time.Now().UnixMicro()
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.Exec(`INSERT INTO outbox(id,conversation_id,body,state,reason,created,updated,remote_id) VALUES(?,'','','preparing','',?,?,'') ON CONFLICT(id) DO NOTHING`, c.ID, now, now)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	if err != nil || n == 0 {
		return false, err
	}
	data, err := json.Marshal(c)
	if err != nil {
		return false, err
	}
	if _, err = tx.Exec(`INSERT INTO outbox_commands VALUES(?,?)`, c.ID, data); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

func (s *Store) SetStartResult(id, conversationID string) error {
	_, err := s.db.Exec(`UPDATE outbox SET state='resolved',reason='',remote_id=?,updated=? WHERE id=? AND conversation_id=''`, conversationID, time.Now().UnixMicro(), id)
	return err
}

func (s *Store) SetSendState(id, state, reason string) error {
	_, err := s.db.Exec(`UPDATE outbox SET state=?,reason=?,updated=? WHERE id=? AND state!='confirmed'`, state, reason, time.Now().UnixMicro(), id)
	return err
}
func (s *Store) RecoverInterruptedSends() error {
	// Opening a conversation is idempotent on the phone, so an interrupted
	// start simply fails and can be retried.
	_, err := s.db.Exec(`UPDATE outbox SET state=CASE state WHEN 'sending' THEN 'unknown' ELSE 'failed' END,
        reason=CASE state WHEN 'sending' THEN 'interrupted' ELSE 'interrupted_before_send' END,updated=? WHERE state IN ('preparing','sending','resolving')`, time.Now().UnixMicro())
	return err
}
func (s *Store) SendState(id string) (string, error) {
	var state string
	err := s.db.QueryRow(`SELECT state FROM outbox WHERE id=?`, id).Scan(&state)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return state, err
}

func (s *Store) ConfirmSend(clientID, conversationID, messageID string) error {
	_, err := s.db.Exec(`UPDATE outbox SET state='confirmed',remote_id=?,updated=? WHERE id=? AND conversation_id=?`, messageID, time.Now().UnixMicro(), clientID, conversationID)
	return err
}

func (s *Store) RecentSendConversations(since time.Time) ([]string, error) {
	rows, err := s.db.Query(`SELECT DISTINCT conversation_id FROM outbox WHERE created>=? AND state IN ('sending','accepted','unknown','confirmed','applied')`, since.UnixMicro())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) MessageByID(id string) (Message, error) {
	var data []byte
	var message Message
	err := s.db.QueryRow(`SELECT payload FROM messages WHERE id=?`, id).Scan(&data)
	if err == nil {
		err = json.Unmarshal(data, &message)
	}
	return message, err
}
