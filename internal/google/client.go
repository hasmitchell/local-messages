package google

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"google.golang.org/protobuf/proto"
	"go.mau.fi/util/exhttp"
	"google.golang.org/protobuf/encoding/protojson"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

type Client struct {
	GM              *libgm.Client
	helper, account string
	directory       string
	cancel          context.CancelFunc
	mediaMu         sync.Mutex
	mediaWaiters    map[mediaReference]*mediaWaiter
	mediaCache      map[mediaReference]archive.Attachment
	mediaCacheOrder []mediaReference
	MediaProgress   func(string)
	simMu           sync.Mutex
	sims            map[string]*gmproto.SIMCard
	// outgoing remembers each conversation's sending participant so typing
	// updates need no extra round trip to the phone.
	outgoing map[string]string
}
type session struct {
	Auth *libgm.AuthData `json:"auth"`
	Push *libgm.PushKeys `json:"push,omitempty"`
}

func newClient(dir string) (*Client, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	key := sha256.Sum256([]byte(abs))
	helper := filepath.Join(filepath.Dir(exe), "gm-account-helper")
	if _, err = os.Stat(helper); err != nil {
		return nil, fmt.Errorf("build the native account helper with ./scripts/build")
	}
	return &Client{helper: helper, account: hex.EncodeToString(key[:]), directory: abs, outgoing: map[string]string{}}, nil
}
func (c *Client) helperCall(ctx context.Context, action string, input []byte) ([]byte, error) {
	args := []string{action}
	if action != "login" {
		args = append(args, c.account)
	}
	cmd := exec.CommandContext(ctx, c.helper, args...)
	cmd.Stdin = bytes.NewReader(input)
	// No secret-bearing stdout or upstream response bodies are written to logs.
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("account helper %s failed; check the sign-in window or Keychain access", action)
	}
	return out, nil
}
func (c *Client) configure(auth *libgm.AuthData, push *libgm.PushKeys) {
	c.GM = libgm.NewClient(auth, push, zerolog.New(io.Discard), exhttp.SensibleClientSettings.WithGlobalTimeout(45*time.Second))
}

func Pair(ctx context.Context, store *archive.Store, output io.Writer) error {
	return PairWithStatus(ctx, store, nil, func(status PairingStatus) {
		if status.Emoji != "" {
			fmt.Fprintf(output, "On your phone, confirm this emoji in Google Messages: %s\n", status.Emoji)
		}
	})
}

var ErrPairingUnavailable = errors.New("no accessible pairing for this archive")

func Connect(ctx context.Context, store *archive.Store, observers ...func(any)) (*Client, error) {
	c, err := newClient(store.Dir)
	if err != nil {
		return nil, err
	}
	b, err := c.helperCall(ctx, "get", nil)
	if err != nil {
		return nil, ErrPairingUnavailable
	}
	var sess session
	if err = json.Unmarshal(b, &sess); err != nil || sess.Auth == nil {
		return nil, ErrPairingUnavailable
	}
	identity, err := identityFromAuth(sess.Auth)
	if err != nil {
		return nil, err
	}
	if err = store.BindPairingIdentity(identity); err != nil {
		return nil, err
	}
	c.configure(sess.Auth, sess.Push)
	c.cancel, err = startPhoneConnection(ctx, c.GM, append([]func(any){c.receiveMediaUpdate, c.receiveSettings}, observers...)...)
	if err != nil {
		return nil, err
	}
	return c, nil
}

type phoneConnection interface {
	Connect(context.Context) error
	IsBugleDefault(context.Context) (*gmproto.IsBugleDefaultResponse, error)
	SetEventHandler(libgm.EventHandler)
	Disconnect()
}

// Current libgm no longer emits ClientReady. A successful read-only request to
// the phone establishes readiness, including when the inbox has no messages.
func startPhoneConnection(ctx context.Context, phone phoneConnection, observers ...func(any)) (context.CancelFunc, error) {
	child, cancel := context.WithCancel(ctx)
	fail := func(err error) (context.CancelFunc, error) {
		cancel()
		phone.Disconnect()
		return nil, err
	}
	phone.SetEventHandler(func(evt any) {
		switch evt.(type) {
		case *events.GaiaLoggedOut, *events.ListenFatalError:
			cancel()
		}
		for _, observer := range observers {
			observer(evt)
		}
	})
	if err := phone.Connect(child); err != nil {
		return fail(fmt.Errorf("Google connection failed; the pairing may need renewal"))
	}
	readyCtx, readyCancel := context.WithTimeout(child, 60*time.Second)
	defer readyCancel()
	response, err := phone.IsBugleDefault(readyCtx)
	if err != nil {
		if ctx.Err() != nil {
			return fail(ctx.Err())
		}
		return fail(fmt.Errorf("phone readiness request failed; check connectivity and competing web sessions"))
	}
	if !response.GetSuccess() {
		return fail(fmt.Errorf("Google Messages must be the default SMS app on the paired phone"))
	}
	return cancel, nil
}

func (c *Client) Save(ctx context.Context) error {
	// Cookie rotation occurs under this library-provided lock.
	c.GM.AuthData.CookiesLock.RLock()
	b, err := json.Marshal(session{Auth: c.GM.AuthData, Push: c.GM.PushKeys})
	c.GM.AuthData.CookiesLock.RUnlock()
	if err != nil {
		return fmt.Errorf("could not encode the pairing session")
	}
	_, err = c.helperCall(ctx, "put", b)
	return err
}
func (c *Client) Close() {
	if c.cancel != nil {
		c.cancel()
	}
	if c.GM != nil {
		c.GM.Disconnect()
	}
}

func (c *Client) Conversations(ctx context.Context, folder gmproto.ListConversationsRequest_Folder, count int) ([]archive.Conversation, error) {
	resp, err := listConversations(ctx, c.GM.ListConversations, count, folder)
	if err != nil {
		return nil, &safeRequestError{label: "Google conversation listing failed for " + folder.String(), cause: err}
	}
	out := []archive.Conversation{}
	c.simMu.Lock()
	for _, raw := range resp.GetConversations() {
		if raw.GetDefaultOutgoingID() != "" {
			c.outgoing[raw.GetConversationID()] = raw.GetDefaultOutgoingID()
		}
		out = append(out, ConvertConversation(raw, folder.String()))
	}
	c.simMu.Unlock()
	return out, nil
}

// Typing tells the phone that a reply is being written; the phone times the
// indicator out on its own, so no stop message is sent.
func (c *Client) Typing(ctx context.Context, conversationID string) error {
	c.simMu.Lock()
	outgoing, known := c.outgoing[conversationID]
	sim := c.sims[outgoing]
	c.simMu.Unlock()
	if !known || sim == nil {
		lookupCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		conv, err := c.GM.GetConversation(lookupCtx, conversationID)
		cancel()
		if err != nil {
			return &safeRequestError{label: "typing update failed", cause: err}
		}
		c.simMu.Lock()
		c.outgoing[conversationID] = conv.GetDefaultOutgoingID()
		sim = c.sims[conv.GetDefaultOutgoingID()]
		c.simMu.Unlock()
	}
	if sim == nil || sim.GetSIMData().GetSIMPayload() == nil {
		return fmt.Errorf("phone SIM details unavailable")
	}
	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := c.GM.SetTyping(requestCtx, conversationID, proto.Clone(sim.GetSIMData().GetSIMPayload()).(*gmproto.SIMPayload)); err != nil {
		return &safeRequestError{label: "typing update failed", cause: err}
	}
	return nil
}

// Contacts returns the phone's address book as Google Messages lists it.
func (c *Client) Contacts(ctx context.Context) ([]archive.Contact, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	resp, err := c.GM.ListContacts(requestCtx)
	if err != nil {
		return nil, &safeRequestError{label: "Google contact listing failed", cause: err}
	}
	var contacts []archive.Contact
	for _, raw := range resp.GetContacts() {
		number := raw.GetNumber().GetFormattedNumber()
		if number == "" {
			number = raw.GetNumber().GetNumber()
		}
		contacts = append(contacts, archive.Contact{ParticipantID: raw.GetParticipantID(), Name: raw.GetName(), Number: number, ContactID: raw.GetContactID()})
	}
	return contacts, nil
}

func ConvertConversation(raw *gmproto.Conversation, folder string) archive.Conversation {
	name := raw.GetName()
	if name == "" {
		for _, person := range raw.GetParticipants() {
			if !person.GetIsMe() {
				if name != "" {
					name += ", "
				}
				label := person.GetFullName()
				if label == "" {
					label = person.GetID().GetNumber()
				}
				name += label
			}
		}
	}
	var participants []archive.Participant
	for _, p := range raw.GetParticipants() {
		participants = append(participants, archive.Participant{ID: p.GetID().GetParticipantID(), Name: p.GetFullName(), Number: p.GetID().GetNumber(), IsMe: p.GetIsMe(), ContactID: p.GetContactID()})
	}
	return archive.Conversation{ID: raw.GetConversationID(), Name: name, Folder: folder, LastMessage: time.UnixMicro(raw.GetLastMessageTimestamp()).UTC(), Unread: raw.GetUnread(), Participants: participants}
}

// ParticipantThumbnails returns the phone's contact photo for each participant
// ID that has one; participants without a photo are absent from the result.
func (c *Client) ParticipantThumbnails(ctx context.Context, ids []string) (map[string][]byte, error) {
	resp, err := c.GM.GetParticipantThumbnail(ctx, ids...)
	if err != nil {
		return nil, err
	}
	photos := make(map[string][]byte, len(ids))
	for _, thumb := range resp.GetThumbnail() {
		if data := thumb.GetData().GetImageBuffer(); len(data) > 0 {
			photos[thumb.GetIdentifier()] = data
		}
	}
	return photos, nil
}

// StartConversation resolves a phone number to its conversation, creating one
// on the phone when none exists. Group creation is deliberately not offered.
func (c *Client) StartConversation(ctx context.Context, number string) (archive.Conversation, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	resp, err := c.GM.GetOrCreateConversation(requestCtx, &gmproto.GetOrCreateConversationRequest{
		Numbers: []*gmproto.ContactNumber{{MysteriousInt: 2, Number: number, Number2: number}},
	})
	if err != nil {
		return archive.Conversation{}, &safeRequestError{label: "Google conversation creation failed", cause: err}
	}
	raw := resp.GetConversation()
	if raw.GetConversationID() == "" {
		return archive.Conversation{}, fmt.Errorf("the phone returned no conversation for that number")
	}
	folder := "INBOX"
	switch raw.GetStatus() {
	case gmproto.ConversationStatus_ARCHIVED, gmproto.ConversationStatus_KEEP_ARCHIVED:
		folder = "ARCHIVE"
	default:
	}
	return ConvertConversation(raw, folder), nil
}

// MarkRead tells the phone the conversation has been read up to a message.
func (c *Client) MarkRead(ctx context.Context, conversationID, messageID string) error {
	requestCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := c.GM.MarkRead(requestCtx, conversationID, messageID); err != nil {
		return &safeRequestError{label: "read status update failed", cause: err}
	}
	return nil
}

func (c *Client) Lookup(ctx context.Context, id string) (archive.Conversation, bool, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	raw, err := c.GM.GetConversation(requestCtx, id)
	if err != nil {
		return archive.Conversation{}, false, &safeRequestError{label: "Google conversation lookup failed", cause: err}
	}
	folder := "INBOX"
	switch raw.GetStatus() {
	case gmproto.ConversationStatus_ARCHIVED, gmproto.ConversationStatus_KEEP_ARCHIVED:
		folder = "ARCHIVE"
	case gmproto.ConversationStatus_ACTIVE:
	default:
		return archive.Conversation{}, false, nil
	}
	return ConvertConversation(raw, folder), true, nil
}

func (c *Client) Fetch(ctx context.Context, id string, cursor json.RawMessage) (history.Page, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	var cur *gmproto.Cursor
	if len(cursor) > 0 {
		cur = &gmproto.Cursor{}
		if err := protojson.Unmarshal(cursor, cur); err != nil {
			return history.Page{}, fmt.Errorf("stored cursor is invalid")
		}
	}
	resp, err := c.GM.FetchMessages(ctx, id, 100, cur)
	if err != nil {
		return history.Page{}, &safeRequestError{label: "Google history request failed", cause: err}
	}
	page := history.Page{}
	var oldest *gmproto.Message
	for _, raw := range resp.GetMessages() {
		page.Messages = append(page.Messages, Convert(raw))
		if oldest == nil || raw.GetTimestamp() < oldest.GetTimestamp() {
			oldest = raw
		}
	}
	next := resp.GetCursor()
	if next == nil && oldest != nil {
		// The upstream bridge uses this fallback: message timestamps are microseconds,
		// while cursor timestamps are milliseconds. Never subtract a timestamp unit.
		next = &gmproto.Cursor{LastItemID: oldest.GetMessageID(), LastItemTimestamp: time.UnixMicro(oldest.GetTimestamp()).UnixMilli()}
	}
	if next != nil {
		page.Cursor, err = protojson.Marshal(next)
	}
	return page, err
}

func Convert(raw *gmproto.Message) archive.Message {
	m := archive.Message{ClientID: raw.GetTmpID(), ID: raw.GetMessageID(), ConversationID: raw.GetConversationID(), Status: raw.GetMessageStatus().GetStatus().String(), ReplyTo: raw.GetReplyMessage().GetMessageID()}
	if raw.GetTimestamp() > 0 {
		m.Timestamp = time.UnixMicro(raw.GetTimestamp()).UTC()
	}
	sender := raw.GetSenderParticipant()
	m.Sender = sender.GetFullName()
	if m.Sender == "" {
		m.Sender = sender.GetID().GetNumber()
	}
	m.Outgoing = sender.GetIsMe() || strings.HasPrefix(m.Status, "OUTGOING_")
	switch raw.GetType() {
	case 1:
		m.Transport = "SMS"
	case 2, 3:
		m.Transport = "MMS"
	case 4:
		m.Transport = "RCS"
	default:
		m.Transport = "unknown"
	}
	deleted := strings.Contains(m.Status, "DELETED")
	if deleted {
		return m
	}
	for i, info := range raw.GetMessageInfo() {
		if text := info.GetMessageContent(); text != nil {
			if m.Body != "" {
				m.Body += "\n"
			}
			m.Body += text.GetContent()
		}
		if media := info.GetMediaContent(); media != nil {
			id := info.GetActionMessageID()
			if id == "" {
				id = fmt.Sprintf("%s:%d", m.ID, i)
			}
			a := archive.Attachment{ID: id, ActionID: info.GetActionMessageID(), Name: media.GetMediaName(), MIME: media.GetMimeType(), Size: media.GetSize(), MediaID: media.GetMediaID(), Key: media.GetDecryptionKey(), State: "pending"}
			if a.MIME == "" {
				format := media.GetFormat().String()
				switch {
				case strings.Contains(format, "IMAGE"), strings.Contains(format, "JPEG"), strings.Contains(format, "PNG"):
					a.MIME = "image/unknown"
				default:
					a.MIME = "application/octet-stream"
				}
			}
			// A thumbnail is deliberately not promoted to an original attachment.
			if a.MediaID == "" || len(a.Key) == 0 {
				a.State = "original_unavailable"
			}
			m.Attachments = append(m.Attachments, a)
		}
	}
	for _, r := range raw.GetReactions() {
		if emoji := r.GetData().GetUnicode(); emoji != "" {
			m.Reactions = append(m.Reactions, archive.Reaction{Emoji: emoji, Participants: r.GetParticipantIDs()})
		}
	}
	return m
}

func (c *Client) Download(ctx context.Context, store *archive.Store, since time.Time, mode string, budget int64) error {
	if mode == "none" {
		return nil
	}
	messages, err := store.PendingMedia(since)
	if err != nil {
		return err
	}
	if c.MediaProgress != nil {
		c.MediaProgress("Refreshing attachment references from the phone…")
	}
	refreshed, err := refreshMedia(ctx, store, c, messages, mode, budget)
	if err != nil {
		return err
	}
	if c.MediaProgress != nil {
		c.MediaProgress(fmt.Sprintf("Recovered %d original download references from current history.", refreshed))
	}
	dir := filepath.Join(store.Dir, "media")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	originalFailures := 0
	for _, m := range messages {
		for i := range m.Attachments {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			a := &m.Attachments[i]
			if a.State == "downloaded_original" {
				if _, err = os.Stat(filepath.Join(store.Dir, a.Path)); err == nil {
					continue
				}
				a.State = "pending"
				a.Path = ""
			}
			if !a.IncludedIn(mode) {
				a.State = "excluded_by_media_filter"
				continue
			}
			if !a.Due(time.Now()) {
				continue
			}
			// Full-size metadata can fill in an initially unknown size. Check again
			// after resolution before downloading any bytes into memory.
			if a.Size > 64<<20 {
				a.State = "size_not_supported"
				continue
			}
			if budget <= 0 || a.Size > budget {
				a.State = "budget_limit"
				continue
			}
			if a.MediaID == "" || len(a.Key) == 0 {
				if err := c.resolveOriginal(ctx, m.ID, a); err != nil {
					// An upload can finish without a matching live update reaching
					// this waiter. Re-read this message before declaring it failed.
					target := []archive.Message{m}
					_, refreshErr := refreshMedia(ctx, store, c, target, mode, budget)
					m = target[0]
					a = &m.Attachments[i]
					if refreshErr == nil && a.MediaID != "" && len(a.Key) > 0 {
						originalFailures = 0
					} else {
						a.State = "original_request_failed"
						a.RecordFailure(time.Now())
						originalFailures++
						if originalFailures >= 3 {
							if saveErr := store.UpdateMedia(m); saveErr != nil {
								return saveErr
							}
							return fmt.Errorf("three original-media requests failed consecutively; archived text is retained (%s)", diagnostic(err))
						}
						continue
					}
				}
				originalFailures = 0
			}
			if a.Size <= 0 || a.Size > 64<<20 {
				a.State = "size_not_supported"
				continue
			}
			if a.Size > budget {
				a.State = "budget_limit"
				continue
			}
			data, fetchErr := c.GM.DownloadMedia(a.MediaID, a.Key)
			if fetchErr != nil {
				a.State = "download_failed"
				a.RecordFailure(time.Now())
				continue
			}
			if int64(len(data)) > budget {
				a.State = "budget_limit"
				continue
			}
			hash := sha256.Sum256([]byte(m.ID + "\x00" + a.ID + "\x00" + a.MediaID))
			name := hex.EncodeToString(hash[:]) + mediaExtension(*a)
			temp, err := os.CreateTemp(dir, ".download-")
			if err != nil {
				return err
			}
			tempName := temp.Name()
			_, err = temp.Write(data)
			if err == nil {
				err = temp.Sync()
			}
			closeErr := temp.Close()
			if err == nil {
				err = closeErr
			}
			if err == nil {
				err = os.Rename(tempName, filepath.Join(dir, name))
			}
			if err != nil {
				os.Remove(tempName)
				return err
			}
			budget -= int64(len(data))
			a.State = "downloaded_original"
			a.Path = filepath.Join("media", name)
			a.Attempts, a.NextAttempt = 0, 0
			if c.MediaProgress != nil {
				c.MediaProgress("Saved an original attachment.")
			}
		}
		if err = store.UpdateMedia(m); err != nil {
			return err
		}
	}
	return nil
}
func mediaExtension(a archive.Attachment) string {
	if a.IsContact() {
		return ".vcf"
	}
	switch a.MediaType() {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/heic":
		return ".heic"
	case "video/mp4":
		return ".mp4"
	case "application/pdf":
		return ".pdf"
	default:
		return ".bin"
	}
}
